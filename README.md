# MetaSonic Bridge

Graph compiler and FFI layer for the MetaSonic audio system.

MetaSonic is a research project exploring compiler architecture for real-time
signal graphs with deterministic execution semantics. This repository —
`metasonic-bridge` — is a prototype implementation of its core pipeline:
representing audio graphs in a strongly typed IR, stripping redundant nodes,
and marshaling the result across a thin FFI boundary into C++20.

The source is documented with Haddock comments and cross-reference notes that go
into significantly more detail than this file. For a conceptual picture of the
system, read the code in pipeline order starting from
[`src/MetaSonic/Types.hs`](./src/MetaSonic/Types.hs).

> *Don't run the graph. Compile it.*

```
Haskell DSL → SynthGraph → GraphIR → RuntimeGraph → DSP Engine
```

No symbolic lookups in the audio thread. No runtime graph solving.
Everything is resolved before the C++ layer sees it.

---

## Motivation

Most audio environments combine graph composition, scheduling, signal
processing, and state management into a single layer. Convenient at first — but
complexity grows, and reasoning becomes difficult.

MetaSonic draws a line:

```
graph construction ≠ signal execution
```

Graph building is a compiler problem. DSP is a runtime problem. Two worlds:

- **Haskell** — builds, analyzes, compiles
- **C++20** — executes DSP, deterministic and strict

You don't evaluate structure at runtime. You build, validate, order, compile —
then execute. When audio starts, decisions are already made.

---

## Architecture

`metasonic-bridge` is one layer of a larger system. Each layer can be developed
and tested independently:

```
metasonic-core       DSL — no C++ dependencies, implemented in pure Haskell
     ↓
metasonic-bridge     graph compiler + FFI — Haskell to C++20
     ↓
tinysynth            real-time audio engine — pure C++20, depends on and extends q_lib
     ↓
metasonic-ui         Dear ImGui interface — visualization + parameter control
```

- **metasonic-core** defines the user-facing DSL. No FFI involvement. Type
  discipline is the bridge's responsibility, not the DSL's.
- **metasonic-bridge** compiles graphs into a strongly typed IR and
  marshals across the FFI boundary.
- **tinysynth** is the audio engine. Plugins are authored and tested entirely in
  C++ — no Haskell toolchain required.
- **metasonic-ui** provides real-time parameter control and audio visualization
  through Dear ImGui. It links tinysynth directly for the hot path (knobs,
  meters, FFT display) and `dlopen`s the bridge shared library for structural
  operations (graph editing, recompilation).

The modules in this repository roughly correspond to stages in the compilation
pipeline. The bridge requires that the Haskell and C++ sides stay in sync —
particularly when new tinysynth plugins are introduced — though there are plans
to derive more of this synchronization from plugin metadata.

As the system stabilizes, all layers will live in a single monorepo while
keeping their architectural modularity.

---

## Quick start

Requirements: GHC (tested with GHC 9.10.3 / LTS 24.34), Stack, C++20 compiler
(GCC or Clang), PortAudio (must be installed separately), and q_io (included as
a git submodule).

```sh
stack build
stack exec metasonic-bridge
```

---

## Syntax example

```haskell
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc
```

This builds a simple chain (`SinOsc → Out`), but what runs is not this
structure directly — it's a compiled, validated, topologically ordered version
of it.

---

## Current state

- Block-based DSP execution
- Static, precompiled graphs
- DSP layer grounded on q_lib 
- Minimal node set (tinysynth includes q_lib "plugins" and will extend it)

---

>  *Before the sound breathes, the structure is decided.*
>  *Before the signal moves, the graph is already aligned.*

