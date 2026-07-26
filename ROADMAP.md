# Yap Roadmap

Yap is hold-to-talk dictation for macOS: hold the Globe/fn key, yap, release,
and clean text lands at your cursor. Fully on-device.

This roadmap is grounded in market research (July 2026) across user forums,
Hacker News threads, GitHub issue trackers, and reviews of Wispr Flow,
superwhisper, VoiceInk, Aqua Voice, Willow, MacWhisper, Handy, Spokenly, and
Apple's built-in dictation. The findings in one line: users are fleeing cloud
subscriptions ($144/yr) toward local, private, one-time or free tools, and the
features they miss most are a personal dictionary, voice self-correction, and
transparency about what the AI cleanup changed.

Yap's position: private, local, instant, yours. No cloud, no subscription, no
telemetry. The system-wide mic indicator is the only thing between you and
your words.

## v0.2 - Daily Driver

Goal: flawless daily use for one person. Every item below is a top churn
reason documented for competing apps.

- Personal dictionary: user-defined names, jargon, and acronyms that survive
  transcription (the single most requested feature in open-source trackers;
  "It's Erin with an E"). Applied via replacement rules plus the cleanup
  prompt.
- Text replacements and snippets: say "my calendar link", get the URL.
- Settings: a simple preferences window (or config file) for language,
  cleanup on/off, cleanup model, sounds, waveform sensitivity, and login item
  toggle. No "configuring a server" onboarding, which is the named churn
  reason for superwhisper.
- Transcript history: last 20 dictations with raw and cleaned versions side
  by side, plus copy buttons. Users distrust cleanup they cannot inspect;
  this is the transparency answer to "the AI silently rewrote my words".
- Reliability hardening: paste into the field that was focused when the hold
  started, verified clipboard restore, graceful mic-device switching, and a
  visible error state instead of silent failures (the founding complaint
  against Apple dictation).
- Additional locales: language picker backed by SpeechAnalyzer's per-locale
  model downloads.

## v0.3 - Context and Control

Goal: differentiation. The research shows raw transcription accuracy has
commoditized; the moat is context handling that stays private.

- Per-app styles: casual in Slack and iMessage, formal in Mail, verbatim
  with preserved camelCase and CLI syntax in terminals and editors. Detected
  from the frontmost app, with user-editable prompts per style, visible in
  the menu. This targets the documented gap between "dumb transcription" and
  "opaque AI rewriting": every prompt is inspectable and yours.
- Private context awareness: read the focused text field via the
  Accessibility API and feed nearby text to the local cleanup model so tone
  and vocabulary match what you are writing. superwhisper-grade context with
  local-only processing, which no competitor currently offers cleanly.
- Self-correction handling: "scratch that", restated sentences, and trailing
  corrections resolved in cleanup instead of transcribed literally (a
  loyalty-winning feature users mourn from Dragon).
- Voice editing v1: select text, hold fn, speak an instruction ("tighten
  this up", "make it a bullet list"), and the selection is rewritten by the
  local model.
- Optional live streaming: SpeechAnalyzer volatile results typed as you
  speak, off by default. Research shows streaming is polarizing, so it ships
  as a choice, not a default.

## v1.0 - Ship It

Goal: something other people can install without a war story.

- Developer ID signing and notarization, DMG packaging, Homebrew cask, and
  Sparkle auto-updates.
- First-run onboarding wizard that walks through the three permission grants
  and the Globe-key system setting, with live status checks for each.
- Distribution model: free and open source, or a modest one-time license.
  Research verdict is unambiguous: one-time or OSS wins this market;
  subscriptions are the top switching trigger.
- Website with the animated waveform mark, a 30-second demo, and honest
  privacy copy: on-device transcription, local LLM cleanup, zero telemetry,
  open code.
- Alternative engine option (exploration): NVIDIA Parakeet via MLX for users
  who want maximum speed or non-Apple-silicon accuracy tradeoffs; community
  benchmarks now treat Parakeet as the latency frontier.
- Moonshot (v1.x exploration): eyes-free mode. Dictate, hear the cleaned
  text read back, say "scratch that" or "send it" without looking at the
  screen. Requested independently across a decade of forum threads; shipped
  by no one.
