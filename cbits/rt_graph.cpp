#include "rt_graph.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <numbers>
#include <span>
#include <vector>

namespace {

constexpr float kSampleRate = 48000.0f;

struct NodeIndex {
  int value = -1;
};

struct PortIndex {
  int value = -1;
};

struct ControlIndex {
  int value = -1;
};

[[nodiscard]] constexpr bool valid(NodeIndex x) noexcept { return x.value >= 0; }
[[nodiscard]] constexpr bool valid(PortIndex x) noexcept { return x.value >= 0; }
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

enum class NodeKind : int {
  SinOsc = 1,
  Out = 2,
};

struct InputRef {
  NodeIndex src_node{};
  PortIndex src_port{};
  bool connected = false;
};

struct SinOscState {
  float phase = 0.0f;
  bool phase_initialized = false;
};

struct NodeRuntime {
  NodeKind kind = NodeKind::Out;
  std::vector<float> controls;
  std::vector<InputRef> input_refs;
  std::vector<std::vector<float>> outputs;
  SinOscState sinosc{};
};

[[nodiscard]] static std::span<float>
output_span(NodeRuntime &node, PortIndex port, int nframes) noexcept {
  return {node.outputs[to_size(port)].data(), static_cast<std::size_t>(nframes)};
}

[[nodiscard]] static std::span<const float>
output_span(const NodeRuntime &node, PortIndex port, int nframes) noexcept {
  return {node.outputs[to_size(port)].data(), static_cast<std::size_t>(nframes)};
}

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
  }

  for (auto &out : node.outputs) {
    out.resize(static_cast<std::size_t>(max_frames), 0.0f);
  }
}

static void process_sinosc(std::vector<NodeRuntime> &nodes, std::size_t node_idx,
                           int nframes) noexcept {
  NodeRuntime &node = nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto freq_in = resolve_input(nodes, node, PortIndex{0}, nframes);
  const auto phase_in = resolve_input(nodes, node, PortIndex{1}, nframes);

  // Preserves the current semantics: external inputs override controls at
  // block rate using sample 0. The next architectural step after this one is
  // to make selected inputs audio-rate.
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

} // namespace

struct RTGraph {
  int capacity = 0;
  int max_frames = 0;
  std::vector<NodeRuntime> nodes;
};

static void ensure_node_slot(RTGraph &g, NodeIndex node_index) {
  if (!valid(node_index)) {
    return;
  }

  const std::size_t idx = to_size(node_index);
  if (g.nodes.size() <= idx) {
    g.nodes.resize(idx + 1);
  }
}

extern "C" {

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

void rt_graph_clear(RTGraph *g) {
  if (!g) {
    return;
  }
  g->nodes.clear();
  if (g->capacity > 0) {
    g->nodes.reserve(static_cast<std::size_t>(g->capacity));
  }
}

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

void rt_graph_process(RTGraph *g, int nframes) {
  if (!g) {
    return;
  }

  if (nframes < 0 || nframes > g->max_frames) {
    std::fprintf(stderr, "Invalid nframes: %d (max_frames=%d)\n", nframes,
                 g->max_frames);
    return;
  }

  for (std::size_t i = 0; i < g->nodes.size(); ++i) {
    switch (g->nodes[i].kind) {
    case NodeKind::SinOsc:
      process_sinosc(g->nodes, i, nframes);
      break;
    case NodeKind::Out:
      process_out(g->nodes, i, nframes);
      break;
    }
  }

  if (!g->nodes.empty() && !g->nodes.back().outputs.empty()) {
    const auto out = output_span(g->nodes.back(), PortIndex{0}, nframes);
    std::printf("First 8 output samples:\n");
    for (int i = 0; i < 8 && i < static_cast<int>(out.size()); ++i) {
      std::printf("%d: %.6f\n", i, out[static_cast<std::size_t>(i)]);
    }
  }
}

} // extern "C"
