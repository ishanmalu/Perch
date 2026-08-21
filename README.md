<div align="center">

<img src="docs/perch-icon.png" width="120" alt="Perch">

# Perch

**One menu bar icon for the small things macOS makes you hunt for.**

Window tiling · Clipboard history · Alt-Tab window switcher · System stats
Disk cleaning · Screen, keyboard & trackpad cleaning · Night mode · Brightness

[![CI](https://github.com/ishanmalu/perch/actions/workflows/ci.yml/badge.svg)](https://github.com/ishanmalu/perch/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/macOS-14%2B-black)
![Universal](https://img.shields.io/badge/binary-universal-black)
![License](https://img.shields.io/badge/license-MIT-black)

No accounts. No telemetry. Nothing leaves your Mac except an update check
you have to turn on.

[Install](#install) · [Features](#features) · [Shortcuts](#shortcuts) · [Updating](#updating) · [Privacy](#privacy-and-security) · [Build](#building-from-source)

</div>

---

## Install

### Homebrew

```bash
brew tap ishanmalu/tap
brew install --cask --no-quarantine perch
```

`--no-quarantine` skips the Gatekeeper prompt. Leave it off if you'd rather
approve the app by hand.

### Download

1. Grab the latest `Perch-x.y.z.dmg` from [Releases](../../releases).
2. Open it, drag **Perch** to Applications.
3. First launch: right-click Perch → **Open** → **Open**. Perch is signed
   ad-hoc rather than with a paid Apple Developer certificate, so Gatekeeper
   asks once.

   If macOS refuses outright:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Perch.app
   ```

### From source

```bash
git clone https://github.com/ishanmalu/perch.git
cd perch
Scripts/install.sh
```

Builds, self-tests, and installs to `/Applications` in one step. Command Line
Tools are enough — full Xcode is not required.

### Then grant Accessibility

System Settings → Privacy & Security → **Accessibility** → add Perch.

Window management, the switcher, Alt-Tab, keyboard cleaning, and paste-on-pick
need it. Everything else works without.

**Requires macOS 14+. Universal binary — Apple silicon and Intel.**

---

## Features

### 🪟 Window manager

Snap the focused window to halves, thirds, quarters, or full screen. Press the
same directional shortcut again and the width cycles ½ → ⅓ → ⅔, so one key
finds the size you meant. `⌃⌥⌫` puts the window back where it started.

Set a **gap** in Settings → Windows and Perch insets each window, halving the
gap between neighbours so tiled windows stay evenly spaced. `⌃⌥⇧←/→` throws a
window to the next display, preserving its relative position and proportions.

### ▦ Custom layouts

A layout is a set of panes in screen-relative coordinates. Applying one tiles
your frontmost windows into its panes, in order.

| Layout | Panes |
| --- | --- |
| Halves | Two columns |
| Thirds | Three columns |
| Main + Stack | 62% main, two stacked beside it |
| Quarters | Four corners |
| Focus | One centred window with margins |

The pane model is plain data — add your own in
[`Sources/Perch/Windows/Layouts.swift`](Sources/Perch/Windows/Layouts.swift).

### ⇥ Window switcher and Alt-Tab

`⌥Tab` is classic Alt-Tab: hold Option, tap Tab to walk the list, release to
switch. `⌥\`` walks backwards. Unlike Command-Tab it lists **windows**, so two
documents in the same app are two separate entries.

`⌃⌥\`` opens the same list as a searchable panel. Typing filters by
subsequence, so `vsc pkg` finds *VS Code — Package.swift*.

### 📋 Clipboard history

Everything you copy, searchable, with image previews and the source app for
each entry.

| Key | Action |
| --- | --- |
| `⌘⇧V` | Open history |
| `⌘1`–`⌘9` | Paste that entry directly |
| `⌘P` | Pin (never expires) |
| `⌘⌫` | Delete entry |
| `↩` | Paste selected |

Text, links, colors, files, and images are detected and shown differently.
Size and retention are configurable, and paste-on-pick drops the entry straight
into the app you came from.

### 📊 System monitoring

Live CPU (user vs system), memory with pressure colouring, disk, network
throughput, battery level, health and cycle count, load average, thermal state,
and uptime — with sparklines for CPU and memory.

The menu bar shows the icon alone by default; Settings → General can put CPU,
memory, network, or battery beside it.

### 🧹 Disk cleaning

Sixteen built-in targets with measured sizes — user caches, Xcode DerivedData
and device support, npm / yarn / pip / Homebrew / Go / Gradle / CocoaPods
caches, crash reports, Trash. Add your own folders, optionally filtered to
files older than N days.

**Nothing is deleted outright.** Every item is moved to the Trash so you can
look through it before emptying.

### ✨ Screen cleaning

Fills every display with flat black so dust and smudges are actually visible.
Space cycles white → red → green → blue → grey, which doubles as a dead-pixel
test. Any key or click exits.

### ⌨️ Keyboard cleaning

Locks out the keyboard and trackpad for a countdown so you can wipe the keys
without typing into whatever was focused. Hold `Esc` for a second to finish
early. Perch counts the presses it blocked but never records which keys.

### 🖱️ Trackpad cleaning

The complement: the pointer is frozen — no movement, clicks, drags, or
scrolling — while **the keyboard stays live**, so a single press of `Esc` or
`⌃⌥⇧T` unlocks it. Your hands are nowhere near the keys while you wipe a
trackpad, which is exactly why the escape hatch lives there.

Both modes run on one event tap, share the same countdown, and share the same
failsafe: an independent timer ends the session even if the UI wedges, and the
tap dies with the process, so input can never stay locked.

### 🌙 Night mode

Warms the screen by rewriting each display's gamma ramp — the same mechanism
f.lux and Night Shift use. Because gamma is applied by the window server
underneath everything, it tints the whole screen without an overlay and never
shows up in screenshots or recordings.

6500K (neutral) down to 2400K (deep amber). Manual with `⌃⌥N`, on a
sunset-to-sunrise schedule, or between custom hours. macOS restores the system
ramps when the process exits, so a crash can't leave your display stuck orange.

### 🔆 Monitor brightness

A slider per display. The built-in panel uses real backlight control; external
displays are dimmed with a black overlay, which works over any cable regardless
of DDC/CI support.

---

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌃⌥Space` | Open the Perch panel |
| `⌘⇧V` | Clipboard history |
| `⌥Tab` | Alt-Tab — hold Option, tap Tab, release to switch |
| `⌃⌥\`` | Window switcher (searchable) |
| `⌃⌥N` | Night mode |
| `⌃⌥K` | Screen cleaning |
| `⌃⌥⇧L` | Keyboard cleaning |
| `⌃⌥⇧T` | Trackpad cleaning |
| `⌃⌥←` `→` | Left / right half — press again to cycle ⅓, ⅔ |
| `⌃⌥↑` `↓` | Top / bottom half |
| `⌃⌥D` `F` `G` | Left / center / right third |
| `⌃⌥↩` | Maximize |
| `⌃⌥C` | Center |
| `⌃⌥⌫` | Restore original size |
| `⌃⌥⇧←` `→` | Move to previous / next display |

All rebindable in Settings → Shortcuts. Click a shortcut, press the new
combination; `Esc` cancels.

**Can't see the menu bar icon?** A notch or a full menu bar can hide it, and
macOS gives apps no say in status item placement. `⌃⌥Space` always opens the
panel, and when Perch detects its icon is unreachable it shows the panel as a
floating window at the top right instead.

---

## Updating

**In-app** — the Updates row at the bottom of the panel, right-click the menu
bar icon → Check for Updates, or Settings → General. Automatic checking is off
by default; when on it runs at most once a day.

Download fetches the DMG, verifies it against the `SHA256SUMS.txt` published
with the release, and reveals it in Finder. You open it and drag Perch across.

Perch does not install updates itself, deliberately. An app that can silently
replace its own binary from the network is a much larger thing to trust than
one that hands you a verified file — especially one already holding
Accessibility and input-tap permissions.

**Homebrew**

```bash
brew update && brew upgrade --cask perch
```

**From source**

```bash
git pull && Scripts/install.sh
```

---

## Privacy and security

Perch holds unusually sensitive capabilities — it can see window titles, read
the clipboard, and intercept keystrokes. That's worth being explicit about.
Full detail in [SECURITY.md](SECURITY.md).

| Capability | Used for | Bounded by |
| --- | --- | --- |
| Accessibility | Window frames, titles, app names | Never reads window contents |
| Event tap | Swallowing input while cleaning keys or trackpad | Counts events; key codes discarded |
| Pasteboard | Clipboard history | `0600` file, filtered (below) |
| Filesystem | Cache measurement and clearing | Path guard, Trash only |
| Network | Update check | Off by default; GitHub only |

**Keystrokes are counted, never recorded.** The keyboard-cleaning event tap
increments a counter and discards the event. Key codes are not stored, logged,
or written anywhere. The tap is torn down when the session ends, when you hold
`Esc`, when Perch quits, and by an independent failsafe that fires even if the
UI wedges.

**Clipboard history is local and permission-restricted**, at
`~/Library/Application Support/Perch/` with the directory `0700` and the file
`0600`. It is **not encrypted** — treat it as readable by anything running as
you. Three filters reduce what lands there:

- Content marked `org.nspasteboard.ConcealedType` (what password managers set).
- A configurable list of bundle IDs that are never recorded from.
- Anything matching a credential shape — `sk-`, `ghp_`, `AKIA`, `xoxb-`,
  bare JWTs, PEM private keys — skipped with a notice.

That last one is a safety net, not a guarantee. A pattern matcher misses
secrets that don't look like secrets. If you copy something truly sensitive,
clear the history afterwards.

**Disk cleaning can't be pointed anywhere dangerous.** Custom targets pass a
guard rejecting `/`, `/System`, `/Users`, your home directory and its important
children (`Documents`, `Desktop`, `.ssh`, `Library`, …), relative paths, and
anything resolving outside home or a temp directory. It runs at scan time *and*
clean time, so a hand-edited preference can't slip past it.

Verify any build yourself:

```bash
/Applications/Perch.app/Contents/MacOS/Perch --selftest
```

---

## Building from source

```bash
git clone https://github.com/ishanmalu/perch.git
cd perch
Scripts/make-dmg.sh 1.1.0
```

Swift 6 and the macOS 14 SDK are all you need — full Xcode is not required.
The universal binary is produced by compiling each architecture separately and
`lipo`-ing them together, which sidesteps Xcode's multi-arch build system.

| Command | What it does |
| --- | --- |
| `swift build` | Debug build |
| `.build/debug/Perch --selftest` | Run the safety checks |
| `Scripts/install.sh [version]` | Build, verify, install to `/Applications`, relaunch |
| `Scripts/build-app.sh [version]` | Universal, signed `Perch.app` |
| `Scripts/make-dmg.sh [version]` | The above, wrapped in a DMG |
| `Scripts/setup-signing-identity.sh` | One-time: stable identity so macOS keeps the Accessibility grant across rebuilds |
| `Scripts/publish-cask.sh [version]` | Update the Homebrew tap from a published release |
| `swift Scripts/makeicon.swift Resources` | Redraw the icon |

The icon is drawn in code ([`Scripts/makeicon.swift`](Scripts/makeicon.swift))
rather than checked in, so it regenerates at any size without design tooling.

### Source layout

```
Sources/Perch/
  Core/        preferences, global hotkeys, HUD, login item, updater
  Windows/     Accessibility wrapper, tiling engine, layouts, switcher
  Clipboard/   pasteboard watcher, persistence, history panel
  System/      CPU/memory/disk/network/battery sampling, disk cleaner
  Screen/      screen cleaning, keyboard lock, night mode, brightness
  UI/          design system, menu bar popover, settings, floating panel
```

`SelfTest.swift` holds the safety-critical checks. They ship inside the binary
because XCTest isn't available with Command Line Tools alone; CI runs them
against both the debug build and the shipped bundle.

### Releasing

```bash
git tag v1.1.0 && git push origin v1.1.0
```

The release workflow builds a universal DMG, self-tests the shipped bundle,
publishes it with checksums, and validates that the Homebrew cask renders.
Then `Scripts/publish-cask.sh 1.1.0` pushes the cask to the tap.

---

## Known limitations

- **Ad-hoc signing** means Gatekeeper warns on first open. Because an ad-hoc
  signature derives from the binary itself, every rebuild is a different code
  identity and macOS forgets the Accessibility grant — the toggle looks enabled
  while the app still reads as untrusted. Run
  `Scripts/setup-signing-identity.sh` once if you build locally.
- **Clipboard capture polls** twice a second; macOS offers no change
  notification. An app that copies and immediately loses focus can be
  attributed to the wrong source.
- **Night mode's sunset schedule** uses fixed hours (20:00–07:00) rather than a
  real solar calculation, which would mean asking for your location.
- **External display brightness** is a software overlay, not real backlight
  control. It can't go fully black and won't survive a screenshot.
- **Window animation** issues one Accessibility call per frame, is off by
  default, and some apps repaint poorly during it.
- **Stage Manager and full-screen windows** aren't tiled — macOS owns their
  geometry.

## License

MIT — see [LICENSE](LICENSE).
