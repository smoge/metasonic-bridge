# MetaSonic

MetaSonic is a research project exploring compiler architecture for
real-time signal graphs with deterministic execution semantics. This
repository, metasonic-bridge, is a prototype implementation of that
architecture.

The code is documented with Haddock comments and cross-reference
notes, which are more detailed than the README.md and ARCHITECTURE.md files.

---

## Why "metasonic-bridge"

This repository is one piece — but a fundamental one — of a larger system design. metasonic-bridge focuses on graph compilation: representing audio graphs in a strongly typed IR (intermediate representation), stripping away unnecessary elements, and marshaling the result across a thin FFI boundary into C++.

But it is only one layer. The two adjacent layers can each be developed independently (as the different modules in this repo, which correspond to different stages into the pipeline):

* metasonic — the Haskell DSL that sits above this layer. It can be developed with no FFI involvement whatsoever.
* tinysynth — the audio engine, written entirely in C++20. Plugins are written at this layer and can be built and tested purely in C++.

The bridge naturally requires that the Haskell and C++ sides stay in sync — particularly when new tinysynth plugins are introduced — but there are plans to automate more of this synchronization via plugin metadata.


--- 

Most systems blur everything together.

This one draws a line.

Two worlds:

* **Haskell** — builds, analyzes, compiles
* **C++20** — executes DSP, deterministic and strict

Pipeline:

```
Haskell DSL → SynthGraph → GraphIR → RuntimeGraph → DSP Engine
```

No symbolic lookups in the audio thread.
No runtime graph solving.
No “figure it out later.”

Everything is resolved before the C++ layer.


---

## Why this exists

Most audio environments combine graph composition, scheduling, signal
processing, and state management into a single layer.

Convenient at first - but complexity grows, reasoning and maintenance gets more difficult.

MetaSonic separates them:

```
graph construction ≠ signal execution
```

Graph building is a compiler problem. DSP is a runtime problem.

---

## The idea

> *Don’t run the graph.*
> *Compile it.*

You don’t evaluate structure at runtime.

You:

1. build
2. validate
3. order
4. compile
5. execute

When audio starts, decisions are already made.

---

## Minimal example

```haskell
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc
```

A simple chain:

```
SinOsc → Out
```

But what runs is not this structure directly — it's a compiled version of it.

---

## What this means

The runtime is simple on purpose. It doesn't resolve graphs. 
It doesn't schedule. It executes what was already decided.

---

## Current state

* minimal node set 
* block-based DSP execution
* static, precompiled graph
* audio output integration in progress (q_io)
* DSP layer grounded on q_lib

This is a structural prototype of the MetaSonic approach.

---

## More

* Haddock documentation (comments) and Notes
* ARCHITECTURE.md 
* ROADMAP.md 

---

> *Before the sound breathes,*
> *the structure is decided.*
> *Before the signal moves,*
> *the graph is already aligned.*