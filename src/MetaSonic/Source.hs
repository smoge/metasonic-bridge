{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}

-- |
-- Module      : MetaSonic.Source
-- Description : Source-level graph construction DSL
--
-- The user-facing language for building synthesis graphs.
-- This module is entirely surface syntax — it records the
-- user's intent without computing what the graph means.
--
-- See Note [Surface syntax vs semantic syntax] for how this
-- module relates to the deeper compilation passes.
--
-- See Note [Builder monad design] for why graph construction
-- uses strict State rather than a free monad.

module MetaSonic.Source
  ( -- * Source-level types
    Connection (..)
  , UGen (..)
  , NodeSpec (..)
  , SynthGraph (..)
  , emptyGraph
  , -- * Builder monad
    SynthM
  , runSynth
  , -- * DSL combinators
    sinOsc
  , out
  , gain
  , -- * Dependency extraction
    dependencies
  ) where

import           Control.DeepSeq            (NFData)
import           Control.Monad              (void)
import           Control.Monad.State.Strict
import qualified Data.Map.Strict            as M
import           GHC.Generics               (Generic)

import           MetaSonic.Types

{- Note [Surface syntax vs semantic syntax]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
One can distinguish surface syntax (what the user writes)
from semantic syntax (the compiler's internal account of signal
equations, state transitions, staging boundaries, and resource
constraints).

This module is entirely surface syntax:

  - UGen constructors (SinOsc, Out, Gain) name DSP primitives
  - Connection values (Audio, Param) describe wiring
  - SynthGraph is an unordered map of node specifications
  - No rates, no effects, no execution order

The semantic account begins in MetaSonic.IR, where lowerGraph
strips the DSL vocabulary and annotates each node with Rate
and Eff metadata. A future MetaSonic.Semantic module would go
further, deriving signal expressions by symbolic propagation
(following Faust's strategy) rather than preserving node
granularity.

See Note [Rate discipline] in MetaSonic.Types for the
annotation system that the IR introduces.
-}

{- Note [Connection design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
A Connection is the atomic unit of wiring in the source graph.
It is either an audio-rate edge from another node's output
port (Audio NodeID PortIndex), or a literal parameter value
(Param Float).

This distinction matters for compilation:

  - A Param is a compile-time constant. It carries no
    dependency, imposes no execution ordering, and will be
    lowered to a control slot in the C++ runtime.

  - An Audio connection creates a data dependency: the source
    node must be computed before the destination node. This
    dependency is extracted by the dependencies function and
    drives topological sorting in MetaSonic.Validate.

Every UGen input is uniformly a Connection, which means the
compiler can extract the dependency graph from UGen structure
alone — no special cases, no implicit wiring.

See Note [Structural vs implicit dependencies] for how this
relates to the effect-dependency system.
-}

{- Note [Structural vs implicit dependencies]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The dependencies function extracts only structural
dependencies — the explicit Audio edges drawn by the user.
Param values are dependency-free.

This is sufficient for topological sorting and for the current
sequential runtime, but it is not sufficient for correct
parallel execution.

Semantically schedulable graph must also include implicit
dependencies derived from resource effects:

  G* = (N, E_s ∪ E_r ∪ E_t)

where E_s are structural edges (what dependencies extracts),
E_r are resource-induced edges, and E_t are temporal or
rate-boundary edges.

Implicit dependencies are computed later, after annotation, in
a future MetaSonic.Effects module using the Eff annotations on
NodeIR. At this level (source syntax), we extract only E_s.

See Note [Resource effects] in MetaSonic.Types.
-}

-- | A connection to a node input: either an audio edge from
-- another node's output, or a literal constant.
--
-- See Note [Connection design].
data Connection
  = Audio !NodeID !PortIndex
    -- ^ An audio-rate edge. Creates a data dependency that
    -- constrains execution order.
  | Param !Float
    -- ^ A literal parameter value. No dependency; known at
    -- graph construction time.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

{- Note [UGen extensibility]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Each UGen constructor defines a DSP primitive. The
constructor's fields are Connections, not raw values — every
input is uniformly either a constant or a dependency.

The current set is minimal:

  SinOsc  — sine oscillator (stateful: phase accumulator)
  Out     — output bus writer (stateless passthrough)
  Gain    — multiply by scalar (stateless)

Adding a new UGen constructor requires changes across both
languages. See Note [Adding a new node kind] in
MetaSonic.Types for the complete checklist.

Future extensions include:

  - Filters (BiquadFilter — stateful, constrains fusion)
  - Envelopes (EnvGen — block-rate, forces rate boundaries)
  - Delay lines (Delay — stateful, introduces recursion)
  - Bus input (In — carries BusRead effect)

Each addition makes the compilation pipeline richer: filters
test state-aware region formation, envelopes test multi-rate
compilation, delay lines test recursive semantics, and bus
I/O tests effect-aware dependency analysis.
-}

-- | A unit generator specification. Each constructor carries
-- its connections as positional fields.
--
-- See Note [UGen extensibility].
data UGen
  = SinOsc !Connection !Connection
    -- ^ Sine oscillator: frequency, initial phase.
    -- Sample-rate, stateful (phase accumulator persists
    -- across blocks).
  | Out !Int !Connection
    -- ^ Output node: bus index, input signal.
    -- Sample-rate, currently a stateless passthrough.
    -- Will carry a BusWrite effect when buses become real
    -- shared resources.
    -- See Note [Resource effects] in MetaSonic.Types.
  | Gain !Connection !Connection
    -- ^ Multiply: input signal, gain amount.
    -- Sample-rate, stateless. The simplest fusable node.
    -- See Note [Region formation] in MetaSonic.Compile.
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | A node in the source graph: a named UGen at a
-- particular symbolic identity.
data NodeSpec = NodeSpec
  { nsID   :: !NodeID
  , nsName :: !String
    -- ^ Human-readable label (for debugging / printing).
  , nsUgen :: !UGen
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | The source graph: a map from symbolic 'NodeID' to
-- 'NodeSpec'. Order is not yet fixed — that is the job of
-- topological sorting in "MetaSonic.Validate".
--
-- See Note [Topological sort as compilation target] in
-- MetaSonic.Validate.
data SynthGraph = SynthGraph
  { sgNodes :: !(M.Map NodeID NodeSpec)
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

emptyGraph :: SynthGraph
emptyGraph = SynthGraph M.empty

{- Note [Builder monad design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Graph construction is a compilation activity, not a real-time
activity. The builder monad is a strict State transformer that
allocates fresh NodeIDs and accumulates NodeSpecs into a
SynthGraph.

The choice of strict State (rather than a free monad or a
Writer) is pragmatic:

  - Strict State with BangPatterns ensures the counter and
    graph are fully evaluated at each step. No thunks
    accumulate during the build phase.

  - The monadic interface (do-notation, fresh ID allocation,
    returning NodeID for downstream wiring) is natural for
    graph construction where nodes refer to earlier nodes.

  - The underlying idea is still algebraic: a synthesis graph
    is formed by composing primitives and introducing named
    dependencies between them.

The source DSL can be reformulated as a typed algebra over signal
combinators rather than only as a node-building API. That allows more
static rejection of ill-typed graphs and cleaner elaboration into
semantic IR. Currently, sinOsc, out, and gain each produce a
single primitive node; higher-level combinators (chain,
parallel, mix) would elaborate down to this level.
-}

data SynthState = SynthState
  { ssNextID :: !Int
  , ssGraph  :: !SynthGraph
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | The graph builder monad. Strict 'State' over a counter
-- and accumulating 'SynthGraph'.
--
-- See Note [Builder monad design].
type SynthM a = State SynthState a

-- | Run a graph builder and extract the resulting
-- 'SynthGraph'. The builder's return value is discarded;
-- the graph is the product.
runSynth :: SynthM a -> SynthGraph
runSynth m = ssGraph (execState m (SynthState 0 emptyGraph))

-- | Allocate a fresh 'NodeID'. Strict in the counter to
-- avoid thunk accumulation.
freshNodeID :: SynthM NodeID
freshNodeID = do
  st <- get
  let !n  = ssNextID st
      !n' = n + 1
  put st { ssNextID = n' }
  pure (NodeID n)

-- | Register a node in the graph. Shared implementation
-- behind all DSL combinators.
insertNode :: String -> UGen -> SynthM NodeID
insertNode name ugen = do
  nid <- freshNodeID
  st  <- get
  let !spec  = NodeSpec nid name ugen
      !graph = ssGraph st
      !nodes = M.insert nid spec (sgNodes graph)
  put st { ssGraph = graph { sgNodes = nodes } }
  pure nid

{- Note [DSL combinator design]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Each combinator constructs a single node and returns its
NodeID, which can then be passed as a Connection to downstream
nodes:

  do osc <- sinOsc 440.0 0.0
     g   <- gain osc 0.5
     out 0 g

The returned NodeID is the handle that the caller uses to wire
this node's output into other nodes' inputs. This is the
"named dependency" pattern: every dependency is explicit and
named.

Currently the combinators take raw Floats and produce Param
connections internally. A future typed DSL could distinguish
audio-rate signals from control-rate signals at the type
level, preventing wiring errors statically rather than
catching them in checkRateEdges (MetaSonic.IR).

Higher-level combinators (chain, parallel, mix, templates)
would elaborate down to these primitives, making the
elaboration pass a meaningful transformation rather
than identity.
-}

-- | Create a sine oscillator with a fixed frequency and
-- initial phase.
sinOsc :: Float -> Float -> SynthM NodeID
sinOsc freq phase =
  insertNode "sinOsc" (SinOsc (Param freq) (Param phase))

-- | Create an output node that writes a signal to a bus.
-- out :: Int -> NodeID -> SynthM NodeID
-- out bus src =
--   insertNode "out" (Out bus (Audio src (PortIndex 0)))
--
-- Note: out creates a sink node, so it is terminal by design:
out :: Int -> NodeID -> SynthM ()
out bus src =
  void $ insertNode "out" (Out bus (Audio src (PortIndex 0)))

-- | Create a gain node: multiply an input signal by a
-- scalar amount. Stateless, sample-rate, and the simplest
-- candidate for fusion.
--
-- See Note [Region formation] in MetaSonic.Compile.
gain :: NodeID -> Float -> SynthM NodeID
gain src amount =
  insertNode "gain" (Gain (Audio src (PortIndex 0)) (Param amount))

-- | Extract all 'NodeID' dependencies from a 'UGen'.
-- Only 'Audio' connections contribute; 'Param' values are
-- dependency-free.
--
-- See Note [Structural vs implicit dependencies].
dependencies :: UGen -> [NodeID]
dependencies = \case
  SinOsc a b -> deps [a, b]
  Out _ a    -> deps [a]
  Gain a b   -> deps [a, b]
  where
    deps = foldr step []
    step (Audio nid _) acc = nid : acc
    step (Param _)     acc = acc
