// ================================================================
// rt_graph.cpp — runtime
// ================================================================
//
// The current runtime model is intentionally minimal. A compiled graph is
// transferred to C++ through a small C ABI, nodes are stored in a contiguous
// vector, and processing traverses the vector in storage order.
//
// This file is the C++ side of MetaSonic. It receives a fully compiled graph
// from the Haskell compiler (MetaSonic.FFI) and executes it. It performs:
//
//   - no symbolic lookup
//   - no dependency resolution
//   - no scheduling
//   - no allocation on the audio path
//
// These are not missing features. They are the visible consequence of the
// compilation principle: if the Haskell side has already validated the graph,
// established execution order, resolved all symbolic identities into dense
// indices, and transferred the result through the FFI, then the runtime's only
// job is to iterate and compute.
//
// This prototype should not be misunderstood as 'merely a simple graph
// evaluator.' Its simplicity is structural. It demonstrates that a dense
// runtime can remain almost trivial if symbolic work is discharged before the
// FFI boundary.
//
// The runtime currently implements three node kinds: SinOsc, Out, and Gain.
// Each is a self-contained process function that reads inputs by dense index,
// writes to a pre-allocated output buffer, and maintains whatever state the
// node requires. Adding a new node kind requires:
//
//   1. A NodeKind enum value here
//   2. A configure_node case here
//   3. A process_* function here
//   4. A dispatch case in rt_graph_process here
//   5. A kindTag case in MetaSonic.Types (Haskell)
//   6. A UGen constructor in MetaSonic.Source (Haskell)
//   7. Lowering cases in MetaSonic.IR (Haskell)
//
// NOTE: When kernel fusion is implemented, this list will change: the compiler
// will generate composite kernels that do not correspond to a single predefined
// node kind, and the runtime will execute fused regions rather than individual
// nodes.
//
// NOTE: The dispatch loop in rt_graph_process will remain structurally
// identical — it will still iterate over a dense array in storage order — but
// the meaning of "unit" will change from "one node" to "one compiled region."

#include "rt_graph.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <numbers>
#include <span>
#include <vector>

namespace {

// ----------------------------------------------------------------
// Constants
// ----------------------------------------------------------------

constexpr float kSampleRate = 48000.0f;

// ----------------------------------------------------------------
// Dense index types
//
// NodeID, NodeIndex, PortIndex, and ControlIndex are represented as distinct
// newtypes, preserving nominal distinctions between otherwise integer-like
// identifiers.
//
// The Haskell side defines these as newtypes in MetaSonic.Types. The C++ side
// mirrors those types with separate structs. The two languages agree on what
// each integer means — by convention, not by a shared type definition, but the
// convention is enforced by identical nominal wrapping on both sides.
//
// After dense lowering (MetaSonic.Compile.compileRuntimeGraph), the only
// identifiers that cross the FFI boundary are these positional indices. No
// symbolic NodeID survives.
// ----------------------------------------------------------------

struct NodeIndex {
  int value = -1;
};

struct PortIndex {
  int value = -1;
};

struct ControlIndex {
  int value = -1;
};

[[nodiscard]] constexpr bool valid(NodeIndex x) noexcept {
  return x.value >= 0;
}
[[nodiscard]] constexpr bool valid(PortIndex x) noexcept {
  return x.value >= 0;
}
[[nodiscard]] constexpr bool valid(ControlIndex x) noexcept {
  return x.value >= 0;
}

[[nodiscard]] constexpr std::size_t to_size(NodeIndex x) noexcept {
  return static_cast<std::size_t>(x.value);
}
[[nodiscard]] constexpr std::size_t to_size(PortIndex x) noexcept {
  return static_cast<std::size_t>(x.value);
}
[[nodiscard]] constexpr std::size_t to_size(ControlIndex x) noexcept {
  return static_cast<std::size_t>(x.value);
}

// ----------------------------------------------------------------
// Node classification
//
// Each enum value corresponds to a kindTag value in MetaSonic.Types. The
// integer tags are the wire format of the C ABI — the only place where the two
// languages must agree numerically.
//
//   Haskell (MetaSonic.Types)     C++ (rt_graph.cpp)
//   ─────────────────────────     ──────────────────
//   kindTag KSinOsc = 1          SinOsc = 1
//   kindTag KOut    = 2          Out    = 2
//   kindTag KGain   = 3          Gain   = 3
//
// Adding a new node kind means adding a value here and a corresponding kindTag
// case in Haskell. The two must stay in sync manually; there is no shared
// header.
//
// Future improvement could generate one side from the other automatically.
// ----------------------------------------------------------------

enum class NodeKind : int {
  SinOsc = 1,
  Out = 2,
  Gain = 3,
};

// ----------------------------------------------------------------
// Input references
//
// An InputRef is the C++ analog of RuntimeInput (RFrom) in MetaSonic.Compile.
// It records which node and port to read from. The 'connected' flag
// distinguishes a wired input from an unwired one; unwired inputs fall back to
// the node's control value.
//
// All references are dense indices into the node vector. No symbolic lookup
// occurs at resolve time.
// ----------------------------------------------------------------

struct InputRef {
  NodeIndex src_node{};
  PortIndex src_port{};
  bool connected = false;
};

// ----------------------------------------------------------------
// Per-node state
//
// SinOscState holds the phase accumulator for a sine oscillator. State persists
// across audio blocks — this is the runtime-side expression of the
// documentation observation that a signal is not merely "a stream of numbers"
// but may carry temporal state.
//
// Stateless nodes (Out, Gain) require no per-node state beyond their output
// buffer. This distinction matters for future region formation: stateful nodes
// constrain fusion because their state creates loop-carried dependencies, while
// stateless nodes can be freely fused or reordered within a region.
// ----------------------------------------------------------------

struct SinOscState {
  float phase = 0.0f;
  bool phase_initialized = false;
};

// ----------------------------------------------------------------
// NodeRuntime: the runtime representation of a single node
//
// This is what the dense array actually stores. Each entry owns its control
// values, input references, output buffers, and any node-specific state.
//
// The runtime should not need to know whether a unit arose from one primitive,
// a fused chain, a vector loop, or a cached shared region. It should execute
// dense units and maintain associated state.
//
// Currently, each NodeRuntime corresponds to one IR node (one NodeIR in
// MetaSonic.IR). After fusion, a single NodeRuntime (or its successor type) may
// correspond to an entire compiled region.
// ----------------------------------------------------------------

struct NodeRuntime {
  NodeKind kind = NodeKind::Out;
  std::vector<float> controls;
  std::vector<InputRef> input_refs;
  std::vector<std::vector<float>> outputs;
  SinOscState sinosc{};
};

// ----------------------------------------------------------------
// Buffer access helpers
//
// output_span returns a view into a node's output buffer, sized to exactly
// nframes. This avoids copies and keeps the process functions zero-allocation.
// ----------------------------------------------------------------

[[nodiscard]] static std::span<float>
output_span(NodeRuntime &node, PortIndex port, int nframes) noexcept {
  return {node.outputs[to_size(port)].data(),
          static_cast<std::size_t>(nframes)};
}

[[nodiscard]] static std::span<const float>
output_span(const NodeRuntime &node, PortIndex port, int nframes) noexcept {
  return {node.outputs[to_size(port)].data(),
          static_cast<std::size_t>(nframes)};
}

// ----------------------------------------------------------------
// Input resolution
//
// resolve_input follows an InputRef to the source node's output buffer. It
// returns an empty span if the input is not connected or if any index is out of
// range.
//
// This is the runtime-side expression of the compiled connection: where the
// Haskell side wrote RFrom (NodeIndex 0) (PortIndex 0) and MetaSonic.FFI
// translated that into a rt_graph_connect call, this function chases the
// resulting InputRef at process time.
//
// The function performs bounds checking defensively, but under correct
// compilation none of these checks should ever fail — the Haskell compiler has
// already validated referential integrity
// (MetaSonic.Validate.checkDependencies) and produced dense indices within
// range (MetaSonic.Compile.compileRuntimeGraph).
// ----------------------------------------------------------------

[[nodiscard]] static std::span<const float>
resolve_input(const std::vector<NodeRuntime> &nodes, const NodeRuntime &dst,
              PortIndex input_index, int nframes) noexcept {
  if (!valid(input_index)) {
    return {};
  }

  const std::size_t idx = to_size(input_index);
  if (idx >= dst.input_refs.size()) {
    return {};
  }

  const InputRef &ref = dst.input_refs[idx];
  if (!ref.connected || !valid(ref.src_node) || !valid(ref.src_port)) {
    return {};
  }

  const std::size_t src_index = to_size(ref.src_node);
  if (src_index >= nodes.size()) {
    return {};
  }

  const NodeRuntime &src = nodes[src_index];
  const std::size_t src_port = to_size(ref.src_port);
  if (src_port >= src.outputs.size()) {
    return {};
  }

  if (src.outputs[src_port].size() < static_cast<std::size_t>(nframes)) {
    return {};
  }

  return output_span(src, ref.src_port, nframes);
}

// ----------------------------------------------------------------
// Node configuration
//
// configure_node sets up a NodeRuntime for a given kind: control slots, input
// refs, and output buffers. This is called once during graph loading (from
// rt_graph_add_node), never during audio processing.
//
// The configuration reflects the node's interface contract:
//
//   SinOsc: 2 controls [freq, phase], 2 inputs, 1 output
//   Out:    1 control  [bus],          1 input,  1 output
//   Gain:   1 control  [amount],       2 inputs, 1 output
//
// Output buffers are pre-allocated to max_frames. This guarantees that the
// audio processing loop performs no allocation — one of the runtime invariants
// listed in ARCHITECTURE.md: no allocation inside DSP loop
// ----------------------------------------------------------------

static void configure_node(NodeRuntime &node, NodeKind kind, int max_frames) {
  node.kind = kind;
  node.controls.clear();
  node.input_refs.clear();
  node.outputs.clear();
  node.sinosc = {};

  switch (kind) {
  case NodeKind::SinOsc:
    node.controls.resize(2, 0.0f); // [freq, initial_phase]
    node.input_refs.resize(2);     // [freq_in, phase_in]
    node.outputs.resize(1);
    break;

  case NodeKind::Out:
    node.controls.resize(1, 0.0f); // [bus]
    node.input_refs.resize(1);     // [signal_in]
    node.outputs.resize(1);
    break;

  case NodeKind::Gain:
    node.controls.resize(1, 1.0f); // [gain_amount] default = unity gain
    node.input_refs.resize(2);     // [signal_in, gain_in]
    node.outputs.resize(1);
    break;
  }

  for (auto &out : node.outputs) {
    out.resize(static_cast<std::size_t>(max_frames), 0.0f);
  }
}

// ================================================================
// Process functions
//
// Each process function implements one DSP kernel. The pattern is the same for
// every node kind:
//
//   1. Get a writable span of the output buffer
//   2. Resolve input connections (may return empty span)
//   3. Read the effective parameter: connected input
//      (block-latched at sample 0) or fallback control
//   4. Compute nframes output samples
//
// The current prototype implements a simple block- latched discipline: incoming
// modulation signals override controls using the first sample of the block.
//
// This is visible in every process function as the pattern:
//   const float x = !input.empty() ? input[0] : node.controls[N];
//
// Block-latching is a prototype constraint, not an architectural one. When
// kernel fusion compiles tightly coupled nodes into a single sample loop,
// modulation edges can be resolved per-sample within the fused region, yielding
// the "sample semantics locally" layer of the timing model described (see
// docs).
//
// ================================================================

// ----------------------------------------------------------------
// SinOsc: sine oscillator
//
// Sample-rate, stateful. The phase accumulator persists across blocks in
// SinOscState. Frequency and initial phase can be overridden by connected
// inputs at block rate.
//
// On the Haskell side, SinOsc is constructed by the sinOsc combinator in
// MetaSonic.Source, lowered to KSinOsc in MetaSonic.IR, and transferred as
// kindTag 1 through MetaSonic.FFI.
// ----------------------------------------------------------------

static void process_sinosc(std::vector<NodeRuntime> &nodes,
                           std::size_t node_idx, int nframes) noexcept {
  NodeRuntime &node = nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto freq_in = resolve_input(nodes, node, PortIndex{0}, nframes);
  const auto phase_in = resolve_input(nodes, node, PortIndex{1}, nframes);

  // Block-latched parameter resolution:
  //
  // if an audio-rate input is connected, use its first sample as the value for
  // the entire block. Otherwise, use the control value set at graph load time.

  const float freq = !freq_in.empty() ? freq_in[0] : node.controls[0];
  const float ph0 = !phase_in.empty() ? phase_in[0] : node.controls[1];

  if (!node.sinosc.phase_initialized) {
    node.sinosc.phase = ph0;
    node.sinosc.phase_initialized = true;
  }

  constexpr float kTwoPi = 2.0f * std::numbers::pi_v<float>;
  const float inc = freq / kSampleRate;

  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    out[fi] = std::sin(kTwoPi * node.sinosc.phase);
    node.sinosc.phase += inc;
    if (node.sinosc.phase >= 1.0f) {
      node.sinosc.phase -= std::floor(node.sinosc.phase);
    }
  }
}

// ----------------------------------------------------------------
// Out: output bus writer
//
// Sample-rate, stateless. Copies the input signal to its output buffer, or
// writes silence if no input is connected.
//
// When buses become real shared resources, Out will carry a BusWrite effect
// (Eff = BusWrite bus) on the Haskell side, and the effect analysis pass will
// generate implicit dependency edges between Out nodes and any In nodes that
// read from the same bus. Currently, Out is marked Pure (inferEff in
// MetaSonic.IR returns [Pure]), because the bus is not yet a shared resource —
// it is simply the last node's output buffer, printed for diagnostic purposes.
// ----------------------------------------------------------------

static void process_out(std::vector<NodeRuntime> &nodes, std::size_t node_idx,
                        int nframes) noexcept {
  NodeRuntime &node = nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto in = resolve_input(nodes, node, PortIndex{0}, nframes);

  if (in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  std::copy_n(in.begin(), static_cast<std::size_t>(nframes), out.begin());
}

// ----------------------------------------------------------------
// Gain: stateless multiply
//
// out[i] = signal_in[i] * gain
//
// Sample-rate, stateless. The gain factor comes from input
// port 1 if connected (block-latched at sample 0), otherwise
// from control slot 0 (default: 1.0, unity gain).
//
// Kernel fusion is often explained as many nodes become one loop. In MetaSonic,
// fusion should be formalized as a semantics-preserving rewrite over the
// normalized region graph.
//
// Gain is the canonical fusion target. A chain like SinOsc → Gain → Out (the
// chainGraph example in Main.hs) forms a single region in
// MetaSonic.Compile.formRegions because all three nodes are SampleRate with a
// linear dependency chain. A future fusion pass would compile this region into
// a single sample loop:
//
//   for (int i = 0; i < nframes; ++i)
//     out[i] = sin(2π * phase) * gain;
//     phase += freq / sr;
//
// eliminating the intermediate buffer between the oscillator and the multiply.
// This is the "fewer intermediate buffers, lower memory traffic, improved
// locality" benefit.
//
// Gain is also stateless, which means it imposes no loop-carried dependency on
// fusion (unlike a filter with delay state). The documentation notes that "a
// region should be factored into vector-friendly loops to expose SIMD or to
// separate stateful recurrences from embarrassingly parallel arithmetic." Gain
// is the embarrassingly parallel case.
// ----------------------------------------------------------------

static void process_gain(std::vector<NodeRuntime> &nodes, std::size_t node_idx,
                         int nframes) noexcept {
  NodeRuntime &node = nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto sig_in = resolve_input(nodes, node, PortIndex{0}, nframes);
  const auto gain_in = resolve_input(nodes, node, PortIndex{1}, nframes);

  // Block-latched gain value
  const float g = !gain_in.empty() ? gain_in[0] : node.controls[0];

  if (sig_in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    out[fi] = sig_in[fi] * g;
  }
}

} // namespace

// ===============================================================
// RTGraph: the top-level runtime handle
//
// This is the opaque struct that Haskell holds behind a Ptr RTGraph. It owns
// all runtime state: the node vector, the capacity hint, and the maximum block
// size.
//
// The Haskell side manages the lifetime through bracket- style allocation in
// MetaSonic.FFI.withRTGraph, which calls rt_graph_create on entry and
// rt_graph_destroy on exit (even under exceptions).
// ===============================================================

struct RTGraph {
  int capacity = 0;
  int max_frames = 0;
  std::vector<NodeRuntime> nodes;
};

// ----------------------------------------------------------------
// ensure_node_slot
//
// Resize the node vector so that a given index is valid. This allows nodes to
// be added in any order, though the Haskell compiler always adds them in dense
// ascending order (by construction in MetaSonic.FFI.loadRuntimeGraph, which
// iterates rgNodes in execution order).
//
// Note: if the Haskell side were to send non-contiguous indices, this function
// would silently create empty gaps — unconfigured NodeRuntime entries with
// zero-sized buffers. The documentation claims dense indexing, but this
// function does not enforce it. A future hardening pass could add a check that
// indices arrive consecutively.
// ----------------------------------------------------------------

static void ensure_node_slot(RTGraph &g, NodeIndex node_index) {
  if (!valid(node_index)) {
    return;
  }

  const std::size_t idx = to_size(node_index);
  if (g.nodes.size() <= idx) {
    g.nodes.resize(idx + 1);
  }
}

// ===============================================================
// C ABI
//
// The runtime exposes an FFI for graph creation, node addition, control
// assignment, connection, and block processing.
//
// This is the minimal surface through which the Haskell compiler communicates
// with the runtime. The protocol is:
//
//   1. rt_graph_create(capacity, max_frames)
//   2. For each node in execution order:
//      a. rt_graph_add_node(g, index, kind)
//      b. rt_graph_set_control(g, index, slot, value)
//         for each control
//   3. For each connection:
//      rt_graph_connect(g, src, src_port, dst, dst_port)
//   4. Repeat:
//      rt_graph_process(g, nframes)
//   5. rt_graph_destroy(g)
//
// MetaSonic.FFI.loadRuntimeGraph implements steps 2–3.
// MetaSonic.FFI.withRTGraph implements steps 1 and 5 via bracket.
//
// All functions return void (except create, which returns the handle). Errors
// are reported to stderr. A future improvement would return error codes or use
// a shared error buffer, so that the Haskell side can detect runtime failures
// programmatically. For now, the documentation's claim that "failure belongs to
// compilation" is upheld by construction: if the Haskell compiler produces a
// valid RuntimeGraph, no error paths in this ABI should trigger.
// ===============================================================

extern "C" {

// ---------------------------------------------------------------
// Lifecycle: create, destroy, clear
// ---------------------------------------------------------------

RTGraph *rt_graph_create(int capacity, int max_frames) {
  auto *g = new RTGraph{};
  g->capacity = std::max(0, capacity);
  g->max_frames = std::max(0, max_frames);
  if (g->capacity > 0) {
    g->nodes.reserve(static_cast<std::size_t>(g->capacity));
  }
  return g;
}

void rt_graph_destroy(RTGraph *g) { delete g; }

// clear resets the graph for reloading without deallocating
// the handle. Used by MetaSonic.FFI.loadRuntimeGraph before
// adding the new graph's nodes.
void rt_graph_clear(RTGraph *g) {
  if (!g) {
    return;
  }
  g->nodes.clear();
  if (g->capacity > 0) {
    g->nodes.reserve(static_cast<std::size_t>(g->capacity));
  }
}

// ----------------------------------------------------------------
// Graph construction: add_node, set_control, connect
//
// These functions are called by MetaSonic.FFI.loadRuntimeGraph to reconstruct
// the compiled graph on the C++ side. They are called once at load time, never
// during audio processing.
//
// The node_kind integer is the wire format of NodeKind — the same value
// produced by kindTag in MetaSonic.Types.
// ----------------------------------------------------------------

void rt_graph_add_node(RTGraph *g, int node_index, int node_kind) {
  if (!g) {
    return;
  }

  NodeKind kind{};
  switch (node_kind) {
  case 1:
    kind = NodeKind::SinOsc;
    break;
  case 2:
    kind = NodeKind::Out;
    break;
  case 3:
    kind = NodeKind::Gain;
    break;
  default:
    std::fprintf(stderr, "Unknown node kind: %d\n", node_kind);
    return;
  }

  const NodeIndex idx{node_index};
  if (!valid(idx)) {
    return;
  }

  ensure_node_slot(*g, idx);
  configure_node(g->nodes[to_size(idx)], kind, g->max_frames);
}

void rt_graph_set_control(RTGraph *g, int node_index, int control_index,
                          float value) {
  if (!g) {
    return;
  }

  const NodeIndex ni{node_index};
  const ControlIndex ci{control_index};
  if (!valid(ni) || !valid(ci)) {
    return;
  }

  const std::size_t nidx = to_size(ni);
  if (nidx >= g->nodes.size()) {
    return;
  }

  NodeRuntime &node = g->nodes[nidx];
  const std::size_t cidx = to_size(ci);
  if (cidx >= node.controls.size()) {
    return;
  }

  node.controls[cidx] = value;
}

// connect wires one source output port to one destination input port. Both
// indices are dense NodeIndex values — the same values produced by
// compileRuntimeGraph in MetaSonic.Compile. The runtime does no symbolic
// lookup; it stores the source index directly in the destination node's
// InputRef.
void rt_graph_connect(RTGraph *g, int src_index, int src_port, int dst_index,
                      int dst_port) {
  if (!g) {
    return;
  }

  const NodeIndex src{src_index};
  const PortIndex sp{src_port};
  const NodeIndex dst{dst_index};
  const PortIndex dp{dst_port};
  if (!valid(src) || !valid(sp) || !valid(dst) || !valid(dp)) {
    return;
  }

  const std::size_t sidx = to_size(src);
  const std::size_t didx = to_size(dst);
  const std::size_t dport = to_size(dp);

  if (sidx >= g->nodes.size() || didx >= g->nodes.size()) {
    return;
  }

  NodeRuntime &dst_node = g->nodes[didx];
  if (dport >= dst_node.input_refs.size()) {
    return;
  }

  dst_node.input_refs[dport] = InputRef{src, sp, true};
}

// ----------------------------------------------------------------
// Audio processing
//
// This is exactly the kind of linearized traversal that SuperNova identifies as
// efficient for fine-grained graphs in the sequential case. The crucial
// difference is that MetaSonic treats this not as a convenient implementation
// shortcut but as the desired target of compilation.
//
// The loop below is the entire runtime execution model: iterate over the dense
// node array in storage order, dispatch on NodeKind, call the appropriate
// process function. Storage order equals execution order because nodes were
// added in topological order by loadRuntimeGraph, and the topological order was
// computed by MetaSonic.Validate.topoSort.
//
// SuperNova explicitly notes that fine-grained graphs are not feasibly
// scheduled by assigning each graph node to the scheduler individually." This
// loop is the sequential alternative: no scheduler, no ready queue, no
// synchronization. Just a for loop over a vector.
//
// When region-level parallel scheduling is implemented, the outer loop will
// iterate over regions rather than individual nodes. Within each region, the
// same sequential iteration applies. Between regions, a lightweight scheduler
// dispatches independent regions to worker threads. The invariant must hold: no
// runtime scheduling mechanism may compromise worst-case callback latency.
// ----------------------------------------------------------------

void rt_graph_process(RTGraph *g, int nframes) {
  if (!g) {
    return;
  }

  if (nframes < 0 || nframes > g->max_frames) {
    std::fprintf(stderr, "Invalid nframes: %d (max_frames=%d)\n", nframes,
                 g->max_frames);
    return;
  }

  // The execution loop: iterate in storage order, dispatch by kind. This is the
  // "dense executable units under latency constraints" target.
  for (std::size_t i = 0; i < g->nodes.size(); ++i) {
    switch (g->nodes[i].kind) {
    case NodeKind::SinOsc:
      process_sinosc(g->nodes, i, nframes);
      break;
    case NodeKind::Out:
      process_out(g->nodes, i, nframes);
      break;
    case NodeKind::Gain:
      process_gain(g->nodes, i, nframes);
      break;
    }
  }

  // Diagnostic output: print the first 8 samples of the last node's output
  // buffer. This is a prototype convenience, not part of the architecture. A
  // real system would write to an audio device (via q_io / portaudio) or expose
  // the buffer through a callback.
  if (!g->nodes.empty() && !g->nodes.back().outputs.empty()) {
    const auto out = output_span(g->nodes.back(), PortIndex{0}, nframes);
    std::printf("First 8 output samples:\n");
    for (int i = 0; i < 8 && i < static_cast<int>(out.size()); ++i) {
      std::printf("%d: %.6f\n", i, out[static_cast<std::size_t>(i)]);
    }
  }
}

} // extern "C"
