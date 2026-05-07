#include "rt_graph.h"

#include <q_io/audio_device.hpp>
#include <q_io/audio_stream.hpp>

#include <portaudio.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <numbers>
#include <span>
#include <thread>
#include <vector>

namespace q = cycfi::q;

struct RTGraph;

namespace {

constexpr float kDefaultSampleRate = 48000.0f;

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

enum class NodeKind : int {
  SinOsc = 1,
  Out = 2,
  Gain = 3,
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
  return {node.outputs[to_size(port)].data(),
          static_cast<std::size_t>(nframes)};
}

[[nodiscard]] static std::span<const float>
output_span(const NodeRuntime &node, PortIndex port, int nframes) noexcept {
  return {node.outputs[to_size(port)].data(),
          static_cast<std::size_t>(nframes)};
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

  case NodeKind::Gain:
    node.controls.resize(1, 1.0f); // [gain_amount]
    node.input_refs.resize(2);     // [signal_in, gain_in]
    node.outputs.resize(1);
    break;
  }

  for (auto &out : node.outputs) {
    out.resize(static_cast<std::size_t>(max_frames), 0.0f);
  }
}

struct GraphAudioStream : q::audio_stream {
  GraphAudioStream(RTGraph &graph, q::audio_device const &device,
                   std::size_t output_channels);

  void process(out_channels const &out) override;
  bool wait_started(std::chrono::milliseconds timeout) noexcept;

  RTGraph &graph;
  std::atomic<bool> started{false};
};

} // namespace

struct RTGraph {
  int capacity = 0;
  int max_frames = 0;
  float sample_rate = kDefaultSampleRate;
  std::vector<NodeRuntime> nodes;
  std::vector<std::vector<float>> output_buses;
  std::unique_ptr<GraphAudioStream> audio;
};

namespace {

static void ensure_node_slot(RTGraph &g, NodeIndex node_index) {
  if (!valid(node_index)) {
    return;
  }

  const std::size_t idx = to_size(node_index);
  if (g.nodes.size() <= idx) {
    g.nodes.resize(idx + 1);
  }
}

static void ensure_output_bus_count(RTGraph &g, std::size_t count) {
  if (g.output_buses.size() >= count) {
    return;
  }

  const std::size_t old_size = g.output_buses.size();
  g.output_buses.resize(count);
  for (std::size_t i = old_size; i < count; ++i) {
    g.output_buses[i].resize(static_cast<std::size_t>(g.max_frames), 0.0f);
  }
}

static void clear_output_buses(RTGraph &g, int nframes) noexcept {
  const std::size_t frames = static_cast<std::size_t>(nframes);
  for (auto &bus : g.output_buses) {
    std::fill_n(bus.begin(), frames, 0.0f);
  }
}

static void process_sinosc(RTGraph &g, std::size_t node_idx,
                           int nframes) noexcept {
  NodeRuntime &node = g.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto freq_in = resolve_input(g.nodes, node, PortIndex{0}, nframes);
  const auto phase_in = resolve_input(g.nodes, node, PortIndex{1}, nframes);

  const float freq = !freq_in.empty() ? freq_in[0] : node.controls[0];
  const float ph0 = !phase_in.empty() ? phase_in[0] : node.controls[1];

  if (!node.sinosc.phase_initialized) {
    node.sinosc.phase = ph0;
    node.sinosc.phase_initialized = true;
  }

  constexpr float kTwoPi = 2.0f * std::numbers::pi_v<float>;
  const float inc = freq / g.sample_rate;

  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    out[fi] = std::sin(kTwoPi * node.sinosc.phase);
    node.sinosc.phase += inc;
    if (node.sinosc.phase >= 1.0f || node.sinosc.phase < 0.0f) {
      node.sinosc.phase -= std::floor(node.sinosc.phase);
    }
  }
}

static void process_gain(RTGraph &g, std::size_t node_idx,
                         int nframes) noexcept {
  NodeRuntime &node = g.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto sig_in = resolve_input(g.nodes, node, PortIndex{0}, nframes);
  const auto gain_in = resolve_input(g.nodes, node, PortIndex{1}, nframes);

  const float amount = !gain_in.empty() ? gain_in[0] : node.controls[0];

  if (sig_in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
    return;
  }

  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    out[fi] = sig_in[fi] * amount;
  }
}

static void process_out(RTGraph &g, std::size_t node_idx,
                        int nframes) noexcept {
  NodeRuntime &node = g.nodes[node_idx];
  auto out = output_span(node, PortIndex{0}, nframes);
  const auto in = resolve_input(g.nodes, node, PortIndex{0}, nframes);

  if (in.empty()) {
    std::fill(out.begin(), out.end(), 0.0f);
  } else {
    std::copy_n(in.begin(), static_cast<std::size_t>(nframes), out.begin());
  }

  const int bus = static_cast<int>(node.controls[0]);
  if (bus < 0) {
    return;
  }

  const std::size_t bus_index = static_cast<std::size_t>(bus);
  if (bus_index >= g.output_buses.size()) {
    return;
  }

  auto &dst = g.output_buses[bus_index];
  for (int i = 0; i < nframes; ++i) {
    const std::size_t fi = static_cast<std::size_t>(i);
    dst[fi] += out[fi];
  }
}

static void process_graph(RTGraph &g, int nframes) noexcept {
  clear_output_buses(g, nframes);

  for (std::size_t i = 0; i < g.nodes.size(); ++i) {
    switch (g.nodes[i].kind) {
    case NodeKind::SinOsc:
      process_sinosc(g, i, nframes);
      break;
    case NodeKind::Out:
      process_out(g, i, nframes);
      break;
    case NodeKind::Gain:
      process_gain(g, i, nframes);
      break;
    }
  }
}

GraphAudioStream::GraphAudioStream(RTGraph &graph_,
                                   q::audio_device const &device,
                                   std::size_t output_channels)
    : q::audio_stream(device, 0, output_channels, device.default_sample_rate(),
                      graph_.max_frames),
      graph(graph_) {}

void GraphAudioStream::process(out_channels const &out) {
  started.store(true, std::memory_order_release);

  const int nframes = static_cast<int>(out.frames.size());
  process_graph(graph, nframes);

  for (std::size_t ch = 0; ch < out.size(); ++ch) {
    auto dst = out[ch];
    std::fill(dst.begin(), dst.end(), 0.0f);

    if (graph.output_buses.empty()) {
      continue;
    }

    const std::size_t bus =
        (graph.output_buses.size() == 1 && out.size() > 1) ? 0 : ch;

    if (bus < graph.output_buses.size()) {
      std::copy_n(graph.output_buses[bus].begin(),
                  static_cast<std::size_t>(nframes), dst.begin());
    }
  }
}

bool GraphAudioStream::wait_started(
    std::chrono::milliseconds timeout) noexcept {
  if (timeout.count() < 0) {
    while (!started.load(std::memory_order_acquire)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
  }

  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (started.load(std::memory_order_acquire)) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }

  return started.load(std::memory_order_acquire);
}

static void stop_audio_stream(RTGraph &g) {
  if (!g.audio) {
    return;
  }

  g.audio->stop();
  g.audio.reset();
}

static std::unique_ptr<GraphAudioStream>
open_audio_stream(RTGraph &g, int requested_output_channels,
                  int requested_device_id) {
  auto devices = q::audio_device::list();
  if (devices.empty()) {
    return {};
  }

  auto try_make =
      [&](q::audio_device const &dev) -> std::unique_ptr<GraphAudioStream> {
    if (static_cast<int>(dev.output_channels()) < requested_output_channels) {
      return {};
    }

    auto stream = std::make_unique<GraphAudioStream>(
        g, dev, static_cast<std::size_t>(requested_output_channels));

    if (!stream->is_valid()) {
      return {};
    }

    return stream;
  };

  if (requested_device_id >= 0) {
    for (auto const &dev : devices) {
      if (dev.id() == requested_device_id) {
        return try_make(dev);
      }
    }
    return {};
  }

  const PaDeviceIndex default_output_id = Pa_GetDefaultOutputDevice();
  if (default_output_id != paNoDevice) {
    for (auto const &dev : devices) {
      if (dev.id() == default_output_id) {
        if (auto stream = try_make(dev)) {
          return stream;
        }
        break;
      }
    }
  }

  for (auto const &dev : devices) {
    if (auto stream = try_make(dev)) {
      return stream;
    }
  }

  return {};
}

} // namespace

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

void rt_graph_destroy(RTGraph *g) {
  if (!g) {
    return;
  }
  stop_audio_stream(*g);
  delete g;
}

void rt_graph_clear(RTGraph *g) {
  if (!g) {
    return;
  }

  stop_audio_stream(*g);
  g->sample_rate = kDefaultSampleRate;
  g->nodes.clear();
  g->output_buses.clear();
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

  if (kind == NodeKind::Out) {
    ensure_output_bus_count(*g, 1);
  }
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

  if (node.kind == NodeKind::Out && cidx == 0 && value >= 0.0f) {
    const auto bus = static_cast<std::size_t>(static_cast<int>(value));
    ensure_output_bus_count(*g, bus + 1);
  }
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

  if (g->output_buses.empty()) {
    ensure_output_bus_count(*g, 1);
  }

  process_graph(*g, nframes);
}

int rt_graph_start_audio(RTGraph *g, int output_channels, int device_id) {
  if (!g) {
    return -100;
  }

  if (g->audio) {
    return 0;
  }

  if (output_channels <= 0) {
    output_channels = std::max(1, static_cast<int>(g->output_buses.size()));
  }

  if (g->output_buses.empty()) {
    ensure_output_bus_count(*g, 1);
  }

  auto stream = open_audio_stream(*g, output_channels, device_id);
  if (!stream) {
    std::fprintf(stderr,
                 "Failed to open audio stream (device_id=%d, outputs=%d)\n",
                 device_id, output_channels);
    return -1;
  }

  g->sample_rate = static_cast<float>(stream->sampling_rate());
  stream->start();
  g->audio = std::move(stream);
  return 0;
}

int rt_graph_wait_started(RTGraph *g, int timeout_ms) {
  if (!g || !g->audio) {
    return -100;
  }

  const bool ok = g->audio->wait_started(std::chrono::milliseconds(timeout_ms));
  return ok ? 0 : -2;
}

void rt_graph_stop_audio(RTGraph *g) {
  if (!g) {
    return;
  }

  stop_audio_stream(*g);
}

} // extern "C"