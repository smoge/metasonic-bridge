---
title: "What sapf can teach MetaSonic"
author: Bernardo Barros
date: 2026-03-26
tags: metasonic, tinysynth, sapf, design, compiler, dsp, haskell, cpp, sequencing
description: >
  sapf is not a runtime model for MetaSonic to imitate directly, but it does
  suggest several semantic layers worth learning from: forms, structured lifting,
  event/control streams, explicit rate semantics, and texture combinators.
---

[MetaSonic](https://github.com/smoge/metasonic-bridge) is a compiler pipeline
for real-time audio graphs. [SAPF](https://github.com/lfnoise/sapf) is James
McCartney's latest project — a functional, postfix, interactive language
for creating and transforming sounds.

James McCartney, of course, created SuperCollider, one of the most influential
computer music systems ever built. SAPF represents decades of accumulated
thinking about what a language for sound should look like when freed from legacy
constraints. That alone makes it worth studying carefully.

MetaSonic and SAPF are very different projects. MetaSonic is a staged compiler
and a dense runtime substrate. SAPF is a live, interactive environment with a
deep philosophy about sound as structure. Neither one should try to become the
other.

The interesting question is: Which semantic ideas in sapf belong in MetaSonic's
compilation layers, while still keeping tinysynth simple, strict, and
deterministic?

## First principle: learn semantics, not syntax

SAPF's surface notation — postfix, concatenative — is a vehicle for deeper
ideas:

- sound described as _forms_ and transformations
- audio and control represented as _lazy sequences_
- pervasive _automatic mapping_ and iteration at depth
- high-level _scan / reduce_ style composition,
- mostly _immutable_ data, with mutation carefully isolated.

These are considered semantic design choices, shaped by McCartney's long
experience building systems for musicians. MetaSonic developers should
understand why they exist before deciding how to adapt them.

## Sound as form should become patch templates

The single best sapf idea for MetaSonic is right there in the project's slogan:
**sound as pure form**.

In SAPF's examples, a sound is not just a signal expression but a record-like
object with named fields and overridable defaults. The `analog_bubbles` example
makes this explicit: parameters live inside a form, `out` renders the form, and
another form can be created simply by overriding fields.

In many senses, that maps onto what MetaSonic wants to become.

Right now the bridge is good at compiling a graph into a dense runtime
representation. The roadmap already points toward a `MetaDef / GraphInstance`
split, where a compiled graph becomes an immutable template and the runtime can
instantiate it many times. 

SAPF suggests the missing authoring layer above that:

```haskell
PatchForm
  -> elaborate to SynthGraph
  -> compile to MetaDef
  -> instantiate as GraphInstance
  -> override controls / buses / events at runtime
```

So instead of building only node-level DSL combinators, MetaSonic should gain a
**patch-form layer** with:

- named parameters
- inheritance / extension
- default control layouts
- graph elaboration from template to concrete structure
- instance-time override bundles

This gives us presets, variants, voices, and families of related patches without
taking away the simplicity of the runtime layer. The runtime still executes
dense kernels. The compiler still lowers graphs. But the user gets to think in
terms of *instruments* and *patch species*, _not_ manual node wiring.

James McCartney's form concept points toward _the cleanest route_ from today's
graph compiler to a interactive musical system/DSL.

## Automatic mapping should become typed lifting

SAPF's automatic mapping is the second major lesson.

The README frames SAPF as doing for lazy sequences what APL does for arrays. The
real power of APL-style thinking is not really about notation — it is about
_structural lifting_: one operation can transparently work across nested
collections, depth levels, and cartesian combinations.

MetaSonic can (or rather _should_) reinterpret that idea in compiler terms.

In our world, "mapping" should not mean runtime responsability. It can mean
instead compile-time expansion with explicit axis meaning.

For starters, MetaSonic probably needs to distinguish these _kinds of lifting_:

- **channel lift**: make this stereo or N-channel,
- **voice lift**: make a bank of instances,
- **event lift**: schedule repeated or triggered instances,
- **control lift**: expand one control description across many targets.

These are genuinely different concerns, and most systems run into some kind of
trouble by conflating them. Stereo, polyphony, modulation banks, and note
scheduling all become some kind of a "list" and then the distinctions that
matter musically get lost in the implementation.

SAPF's automatic mapping suggests a _much_ cleaner approach: let plugin metadata
and patch elaboration rules declare where lifting is legal and what it means.
Then the bridge can lower the expansion into concrete graph families, channel
layouts, bus signatures, instance streams, &c.

In other words: automatic mapping in MetaSonic should become Haskell-style
_typed lifting_, not implicit container polymorphism.

## SAPF makes a case for an event/control layer "sooner than later"

SAPF represents audio and control events using lazy, possibly infinite
sequences. That model should probably not be copied literally into the tinysynth
runtime, but it does expose something to be redesigned in the current MetaSonic
architecture.

Today the project is not bad on graph structure and presently lacks behind on
temporal structure. The roadmap already notes that: we are missing instance
management, voice allocation, bus effects, and a future sequencing/pattern
layer. SAPF makes a compelling case that this temporal layer should not be
treated as a secondary concern to be added (on a layer above `-core`) after the
"real" graph compiler is finished. There is no reason to impose this
architecture.

Another lesson to kleed in mind: for actual music making,
_event structure is part of the language_, not an afterthought.

This does _not_ mean that tinysynth should evaluate lazy symbolic lists on the
audio thread — that would undermine the determinism that makes the runtime
"trustworthy". Let's flip that: the authoring side of MetaSonic should be able
to describe:

- finite and infinite event streams
- control streams
- triggered patch instances
- texture generators
- note and voice allocation policies
- stream-to-instance lowering

Then the compiler can turn those descriptions into concrete, block-scheduled
runtime actions.

For us, a good rule-of-thumb would be:

> lazy and symbolic on the authoring side, finite and explicit by the time we
> cross the ABI.

That keeps the runtime honest while still letting the language speak about time.

## Rate should stop being a note in the margin

One of the most relevant technical parallels is SAPF's explicit separation of
signal/value behavior and block sizes. Even without mirroring the runtime model,
it reinforces something MetaSonic already knows but has not fully implemented:
_rate is a semantic fact, not a node label_.

MetaSonic already has the right vocabulary on paper:

```haskell
CompileRate < InitRate < BlockRate < SampleRate
```

The current limitation is also already documented: rate is still inferred mostly
from node kind, rather than propagated through the graph. That means a `Gain`
fed by block-rate values still becomes sample-rate simply because the current
compiler does not yet know how to do better. This improvement is already planned
and documented in `ROADMAP.md`.

SAPF reinforces the right instinct: a language for sound should treat temporal
distinctions as _first-class semantic_ information.

For MetaSonic, that suggests three tasks:

1. implement proper upward rate propagation (partially implemented, but not completed)
2. make region formation rate-aware in a musically meaningful way
3. allow authoring constructs that state temporal intent explicitly

So the next time we add a modulation path, the question should not be only
"which node kind is this?" but _also_ "what time scale does this belong to, and
what lowerings are legal from here?"

This is not a matter of (just) optimization. It changes what kinds of musical
structure the system _can express clearly_.

## Scan and reduce should become graph skeletons

SAPF's high-level sequence operators point toward a family of graph-building
abstractions that MetaSonic does not yet expose clearly enough.

Reduction corresponds to things like:

- summing oscillator banks
- mixing voices
- combining channels
- merging analysis paths

Scan corresponds to stuff like:

- serial filter chains
- cumulative modulation
- prefix accumulation
- iterative transformation over a voice list or effect stack

So instead of adding ad-hoc helpers, MetaSonic should probably grow a small set
of _graph skeleton combinators_ that compile to lowering patterns, something
like:

- `mixReduce`
- `serialScan`
- `voiceBank`
- `fanoutMap`
- `outerBank`
- `crossPatch`

These would _not_ be runtime objects. They would be source-language and IR-level
construction idioms that the compiler can analyze, canonicalize, and fuse.

SAPF is a good reminder that expressive power often comes from a small number of
well-chosen structural combinators rather than from a large catalog of primitive
UGens. 

James McCartney has clearly been thinking about this balance for a long time,
and it shows in SAPF's design.

## Texture combinators belong above the runtime

SAPF's texture helpers and overlapping-sound patterns are another important
signal. The examples and prelude are full of texture-oriented abstractions:
forms rendered into streams of events, overlapping layers, randomized swarms,
repeated voice creation, and stereo distribution helpers such as `splay`.

This is exactly the kind of material that should exist in MetaSonic, but, as I
understand at least, in the context of this project, expressed at the authoring
layer rather than inside the C++ hot path.

The split could look like this:

- **tinysynth**: execute compiled graph instances, move samples, manage buses,
  manage voice lifetimes, keep latency predictable
- **bridge / core layer**: describe textures, event populations,
  patch families, and scheduling logic

A texture combinator in MetaSonic should lower into something like a stream of
`GraphInstance` allocations plus control updates, rather than into a runtime
object that interprets symbolic structure while audio is running.

SAPF shows the right *musical layer*. MetaSonic should keep that layer, that
idea and concepts, but move its realization into compilation and scheduling
rather than interpretation.

## Immutability should become an architectural rule

SAPF's immutability story is not incidental. It is part of why the system can be
concurrent without inviting undefined behavior.

MetaSonic should most probably adopt the same discipline, in its own vocabulary:

- `MetaDef` should be immutable
- compiled region graphs should be immutable
- control layouts and bus signatures should be immutable
- runtime mutation should happen only through explicit instance state,
  control ingress, buffers, buses, or other named resources

SAPF isolates mutability in `Ref`. MetaSonic should probably develop an analogous
notion over time, but with more explicit semantics: a control cell, feedback
cell, delay state, buffer handle, or bus endpoint, each carrying effect
information the compiler can reason about.

This fits well with the existing `Eff` vocabulary. The bridge already knows that
graph edges are not enough and that resource effects must matter for ordering and
parallelism. 

SAPF's lesson is that the language should make this discipline feel natural
rather than accidental or difficult.

## Stronger canonicalization follows naturally

There is another lesson in SAPF's style of high-level operators: the more
structural a language becomes, the more important canonicalization becomes.

If MetaSonic gains patch forms, typed lifting, texture combinators, banks,
reductions, scans, and instance streams, then many distinct source programs will
want to lower into the same small family of runtime shapes.

That is good news, I guess.

It means the compiler can normalize aggressively:

- collapse adjacent gains
- fold constant controls
- erase identity routing
- recognize sum trees
- recognize serial chains
- reduce patch overrides to compact control bundles
- collapse lifted structures into shared templates plus per-instance state

SAPF's surface compactness is a reminder that expressive source structure and
compact execution structure can coexist, but only if the compiler is willing to
canonicalize thoroughly.

## Different projects, different trade-offs

There are several areas where MetaSonic's design constraints naturally lead to
different choices than SAPF's. This is not a criticism of either project — all
I'm saying it that they have different goals.

### Compilation vs. interpretation

SAPF is an interpreter. MetaSonic is a compiler. The whole point of MetaSonic is
that graph topology, rate discipline, ordering, and eventually hazard analysis
are resolved before the runtime touches the result. 

That is a different set of trade-offs than SAPF's interactive model, each with
real strengths. Note that this does not mean MetaSonic can't have a REPL or
interactive layer above the compiler.

### Surface syntax

Concatenative syntax is not SAPF's strength we may want to get some inspiration.
The semantic layers are much better candidates. MetaSonic can learn from the
latter without adopting the former.

### Runtime model

On the authoring side, SAPF's "everything is a stream" viewpoint is fertile.
On the runtime side, MetaSonic wants explicit regions, explicit instances,
explicit buses, explicit controls, and explicit lifetimes. Both choices are
valid — they serve different kinds of workflows.

## Concrete changes this comparison suggests

If we try to translate SAPF's lessons into concrete MetaSonic work items, we
could put them in roughly this order:

### Add a patch-form layer above raw node wiring

A source-level structure for named parameters, inheritance, and graph
elaboration. This is the clearest missing layer between a strongly typed graph
DSL and "musically usable instrument description."

### Move `MetaDef / GraphInstance` higher in the design

Not merely as a runtime refactor, but as the place where patch forms, overrides,
voice banks, and texture scheduling eventually meet.

### Add typed lifting metadata

Per node / per patch declarations about whether a thing lifts across channels,
voices, events, or control targets.

### Implement real rate propagation

Not later. Sooner! _Too many later decisions depend on it_.

### Introduce graph skeleton combinators

A small algebra of banks, reductions, scans, and fanouts that lowers cleanly
into IR and fused runtime regions.

### Add an event/control layer before, while keeping it simple for our context

Not a giant host. Not a giant editor. Just enough temporal language to express
instance creation, note streams, texture scheduling, and control processes.

### Keep mutation explicit and effect-typed

No hidden shared state. If something is mutable, it should have a name in the
compiler and a "cost" in the scheduling rules.

## Final thought

What I find most valuable in SAPF is a demonstration of how much musical
expressivity can live _above_ the oscillator/filter level when the language has
the right structural ideas. That is something McCartney has been exploring since
SuperCollider, and SAPF feels like a distillation of those ideas into their
_purest_ form.

MetaSonic should not try to become SAPF. The projects serve different needs and
make different trade-offs. But MetaSonic can learn a great deal from the
thinking behind SAPF.

The goal for MetaSonic is:

- let the author describe musical structure at a high level
- compile that structure into explicit graph templates and instance behavior
- keep the runtime strict, dense, and predictable (thus the name `tinysynth`)

If SAPF says _sound is pure form_, then MetaSonic's answer can be: form is
compiled structure. That is a statement that sapf helped clarify.

---

## References

- [SAPF repository](https://github.com/lfnoise/sapf)
- [SAPF README](https://raw.githubusercontent.com/lfnoise/sapf/main/README.txt)
- [SAPF examples](https://raw.githubusercontent.com/lfnoise/sapf/main/sapf-examples.txt)
- [MetaSonic Bridge repository](https://github.com/smoge/metasonic-bridge)
- [MetaSonic ROADMAP](https://raw.githubusercontent.com/smoge/metasonic-bridge/main/ROADMAP.md)