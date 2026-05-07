-- |
-- Module      : MetaSonic.FFI
-- Description : Transfer compiled graphs to the C++ runtime
--
-- The border crossing between the Haskell compiler and the
-- C++ runtime. Only dense, fully compiled structure crosses
-- this boundary.
--
-- See Note [FFI boundary design] for the protocol.
-- See Note [Two-pass loading] for why loadRuntimeGraph uses
-- separate add and wire passes.

module MetaSonic.FFI
  ( -- * Opaque handle
    RTGraph
  , -- * Lifecycle
    withRTGraph
  , -- * Loading a compiled graph
    loadRuntimeGraph
  , -- * Low-level (re-exported for tests / experimentation)
    c_rt_graph_process
  ) where

import           Control.Exception (bracket)
import           Control.Monad     (forM_)
import           Foreign
import           Foreign.C.Types

import           MetaSonic.Compile (RuntimeGraph (..), RuntimeInput (..),
                                    RuntimeNode (..))
import           MetaSonic.Types

{- Note [FFI boundary design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
On the Haskell side, the graph is a rich, typed, annotated
structure with symbolic identities, rate tags, effect
annotations, and region membership. On the C++ side, it is a
flat array of execution units with dense index references.

This module translates between those two worlds through a
small C ABI defined in rt_graph.h:

  rt_graph_create      — allocate a runtime graph handle
  rt_graph_destroy     — free all owned resources
  rt_graph_clear       — reset for reloading
  rt_graph_add_node    — register a node at a dense index
  rt_graph_set_control — set a control value
  rt_graph_connect     — wire one output port to one input
  rt_graph_process     — execute one audio block

The protocol is:

  1. rt_graph_create(capacity, max_frames)
  2. For each node in execution order:
     a. rt_graph_add_node(g, index, kind)
     b. rt_graph_set_control(g, index, slot, value)
  3. For each connection:
     rt_graph_connect(g, src, src_port, dst, dst_port)
  4. Repeat: rt_graph_process(g, nframes)
  5. rt_graph_destroy(g)

Steps 2–3 are performed by loadRuntimeGraph.
Steps 1 and 5 are managed by withRTGraph via bracket.

The integer-based wire format (node kinds as ints, indices as
ints, controls as floats) is deliberately simple: it avoids
any C++ types in the ABI, ensuring that the boundary is
portable and trivially serializable.

All functions except create return void. If something fails
on the C++ side (bad index, unknown kind), it prints to
stderr and continues. Failure belongs to compilation",
this is upheld by construction: if the Haskell
compiler produces a valid RuntimeGraph, no error paths in
this ABI should trigger. A future improvement would return
error codes or use a shared error buffer.

See Note [Dense lowering] in MetaSonic.Compile for what
guarantees the indices are valid.
-}

{- Note [Unsafe foreign calls]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
All foreign imports use ccall unsafe. This is correct because:

  1. The C++ functions do not call back into Haskell.
  2. They are short-lived (no blocking, no I/O waits).

The unsafe annotation avoids the overhead of saving and
restoring Haskell's runtime state across the call boundary.
This matters most for rt_graph_process, which is the only
function that performs actual DSP computation and may be
called at audio-callback frequency.

If a future C++ function needs to call back into Haskell
(e.g., for a user-defined UGen callback), it must be
imported as ccall safe instead. Do not change existing
imports to safe without measuring the overhead.
-}

{- Note [Two-pass loading]
~~~~~~~~~~~~~~~~~~~~~~~~~~
loadRuntimeGraph proceeds in two passes:

  Pass 1 — add nodes:
    Register each RuntimeNode at its dense index with the
    correct kind tag (via rt_graph_add_node) and set each
    control to its default value (via rt_graph_set_control).

  Pass 2 — wire connections:
    For each RFrom input on each node, emit a rt_graph_connect
    call linking the source output port to the destination
    input port.

The two-pass structure is necessary because rt_graph_connect
requires both the source and destination nodes to already
exist in the C++ graph. Since nodes are added in execution
order (source before destination, guaranteed by
Note [Execution order invariant] in MetaSonic.IR), pass 1
ensures all endpoints exist before pass 2 wires them.

RConst inputs do not generate connect calls. Their values
are already set as control defaults in pass 1.

After loadRuntimeGraph completes, the C++ runtime owns a
fully configured graph. The Haskell RuntimeGraph can be
discarded (though we keep it for debugging and for potential
re-loading after graph mutation).
-}

-- | Opaque handle to the C++ runtime graph. The Haskell
-- side never inspects its contents.
--
-- See Note [FFI boundary design].
data RTGraph

-- Foreign imports.
-- See Note [Unsafe foreign calls].

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

-- | Allocate a C++ runtime graph, run an action with it,
-- and guarantee cleanup via bracket.
--
-- The @capacity@ parameter is an advisory hint for vector
-- pre-allocation; @maxFrames@ is the maximum block size
-- accepted by @rt_graph_process@.
--
-- See Note [FFI boundary design].
withRTGraph :: Int -> Int -> (Ptr RTGraph -> IO a) -> IO a
withRTGraph capacity maxFrames =
  bracket
    (c_rt_graph_create (fromIntegral capacity) (fromIntegral maxFrames))
    c_rt_graph_destroy

{- Note [Marshaling newtypes to C]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
cNodeIndex, cPortIndex, and cControlIndex convert Haskell
newtypes to CInt for the FFI. The conversions are all
fromIntegral on Int → CInt, which is safe for the index
ranges we operate in (graph sizes are far below 2^31).

These helpers exist to keep the loadRuntimeGraph code
readable and to ensure that the nominal distinction between
NodeIndex, PortIndex, and ControlIndex is maintained up to
the FFI call site. Without them, it would be easy to
accidentally pass a NodeIndex where a PortIndex is expected,
since both unwrap to Int.

See Note [Symbolic vs dense identifiers] in MetaSonic.Types.
-}

cNodeIndex :: NodeIndex -> CInt
cNodeIndex (NodeIndex x) = fromIntegral x

cPortIndex :: PortIndex -> CInt
cPortIndex (PortIndex x) = fromIntegral x

cControlIndex :: ControlIndex -> CInt
cControlIndex (ControlIndex x) = fromIntegral x

-- | Transfer a compiled 'RuntimeGraph' to the C++ runtime.
-- Clears any existing graph state first, then adds nodes
-- and wires connections.
--
-- See Note [Two-pass loading].
-- See Note [FFI boundary design].
loadRuntimeGraph :: Ptr RTGraph -> RuntimeGraph -> IO ()
loadRuntimeGraph g rg = do
  c_rt_graph_clear g
  -- Pass 1: add nodes and set control values.
  -- See Note [Two-pass loading].
  mapM_ addNode  (rgNodes rg)
  -- Pass 2: wire connections (all nodes now exist).
  mapM_ wireNode (rgNodes rg)
  where
    addNode :: RuntimeNode -> IO ()
    addNode node = do
      c_rt_graph_add_node g
        (cNodeIndex (rnIndex node))
        (kindTag    (rnKind  node))
      forM_ (zip [0..] (rnControls node)) $ \(i, v) ->
        c_rt_graph_set_control g
          (cNodeIndex    (rnIndex node))
          (cControlIndex (ControlIndex i))
          (CFloat v)

    wireNode :: RuntimeNode -> IO ()
    wireNode node =
      forM_ (zip [0..] (rnInputs node)) $ \(i, inp) ->
        case inp of
          RFrom src srcPort ->
            c_rt_graph_connect g
              (cNodeIndex src)
              (cPortIndex srcPort)
              (cNodeIndex (rnIndex node))
              (cPortIndex (PortIndex i))
          RConst _ ->
            pure ()
