# AGENTS.md — TTS

Offline macOS text-to-speech app and CLI (`tts`) using Apple's Siri neural voices via `osascript` + `AVSpeechSynthesizer` + bundled LAME MP3 encoder (`vendor/lame`). No Xcode project; `./build` compiles directly with `swiftc`.

## Architecture

- `tts` (`Contents/Resources/tts`) — standalone JXA (`#!/usr/bin/osascript -l JavaScript`) CLI and `--serve` worker: voice discovery & ranking, 4-stage Russian/Ukrainian number/case/unit normaliser (`ROLE` + `NOUNCASE`), Latin slow-down, clause pause splitting (`joins`), PCM/MP3/M4A output.
- `app.swift`, `window.swift` — AppKit main window (420 × 520 pt), menu bar, file open/drop.
- `engine.swift`, `speech.swift`, `voices.swift`, `player.swift`, `text.swift`, `mp3.swift` — bridge to `Resources/tts --serve`, live playback, LAME MP3 encoding.
- `updates.swift` — Sparkle 2.10.1 updater.
- `icon.swift` — 9-bar procedural waveform icon generator.

## Build & Test

- `./build` — builds ad-hoc signed `TTS.app` (`-target arm64-apple-macos13.0`). Works with Xcode Command Line Tools alone (`iconutil` fallback). Full Xcode is used for `Assets.car` (required when `SIGN_ID` is set).
- Run `tts -t FILE` to verify Russian/Ukrainian text normalisation without synthesizing audio.

## Invariants

- **Why `osascript` for Siri voices**: macOS exposes `com.apple.ttsbundle.siri_*` neural voices only to Apple-signed binaries (`/usr/bin/osascript`), never to third-party compiled binaries or `/usr/bin/say`.
- **Zero network**: offline synthesis; only Sparkle update checks use the network.
- **Customizing locally**: edit `tts` (normaliser rules, voice ranking, pause lengths) or Swift UI files, run `./build`, replace `/Applications/TTS.app`.
