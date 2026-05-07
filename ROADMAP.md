# MetaSonic Roadmap

MetaSonic compiles rich synth graphs in Haskell and executes them
deterministically in C++. The goal is a system with SuperCollider's expressive
power but stronger ahead-of-time guarantees: graph topology, execution order,
rate propagation, and resource hazards are all resolved at compile time, not
discovered at runtime.

The architecture has three layers:

| Layer                                 | Role                                           | Analog in SC |
|---------------------------------------|------------------------------------------------|--------------|
| **metasonic-core + bridge**           | Create and compile graphs                      | sclang       |
| **Compiled RuntimeGraph/RegionGraph** | Immutable synth template                       | SynthDef     |
| **tinysynth runtime**                 | Instance host, buses, groups, voices, MIDI, UI | scsynth      |

[Cycfi Q](https://github.com/cycfi/q) serves as the **DSP kernel and I/O
substrate** — oscillators, filters, envelopes, delays, smoothing, audio streams,
MIDI. It does _not_ own graph topology; MetaSonic does. MIDI input (via Q's
typed MIDI stack) and UI control surfaces are part of the tinysynth layer: live
event dispatch and voice management stay in C++, while Haskell is responsible
only for compiling structure.

---

# Next Steps 

## 0 — Current State (2026-03-22)

What already works:

- Haskell DSL constructs synth graphs with typed nodes and connections.
- Bridge lowers graphs to dense execution order with no symbolic IDs.
- FFI loads nodes/controls in one pass, connections in another.
- C++ runtime walks a dense node array in storage order — no symbolic lookups on the audio thread.
- Three node kinds implemented: `SinOsc`, `Out`, `Gain`.
- Runtime subclasses `q::audio_stream` for audio callback.

Known limitations:

- Connected control inputs are block-latched from sample 0, not sample-accurate yet.
- No `In` node, no real bus-effect propagation.
- Rate inference marks everything `SampleRate` — block-rate regions can't emerge yet.
- No instance model: one compiled graph = the entire engine.

---

## 1 — Q-Backed Node Registry

Replace hand-written DSP with Q primitives and expand the node roster to cover
basic synthesis first.

### 1.1 Replace `SinOsc` internals with `q::sin_osc`

The current `process_sinosc` calls `std::sin` every sample and owns phase as
runtime state. Q's `sin_osc` uses a lookup table, avoids expensive real-time
trig, and expects the exact phase-state/waveform-generation separation the
runtime already has.

### 1.2 Add bandlimited oscillators

Wire up Q's PolyBLEP-based `saw_osc`, `square_osc`, and `pulse_osc`. This is the
single fastest jump from "prototype" to "sounds like a real synth engine."

### 1.3 Add `biquad` / lowpass filter

`NodeKind` already reserves `KBiquad` on the Haskell side. Point it at Q's biquad filter.

### 1.4 Add envelope generator

Wrap `q::envelope_gen` as a node kind. One instance per voice, driven by gate events.

### 1.5 Add delay line

Wrap Q's ring-buffer and fractional-ring-buffer delay. Enables basic effects
(echo, comb, simple reverb building blocks).

### 1.6 Add `In` node

Implement bus input so one graph instance can read from another's output.

### 1.7 Add `dynamic_smoother` at control ingress

Use Q's `dynamic_smoother` at the control-bus boundary so UI/MIDI control
updates arrive at control rate, get smoothed once, and feed sample-rate regions
cleanly. This gives "lag" behavior without complicating the graph language.

**Milestone:** A compiled graph can describe a subtractive voice (oscillator →
filter → envelope → output) using Q-backed nodes.

---

## 2 — MetaDef / GraphInstance Split

Move from "one compiled graph is the whole engine" to "a compiled graph is an
immutable template instantiated many times."

### 2.1 Define the core types

Something like:

```cpp
struct MetaDef {
  RuntimeGraph graph;
  RegionGraph regions;
  ControlLayout controls;
  BusSignature buses;
};

struct GraphInstance {
  MetaDef const* def;
  std::vector<NodeState> states;   // Q objects or kernel state per node
  LocalBuffers locals;
  InstanceStatus status;           // running, releasing, free
};

struct Server {
  GlobalAudioBuses audio;
  GlobalControlBuses control;
  std::vector<Group> groups;
  VoiceAllocator voices;
};
```

### 2.2 Instance lifecycle

- **Allocate** a `GraphInstance` from a `MetaDef`, initializing per-node Q state
- **Set controls** on a live instance (frequency, gate, filter cutoff, …)
- **Release** an instance (gate-off triggers envelope release; instance freed when silent).
- **Free** immediately.

### 2.3 Global buses

Instances read and write named global audio and control buses. Bus width and
rate are known from `BusSignature` at template compile time.

### 2.4 Groups and execution order

Group instances into ordered containers. Within a group, execution order follows
bus dependencies — but unlike SuperCollider, the compiler can derive safe
ordering from `Eff` annotations (`BusRead`, `BusWrite`, `BufRead`, `BufWrite`)
rather than requiring the user to manage node order manually.

**Milestone:** tinysynth can host multiple simultaneous voices from the same or
different MetaDefs, routed through global buses.

---

## Phase 3 — Polyphony and MIDI

**Goal:** Real-time voice allocation driven by MIDI input.

### 3.1 Voice allocator

A C++-side `VoiceAllocator` that maps note-on events to `GraphInstance`
allocation and note-off events to envelope release. Voice stealing policy
(oldest, quietest, etc.) lives here.

### 3.2 Q MIDI integration

Use Q's typed MIDI stack — `note_on`, `note_off`, CC, pitch-bend messages,
processor concept, and MIDI input stream dispatch. Note events stay in C++;
Haskell compiles structure, C++ owns live note lifetimes.

### 3.3 Per-voice control mapping

CC and pitch-bend map to instance control inputs via `dynamic_smoother`.
Velocity maps to envelope or gain.

Milestone: Play a polyphonic MetaSonic instrument from a MIDI controller.

---

## 4 — Regions, Fusion, and Rate Propagation

Move scheduling granularity from individual nodes to fused regions.

### 4.1 Region formation

The compiler already conceptually forms regions. Make this concrete: identify
chains of nodes at the same rate with no external observers of intermediate
values and fuse them into single kernel functions.

### 4.2 Q inside region kernels

A fused region like `saw → lowpass → gain` becomes one tight loop containing a
`q::saw_osc`, a `q::lowpass`, and a multiply — not three dispatch "islands". Q's
function-object style fits this exactly.

### 4.3 Block-rate regions

Fix rate inference so that nodes whose inputs change at control rate actually
run at block rate. This requires the `Eff`-aware region DAG to distinguish
sample-rate and block-rate scheduling units.

### 4.4 Region-level parallelism

Independent regions (no shared bus hazards) can run on separate threads. This is
cleaner than SuperNova's ParGroup model because hazard analysis is structural,
not manual.

Milestone: The runtime schedules fused, rate-aware regions instead of individual
nodes, with measurable performance improvement.

---

## 5 — Hot Graph Replacement

Replace a running MetaDef with a recompiled version without audible glitches.

### 5.1 RCU-based topology swap

The runtime already targets RCU-style reconfiguration. Formalize the protocol:
new `MetaDef` is compiled and lowered while the old one plays; swap happens at a
block boundary; old instance state is migrated where node identity is preserved.

### 5.2 State migration policy

Define which node states survive a hot swap (phase continuity for oscillators,
filter memory, envelope position) and which are reinitialized.

**Milestone:** Edit a graph in the Haskell DSL, recompile, and hear the change
without restarting audio.

---

## Phase 6 — Extended DSP and Ecosystem

Lower priority, reserved for when the core is stable.

- **Spectral processing:** Streaming DFT nodes for vocoder, spectral freeze,
  convolution.
- **Buffer I/O:** Sample playback, granular synthesis, recording into buffers.
- **OSC control interface:** Receive and send OSC for integration with other
  tools.
- **Sequencing / pattern layer:** Haskell-side pattern system (already
  prototyped) driving the server via timed control messages.
- **Plugin hosting:** Load external audio plugins (VST3/CLAP) as opaque nodes.

---

## Design Principles

1. **Haskell compiles, C++ executes.** All graph semantics, rate inference,
   effect analysis, and topological ordering happen before the FFI boundary. The
   C++ runtime is intentionally as simple as possible at each stage.

2. **Q is the DSP substrate, not the architecture.** Q is just the starting
   point, it provides oscillators, filters, envelopes, delays, smoothing, audio
   I/O, and MIDI. It does not own graph topology, scheduling, or instance
   management.

3. **Compiled graphs are stronger than SynthDefs.** A MetaDef carries execution
   order, rate annotations, and (eventually) resource-hazard metadata.
   SuperCollider's SynthDef is a template; a MetaDef is a template _plus_ a
   proof of safe execution.

4. **No symbolic lookups on the audio thread.** Dense indices, pre-resolved
   order, pre-allocated state. This is already true and must stay true at every
   stage.

5. **Compiler-derived ordering beats manual ordering.** SuperCollider requires
   users to manage node order and group structure to avoid bus-dependency bugs.
   MetaSonic can compute safe ordering from effect annotations, giving the same
   flexibility with much less runtime superstition.

6. **Regions are the scheduling unit, not nodes.** Individual UGens are too
   fine-grained for efficient scheduling. Fusion, SIMD, and threading all target
   regions.
