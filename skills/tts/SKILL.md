---
name: tts
description: "Turns text into offline MP3, M4A, or WAV audio with macOS Siri voices and Russian/Ukrainian number declension using TTS for Mac (tts). Use when voicing text on a Mac with TTS installed, previewing number normalisation, or customizing TTS."
license: MIT
compatibility: "macOS 13 or later (Apple Silicon) with TTS installed (brew install geragarazagh/tap/tts or /Applications/TTS.app). For cross-platform offline TTS (Linux/Windows too), see geragarazagh/offline-tts."
---

# TTS

Drives the macOS TTS app's bundled `tts` CLI (`Contents/Resources/tts`) for offline Siri-voice synthesis and Russian/Ukrainian number/case normalisation.

## Locate the CLI

Check in order; use the first whose `-h` prints `usage: tts [-v VOICE]` (avoid unrelated `tts` binaries such as Coqui TTS):

```sh
/Applications/TTS.app/Contents/Resources/tts -h
tts -h
```

If neither exists, tell the user how to install it (`brew install geragarazagh/tap/tts`) and stop.

## Common tasks

1. **List available voices** (Siri ranked first, then premium, enhanced, compact):
   ```sh
   /Applications/TTS.app/Contents/Resources/tts -L ru
   /Applications/TTS.app/Contents/Resources/tts -L en
   ```
2. **Preview normalised text** (checks Russian/Ukrainian number & case inflection without rendering audio):
   ```sh
   /Applications/TTS.app/Contents/Resources/tts -t input.txt
   ```
3. **Render audio to MP3 / M4A / WAV** (write text to a temp file first; never pass long text inline):
   ```sh
   /Applications/TTS.app/Contents/Resources/tts -v female -r 1.25 -o output.mp3 input.txt
   ```
   `-v`: `female`, `male`, or exact voice name (`"Voice 2"`, `Milena`). `-r`: speed (`0.6` to `3.9`, `1` = normal). `-o`: output file or directory (`.mp3` uses `ffmpeg` if installed; `.m4a`/`.wav` need no extra tools).

## Rebuilding from source

Clone `https://github.com/geragarazagh/tts`, read `AGENTS.md`, edit `tts` or Swift files, and run `./build` (requires only Xcode Command Line Tools for ad-hoc builds).
