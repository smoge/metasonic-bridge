#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// forward declaration of RTGraph structure
struct RTGraph;

// create new real-time graph with capacity and maximum number of frames
// returns pointer to the newly created RTGraph instance.
RTGraph *rt_graph_create(int capacity, int max_frames);

// destroy an existing RTGraph instance, freeing allocated resources
void rt_graph_destroy(RTGraph *g);

// clear all nodes and connections in the given RTGraph, resetting it
void rt_graph_clear(RTGraph *g);

// add a new node to the RTGraph with specified node ID and kind/type
void rt_graph_add_node(RTGraph *g, int node_id, int node_kind);

// set a control parameter for specific node in the RTGraph
// control is identified by its index, value is a floating-point number
void rt_graph_set_control(RTGraph *g, int node_id, int control_index,
                          float value);

// connect two nodes in the RTGraph
// specifies the source node and port, also as the destination node and port
void rt_graph_connect(RTGraph *g, int src_id, int src_port, int dst_id,
                      int dst_port);

// set the execution order of nodes in the RTGraph
// determines the sequence in which nodes are processed
void rt_graph_set_exec_order(RTGraph *g, int order_index, int node_id);

// process the RTGraph for a specified number of frames
// this typically involves executing the nodes in the defined order
void rt_graph_process(RTGraph *g, int nframes);

#ifdef __cplusplus
}
#endif