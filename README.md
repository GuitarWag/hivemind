# Hivemind

A native macOS app that shows every open AI coding session as a tile in a honeycomb, with live
status, and opens the right terminal tab when you click one.

It watches Claude Code and Codex sessions, reports their status (working, idle, blocked, done),
the model each one runs, how much of its context window it has used, which app hosts it, and how
much of your plan allowance you have spent.

## Requirements

- macOS 26 or later. The UI uses Liquid Glass (`glassEffect`), which does not exist earlier.
- The Xcode command line tools, for `swiftc`.
- [Claude Code](https://claude.com/claude-code) and/or [Codex](https://developers.openai.com/codex),
  whichever you run.
- [herdr](https://github.com/GuitarWag/dev-setup) is optional but does the heavy lifting: it
  supplies live status and lets a click focus the exact terminal tab. See
  [Adapting to your setup](#adapting-to-your-setup) for what happens without it.

## Build and run

```sh
./build.sh          # writes Hivemind.app next to the script
open Hivemind.app
```

There is no Xcode project and no package manifest. `build.sh` is a single `swiftc` call plus a
copy of the icons, so a build takes a few seconds.

To check the data layer without the GUI:

```sh
./Hivemind.app/Contents/MacOS/Hivemind --dump
```

That prints one line per session, the usage limits, and runs the built-in self-checks (icon
loading, comb layout parity, fit-to-view maths, the fuzzy matcher, the Codex rollout parser).
Use it whenever you change anything in the data layer.

## Widget mode

`⌘⇧M`, or the collapse button in the header, shrinks the window to a floating panel pinned to a
corner of the screen. It stays above other windows, lists one compact row per session with its
status colour, keeps the plan usage bars at the bottom, and a click still focuses the session's
terminal tab. `⌘⇧M` again, or the expand button, restores the full window.

The corner is chosen from the small menu in the panel and remembered, as is widget mode itself, so
the app reopens the way you left it. The panel is draggable anywhere by its background if you want
it somewhere other than a corner, and rows scroll past nine sessions.

## Where the data comes from

Nothing is scraped from a terminal and nothing is guessed from a screenshot.

| What | Source |
| --- | --- |
| Claude sessions, live | `~/.claude/sessions/<pid>.json`, one file per running session |
| Claude model and context | the session's transcript in `~/.claude/projects/**/*.jsonl` |
| Claude daily token history | the same transcripts, aggregated over 14 days |
| Claude plan limits | `https://api.anthropic.com/api/oauth/usage`, using Claude Code's own keychain token |
| Codex sessions, live | `herdr agent list` — Codex writes no live registry of its own |
| Codex model, context, plan limits | rollout files in `~/.codex/sessions/**/*.jsonl` |
| Status, tab focus | `herdr agent list` and `herdr agent focus` |
| Which app hosts a session | the process ancestry, walked until an `.app` bundle appears |

## Adapting to your setup

Everything below is a small, clearly marked edit in `App.swift`. The app is one file on purpose.

### Your terminal is not Ghostty

Two constants at the top of `Hosts`, and nothing else:

```swift
static let herdrTerminalBundleID = "com.mitchellh.ghostty"
static let herdrTerminalLabel = "Ghostty · herdr"
```

Set the bundle id to yours, for example `com.googlecode.iterm2` or `com.apple.Terminal`, and the
label to match. They exist because herdr runs as a detached server, so its process ancestry ends at
`launchd` rather than at the terminal that draws it: the terminal has to be named rather than
detected.

Everything else adapts on its own. Host detection walks the process tree until it finds an `.app`
bundle, so cmux, iTerm, WezTerm, kitty, VS Code, GoLand, WebStorm and friends are all identified
with no per-app code, and clicking a tile activates whichever app actually owns the session.

### You do not run herdr

The app still works, with two reductions:

- Claude status falls back to the `status` field Claude Code writes in its own session file, so
  you get idle and busy but not herdr's richer states.
- Clicking a tile activates the host app but cannot select the tab inside it, because no terminal
  exposes a reliable way to map a session to a tab. Terminal.app and iTerm2 are the exception —
  both expose a per-tab `tty`, which `ps` can match to a session's pid, so tab focus for those is
  a contained addition to `Model.focus(_:)` if you want it.
- Codex sessions disappear entirely. They are discovered through herdr, so without it there is
  nothing to list.

### You want Codex sessions

```sh
herdr integration install codex
```

That installs the state hook herdr reads. Without it, `herdr agent list` reports no Codex agents
and the Codex tab never appears.

Two Codex caveats, both because the herdr Codex integration reports no session id:

- Rollouts are matched to a session by working directory, so two Codex sessions running in the
  same directory show the same model, context and title.
- Codex reports no pid either, so those tiles have no Kill action. Focus still works.

### Plans, limits and API keys

Codex plan usage is read from whatever its rollout files report: a primary window and an optional
secondary one, each labelled from its own `window_minutes`, so a five-hour ChatGPT allowance, an
extra weekly limit, or a single 30-day window all render correctly with no code change. If you run
Codex with an API key instead of a ChatGPT plan, there are no plan percentages to read and the
Codex gauge simply does not appear.

For Claude, `Usage.token()` reads Claude Code's OAuth token from the keychain item
`Claude Code-credentials` via `/usr/bin/security`. It goes through the CLI rather than
`SecItemCopyMatching` on purpose: this app is built unsigned and ad hoc, so its identity changes on
every rebuild and the keychain would prompt every time.

### Numbers you may want to change

| Where | What it does |
| --- | --- |
| `Model.init`, the 2 second timer | how often sessions are re-scanned |
| `Model.init`, the 300 second timer | how often plan usage is fetched; the endpoint answers 429 if you go much faster |
| `Comb.baseCell` | unzoomed hex size, 176pt |
| `Comb.zoomRange`, `Comb.fitCeiling` | how far zoom and fit-to-view may go |
| `InfoCard`, the 190k check | Claude does not report its context window, so the cap is inferred; Codex reports its own exactly and is used directly |
| `Stats.scan(days:)` | how far back the daily chart looks |
| `alertGate`, the 80 check | when a usage notification fires |

### A note on animation

There are `ponytail:` comments where a shortcut was taken deliberately. The one worth reading
before you add a spinner: any repeating animation underneath `glassEffect` recomposites the whole
window. A pulsing status icon measured 12-21% CPU while idle; without it the app sits at 0-2%.
One-shot animations tied to a hover or a click are fine, and the app uses several. Repeating ones
are not.

## What it touches

Worth knowing before you run someone else's monitoring app:

- It reads only. The one exception is the Kill action in a tile's context menu, which sends
  `SIGTERM` to that session's process after you confirm a dialog naming the session and its pid.
- It reads your Claude Code OAuth token from the keychain item `Claude Code-credentials` and sends
  it to `https://api.anthropic.com/api/oauth/usage`, and nowhere else. That is the same endpoint and
  the same token Claude Code itself uses for `/usage`. The token is never written to disk, never
  logged, and never printed by `--dump`. Two things worth understanding before you approve the
  keychain prompt:
  - The read goes through `/usr/bin/security`, so approving **Always Allow** grants access to that
    binary, not to Hivemind. Afterwards any process running as you can read the same token with the
    same command and no prompt. Choose **Allow** rather than Always Allow if that matters to you;
    this app cannot undo the grant afterwards.
  - `URLSession` honours system proxy settings, so on a machine with an intercepting proxy the
    bearer token traverses it like any other HTTPS request.
- No other network request is made. Session names, folders, prompts and transcript content stay on
  your machine.
- It shells out to `herdr` for the session list and to `ps` for process ancestry.

## Adding an icon

Icons are [Phosphor](https://phosphoricons.com) SVGs, vendored into `icons/` (MIT, see
`icons/LICENSE`). macOS renders SVG through `NSImage` directly, so there is no asset catalog and no
package dependency for eight kilobytes of glyphs.

To add one: drop the SVG in `icons/`, add a line to the `Ph` enum, and add its name to `Ph.names`
so the `--dump` check verifies it is in the bundle.

Note that the upstream `phosphor-icons/swift` package cannot be used here: its `Package.swift`
never declares `Assets.xcassets` as a resource, so `Bundle.module` does not exist outside Xcode and
the package fails to compile under plain `swift build`.

## Commits

Commits on this repo are recorded at 19:00 or later. A `pre-commit` hook enforces it. Enable the
hooks once per clone:

```sh
git config core.hooksPath .githooks
```

Then commit normally in the evening, or use the helper at any hour:

```sh
scripts/evening-commit.sh -m "feat: something"
```

## License

MIT, see [LICENSE](LICENSE). Phosphor icons are MIT, see `icons/LICENSE`.
