// ================================================================
// rt_graph.h — C ABI
// ================================================================
//
// The runtime exposes an FFI for graph creation, node
// addition, control assignment, connection, and block
// processing.
//
// This header defines the entire surface area between the
// Haskell compiler and the C++ runtime. It is a pure C ABI:
// no C++ types, no templates, no exceptions. Every argument
// is an int or a float; the only opaque type is the RTGraph
// handle itself.
//
// The Haskell side (MetaSonic.FFI) imports these functions
// via `foreign import ccall unsafe` and calls them through
// a strict protocol:
//
//   1. rt_graph_create    — allocate a handle
//   2. rt_graph_clear     — reset for (re)loading
//   3. rt_graph_add_node  — for each node, in execution order
//   4. rt_graph_set_control — for each control on each node
//   5. rt_graph_connect   — for each audio connection
//   6. rt_graph_process   — called repeatedly, once per block
//   7. rt_graph_destroy   — free all owned resources
//
// Steps 2–5 are performed by MetaSonic.FFI.loadRuntimeGraph.
// Steps 1 and 7 are managed by MetaSonic.FFI.withRTGraph via
// bracket-style allocation.
//
// Graph construction and signal execution are distinct computational domains.
// This header is the boundary between them. Nothing above this boundary
// (Haskell types, symbolic NodeIDs, rate annotations, region
// graphs) is visible here. Nothing below it (NodeRuntime,
// process functions, phase accumulators) is visible to Haskell.
//
// The ABI is intentionally narrow so that the two sides can evolve
// independently.
//
// All integer arguments that represent node or port positions
// are dense runtime indices — the values produced by
// MetaSonic.Compile.compileRuntimeGraph after the decisive
// NodeID → NodeIndex transformation. No symbolic identifier
// ever appears in this ABI.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// ----------------------------------------------------------------
// Opaque handle
//
// RTGraph is defined in rt_graph.cpp as a struct owning a
// std::vector<NodeRuntime>. The Haskell side holds it as a
// Ptr RTGraph and never inspects its contents.
//
// Lifetime is managed by create/destroy, with an optional
// clear for reloading without reallocating the handle.
// ----------------------------------------------------------------

typedef struct RTGraph RTGraph;

// ----------------------------------------------------------------
// Lifecycle
// ----------------------------------------------------------------

// Allocate a new runtime graph.
//
//   capacity   — advisory hint for vector pre-allocation.
//                The Haskell side passes the number of nodes
//                in the RuntimeGraph so the C++ vector can
//                reserve storage up front, avoiding reallocation
//                during add_node calls.
//
//   max_frames — maximum block size accepted by rt_graph_process.
//                All output buffers are pre-allocated to this
//                size during configure_node, guaranteeing that
//                the audio processing loop performs no allocation.
//                (ARCHITECTURE.md invariant: "no allocation inside
//                DSP loop.")
RTGraph *rt_graph_create(int capacity, int max_frames);

// Free the graph and all owned resources (node state, buffers).
// Called by MetaSonic.FFI.withRTGraph's bracket finalizer.
void rt_graph_destroy(RTGraph *g);

// Remove all nodes and reset runtime state, preserving the
// handle and its capacity/max_frames configuration. Called by
// MetaSonic.FFI.loadRuntimeGraph before adding the new graph's
// nodes, enabling graph replacement without handle reallocation.
void rt_graph_clear(RTGraph *g);

// ----------------------------------------------------------------
// Graph construction (called at load time, not during audio)
// ----------------------------------------------------------------

// Register a node at a dense runtime index.
//
// Nodes must be added in execution order — the order produced
// by MetaSonic.Validate.topoSort and preserved through
// MetaSonic.Compile.compileRuntimeGraph. The runtime processes
// them in storage order, and storage order equals the
// order in which nodes are added.
//
// node_kind is the integer tag from MetaSonic.Types.kindTag:
//
//   Haskell (MetaSonic.Types)     C++ (rt_graph.cpp)
//   ─────────────────────────     ──────────────────
//   kindTag KSinOsc = 1          SinOsc = 1
//   kindTag KOut    = 2          Out    = 2
//   kindTag KGain   = 3          Gain   = 3
//
// An unrecognized kind prints a diagnostic to stderr and
// leaves the node unconfigured. Under correct compilation
// this should never occur, since the Haskell side only emits
// kind tags for constructors it knows about.
void rt_graph_add_node(RTGraph *g, int node_index, int node_kind);

// Set one control value on a node.
//
// Controls are the fallback parameter values for inputs that
// have no audio-rate connection. They correspond to the
// rnControls field of RuntimeNode in MetaSonic.Compile.
//
// For example, a SinOsc node has two controls:
//   control 0 = frequency (Hz)
//   control 1 = initial phase (0–1)
//
// These are set once at load time by MetaSonic.FFI.loadRuntimeGraph.
// At process time, if an audio input is connected to the same
// port, the input value overrides the control (block-latched
// at sample 0).
void rt_graph_set_control(RTGraph *g, int node_index, int control_index,
                          float value);

// Wire one source output port to one destination input port.
//
// All indices are dense runtime positions — the same values
// that appear in RFrom (NodeIndex n) (PortIndex p) in
// MetaSonic.Compile. The runtime stores them directly in
// the destination node's InputRef without any symbolic lookup.
//
// The runtime should not need to know whether a unit
// arose from one primitive, a fused chain, a vector loop, or
// a cached shared region.  At this level, a connection is
// just two integers pointing into the dense node array.
//
// MetaSonic.FFI.loadRuntimeGraph calls this once for each
// RFrom input in the RuntimeGraph, after all nodes have been
// added (so both endpoints exist in the C++ vector).
void rt_graph_connect(RTGraph *g, int src_index, int src_port, int dst_index,
                      int dst_port);

// ----------------------------------------------------------------
// Audio processing
// ----------------------------------------------------------------

// Execute one audio block of nframes samples.
//
// nframes must be between 0 and max_frames (inclusive).
// The function iterates over the dense node array in storage
// order and dispatches to the appropriate process function
// for each node kind.
//
// This is exactly the kind of linearized traversal
// that SuperNova identifies as efficient for fine-grained
// graphs in the sequential case. The crucial difference is
// that MetaSonic treats this not as a convenient implementation
// shortcut but as the desired target of compilation.
//
// When region-level parallel scheduling is implemented,
// this function will become the entry point for dispatching
// regions to worker threads, while the per-region inner loop
// remains a sequential iteration.
void rt_graph_process(RTGraph *g, int nframes);

#ifdef __cplusplus
}
#endif