#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// opaque runtime graph handle used through the C ABI
struct RTGraph;

// create a new runtime graph
//
// capacity   - advisory node capacity, used to reserve storage
// max_frames - maximum block size accepted by rt_graph_process()
RTGraph *rt_graph_create(int capacity, int max_frames);

// destroy the graph and all owned resources
void rt_graph_destroy(RTGraph *g);

// remove all nodes and reset runtime state.
void rt_graph_clear(RTGraph *g);

// add one node to the graph at a dense runtime index.
// Nodes are expected to be added in execution order. The runtime processes them
// in storage order, so there is no separate execution-order API anymore
//
// node_kind currently supports:
//   1 = SinOsc
//   2 = Out
void rt_graph_add_node(RTGraph *g, int node_index, int node_kind);

// set one control value on a node
void rt_graph_set_control(RTGraph *g, int node_index, int control_index,
                          float value);

// connect one source output port to one destination input port
// src_index and dst_index are dense runtime indices, not symbolic node ids
void rt_graph_connect(RTGraph *g, int src_index, int src_port, int dst_index,
                      int dst_port);

// process one audio block
// nframes must be between 0 and max_frames inclusive
void rt_graph_process(RTGraph *g, int nframes);

#ifdef __cplusplus
}
#endif
