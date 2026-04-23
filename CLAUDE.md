# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

**chorus** is a multi-agent text-to-speech broker written in Zig. A long-running daemon owns the sound card; many agents (Claude Code sessions, other LLM tools) speak through it with distinct voices, volumes, queues, and histories. The user controls any agent individually (pause, resume, skip, rewind) and the set globally (mute all, solo one).

The problem it solves: running multiple LLM agent sessions that all independently grab the audio device produces overlapping speech the user can't parse. chorus centralizes audio output behind one process with per-agent identity.

## Architecture (target)

```
┌────────────────────┐       ┌────────────────────┐       ┌──────────────┐
│  Agent (Claude)    │       │  Agent (Claude)    │       │  Control CLI │
│  ─ MCP shim (stdio)│       │  ─ MCP shim (stdio)│       │  (pause/skip)│
└─────────┬──────────┘       └─────────┬──────────┘       └──────┬───────┘
          │ Unix socket JSON-RPC       │                         │
          └────────────┬───────────────┴─────────────────────────┘
                       │
              ┌────────▼────────┐
              │  chorus daemon  │
              │  ─ agent registry (voice, volume, pan, queue, history)
              │  ─ provider interface (OpenAI, ElevenLabs, ...)
              │  ─ serialize mixer (global FIFO, one agent at a time)
              │  ─ miniaudio playback
              └─────────────────┘
```

## Milestones

1. **miniaudio binding, play file from disk.** _(complete)_
2. TTS provider interface + OpenAI implementation (HTTP fetch MP3 bytes).
3. Daemon skeleton: Unix socket, agent registry, `speak` forwarding.
4. MCP shim binary: stdio JSON-RPC, forwards `speak` to daemon with tmux pane ID as agent identity.
5. Serialize mixer: global FIFO across agents, one speaks at a time.
6. Control CLI: `chorus pause <agent>`, `resume`, `skip`, `list`.
7. Per-agent voice and volume configuration.
8. Ring buffer per agent for rewind.
9. Ducking and panning policies.
10. TUI dashboard.

## Layout

```
src/
  main.zig       — entry point (currently: CLI that plays a file)
  audio.zig      — miniaudio wrapper; playFile(path) blocks until done
vendor/
  miniaudio/     — single-header C library, linked via build.zig
build.zig        — wires C include + source, links platform audio frameworks
build.zig.zon    — Zig package manifest
```

## Commands

```bash
zig build              # build to zig-out/bin/chorus
zig build run -- FILE  # build and play FILE
zig build test         # run unit tests
```

## Design Principles

- **One process owns the audio device.** Every other component is a client.
- **Agents are identified by opaque string IDs.** Default resolver uses tmux pane ID (`$TMUX_PANE`); fallbacks to `pid+cwd` for non-tmux callers. Daemon doesn't care about the shape — just uniqueness.
- **Providers are pluggable behind a Zig interface.** Each provider fetches audio bytes for a (text, voice, speed) request; mixing and playback are provider-agnostic.
- **Zig first, C libraries when they save real work.** We write the daemon, IPC, mixer, ring buffer, and MCP shim ourselves (learning). We pull in miniaudio, libcurl (maybe), and similar for battle-tested lower-level work.
- **Verifiable at every step.** Each milestone produces a runnable artifact you can exercise from the shell.

## Zig Version

Uses Zig 0.16.0 APIs: `std.process.Init` entry signature, `std.heap.smp_allocator`, module-level C integration (`exe_mod.addCSourceFile`, `exe_mod.linkFramework`).

## Environment

- macOS primary target (dev machine). Linux and Windows supported via miniaudio.
- No runtime env vars yet. Milestone 2 will introduce `OPENAI_API_KEY` for the OpenAI provider.
