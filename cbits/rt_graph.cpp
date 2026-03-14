#include "rt_graph.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <unordered_map>
#include <vector>

namespace {

// Const for sample rate
constexpr float kSampleRate = 48000.0f;

// struct representing a reference to an input connection
struct InputRef {
  int src_node = -1;      // id of the source node
  int src_port = -1;      // port index on the source node
  bool connected = false; // true if the input is connected
};

// base struct for nodes in the graph
struct Node {
  int id = -1;                             // unique identifier for the node
  std::vector<float> controls;             // control parameters for the node
  std::vector<InputRef> input_refs;        // references to input connections
  std::vector<std::vector<float>> outputs; // output buffers for the node

  explicit Node(int node_id) : id(node_id) {}
  virtual ~Node() = default;

  // pure virtual function to process audio for the node
  virtual void process(
      int nframes,
      const std::unordered_map<int, std::unique_ptr<Node>> &nodes) noexcept = 0;

  // resolves and returns the input buffer for a index
  const float *
  resolve_input(std::size_t idx,
                const std::unordered_map<int, std::unique_ptr<Node>> &nodes)
      const noexcept {
    if (idx >= input_refs.size())
      return nullptr;

    const InputRef &ref = input_refs[idx];
    if (!ref.connected)
      return nullptr;

    auto it = nodes.find(ref.src_node);
    if (it == nodes.end())
      return nullptr;

    const Node *src = it->second.get();
    if (ref.src_port < 0)
      return nullptr;

    const std::size_t port = static_cast<std::size_t>(ref.src_port);
    if (port >= src->outputs.size())
      return nullptr;
    if (src->outputs[port].empty())
      return nullptr;

    return src->outputs[port].data();
  }
};

// node representing a sine oscillator
struct SinOscNode final : Node {
  float phase = 0.0f;             // current phase of the oscillator
  bool phase_initialized = false; // flag to check if phase is initialized

  explicit SinOscNode(int node_id) : Node(node_id) {
    controls.resize(
        2, 0.0f);         // two control parameters: frequency and initial phase
    input_refs.resize(2); // two inputs: frequency and phase
    outputs.resize(1);    // one output: the generated sine wave
  }

  // processes the sine wave generation for a given number of frames
  void process(int nframes, const std::unordered_map<int, std::unique_ptr<Node>>
                                &nodes) noexcept override {
    outputs[0].resize(static_cast<std::size_t>(nframes));

    const float *freqIn = resolve_input(0, nodes);
    const float *phaseIn = resolve_input(1, nodes);

    const float freq = freqIn ? freqIn[0] : controls[0];
    const float ph0 = phaseIn ? phaseIn[0] : controls[1];

    if (!phase_initialized) {
      phase = ph0;
      phase_initialized = true;
    }

    const float inc = freq / kSampleRate;

    for (int i = 0; i < nframes; ++i) {
      outputs[0][static_cast<std::size_t>(i)] =
          std::sin(2.0f * 3.14159265358979323846f * phase);
      phase += inc;
      if (phase >= 1.0f) {
        phase -= std::floor(phase);
      }
    }
  }
};

// node representing an output node that passes through its input
struct OutNode final : Node {
  explicit OutNode(int node_id) : Node(node_id) {
    controls.resize(1, 0.0f); // one control parameter
    input_refs.resize(1);     // one input4
    outputs.resize(1);        // one output
  }

  // processes the input and copies it to the output
  void process(int nframes, const std::unordered_map<int, std::unique_ptr<Node>>
                                &nodes) noexcept override {
    outputs[0].resize(static_cast<std::size_t>(nframes));
    const float *in = resolve_input(0, nodes);

    if (!in) {
      std::fill(outputs[0].begin(), outputs[0].end(), 0.0f);
      return;
    }

    for (int i = 0; i < nframes; ++i) {
      outputs[0][static_cast<std::size_t>(i)] = in[i];
    }
  }
};

} // namespace

// struct representing the real-time graph
struct RTGraph {
  int capacity = 0;
  int max_frames = 0;
  std::unordered_map<int, std::unique_ptr<Node>> nodes;
  std::vector<int> exec_order;
};

// helper function to lookup a node in the graph by ID
static Node *lookup_node(RTGraph *g, int node_id) {
  auto it = g->nodes.find(node_id);
  if (it == g->nodes.end())
    return nullptr;
  return it->second.get();
}

extern "C" {

// a new RTGraph with specified capacity and max frames
RTGraph *rt_graph_create(int capacity, int max_frames) {
  auto *g = new RTGraph{};
  g->capacity = capacity;
  g->max_frames = max_frames;
  return g;
}

// destroys the graph and frees memory
void rt_graph_destroy(RTGraph *g) { delete g; }

// clears all nodes in the graph, removing all nodes and execution order
void rt_graph_clear(RTGraph *g) {
  if (!g)
    return;
  g->nodes.clear();
  g->exec_order.clear();
}

// adds a new node to the graph (based on its kind) with the specified ID
void rt_graph_add_node(RTGraph *g, int node_id, int node_kind) {
  if (!g)
    return;

  switch (node_kind) {
  case 1:
    g->nodes[node_id] = std::make_unique<SinOscNode>(node_id);
    break;
  case 2:
    g->nodes[node_id] = std::make_unique<OutNode>(node_id);
    break;
  default:
    std::fprintf(stderr, "Unknown node kind: %d\n", node_kind);
    break;
  }
}

// sets a control value for a specific node
void rt_graph_set_control(RTGraph *g, int node_id, int control_index,
                          float value) {
  if (!g)
    return;

  Node *node = lookup_node(g, node_id);
  if (!node)
    return;
  if (control_index < 0)
    return;

  const std::size_t idx = static_cast<std::size_t>(control_index);
  if (idx >= node->controls.size())
    return;

  node->controls[idx] = value;
}

// connects two nodes within the graph
void rt_graph_connect(RTGraph *g, int src_id, int src_port, int dst_id,
                      int dst_port) {
  if (!g)
    return;

  Node *dst = lookup_node(g, dst_id);
  if (!dst)
    return;
  if (dst_port < 0)
    return;

  const std::size_t dp = static_cast<std::size_t>(dst_port);
  if (dp >= dst->input_refs.size())
    return;

  dst->input_refs[dp] = InputRef{src_id, src_port, true};
}

// sets the execution order for nodes in the graph
void rt_graph_set_exec_order(RTGraph *g, int order_index, int node_id) {
  if (!g)
    return;
  if (order_index < 0)
    return;

  const std::size_t idx = static_cast<std::size_t>(order_index);
  if (g->exec_order.size() <= idx) {
    g->exec_order.resize(idx + 1, -1);
  }
  g->exec_order[idx] = node_id;
}

// processes the graph for a given number of frames
void rt_graph_process(RTGraph *g, int nframes) {
  if (!g)
    return;

  for (int node_id : g->exec_order) {
    Node *node = lookup_node(g, node_id);
    if (!node)
      continue;
    node->process(nframes, g->nodes);
  }

  if (!g->exec_order.empty()) {
    Node *last = lookup_node(g, g->exec_order.back());
    if (last && !last->outputs.empty()) {
      const auto &out = last->outputs[0];
      std::printf("First 8 output samples:\n");
      for (int i = 0; i < 8 && i < static_cast<int>(out.size()); ++i) {
        std::printf("%d: %.6f\n", i, out[static_cast<std::size_t>(i)]);
      }
    }
  }
}

} // extern "C"