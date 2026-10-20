# Changelog

## [1.0.0] - 2026-10-20

### Added

- Local AnkiConnect connection with deck selection, a configurable port and an optional API key kept in memory only.
- Solo shelf reviews with question and answer templates, Anki's available rating buttons and interval labels.
- Pause, resume and stop controls, confirmed session-review counts and optional compact notch progress.
- A paired shelf summary that opens the full reviewer.
- Isolated HTML/CSS rendering and supported local images, fonts and audio, with an Open in Anki fallback for unsupported content.
- Persistent recovery for uncertain ratings. Refresh checks saved review history without automatically sending a rating again.

### Fixed

- Keep the connection usable when AnkiConnect reports unavailable scheduler deck counts. Show missing counts as unavailable, not zero.

### Compatibility

- Requires Anki desktop with AnkiConnect running on the same Mac. Anki handles scheduling and saves reviews.
- Use only one reviewer at a time. Concurrent grading in Anki and Droppy is not supported, and fully background operation is not guaranteed.
- Interactive templates, typed-answer comparison, MathJax, video and some Anki audio/TTS require Anki's own reviewer. Scripts and remote resources are blocked.
