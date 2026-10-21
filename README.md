# Anki for Droppy

Quick Anki reviews from [Droppy](https://getdroppy.app)'s shelf. Choose a deck, reveal an answer and rate your recall. Anki selects the cards, schedules them and saves your reviews.

## Setup

1. Install [Anki desktop](https://apps.ankiweb.net/).
2. In Anki, open **Tools → Add-ons → Get Add-ons**, enter **2055492159** ([AnkiConnect](https://ankiweb.net/shared/info/2055492159)), then restart Anki.
3. Add the built `AnkiForDroppy.droplet` under Droppy's **Settings → Store → Local droplets** and approve the build, or use Droppy Playground for development.
4. Open this droplet's settings and press **Connect**. Anki must stay running.
5. Choose a deck, open the widget alone, and press **Start review**.

The connection uses `http://127.0.0.1:8765` by default. If you changed AnkiConnect's port, enter the same port in settings. Remote servers and redirects are not supported. No AnkiWeb credentials or direct collection-file access are used.

If your AnkiConnect configuration requires an API key, enter it in settings. The key is kept in memory only and must be re-entered after restarting or re-enabling the droplet. It is not stored in Droppy preferences or logs.

If AnkiConnect reports “Deck counts unavailable” or omits a deck's counts, the droplet automatically searches for its scheduled-due cards, including subdecks. No add-on changes or extra setup are needed. The widget labels these **scheduled due**: they exclude unseen new, suspended and buried cards, include learning cards within Anki's learn-ahead window, and do not apply daily study limits. Home and filtered deck counts can overlap. When scheduler counts work, **due** continues to include Anki's new, learning and review counts. If the installed AnkiConnect lacks the fallback search actions, missing counts remain **Due count unavailable**, never zero.

## Reviewing

- The solo widget displays the card. **Show answer** reveals Anki's answer template; the rating buttons and intervals follow the available Anki choices.
- The paired widget is a compact summary. **Open review** reveals the solo widget.
- The shelf stays open while reviewing. **Pause** releases it; **Resume** rechecks the active card. **Stop** ends the local session without undoing reviews or closing Anki.
- Optional notch progress appears only during an active session. Other Droppy activities can take its place.
- The reviewed count includes confirmed reviews from this session, not an estimated completion percentage. Learning cards can repeat or become due later.

### Use one reviewer at a time

The droplet shares Anki's active reviewer. **Do not grade concurrently in Anki and Droppy**, or run a second review client. The droplet checks the card before actions, but AnkiConnect's legacy interface cannot atomically bind a rating to an expected card ID or guarantee exactly-once delivery.

Starting/revealing changes Anki's reviewer and may focus Anki content, trigger add-on dialogs or play Anki-side audio. Fully background, focus-free behavior is not guaranteed across Anki/add-on versions. Custom add-ons that relabel or intercept rating buttons are not supported.

### Uncertain ratings

AnkiConnect can accept a rating before it is saved. The droplet checks Anki's persisted review history before counting it, and **never automatically sends a rating again** after an ambiguous result.

If **Check your last rating** appears:

1. Press **Check status** to look for the saved review without resending it.
2. If needed, open Anki and verify the card's review history.
3. Only after checking, choose **I've checked Anki…** to acknowledge the uncertainty and start another session.

A small local recovery record (card ID, requested ease, prior review IDs and connection port) survives stopping/re-enabling/restarting. It contains no card text or API key. Pause, stop and cancellation cannot retract a rating already received by Anki. Changing Anki profiles while a rating is pending requires checking it manually in the original profile.

## Card compatibility

The widget renders Anki's template HTML and CSS, including cloze selection and front-side expansion. Supported collection images, styles, fonts and portable audio references load through AnkiConnect. Scripts, remote resources, arbitrary file access and navigation are blocked; supported audio requires explicit playback.

Interactive templates, typed-answer comparison, MathJax, video, SVG, reviewer-only hooks and some Anki-extracted audio/TTS are not reproduced. Missing or unsupported content shows a warning when detectable; use **Open in Anki** rather than rating an incomplete card. This is a companion, not a full replacement for Anki's renderer.

## Development

Built with [DroppyKit](https://getdroppy.app/docs/droppykit), Swift 6.2+ and macOS 14+. Requires Droppy 15.3+ with a compatible SDK framework.

```bash
swift test
/Users/jij/droppykit/Scripts/droppykit build
/Users/jij/droppykit/Scripts/droppykit validate
/Users/jij/droppykit/Scripts/droppykit run -- --shots .build/shots --report .build/shots/report.json
```

Use `droppykit build`, never a bare `swift build`, to produce the loadable bundle. Inspect screenshots and the JSON report, then install into Playground and confirm loading. The DroppyKit MCP tools provide the same loop.

The harness uses injected fixtures by default, not a real Anki connection. Its screenshots cannot grade a real collection. Select another fixture with:

```bash
/Users/jij/droppykit/Scripts/droppykit run -- --scenario answer --shots .build/shots-answer --report .build/shots-answer/report.json
```

Scenarios: `question` (default), `answer`, `ready`, `scheduled-due`, `counts-unavailable`, `paused`, `offline`, `ended`, `uncertain`, `long`, `image`, `unsupported`. Use the production bundle in Droppy/Playground for live integration checks; harness fixtures do not verify Anki's focus behavior, scheduling or host WebKit support.

To test the real connection on the default port without starting a review or grading cards, keep Anki running with AnkiConnect and no API key required, then run:

```bash
ANKI_CONNECT_LIVE_TESTS=1 swift test --filter liveConnectionLoadsDecksWithoutStartingAReview
```

## Before submitting

Before publishing a release:

- Run the tests, universal build, validation and screenshot checks in [Development](#development). Fixture screenshots and the read-only connection test do not verify real grading or installed-host behavior.
- Load the built bundle in Droppy or Droppy Playground and confirm it loads without errors.
- In a disposable Anki test collection, verify start, reveal, one saved rating, next-card presentation, pause/resume and uncertain-rating recovery. Grading changes review history; do not use a personal collection for release testing without explicit approval.
- Check that the newest `CHANGELOG.md` entry matches `version` in `droplet.json` and describes the release. The project uses the [MIT licence](LICENSE).

Before Store submission, replace `Assets/Creator.png` with an owner-selected square PNG of at least 256×256 and review the creator metadata. Leave `AnkiForDroppy.icon` unchanged; the Store's icon is designed by its maintainer.

A GitHub pull request does not publish the droplet. Store submission is a separate, explicit action through `droppykit submit`, which fills in the Store source URL and GitLab owner metadata. Merging, tagging and publishing a release also require separate approval.
