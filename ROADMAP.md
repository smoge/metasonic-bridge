# MetaSonic Roadmap

This document describes where the system is heading.

Not everything here exists yet.
Everything here follows from the architecture.

---

## Short-term (stability)

Strengthen the foundation:

* more UGens (filters, envelopes)
* shared buffer allocation
* graph validation improvements
* unit + property-based testing

Just making the system solid.

---

## Mid-term (control)

Introduce controlled flexibility without breaking determinism:

* audio-rate modulation
* parameter automation
* command queue for runtime updates
* partial graph recompilation

The system begins to adapt while preserving compile-time guarantees.

---

## Long-term (transformation)


### 1. Kernel Fusion

> *Many nodes.*
> *One loop.*

Transform:

```
Osc → Filter → Gain
```

Into:

```
single compiled kernel
```

Effects:

* remove intermediate buffers
* reduce memory traffic
* improve cache locality
* improve sample-accurate synchronization within fused regions
* eliminate block-boundary lag between tightly coupled UGens

When multiple DSP nodes are compiled into the same execution unit, modulation, triggers, and state transitions can be resolved inside a single sample loop rather than only at block boundaries.

The runtime loop stays the same.

The execution units become larger.


---

### 2. Sample-Accurate Semantics

Extend timing precision beyond block boundaries:

* sample-accurate triggers
* phase resets
* envelope starts
* parameter changes
* modulation edges

Fusion enables sample-accurate behavior within execution units.

Future work defines how these guarantees extend across execution units.

The goal is to move from block-latched behavior to precise temporal coordination where the architecture allows it.

---

### 3. Multi-rate Graphs

Move beyond fixed rates:

* per-node execution rates
* oversampling for specific nodes
* mixed-rate graphs

Execution becomes heterogeneous across the graph, not fixed globally.

---

### 4. Graph Rewriting

Treat graphs as programs:

* algebraic transformations
* optimization passes
* partial evaluation

The system begins to rewrite itself.

---

### 5. Dynamic Graph Mutation

But controlled:

* versioned graphs
* lock-free swap (RCU-style)
* no interruption of audio thread

Real-time safety remains.

---

### 6. Vectorized Execution

* SIMD kernels
* batch processing
* architecture-aware compilation

DSP becomes explicitly shaped by compiler and hardware characteristics.

---

## Endgame 


At first:

* the system runs graphs

Then:

* the system compiles graphs

Eventually:

* the system determines how graphs should exist

---

## Philosophy

MetaSonic is not trying to be:

* a DAW
* a patching environment
* a scripting tool

It is aiming to be *a domain-specific language for sound, backed by a compiler*.

---

> *You don’t patch cables forever.*
> *At some point, you rewrite the circuit.*
