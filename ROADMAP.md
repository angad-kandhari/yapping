# Yapping Roadmap (v2, July 2026)

Grounded in a second research round across open-source dictation issue
trackers (VoiceInk, Handy, Whispering, OpenWhispr, Hex, Amical), competitor
changelogs (Wispr Flow, superwhisper, Aqua Voice, Willow, Spokenly,
MacWhisper), and community discussions. Highlights that shaped this list:

- Voice input for AI coding agents is the category battleground; native
  tools have accuracy and vocabulary gaps that local apps can own.
- First-word clipping from mic startup latency is the most-complained bug
  class in every competitor.
- Hotkey ergonomics (hands-free toggle, silence auto-stop) is the largest
  ergonomics demand cluster, and hold-only PTT is itself an RSI hazard.
- Audio-file transcription is the single most-upvoted request found in
  any tracker, and is nearly free on top of SpeechAnalyzer.
- Removing the Ollama requirement (Apple's on-device Foundation Models)
  kills the biggest setup barrier while staying local-first.

## v1.1 Trust (shipping now)

- Updates window: see at a glance whether you are on the latest, and if
  not, read the release notes for everything you are missing and download
  in one click. Replaces the silent notification-only check.
- First-word reliability: the audio engine starts before anything else on
  key-press and stays pre-warmed between dictations.
- Esc cancels a hold (alongside the existing fn-combo cancel).
- Output options: copy-to-clipboard-only mode, trailing space toggle.

## v1.2 Hands-free

- Double-tap the globe key to toggle hands-free recording; single tap,
  Esc, or (optional) silence detection ends it.
- "Send it" voice command: end a dictation with the phrase and the message
  is sent with zero keypresses. Per-style opt-in, off in terminals.
- RSI-friendly positioning: yapping without holding anything down.

## v1.3 Zero-setup brains

- Cleanup provider choice: Apple's on-device Foundation Models (no setup
  at all), Ollama, or any OpenAI-compatible endpoint (LM Studio and
  friends). Local-first remains the default and the point.
- A built-in "Prompt" style tuned for dictating to AI coding agents:
  terse, technical tokens preserved, no filler.

## v1.4 Files

- Transcribe audio and video files: a menu item and drag-and-drop onto
  the menu bar icon. Transcript to History and clipboard. No speaker
  diarization; meeting notetakers are a different product.

## Parked, deliberately

- Notarized builds and a Homebrew cask (requires the paid Apple Developer
  Program; revisit when adoption warrants it)
- Meeting and system-audio capture with diarization
- Windows and iOS
- Live typing while you speak (tried; did not meet the quality bar)
- Talon-scale voice command grammars
- TTS readback and eyes-free mode
