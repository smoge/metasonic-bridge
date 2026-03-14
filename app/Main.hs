{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}

module Main where

-- foldM is used for graph traversal algorithms
import Control.Monad (foldM)
-- State monad to build graphs in a functional DSL style
import Control.Monad.State.Strict
-- State monad to build graphs in a functional DSL style
import Data.Int (Int32)
-- Map to store nodes by NodeID
import qualified Data.Map.Strict as M
-- for cycle detection during graph traversal
import qualified Data.Set as S
-- FFI types
import Foreign (Int32, Ptr)
import Foreign.C.Types

------------------------------------------------------------
-- Graph identifiers
------------------------------------------------------------

-- NodeID is a strongly typed identifier for nodes in the graph. Uses Int32 to
-- match the C side
newtype NodeID = NodeID Int32
  deriving (Eq, Ord, Show, Num)

------------------------------------------------------------
-- Node kinds
------------------------------------------------------------

-- Runtime node kinds understood by the C++ engine
data NodeKind
  = KSinOsc
  | KOut
  deriving (Eq, Show)

-- High-level connection model:
--   Audio nid port = take signal from another node output
--   Param x        = constant parameter value
data Connection
  = Audio NodeID Int
  | Param Float
  deriving (Eq, Show)

-- DSL-level node descriptions.
data UGen
  = SinOsc Connection Connection -- freq, phase
  | Out Int Connection -- bus, input
  deriving (Eq, Show)

-- A named node inside the Haskell graph.
data NodeSpec = NodeSpec
  { nsID :: NodeID,
    nsName :: String,
    nsUgen :: UGen
  }
  deriving (Eq, Show)

-- The graph is stored as a map from NodeID to node specification.
data SynthGraph = SynthGraph
  { sgNodes :: M.Map NodeID NodeSpec
  }
  deriving (Eq, Show)

-- State used while building graphs in the DSL.
data SynthState = SynthState
  { ssNextID :: Int32,
    ssGraph :: SynthGraph
  }
  deriving (Eq, Show)

type SynthM a = State SynthState a

emptyGraph :: SynthGraph
emptyGraph = SynthGraph M.empty

-- Run the DSL and extract the final graph
runSynth :: SynthM a -> SynthGraph
runSynth m = ssGraph (execState m (SynthState 0 emptyGraph))

-- Allocate a new node id by incrementing the next ID counter in the state.
freshNodeID :: SynthM NodeID
freshNodeID = do
  st <- get
  let n = ssNextID st
  put st {ssNextID = n + 1}
  pure (NodeID n)

-- Insert a node into the graph under construction with a given name and UGen,
-- returning its NodeID
insertNode :: String -> UGen -> SynthM NodeID
insertNode name ugen = do
  nid <- freshNodeID
  st <- get
  let spec = NodeSpec nid name ugen
      graph = ssGraph st
  put st {ssGraph = graph {sgNodes = M.insert nid spec (sgNodes graph)}}
  pure nid

-- DSL constructor: sine oscillator with constant freq and phase
sinOsc :: Float -> Float -> SynthM NodeID
sinOsc freq phase =
  insertNode "sinOsc" (SinOsc (Param freq) (Param phase))

-- DSL constructor: output signal
out :: Int -> NodeID -> SynthM NodeID
out bus src =
  insertNode "out" (Out bus (Audio src 0))


-- Collect upstream dependencies from a node only audio connections create graph
-- dependencies, params are just constants (for now)
dependencies :: UGen -> [NodeID]
dependencies u = case u of
  SinOsc a b -> deps [a, b]
  Out _ a -> deps [a]
  where
    deps = foldr step []
    step (Audio nid _) acc = nid : acc
    step (Param _) acc = acc

-- Validate that all dependencies exist and that the graph is acyclic
validateGraph :: SynthGraph -> Either String ()
validateGraph g = do
  mapM_ validateNode (M.elems (sgNodes g))
  _ <- topoSort g
  pure ()
  where
    exists nid = M.member nid (sgNodes g)

    validateNode spec =
      mapM_ checkDep (dependencies (nsUgen spec))

    checkDep nid
      | exists nid = Right ()
      | otherwise = Left ("Missing dependency: " ++ show nid)

-- Topological sort with cycle detection
-- Produces the execution order expected by the runtime engine
topoSort :: SynthGraph -> Either String [NodeID]
topoSort g = do
  (_, _, order) <- foldM step (S.empty, S.empty, []) (M.keys (sgNodes g))
  pure (reverse order)
  where
    depMap = M.map (dependencies . nsUgen) (sgNodes g)

    step ::
      (S.Set NodeID, S.Set NodeID, [NodeID]) ->
      NodeID ->
      Either String (S.Set NodeID, S.Set NodeID, [NodeID])
    step (temp, perm, acc) nid = go temp perm acc nid

    go ::
      S.Set NodeID ->
      S.Set NodeID ->
      [NodeID] ->
      NodeID ->
      Either String (S.Set NodeID, S.Set NodeID, [NodeID])
    go temp perm acc nid
      | nid `S.member` perm = Right (temp, perm, acc)
      | nid `S.member` temp = Left ("Cycle detected at node " ++ show nid)
      | otherwise =
          case M.lookup nid depMap of
            Nothing -> Left ("Unknown node in topoSort: " ++ show nid)
            Just ds -> do
              let temp' = S.insert nid temp
              (temp'', perm', acc') <-
                foldM
                  (\(t, p, a) d -> go t p a d)
                  (temp', perm, acc)
                  ds
              let tempFinal = S.delete nid temp''
                  permFinal = S.insert nid perm'
              pure (tempFinal, permFinal, nid : acc')

-- Lowered input connections for the runtime IR
data InputConn
  = FromNode NodeID Int
  | Const Float
  deriving (Eq, Show)

-- Runtime node description sent to C++
data NodeIR = NodeIR
  { irNodeID :: NodeID,
    irKind :: NodeKind,
    irInputs :: [InputConn],
    irControls :: [Float]
  }
  deriving (Eq, Show)

-- Lowered graph: node inventory with execution order
data GraphIR = GraphIR
  { giNodes :: [NodeIR],
    giExecOrder :: [NodeID]
  }
  deriving (Eq, Show)

-- Lower a DSL node into a simpler runtime IR
lowerNode :: NodeSpec -> NodeIR
lowerNode spec =
  case nsUgen spec of
    SinOsc freq phase ->
      NodeIR
        { irNodeID = nsID spec,
          irKind = KSinOsc,
          irInputs = map lowerConn [freq, phase],
          irControls = [connDefault freq, connDefault phase]
        }
    Out bus input ->
      NodeIR
        { irNodeID = nsID spec,
          irKind = KOut,
          irInputs = [lowerConn input],
          irControls = [fromIntegral bus]
        }
  where
    lowerConn c = case c of
      Audio nid port -> FromNode nid port
      Param x -> Const x

    connDefault c = case c of
      Param x -> x
      Audio _ _ -> 0.0

-- Validate, sort, and lower the (haskell-side) graph
lowerGraph :: SynthGraph -> Either String GraphIR
lowerGraph g = do
  validateGraph g
  order <- topoSort g
  pure
    GraphIR
      { giNodes = map lowerNode (M.elems (sgNodes g)),
        giExecOrder = order
      }

-- Opaque runtime graph handle owned by C++
data RTGraph

foreign import ccall unsafe "rt_graph_create"
  c_rt_graph_create :: CInt -> CInt -> IO (Ptr RTGraph)

foreign import ccall unsafe "rt_graph_destroy"
  c_rt_graph_destroy :: Ptr RTGraph -> IO ()

foreign import ccall unsafe "rt_graph_clear"
  c_rt_graph_clear :: Ptr RTGraph -> IO ()

foreign import ccall unsafe "rt_graph_add_node"
  c_rt_graph_add_node :: Ptr RTGraph -> CInt -> CInt -> IO ()

foreign import ccall unsafe "rt_graph_set_control"
  c_rt_graph_set_control :: Ptr RTGraph -> CInt -> CInt -> CFloat -> IO ()

foreign import ccall unsafe "rt_graph_connect"
  c_rt_graph_connect :: Ptr RTGraph -> CInt -> CInt -> CInt -> CInt -> IO ()

foreign import ccall unsafe "rt_graph_set_exec_order"
  c_rt_graph_set_exec_order :: Ptr RTGraph -> CInt -> CInt -> IO ()

foreign import ccall unsafe "rt_graph_process"
  c_rt_graph_process :: Ptr RTGraph -> CInt -> IO ()

-- Convert Haskell node kinds into the integer tags expected by C+
kindTag :: NodeKind -> CInt
kindTag KSinOsc = 1
kindTag KOut = 2

-- Materialize the lowered graph inside the C++ runtime
-- clear graph, add nodes, set schedule... then wire connections
compileGraph :: Ptr RTGraph -> GraphIR -> IO ()
compileGraph g ir = do
  c_rt_graph_clear g

  mapM_ addNode (giNodes ir)
  mapM_ setNodeOrder (zip [0 :: Int ..] (giExecOrder ir))
  mapM_ wireNode (giNodes ir)
  where
    addNode node = do
      let NodeID nid = irNodeID node
      c_rt_graph_add_node g (fromIntegral nid) (kindTag $ irKind node)
      mapM_
        ( \(i, v) ->
            c_rt_graph_set_control g (fromIntegral nid) (fromIntegral i) (CFloat v)
        )
        (zip [0 :: Int ..] (irControls node))

    setNodeOrder (i, NodeID nid) =
      c_rt_graph_set_exec_order g (fromIntegral i) (fromIntegral nid)

    wireNode node = do
      let NodeID dst = irNodeID node
      mapM_ (wireInput dst) (zip [0 :: Int ..] (irInputs node))

    wireInput dst (dstPort, conn) =
      case conn of
        FromNode (NodeID src) srcPort ->
          c_rt_graph_connect
            g
            (fromIntegral src)
            (fromIntegral srcPort)
            (fromIntegral dst)
            (fromIntegral dstPort)
        Const _ ->
          pure ()

-- Minimal example demo graph
simpleGraph :: SynthGraph
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc

main :: IO ()
main = do
  putStrLn "Building graph in Haskell..."
  print simpleGraph

  case lowerGraph simpleGraph of
    Left err -> putStrLn ("Lowering error: " ++ err)
    Right ir -> do
      putStrLn "Lowered IR:"
      print ir

      rt <- c_rt_graph_create 16 64
      compileGraph rt ir

      putStrLn "Processing 3 blocks in C++..."
      mapM_
        ( \n -> do
            putStrLn ("Block " ++ show n)
            c_rt_graph_process rt 64
        )
        [1 :: Int .. 3]

      c_rt_graph_destroy rt
      putStrLn "Done."
