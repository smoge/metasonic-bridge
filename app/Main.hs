{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-# OPTIONS_GHC -Wno-unused-imports #-}

module Main where

import           Control.DeepSeq
import           Control.Exception          (bracket, evaluate)
import           Control.Monad              (foldM, forM_)
import           Control.Monad.State.Strict
import           Data.List
import qualified Data.Map.Strict            as M
import qualified Data.Set                   as S
import           Foreign
import           Foreign.C.Types
import           GHC.Generics               (Generic)

------------------------------------------------------------
-- Strong identifiers on the Haskell side
------------------------------------------------------------

newtype NodeID = NodeID Int
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

newtype NodeIndex = NodeIndex Int
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

newtype PortIndex = PortIndex Int
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (NFData)

newtype ControlIndex = ControlIndex Int
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (NFData)


------------------------------------------------------------
-- Runtime node kinds
------------------------------------------------------------

data NodeKind
  = KSinOsc
  | KOut
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)


kindTag :: NodeKind -> CInt
kindTag KSinOsc = 1
kindTag KOut    = 2

------------------------------------------------------------
-- High-level DSL
------------------------------------------------------------

data Connection
  = Audio !NodeID !PortIndex
  | Param !Float
  deriving (Eq, Show, Generic, NFData)

data UGen
  = SinOsc !Connection !Connection -- freq, phase
  | Out !Int !Connection           -- bus, input
  deriving (Eq, Show, Generic, NFData)

data NodeSpec = NodeSpec
  { nsID   :: !NodeID
  , nsName :: !String
  , nsUgen :: !UGen
  }
  deriving (Eq, Show, Generic, NFData)


data SynthGraph = SynthGraph
  { sgNodes :: !(M.Map NodeID NodeSpec)
  }
  deriving (Eq, Show, Generic, NFData)


data SynthState = SynthState
  { ssNextID :: !Int
  , ssGraph  :: !SynthGraph
  }
  deriving (Eq, Show, Generic, NFData)

type SynthM a = State SynthState a

emptyGraph :: SynthGraph
emptyGraph = SynthGraph M.empty

runSynth :: SynthM a -> SynthGraph
runSynth m = ssGraph (execState m (SynthState 0 emptyGraph))

-- Lazy version (not thread-safe, but simpler to write and read)
-- freshNodeID :: SynthM NodeID
-- freshNodeID = do
--   st <- get
--   let n = ssNextID st
--   put st {ssNextID = n + 1}
--   pure (NodeID n)

-- Strict version
freshNodeID :: SynthM NodeID
freshNodeID = do
  st <- get
  let !n  = ssNextID st
      !n' = n + 1
  put st { ssNextID = n' }
  pure (NodeID n)

insertNode :: String -> UGen -> SynthM NodeID
insertNode name ugen = do
  nid <- freshNodeID
  st <- get
  let spec = NodeSpec nid name ugen
      graph = ssGraph st
  put st {ssGraph = graph {sgNodes = M.insert nid spec (sgNodes graph)}}
  pure nid

sinOsc :: Float -> Float -> SynthM NodeID
sinOsc freq phase =
  insertNode "sinOsc" (SinOsc (Param freq) (Param phase))

out :: Int -> NodeID -> SynthM NodeID
out bus src =
  insertNode "out" (Out bus (Audio src (PortIndex 0)))

------------------------------------------------------------
-- Validation and topological ordering
------------------------------------------------------------

dependencies :: UGen -> [NodeID]
dependencies u = case u of
  SinOsc a b -> deps [a, b]
  Out _ a    -> deps [a]
  where
    deps = foldr step []
    step (Audio nid _) acc = nid : acc
    step (Param _) acc     = acc

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
      | otherwise  = Left ("Missing dependency: " ++ show nid)

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

------------------------------------------------------------
-- Symbolic IR (still uses NodeID)
------------------------------------------------------------

data InputConn
  = FromNode !NodeID !PortIndex
  | Const !Float
  deriving (Eq, Show, Generic, NFData)

data NodeIR = NodeIR
  { irNodeID   :: !NodeID
  , irKind     :: !NodeKind
  , irInputs   :: ![InputConn]
  , irControls :: ![Float]
  }
  deriving (Eq, Show, Generic, NFData)

data GraphIR = GraphIR
  { giNodes     :: ![NodeIR]
  , giExecOrder :: ![NodeID]
  }
  deriving (Eq, Show, Generic, NFData)

lowerNode :: NodeSpec -> NodeIR
lowerNode spec =
  case nsUgen spec of
    SinOsc freq phase ->
      NodeIR
        { irNodeID = nsID spec
        , irKind = KSinOsc
        , irInputs = map lowerConn [freq, phase]
        , irControls = [connDefault freq, connDefault phase]
        }
    Out bus input ->
      NodeIR
        { irNodeID = nsID spec
        , irKind = KOut
        , irInputs = [lowerConn input]
        , irControls = [fromIntegral bus]
        }
  where
    lowerConn c = case c of
      Audio nid port -> FromNode nid port
      Param x        -> Const x

    connDefault c = case c of
      Param x   -> x
      Audio _ _ -> 0.0

lowerGraph :: SynthGraph -> Either String GraphIR
lowerGraph g = do
  validateGraph g
  order <- topoSort g
  pure GraphIR
    { giNodes = map lowerNode (M.elems (sgNodes g))
    , giExecOrder = order
    }

------------------------------------------------------------
-- Compiled runtime graph (dense NodeIndex, no symbolic lookups at runtime)
------------------------------------------------------------

data RuntimeInput
  = RFrom !NodeIndex !PortIndex
  | RConst !Float
  deriving (Eq, Show, Generic, NFData)

data RuntimeNode = RuntimeNode
  { rnIndex      :: !NodeIndex
  , rnOriginalID :: !NodeID
  , rnKind       :: !NodeKind
  , rnInputs     :: ![RuntimeInput]
  , rnControls   :: ![Float]
  }
  deriving (Eq, Show, Generic, NFData)


data RuntimeGraph = RuntimeGraph
  { rgNodes :: ![RuntimeNode]
  }
  deriving (Eq, Show, Generic, NFData)

compileRuntimeGraph :: GraphIR -> Either String RuntimeGraph
compileRuntimeGraph ir = do
  let !execOrder = giExecOrder ir
      !indexMap =
        M.fromList (zipWith (\i nid -> (nid, NodeIndex i)) [0..] execOrder)
      !nodeMap =
        M.fromList [(irNodeID n, n) | n <- giNodes ir]
      indexedOrder =
        zipWith (\i nid -> (NodeIndex i, nid)) [0..] execOrder

  nodes <- mapM (compileNode indexMap nodeMap) indexedOrder
  let !rg = RuntimeGraph nodes
  pure rg
  where
    compileNode indexMap nodeMap (ix, nid) = do
      node <-
        maybe
          (Left ("Missing node in compileRuntimeGraph: " ++ show nid))
          Right
          (M.lookup nid nodeMap)

      inputs <- mapM (compileInput indexMap) (irInputs node)

      let !rtNode = RuntimeNode
            { rnIndex      = ix
            , rnOriginalID = nid
            , rnKind       = irKind node
            , rnInputs     = inputs
            , rnControls   = irControls node
            }
      pure rtNode

    compileInput indexMap inp =
      case inp of
        Const x ->
          Right (RConst x)

        FromNode src port ->
          case M.lookup src indexMap of
            Nothing ->
              Left ("Missing runtime index for source node " ++ show src)
            Just ix ->
              Right (RFrom ix port)



------------------------------------------------------------
-- FFI layer
------------------------------------------------------------

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

foreign import ccall unsafe "rt_graph_process"
  c_rt_graph_process :: Ptr RTGraph -> CInt -> IO ()

withRTGraph :: Int -> Int -> (Ptr RTGraph -> IO a) -> IO a
withRTGraph capacity maxFrames =
  bracket
    (c_rt_graph_create (fromIntegral capacity) (fromIntegral maxFrames))
    c_rt_graph_destroy

cNodeIndex :: NodeIndex -> CInt
cNodeIndex (NodeIndex x) = fromIntegral x

cPortIndex :: PortIndex -> CInt
cPortIndex (PortIndex x) = fromIntegral x

cControlIndex :: ControlIndex -> CInt
cControlIndex (ControlIndex x) = fromIntegral x

loadRuntimeGraph :: Ptr RTGraph -> RuntimeGraph -> IO ()
loadRuntimeGraph g rg = do
  c_rt_graph_clear g
  mapM_ addNode (rgNodes rg)
  mapM_ wireNode (rgNodes rg)
  where
    addNode node = do
      c_rt_graph_add_node g (cNodeIndex (rnIndex node)) (kindTag (rnKind node))
      forM_ (zipWith (\i v -> (ControlIndex i, v)) [0 ..] (rnControls node)) $ \(ci, v) ->
        c_rt_graph_set_control g (cNodeIndex (rnIndex node)) (cControlIndex ci) (CFloat v)

    wireNode node =
      forM_ (zipWith (\i inp -> (PortIndex i, inp)) [0 ..] (rnInputs node)) $ \(dstPort, inp) ->
        case inp of
          RFrom src srcPort ->
            c_rt_graph_connect
              g
              (cNodeIndex src)
              (cPortIndex srcPort)
              (cNodeIndex (rnIndex node))
              (cPortIndex dstPort)
          RConst _ ->
            pure ()

------------------------------------------------------------
-- Demo
------------------------------------------------------------

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
    Right ir0 -> do
      ir <- evaluate (force ir0)
      putStrLn "Lowered symbolic IR:"
      print ir

      case compileRuntimeGraph ir of
        Left err -> putStrLn ("Runtime compilation error: " ++ err)
        Right rg0 -> do
          rg <- evaluate (force rg0)
          putStrLn "Compiled runtime graph:"
          print rg

          withRTGraph 16 64 $ \rt -> do
            loadRuntimeGraph rt rg

            putStrLn "Processing 3 blocks in C++..."
            mapM_
              (\n -> do
                  putStrLn ("Block " ++ show n)
                  c_rt_graph_process rt 64)
              [1 :: Int .. 3]

          putStrLn "Done."
