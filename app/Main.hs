{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Module      : Main
-- Description : Demonstration of the MetaSonic compilation pipeline
--               and realtime audio output
--
-- Exercises the full pipeline from source graph construction
-- through lowering, region formation, dense compilation, and
-- finally q_io / PortAudio realtime playback from the C++
-- runtime.
--
-- Earlier versions of this demo ended by calling
-- @c_rt_graph_process@ a few times and printing block output.
-- That was useful for smoke testing, but it was not an audio
-- backend. The runtime now owns a realtime engine, so the demo
-- should actually play the compiled graph.
--
-- See Note [Example graphs] for what the three test cases
-- are designed to exercise.
--
-- See Note [Pipeline reading order] in MetaSonic.Types for
-- the recommended reading sequence across the library.

module Main where

import           Control.DeepSeq   (force)
import           Control.Exception (evaluate, finally)

import           MetaSonic.Compile
import           MetaSonic.FFI
import           MetaSonic.IR
import           MetaSonic.Source
import           MetaSonic.Types

{- Note [Example graphs]
~~~~~~~~~~~~~~~~~~~~~~~~
The three example graphs are ordered by structural complexity.
Each is designed to exercise a specific aspect of the
compilation pipeline:

simpleGraph — SinOsc → Out
  The minimal graph. Two SampleRate nodes in a linear chain.
  Should form a single region in formRegions. Validates that
  the basic pipeline (validate, sort, lower, annotate, compile,
  transfer, execute) works end to end.

chainGraph — SinOsc → Gain → Out
  A linear chain of three same-rate nodes with no fan-out.
  Should also form a single region, demonstrating that the
  greedy region formation algorithm (see Note [Region formation]
  in MetaSonic.Compile) correctly extends across compatible
  nodes.

  This chain is the canonical fusion target: when
  kernel fusion is implemented, the oscillator, multiply, and
  output copy can be compiled into a single sample loop,
  eliminating the two intermediate buffers.

  Expected output: Gain output should be half the amplitude
  of the raw oscillator (gain factor = 0.5).

fanOutGraph — SinOsc → 2×Gain → 2×Out
  One oscillator feeding two independent gain paths. The
  fan-out from the oscillator means the two Gain nodes both
  depend on a common upstream node.

  This tests whether region formation correctly handles fan-out.
  Fusion and splitting are dual transformations: sometimes a region
  should be split at a fan-out point to expose parallelism
  or improve vectorization.

  Expected output: two output buses at 0.3 and 0.7 amplitude.
-}

-- | Minimal graph: one oscillator writing to output bus 0.
--
-- See Note [Example graphs].
simpleGraph :: SynthGraph
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc

-- | Linear chain: oscillator → gain → output.
--
-- See Note [Example graphs].
chainGraph :: SynthGraph
chainGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g   <- gain osc 0.5
  out 0 g

-- | Fan-out: one oscillator feeds two independent gain
-- nodes, each writing to a separate output bus.
--
-- See Note [Example graphs].
fanOutGraph :: SynthGraph
fanOutGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g1  <- gain osc 0.3
  g2  <- gain osc 0.7
  out 0 g1
  out 1 g2

{- Note [Demo audio settings]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The C++ runtime pre-allocates per-node buffers to the graph's
@maxFrames@ size. For the realtime path, that value also serves
as the stream block size requested from q_io.

We choose a moderate block size here because this is a demo,
not a latency benchmark. 256 frames is usually a reasonable
compromise between stability and responsiveness.

The demo requests two output channels explicitly. That makes
stereo devices the default happy path:

  * graphs with one Out bus are duplicated to both channels by
    the C++ callback;
  * graphs with two Out buses map naturally to left and right.

If you want the runtime to infer channel count from the graph,
pass 0 to startAudio instead.
-}

demoMaxFrames :: Int
demoMaxFrames = 256

demoOutputChannels :: Int
demoOutputChannels = 2

audioReadyTimeoutMs :: Int
audioReadyTimeoutMs = 1000

{- Note [Pipeline runner stages]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
runPipeline takes a source graph through four stages, printing
the result of each to make the staged architecture visible:

  Stage 1 — Lower to IR (lowerGraph)
    Validates, toposorts, annotates with rates and effects,
    checks rate edge compatibility.
    See Note [Lowering as compilation] in MetaSonic.IR.

  Stage 2 — Region formation (formRegions)
    Partitions the annotated IR into schedulable regions.
    See Note [Region formation] in MetaSonic.Compile.

  Stage 3 — Dense compilation (compileRuntimeGraph)
    Replaces NodeID with NodeIndex; erases symbolic identity.
    See Note [Dense lowering] in MetaSonic.Compile.

  Stage 4 — C++ realtime execution
    Transfers the dense graph across the FFI boundary,
    starts the q_io / PortAudio audio engine, waits for the
    first callback, then lets the graph play until the user
    presses Enter.
    See Note [FFI boundary design] and Note [Realtime audio
    lifecycle] in MetaSonic.FFI.

Each stage's output is force-evaluated before printing to
ensure that any errors surface at the correct stage rather
than being deferred by laziness.
-}

-- | Run the full compilation pipeline on a graph and print
-- each stage's output.
--
-- See Note [Pipeline runner stages].
runPipeline :: String -> SynthGraph -> IO ()
runPipeline label graph = do
  putStrLn $ "\n══════════════════════════════════════"
  putStrLn $ "  " ++ label
  putStrLn   "══════════════════════════════════════"

  -- Stage 1: Lower to IR.
  -- See Note [Lowering as compilation] in MetaSonic.IR.
  case lowerGraph graph of
    Left err -> putStrLn $ "  Lowering error: " ++ err
    Right ir -> do
      ir' <- evaluate (force ir)
      putStrLn "\n  IR nodes (execution order):"
      mapM_ printIRNode (giNodes ir')

      -- Stage 2: Region formation.
      -- See Note [Region formation] in MetaSonic.Compile.
      let !regionGraph = formRegions (giNodes ir')
      putStrLn "\n  Regions:"
      mapM_ printRegion (rgRegions regionGraph)

      -- Stage 3: Dense compilation.
      -- See Note [Dense lowering] in MetaSonic.Compile.
      case compileRuntimeGraph ir' of
        Left err -> putStrLn $ "  Compilation error: " ++ err
        Right rg -> do
          rg' <- evaluate (force rg)
          putStrLn "\n  Runtime nodes (dense):"
          mapM_ printRTNode (rgNodes rg')

          -- Stage 4: C++ realtime execution.
          -- See Note [FFI boundary design] in MetaSonic.FFI.
          withRTGraph (length (rgNodes rg')) demoMaxFrames $ \rt -> do
            loadRuntimeGraph rt rg'
            putStrLn "\n  Starting realtime audio..."
            startRC <- startAudio rt demoOutputChannels (-1)
            if startRC /= 0
              then
                putStrLn $ "  Audio start failed with status " ++ show startRC
              else
                flip finally (stopAudio rt) $ do
                  ready <- waitAudioStarted rt audioReadyTimeoutMs
                  if ready
                    then do
                      putStrLn "  Audio running. Press Enter to stop this example."
                      _ <- getLine
                      pure ()
                    else
                      putStrLn $
                        "  Audio stream opened, but the callback did not report "
                        ++ "ready within " ++ show audioReadyTimeoutMs ++ " ms."

  putStrLn ""

-- Diagnostic printers. These are not part of the
-- compilation pipeline; they exist only to make the
-- intermediate representations visible during development.

printIRNode :: NodeIR -> IO ()
printIRNode n =
  putStrLn $ "    " ++ show (irNodeID n)
          ++ " : " ++ show (irKind n)
          ++ " @ " ++ show (irRate n)
          ++ "  effects=" ++ show (irEffects n)

printRegion :: Region -> IO ()
printRegion r =
  putStrLn $ "    " ++ show (regID r)
          ++ " [" ++ show (regRate r) ++ "]"
          ++ "  nodes=" ++ show (regNodes r)
          ++ "  deps=" ++ show (regDeps r)

printRTNode :: RuntimeNode -> IO ()
printRTNode n =
  putStrLn $ "    " ++ show (rnIndex n)
          ++ " ← " ++ show (rnOriginalID n)
          ++ " : " ++ show (rnKind n)

main :: IO ()
main = do
  putStrLn "MetaSonic realtime demo"
  putStrLn "Each example will compile, start audio, and wait for Enter."
  runPipeline "Simple (SinOsc → Out)"              simpleGraph
  runPipeline "Chain (SinOsc → Gain → Out)"        chainGraph
  runPipeline "Fan-out (SinOsc → 2×Gain → 2×Out)" fanOutGraph
  putStrLn "Done."
