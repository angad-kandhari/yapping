# yapping

Hold
the Globe/fn key, speak, release - text appears at your cursor.

Compared to the Python version, transcription uses Apple's on-device
SpeechAnalyzer (macOS 26): audio streams into the recognizer while you are
still holding the key, so the transcript is nearly ready the moment you
release. No Whisper, no model downloads to manage, one 220 KB binary.
Optional cleanup still runs through local Ollama (gemma3:4b) with the same
never-lose-words guards.

## Build and install

```bash
make install     # build, bundle, sign, install to /Applications, launch
```

Requires macOS 26, Xcode command line tools, and (optionally) Ollama with
gemma3:4b for cleanup. First launch downloads the OS speech model for en_US
and asks for Microphone, Input Monitoring, and Accessibility permissions.

## Layout

- `Sources/Yap/FnKeyMonitor.swift` - listen-only CGEventTap on the fn key
- `Sources/Yap/Transcriber.swift`  - AVAudioEngine + SpeechAnalyzer streaming
- `Sources/Yap/Cleanup.swift`      - Ollama polish with length guards
- `Sources/Yap/Paster.swift`       - clipboard + synthetic cmd-V insertion
- `Sources/Yap/StatusItem.swift`   - menu bar icon with live waveform
- `Sources/Yap/AppDelegate.swift`  - hold-to-talk state machine
