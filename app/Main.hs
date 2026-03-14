{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Main where

import           Control.Monad              (foldM)
import           Control.Monad.State.Strict
import           Data.Int                   (Int32)
import qualified Data.Map.Strict            as M
import qualified Data.Set                   as S
import           Foreign
import           Foreign.C.Types

newtype NodeID = NodeID Int32
    deriving (Eq, Ord, Show, Num)


data NodeKind
    = KSinOsc
    | KOut
    deriving (Eq, Show)

data Connection
    = Audio NodeID Int
    | Param Float
    deriving (Eq, Show)


data UGen
  = SinOsc Connection Connection   -- freq, phase
  | Out Int Connection             -- bus, input
  deriving (Eq, Show)


data NodeSpec = NodeSpec
    { nsID   :: NodeID
    , nsName :: String
    , nsUgen :: UGen
    } deriving (Eq, Show)

data SynthGraph = SynthGraph
    { sgNodes :: M.Map NodeID NodeSpec
    } deriving (Eq, Show)


data SynthState = SynthState
  { ssNextID :: Int32
  , ssGraph  :: SynthGraph
  } deriving (Eq, Show)


type SynthM a = State SynthState a

emptyGraph :: SynthGraph
emptyGraph = SynthGraph M.empty

runSynth :: SynthM a -> SynthGraph
runSynth m = ssGraph (execState m (SynthState 0 emptyGraph))


freshNodeID :: SynthM NodeID
freshNodeID = do
  st <- get
  let n = ssNextID st
  put st { ssNextID = n + 1 }
  pure (NodeID n)

insertNode :: String -> UGen -> SynthM NodeID
insertNode name ugen = do
  nid <- freshNodeID
  st <- get
  let spec  = NodeSpec nid name ugen
      graph = ssGraph st
  put st { ssGraph = graph { sgNodes = M.insert nid spec (sgNodes graph) } }
  pure nid

sinOsc :: Float -> Float -> SynthM NodeID
sinOsc freq phase =
  insertNode "sinOsc" (SinOsc (Param freq) (Param phase))

out :: Int -> NodeID -> SynthM NodeID
out bus src =
  insertNode "out" (Out bus (Audio src 0))

dependencies :: UGen -> [NodeID]
dependencies u = case u of
  SinOsc a b -> deps [a, b]
  Out _ a    -> deps [a]
  where
    deps = foldr step []
    step (Audio nid _) acc = nid : acc
    step (Param _)     acc = acc

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

    step
      :: (S.Set NodeID, S.Set NodeID, [NodeID])
      -> NodeID
      -> Either String (S.Set NodeID, S.Set NodeID, [NodeID])
    step (temp, perm, acc) nid = go temp perm acc nid

    go
      :: S.Set NodeID
      -> S.Set NodeID
      -> [NodeID]
      -> NodeID
      -> Either String (S.Set NodeID, S.Set NodeID, [NodeID])
    go temp perm acc nid
      | nid `S.member` perm = Right (temp, perm, acc)
      | nid `S.member` temp = Left ("Cycle detected at node " ++ show nid)
      | otherwise =
          case M.lookup nid depMap of
            Nothing -> Left ("Unknown node in topoSort: " ++ show nid)
            Just ds -> do
              let temp' = S.insert nid temp
              (temp'', perm', acc') <- foldM
                (\(t, p, a) d -> go t p a d)
                (temp', perm, acc)
                ds
              let tempFinal = S.delete nid temp''
                  permFinal = S.insert nid perm'
              pure (tempFinal, permFinal, nid : acc')



data InputConn
  = FromNode NodeID Int
  | Const Float
  deriving (Eq, Show)

data NodeIR = NodeIR
  { irNodeID   :: NodeID
  , irKind     :: NodeKind
  , irInputs   :: [InputConn]
  , irControls :: [Float]
  } deriving (Eq, Show)

data GraphIR = GraphIR
  { giNodes     :: [NodeIR]
  , giExecOrder :: [NodeID]
  } deriving (Eq, Show)

lowerNode :: NodeSpec -> NodeIR
lowerNode spec =
  case nsUgen spec of
    SinOsc freq phase ->
      NodeIR
        { irNodeID   = nsID spec
        , irKind     = KSinOsc
        , irInputs   = map lowerConn [freq, phase]
        , irControls = [connDefault freq, connDefault phase]
        }

    Out bus input ->
      NodeIR
        { irNodeID   = nsID spec
        , irKind     = KOut
        , irInputs   = [lowerConn input]
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
    { giNodes     = map lowerNode (M.elems (sgNodes g))
    , giExecOrder = order
    }

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

kindTag :: NodeKind -> CInt
kindTag KSinOsc = 1
kindTag KOut    = 2

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
      mapM_ (\(i, v) ->
        c_rt_graph_set_control g (fromIntegral nid) (fromIntegral i) (CFloat v))
        (zip [0 :: Int ..] (irControls node))

    setNodeOrder (i, NodeID nid) =
      c_rt_graph_set_exec_order g (fromIntegral i) (fromIntegral nid)

    wireNode node = do
      let NodeID dst = irNodeID node
      mapM_ (wireInput dst) (zip [0 :: Int ..] (irInputs node))

    wireInput dst (dstPort, conn) =
      case conn of
        FromNode (NodeID src) srcPort ->
          c_rt_graph_connect g
            (fromIntegral src)
            (fromIntegral srcPort)
            (fromIntegral dst)
            (fromIntegral dstPort)
        Const _ ->
          pure ()

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
      mapM_ (\n -> do
        putStrLn ("Block " ++ show n)
        c_rt_graph_process rt 64
        ) [1 :: Int .. 3]

      c_rt_graph_destroy rt
      putStrLn "Done."


