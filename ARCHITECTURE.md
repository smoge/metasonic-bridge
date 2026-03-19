# MetaSonic Architecture

> *The graph is written in symbols.*
> *The runtime speaks in positions.*

This document describes the system as implemented today.

---

## Core Principle

MetaSonic enforces a separation between:

```
graph construction ≠ signal execution
```

* Haskell builds and compiles graphs
* C++20 executes DSP

The runtime does not interpret graphs.
It executes a compiled structure.

---

## Pipeline

```
SynthGraph → GraphIR → RuntimeGraph → DSP
```

Each stage removes ambiguity and fixes structure.

By the time execution begins, nothing remains undecided.

---

## Stage 1 — SynthGraph (symbolic)

* nodes identified by `NodeID`
* connections may refer to other nodes
* order is not yet fixed

This is the most expressive layer.

Invalid graphs can exist here temporarily.

---

## Stage 2 — Validation

The system enforces:

* dependency resolution
* missing node detection
* cycle detection

If the graph is invalid, it fails here.

> *Failure belongs to compilation,*
> *not to the audio thread.*

---

## Stage 3 — Ordering

A topological sort produces:

```
[NodeID] in execution order
```

This step establishes causality and fixes execution order.

---

## Stage 4 — GraphIR (structural)

The graph is lowered into a minimal representation:

* node kind
* inputs
* controls

Still symbolic, but no longer tied to the DSL.

---

## Stage 5 — RuntimeGraph (compiled)

The decisive transformation:

```
NodeID → NodeIndex
```

Symbolic identity is removed.

The graph becomes:

* dense
* ordered
* positional

Properties:

* no maps
* no hashing
* no runtime lookup
* no ambiguity

> *Names disappear.*
> *Only positions remain.*

---

## Runtime Execution Model

The runtime executes a linear sequence:

```
for each unit in memory order:
    process(unit)
```

* execution order = storage order
* no scheduler exists
* no dependency resolution occurs

The runtime does not interpret.
It *only* executes.

---

## Execution Units (and Fusion)

In the current prototype:

* one unit = one node
* one node = one kernel call

Future versions may instead produce:

* fused DSP regions
* grouped execution units
* compiled kernels

The loop remains unchanged.

Only the meaning of “unit” changes.

> *The structure stays.*
> *The granularity changes.*

---

## Node Model

Each runtime node owns:

* control values
* input references
* output buffers
* internal state

Example:

```
SinOsc:
  controls: [freq, phase]
  state: phase accumulator
```

State persists across blocks.

No external scheduler is required.

---

## DSP Semantics (current)

The current system is intentionally simple:

* inputs override controls at **block rate**
* only **sample 0** is used right now
* no audio-rate modulation yet
* buffers sized to `max_frames`

This is a prototype constraint, not an architectural one. This will change.

---

## Memory Model

* buffers allocated per node
* fixed size (`max_frames`)
* no pooling
* no reuse

Predictability over optimization. For now.

---

## FFI Boundary

The boundary between Haskell and C++ is minimal:

* create graph
* add nodes
* connect nodes
* process blocks

Only compiled structure crosses the boundary.

---

## Invariants

These must always hold:

* graph is acyclic before runtime
* execution order is fixed
* runtime graph is dense
* no allocation inside DSP loop
* no symbolic lookup at runtime

---

## What this enables

Given this structure, the system can support:

* kernel fusion
* IR-level optimization
* multi-rate execution
* alternative runtimes

These are not add-ons.
They follow directly from the separation and original design.

---

## What is not implemented yet

* audio-rate modulation
* dynamic graph mutation
* SIMD/vectorized kernels
* shared buffer graph

---

> *The runtime is simple by design.*
> *Because the compiler already made the decisions.*
