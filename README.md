# chorus

Multi-agent text-to-speech broker. One daemon owns the sound card; many agents (Claude Code sessions, other LLM tools) speak through it with distinct voices, volumes, and queues. The user pauses, skips, mutes, or rewinds any agent individually — or controls them as a set. Built in Zig.

## Why

Running several LLM agents in parallel makes them all grab the audio device at once and talk over each other. chorus centralizes audio output behind one process with per-agent identity so you can actually hear what's happening.

## Status

Working end-to-end against OpenAI and Azure TTS. The daemon serializes speech across agents (FIFO, one at a time), supports per-agent pause, resume, mute, skip, volume, and default-voice overrides, and exposes an MCP stdio shim so Claude Code can drive it.

## Build

```
zig build            # emits zig-out/bin/chorus
```

Requires Zig 0.16.0.

## Run

```bash
# 1. pick a provider
export CHORUS_PROVIDER=elevenlabs   # or azure, or openai

# elevenlabs (recommended for distinguishing agents — many distinct voices)
export ELEVENLABS_API_KEY=...
# optional: export ELEVENLABS_MODEL=eleven_turbo_v2_5

# or azure
export AZURE_OPENAI_ENDPOINT=https://...
export AZURE_OPENAI_DEPLOYMENT=gpt-4o-mini-tts
export AZURE_OPENAI_API_VERSION=2025-03-01-preview
export AZURE_OPENAI_API_KEY=...

# or openai
export OPENAI_API_KEY=sk-...

# 2. start the broker (it owns the sound card)
chorus daemon

# 3. from any other terminal, send speech
chorus say "Hello from chorus" onyx

# 4. manage agents
chorus list
chorus pause %12          # tmux pane id, or anything unique
chorus resume %12
chorus skip %12           # drop queued + cancel current
chorus mute %12
chorus volume %12 0.3
chorus voice %12 nova
chorus status
```

## Using with Claude Code

Each Claude Code session launches `chorus mcp` as its MCP stdio server. The shim resolves the session's tmux pane ID (`$TMUX_PANE`) as the agent identity and forwards `speak` calls to the daemon.

## Layout

```
src/
  main.zig         — CLI dispatch (play | speak | daemon | say | list | pause | …)
  daemon.zig       — long-running broker; Unix socket protocol; worker loop
  client.zig       — Unix socket client + agent id resolution
  queue.zig        — thread-safe FIFO SpeakJob queue (pthread-backed)
  registry.zig     — per-agent state (voice, volume, paused, muted, counters)
  audio.zig        — miniaudio wrapper; playFile / playBytes with CancelToken
  mcp_shim.zig     — MCP stdio server; forwards to the daemon
  provider.zig     — type-erased TTS provider interface
  providers/
    openai.zig     — OpenAI /v1/audio/speech
    azure.zig      — Azure OpenAI TTS deployment
    elevenlabs.zig — ElevenLabs /v1/text-to-speech/{voice_id}
vendor/
  miniaudio/       — single-header C audio library
build.zig          — wires C include/source + platform frameworks
```

## Roadmap

1. miniaudio binding, play file from disk. ✅
2. TTS provider interface + OpenAI + Azure + ElevenLabs. ✅
3. Daemon skeleton + Unix socket + agent registry. ✅
4. MCP stdio shim. ✅
5. Serialize mixer: FIFO across agents. ✅
6. Control CLI: pause, resume, skip, list, mute, volume, voice. ✅
7. Per-agent voice + volume config. ✅
8. Ring buffer per agent for rewind.
9. Ducking + panning policies.
10. TUI dashboard.

## License

MIT.
