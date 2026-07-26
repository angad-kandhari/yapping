<p align="center">
  <img src="icon-pack/yapping-icon-1024.png" width="120" alt="yapping icon">
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="icon-pack/wordmark/wordmark-dark.png">
    <img src="icon-pack/wordmark/wordmark-light.png" width="260" alt="yapping">
  </picture>
</p>

<p align="center">
  <b>Hold the globe key. Yap. Done.</b><br>
  Private, on-device dictation for macOS. For certified yappers.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26+-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-F05138" alt="Swift 6">
  <img src="https://img.shields.io/badge/processing-100%25%20local-2ea44f" alt="100% local">
  <img src="https://img.shields.io/github/v/release/angad-kandhari/yapping" alt="latest release">
</p>

---

Hold the Globe (fn) key anywhere on your Mac, speak, release. Your words
appear at the cursor: filler words gone, punctuation fixed, your meaning
untouched. The menu bar logo is the level meter; it dances while you talk.

Nothing ever leaves your Mac. No cloud, no account, no subscription, no
telemetry, no word limits.

## How it works

1. A listen-only event tap watches the Globe/fn key.
2. While you hold it, audio streams into Apple's on-device SpeechAnalyzer,
   so transcription is nearly done the moment you release.
3. An optional local LLM pass (Ollama + gemma3:4b) strips filler words and
   fixes punctuation, with strict guards: if the model is down, slow, or
   tries to editorialize, your raw words are used instead.
4. The text is pasted into whatever field was focused when you started
   talking, and your clipboard is restored.

## Features

- Hold-to-talk on the Globe key, with accidental-tap and fn-shortcut detection
- Live animated waveform in the menu bar (the logo is the meter)
- Personal dictionary: bias recognition toward your names, jargon, and acronyms
- Replacements and snippets: say "my email", get the address
- History with raw and cleaned text side by side; cleanup is never a black box
- Multi-language via on-device model downloads
- Single small binary; the OS owns the speech model

## Install

Build from source (no Gatekeeper friction):

```bash
git clone https://github.com/angad-kandhari/yapping.git
cd yapping
make install
```

Or download the zip from [Releases](https://github.com/angad-kandhari/yapping/releases),
move Yapping.app to /Applications, and on first launch allow it under
System Settings, Privacy & Security ("Open Anyway"), since releases are not
notarized.

One-time setup: grant Microphone, Input Monitoring, and Accessibility when
prompted, and set System Settings > Keyboard > "Press globe key to" to
"Do Nothing". For cleanup, install [Ollama](https://ollama.com) and run
`ollama pull gemma3:4b` (optional; raw transcription works without it).

## Privacy

- Speech recognition: Apple SpeechAnalyzer, on-device
- Cleanup: your own local Ollama model
- Network calls: exactly one destination, localhost
- Your dictations are stored only in your local history file, which you can
  clear from the app

## Roadmap

See [ROADMAP.md](ROADMAP.md). Built with the findings of a market deep-dive
on what dictation users actually want: local processing, no subscriptions,
a personal dictionary, and transparency about what cleanup changed.
