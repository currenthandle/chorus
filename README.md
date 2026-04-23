# chorus

Multi-agent text-to-speech daemon. One broker owns the sound card; many agents speak through it with distinct voices, volumes, and queues. Built in Zig.

## Status

Milestone 1: miniaudio bound, plays an audio file from disk.

## Build

```
zig build
```

## Run

```
zig build run -- path/to/audio.mp3
```

## Roadmap

1. miniaudio binding, play file from disk. **(current)**
2. TTS provider interface, OpenAI implementation.
3. Daemon skeleton: Unix socket, agent registry.
4. MCP shim binary: stdio JSON-RPC, forwards `speak` to daemon.
5. Serialize mixer: global FIFO, one agent at a time.
6. Control CLI: `pause`, `resume`, `skip`, `list`.
7. Per-agent voice and volume config.
8. Ring buffer per agent for rewind.
9. Ducking and panning policies.
10. TUI dashboard.

## License

MIT
