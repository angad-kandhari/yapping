# Security policy

yapping's central claim is that your voice and your text never leave your
machine. A bug that breaks that claim is a security bug, not a feature request,
and it will be treated that way.

## Reporting a vulnerability

Use GitHub's private reporting on this repository: **Security > Report a
vulnerability**. That opens a thread only the maintainer can see.

Please do not open a public issue for something exploitable before there is a
fix. Expect a first response within 72 hours. If a fix is warranted it ships in
the next release, and the advisory is published crediting you unless you would
rather stay anonymous.

## In scope

- Any path where audio, transcripts, or clipboard contents leave the machine
  without the user asking. The app should only ever reach your configured cleanup provider and GitHub for updates.
- Update integrity: a downloaded update that installs without passing the Developer ID signature check
- Local storage: history, stats, or transcripts written without owner-only
  permissions, or in a location other users can read
- Misuse of the input and accessibility grants beyond capturing your voice and pasting the result

## The password field guard is a mitigation, not a boundary

From 2.5 yapping refuses to start the microphone when the focused field
reports itself as a password field, and it repeats that check before pasting.
Please understand its limits before relying on it.

It works by asking the accessibility API what the focused element is. Only an
explicit answer of AXSecureTextField counts. Silence is treated as permission
to dictate, because silence is what most applications return: browsers and
Electron apps usually describe a password box as an ordinary text field, and a
terminal asking for a sudo password is not a text field at all. Blocking on
silence would break dictation nearly everywhere, so it does not.

So: a positive signal is trustworthy and acted on. A negative one cannot be
manufactured. Treat the guard as a seatbelt, not a vault, and please do report
apps where it should fire and does not.

## Out of scope

- Bugs with no security impact; please file a normal issue
- Weaknesses in third-party models or servers you configure yourself, such as
  your own Ollama instance or a custom endpoint
- Attacks that require the attacker to already control your machine or account

## Supported versions

Fixes land in the latest release. Older releases are not patched.
