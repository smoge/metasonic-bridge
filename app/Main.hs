{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Module      : Main
-- Description : Demonstration of the MetaSonic compilation pipeline
--               and realtime audio output

module Main where

import           Control.DeepSeq   (force)
import           Control.Exception (evaluate, finally)

import           MetaSonic.Compile
import           MetaSonic.FFI
import           MetaSonic.IR
import           MetaSonic.Source
import           MetaSonic.Types

-- | Minimal graph: one oscillator writing to output bus 0.
simpleGraph :: SynthGraph
simpleGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  out 0 osc

-- | Linear chain: oscillator → gain → output.
chainGraph :: SynthGraph
chainGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g   <- gain osc 0.5
  out 0 g

-- | Fan-out: one oscillator feeds two independent gain
-- nodes, writing to a separate output bus.
fanOutGraph :: SynthGraph
fanOutGraph = runSynth $ do
  osc <- sinOsc 440.0 0.0
  g1  <- gain osc 0.3
  g2  <- gain osc 0.7
  out 0 g1
  out 1 g2
ass 0 to startAudio instead.
-}

demoMaxFrames :: Int
demoMaxFrames = 256

demoOutputChannels :: Int
demoOutputChannels = 2

audioReadyTimeoutMs :: Int
audioReadyTimeoutMs = 1000

-- | Run the full compilation pipeline on a graph and print
-- each stage's output.
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

-- These are not part of the compilation pipeline; 
-- they exist only to make the intermediate
-- representations visible
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
  putStrLn "Each example will compile, and wait for Enter."
  runPipeline "Simple (SinOsc → Out)"              simpleGraph
  runPipeline "Chain (SinOsc → Gain → Out)"        chainGraph
  runPipeline "Fan-out (SinOsc → 2×Gain → 2×Out)" fanOutGraph
  putStrLn "Done."
