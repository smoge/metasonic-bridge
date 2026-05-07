# MetaSonic

> *Before the sound breathes,*
> *the structure is decided.*
> *Before the signal moves,*
> *the graph is already aligned.*

MetaSonic is a research direction exploring a compiler architecture for real-time signal graphs with deterministic execution semantics.

This repository, `metasonic-bridge`, is a prototype implementation of that idea.

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

Most audio environments combine:

* graph composition
* scheduling
* signal processing
* state management

Convenient.
But complexity leaks, reasoning breaks down, and maintenance gets harder.

MetaSonic separates:

```
graph construction ≠ signal execution
```

Graph building becomes a compiler problem.
DSP becomes a runtime problem.

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

## Example

```haskell
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc
```

A simple chain:

```
SinOsc → Out
```

But what runs is not this structure directly.

It’s a compiled version of it.

---

## What this means?

The runtime is simple on purpose.

It doesn’t resolve graphs.
It doesn’t schedule.

It executes what was already decided.

---

## Current state

* minimal node set 
* block-based DSP execution
* static, precompiled graph
* audio output integration in progress (q_io)
* DSP layer grounded on q_lib

This is a structural prototype of the MetaSonic approach.

---

## More:

* ARCHITECTURE.md 
* ROADMAP.md 

---

> *you thought this was a synth*
> *it’s a compiler with headphones, rewriting the script*
> *no reaction, just action, every move already fixed*
> *press play—too late, it was already legit*
