# MetaSonic Bridge

> *They build systems that react.*
> *We build systems that decide.*

`metasonic-bridge` is a research prototype exploring a **compiled architecture for modular audio synthesis**.

Most environments blur everything together.

This one splits the world clean:

* **Haskell** — constructs, validates, compiles
* **C++20** — executes, deterministically, no questions asked

Pipeline:

```
Haskell DSL → Graph → IR → RuntimeGraph → DSP
```

No shortcuts. No hidden work at runtime.

---

# Motivation

Typical audio systems mix:

* graph composition
* scheduling
* DSP execution
* state and memory

That’s convenient.
It’s also messy.

MetaSonic draws a line:

```
graph ≠ execution
```

Graph building is a **compile-time problem**.
DSP is a **runtime problem**.

That split gives you:

* deterministic execution
* analyzable graphs
* minimal runtime
* room for aggressive optimization later

---

# Architecture

```
+-----------------------+
|     Haskell Layer     |
|  DSL → Graph → IR     |
+-----------+-----------+
            |
            v
+-----------------------+
|   Runtime Compiler    |
| NodeID → NodeIndex    |
+-----------+-----------+
            |
            v
+-----------------------+
|     C++ Runtime       |
|   Dense DSP Engine    |
+-----------------------+
```

The key move:

> **Erase symbols before audio starts.**

No maps. No lookups. No hesitation.

---

# Haskell Layer (Compiler)

This is not just a DSL.

This is a **graph compiler**.

Responsibilities:

* graph construction
* dependency tracking
* cycle detection
* topological sorting
* IR generation
* runtime graph compilation

Example:

```haskell
simpleGraph :: SynthGraph
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc
```

Underneath:

* symbolic `NodeID`
* validated structure
* ordered execution
* compiled into dense indices

Strictness is enforced where it matters:

```haskell
let !n  = ssNextID st
    !n' = n + 1
```

No lazy buildup. No leaks hiding in the shadows. 

---

# Graph IR

Minimal by design:

```haskell
data NodeIR = NodeIR
  { irNodeID   :: NodeID
  , irKind     :: NodeKind
  , irInputs   :: [InputConn]
  , irControls :: [Float]
  }
```

It describes structure.

Nothing about execution strategy.
Nothing about memory.

---

# Runtime Graph (Where It Gets Real)

The compiler transforms:

```
NodeID → NodeIndex
```

Result:

```haskell
data RuntimeNode = RuntimeNode
  { rnIndex      :: NodeIndex
  , rnOriginalID :: NodeID
  , rnKind       :: NodeKind
  , rnInputs     :: [RuntimeInput]
  , rnControls   :: [Float]
  }
```

Everything is:

* dense
* pre-resolved
* ready for linear execution

No symbolic overhead survives this step. 

---

# C++ Runtime

The runtime is not smart.

It doesn’t need to be.

It just runs:

```cpp
for (std::size_t i = 0; i < g->nodes.size(); ++i) {
    process(node[i]);
}
```

Execution order = memory order. 

That’s the whole trick.

## Properties

* no scheduler
* no graph traversal
* no dynamic dispatch
* preallocated buffers
* per-node state

Everything complicated already happened.

---

# DSP Semantics (Current)

This part matters, so no poetry:

* inputs override controls at **block rate**
* only **sample 0** is used for modulation
* oscillator phase is persistent across blocks
* buffers are allocated to `max_frames`

From the runtime:

> “external inputs override controls at block rate using sample 0” 

So yes, this is not audio-rate modulation yet.

---

# FFI Boundary

Small. Sharp. No abstractions leaking.

```c
rt_graph_create(...)
rt_graph_add_node(...)
rt_graph_connect(...)
rt_graph_process(...)
```

That’s it. 

Haskell sends intent.
C++ executes reality.

---

# Example Output

```
Processing 3 blocks in C++...

Block 1
0: 0.000000
1: 0.057564
...
```

Phase continues across blocks.

State is not reset.

Time keeps its memory.

---

# Design Philosophy

MetaSonic treats synthesis as a **compilation pipeline**:

```
DSL → Graph → IR → RuntimeGraph → DSP
```

Each stage is isolated.

Each stage is replaceable.

Each stage can evolve without breaking the others.

---

# Why This Matters

Most systems ask:

> “What should I do next?”

This one answers that question **before audio starts**.

So the runtime never asks.

It just executes.

---

# Current State

Nodes:

* `SinOsc`
* `Out`

Features:

* strict graph construction
* topological ordering
* runtime graph compilation
* dense execution model
* FFI bridge
* stateful DSP

Limitations:

* block-rate modulation only
* minimal node set
* no audio output device
* static graph

---

# Roadmap

Short-term:

* filters, envelopes
* shared buffers
* better validation

Mid-term:

* audio-rate modulation
* parameter automation
* command queue

Long-term:

* kernel fusion
* multi-rate graphs
* SIMD execution
* dynamic graph mutation

---

# Build

```bash
stack build
stack exec metasonic-bridge
```

---

# Status

Research prototype.

APIs unstable.
Architecture evolving.

---

> *You thought this was a synth.*
> *It’s a compiler wearing headphones.*
