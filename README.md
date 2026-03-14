# MetaSonic Bridge

`metasonic-bridge` is an experimental project exploring a hybrid architecture for modular audio synthesis.

It separates two concerns that most audio environments mix together:

* graph construction and scheduling
* real-time signal processing

In this system:

* Haskell builds and analyzes DSP graphs.
* C++20 executes the real-time DSP engine.

This repo is a small prototype demonstrating a pipeline: 

```
Haskell DSL → Graph IR → C++ Runtime Engine → DSP Processing
```

It contains a minimal working implementation of that idea.


---

# Motivation

Most modular audio environments blur several responsibilities into a single system:

* graph composition
* scheduling
* signal processing
* UI
* memory management

Examples include SuperCollider, Pure Data, Max, and plugin frameworks.

These systems are excellent, but they also come with some trade-offs between:

* flexibility
* predictable real-time execution
* maintainability

MetaSonic explores a different approach:

```
graph composition ≠ signal processing
```

Graph construction can be treated as a compiler problem, while DSP execution
remains a runtime problem.

This separation enables:

* expressive graph composition
* graph analysis and transformation
* deterministic real-time DSP
* simpler runtime engines

---

# System Architecture

The system has two primary layers.

```
+---------------------+
|     Haskell Layer   |
|  Graph DSL + IR     |
+----------+----------+
           |
           | GraphIR
           v
+---------------------+
|     C++ Runtime     |
|   DSP Graph Engine  |
+---------------------+
```

---

# Haskell Layer

The Haskell side is responsible for graph description and compilation.

Responsibilities include:

* building synthesis graphs using a DSL
* dependency analysis
* cycle detection
* topological sorting
* lowering the graph into a runtime IR

Example graph:

```haskell
simpleGraph :: SynthGraph
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc
```

This generates the following graph structure:

```
SinOsc(440 Hz) → Out
```

The graph is lowered into a minimal IR:

```
GraphIR
  Nodes:
    Node 0: SinOsc
    Node 1: Out
  Execution order:
    [0, 1]
```

This IR is passed to the runtime engine through FFI during graph compilation.

---

# Graph IR

The intermediate representation intentionally stays simple.

```haskell
data NodeIR = NodeIR
  { irNodeID   :: NodeID
  , irKind     :: NodeKind
  , irInputs   :: [InputConn]
  , irControls :: [Float]
  }
```

The runtime engine only needs to know:

* node type
* control values
* input connections
* execution order

This keeps the boundary between languages small and stable.

---

# C++ Runtime Engine

The runtime engine executes DSP in blocks.

Each node implements a small processing kernel.

Example node types:

```
SinOsc
Out
```

Nodes are scheduled in topological order:

```cpp
for (int node_id : exec_order) {
    Node* node = lookup_node(g, node_id);
    if (node) {
        node->process(nframes, g->nodes);
    }
}
```

The runtime layer handles:

* node state
* audio buffers
* execution scheduling
* signal propagation

Because graph analysis already happened in Haskell, the runtime engine can remain small.

---

# Example Runtime Output

Running the prototype:

```
stack exec metasonic-bridge
```

Produces:

```
Building graph in Haskell...
SynthGraph { ... }

Lowered IR:
GraphIR { ... }

Processing 3 blocks in C++...

Block 1
First 8 output samples:
0: 0.000000
1: 0.057564
2: 0.114937
...

Block 2
First 8 output samples:
0: -0.518026
...

Block 3
First 8 output samples:
0: 0.886202
...
```

The oscillator phase continues across blocks, confirming that stateful DSP execution works correctly.

---

# Design Philosophy

MetaSonic aims to treat synthesis graphs as **compilable structures** rather than dynamic runtime objects.

This enables:

* graph rewriting
* scheduling analysis
* compile-time optimizations
* IR transformations
* alternative runtimes

Instead of a monolithic environment, the system becomes a pipeline:

```
DSL → Graph → IR → Runtime
```

Each stage can evolve independently.

---

# Why Haskell?

Functional languages are particularly well suited for graph construction.
Advantages include:


* algebraic data types for graph representation
* pattern matching for transformations
* strong type systems for graph invariants
* declarative DSLs

In this architecture, Haskell provides the DSL and acts as a graph compiler,
while real-time DSP execution is delegated to the runtime engine.


---

# Why C++?

Real-time DSP engines require:

* predictable memory layout
* deterministic execution
* tight control over allocations
* efficient math operations

C++ remains a good fit for these requirements.

The runtime engine is intentionally minimal and focuses only on `signal processing`.

---

# Current Prototype

Implemented nodes:

```
SinOsc
Out
```

Features:

* graph DSL in Haskell
* topological scheduling
* IR lowering
* FFI bridge
* real-time block processing

Limitations:

* block-rate modulation
* buffers resized per block
* minimal node set
* no audio device output
* graph compiled only once at startup

The prototype focuses on validating the architecture.

---

# Roadmap

Short-term goals:

* a variety of oscillator and filter nodes
* unit tests and property-based testing
* preallocated buffers
* graph validation improvements

Medium-term goals:

* parameter automation
* audio-rate modulation
* larger node library
* real-time command queue

Long-term goals:

* typed DSP graphs
* dynamic graph mutation
* vectorized DSP kernels
* offline rendering
* plugin backends

Ultimately the goal is a flexible synthesis system where:

* graph construction is declarative
* DSP execution moves toward deterministic real-time behavior


---

# Building

Requirements:

* GHC ≥ 9
* Stack
* C++20 compiler (gcc, clang)


Build:

```bash
stack build
```

Run:

```bash
stack exec metasonic-bridge
```

---

# Project Structure

```
metasonic-bridge
│
├─ app/
│  └─ Main.hs
│
├─ cbits/
│  ├─ rt_graph.cpp
│  └─ rt_graph.h
│
├─ package.yaml
├─ stack.yaml
└─ README.md
```

---

# Status

This is a research prototype. The architecture is still evolving and APIs may
change. The project in this repo exists to explore ideas about graph-based
synthesis systems rather than to provide a finished production engine.

