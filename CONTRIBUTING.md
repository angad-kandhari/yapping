# Contributing to yapping

Issues and pull requests are welcome.

- Build: `make install` (requires macOS 26, Xcode command line tools)
- No Xcode project; plain SwiftPM plus a Makefile
- Style: match the surrounding code; no em dashes anywhere in code, docs, or output
- Privacy is the product: nothing may make a network call except to localhost
  (Ollama) and, for the user-initiated update check only, the GitHub API
- Test the full hold-to-talk loop before submitting: hold fn, speak, release,
  verify the paste, check History for raw vs cleaned
