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

1. miniaudio binding, play file from disk. ✅
2. TTS provider interface + OpenAI + Azure implementations. ✅
3. Daemon skeleton: Unix socket + agent registry + `speak` forwarding. ✅
4. MCP shim binary: stdio JSON-RPC, forwards to daemon, uses `$TMUX_PANE` as agent identity. ✅
5. Serialize mixer: global FIFO across agents, one speaks at a time. ✅
6. Control CLI: `pause`, `resume`, `skip`, `list`, `mute`, `volume`, `voice`. ✅
7. Per-agent voice and volume configuration (voice falls back to agent's default when `speak` omits it). ✅
8. Ring buffer per agent for rewind. _(next)_
9. Ducking + panning playback policies.
10. TUI dashboard.

## Layout

```
src/
  main.zig         — CLI dispatch
  daemon.zig       — long-running broker; Unix socket protocol; worker loop
  client.zig       — Unix socket client + agent id resolution
  queue.zig        — thread-safe FIFO SpeakJob queue (pthread-backed)
  registry.zig     — per-agent state (voice, volume, paused, muted, counters)
  audio.zig        — miniaudio wrapper; playBytes with CancelToken + volume
  mcp_shim.zig     — MCP stdio server; forwards to the daemon
  provider.zig     — type-erased TTS provider interface
  providers/
    openai.zig     — OpenAI /v1/audio/speech
    azure.zig      — Azure OpenAI TTS deployment
vendor/
  miniaudio/       — single-header C audio library
build.zig          — wires C include/source + platform frameworks
build.zig.zon     — Zig package manifest
```

## Commands

```bash
zig build              # build to zig-out/bin/chorus
zig build test         # run unit tests
chorus daemon          # run the broker (owns the sound card)
chorus mcp             # run as an MCP stdio server for Claude Code
chorus say "hi" onyx   # enqueue speech against the running daemon
chorus list            # inspect agents
chorus pause <agent>   # pause/resume/skip/mute/unmute/volume/voice …
```

## Daemon Protocol

Newline-delimited JSON over a Unix socket (default
`$XDG_RUNTIME_DIR/chorus.sock`; override with `CHORUS_SOCKET`).

Requests:
- `{"op":"speak","agent_id":"…","text":"…","voice":"…","speed":1.0}`
- `{"op":"status"}` / `{"op":"list"}`
- `{"op":"pause"|"resume"|"mute"|"unmute"|"skip","agent_id":"…"}`
- `{"op":"set_voice","agent_id":"…","voice":"…"}`
- `{"op":"set_volume","agent_id":"…","volume":0.3}`

Every response is a single-line JSON object with `ok: bool` and either
an `error` string or op-specific fields.

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
