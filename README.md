<div align="center">

<img src="docs/perch-icon.png" width="128" alt="Perch">

# Perch

**One menu bar icon for the small things macOS makes you hunt for.**

Window tiling, clipboard history, a window switcher, live system stats,
disk cleaning, screen and keyboard cleaning, and brightness for every display —
in a single popover, driven by keyboard shortcuts.

No network access. No accounts. No telemetry. Everything stays on your Mac.

[Install](#install) · [Features](#what-it-does) · [Shortcuts](#default-shortcuts) · [Privacy](#privacy-and-security) · [Build it yourself](#building-from-source)

</div>

---

## Install

1. Download the latest `Perch-x.y.z.dmg` from [Releases](../../releases).
2. Open it and drag **Perch** to Applications.
3. **First launch:** right-click Perch in Applications → **Open** → **Open**.
   The app is signed ad-hoc rather than with a paid Apple Developer certificate,
   so Gatekeeper asks once. After that it opens normally.

   If macOS refuses outright, clear the download flag:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Perch.app
   ```

4. Grant **Accessibility** access when prompted
   (System Settings → Privacy & Security → Accessibility).
   Window management, the switcher, keyboard cleaning, and paste-on-pick need it.
   Everything else works without it.

Requires macOS 14 or later. Universal binary — Apple silicon and Intel.

---

## What it does

### Window manager

Snap the focused window to halves, thirds, quarters, or full screen from the
popover or a shortcut. Pressing the same directional shortcut repeatedly cycles
the width through ½ → ⅓ → ⅔, so one key finds the size you meant. `⌃⌥⌫` puts
the window back where it started.

Set a **gap** in Settings → Windows and Perch insets each window, halving the
gap between neighbours so tiled windows stay evenly spaced.

### Custom layouts

A layout is a set of panes in screen-relative coordinates. Applying one tiles
your frontmost windows into its panes in order — five come built in
(Halves, Thirds, Main + Stack, Quarters, Focus), and the pane model is plain
JSON, so adding your own is a small edit in `Sources/Perch/Windows/Layouts.swift`.

### Window switcher

`⌃⌥\`` opens a searchable list of every open window across every app — not just
apps, individual windows. Type to filter by subsequence, so `vsc pkg` finds
*VS Code — Package.swift*. Arrows or Tab to move, Return to raise.

### Clipboard history

Everything you copy, searchable, with an image preview and the source app for
each entry. `⌘⇧V` opens it; `⌘1`–`⌘9` pastes an entry directly; `⌘P` pins one so
it never expires; `⌘⌫` deletes it.

Text, links, colors, files, and images are recognised and shown differently.
History size and retention are configurable, and paste-on-pick puts the entry
straight into the app you came from.

### System monitoring

Live CPU (user vs system), memory with pressure colouring, disk, network
throughput, battery level, health and cycle count, load average, thermal state,
and uptime. Pick one stat to display inline in the menu bar.

### Disk cleaning

Sixteen built-in targets — user caches, Xcode DerivedData and device support,
npm/yarn/pip/Homebrew/Go/Gradle/CocoaPods caches, crash reports, Trash — each
with its measured size. Add your own folders, optionally filtered to files older
than N days.

**Nothing is deleted outright.** Every item is moved to the Trash, so you can
look through it before emptying.

### Screen cleaning

Fills every display with flat black so dust and smudges are actually visible.
Space cycles through white, red, green, blue and grey, which doubles as a
dead-pixel test. Any key or click exits.

### Keyboard cleaning

Locks out the keyboard and trackpad for a countdown so you can wipe the keys
without typing into whatever was focused or triggering shortcuts. Hold `Esc` for
a second to finish early. Perch counts the presses it blocked but never records
which keys they were.

### Monitor brightness

A slider per display. The built-in panel uses real backlight control; external
displays are dimmed with a black overlay, which works over any cable regardless
of DDC/CI support.

---

## Default shortcuts

| Shortcut | Action |
| --- | --- |
| `⌃⌥Space` | Open the Perch panel |
| `⌘⇧V` | Clipboard history |
| `⌃⌥\`` | Window switcher |
| `⌃⌥K` | Screen cleaning |
| `⌃⌥⇧L` | Keyboard cleaning |
| `⌃⌥←` / `→` | Left / right half (press again to cycle ⅓, ⅔) |
| `⌃⌥↑` / `↓` | Top / bottom half |
| `⌃⌥D` / `F` / `G` | Left / center / right third |
| `⌃⌥↩` | Maximize |
| `⌃⌥C` | Center |
| `⌃⌥⌫` | Restore original size |
| `⌃⌥⇧←` / `→` | Move to previous / next display |

Every one of them is rebindable in Settings → Shortcuts. Click a shortcut and
press the new combination; `Esc` cancels.

---

## Privacy and security

Perch is a personal tool that holds unusually sensitive capabilities — it can
see window titles, read the clipboard, and intercept keystrokes. That is worth
being explicit about.

**It never talks to the network.** There is no `URLSession`, no analytics, no
update check, and no subprocess execution anywhere in the source. Grep for it.

**Keystrokes are counted, never recorded.** Keyboard cleaning installs an event
tap to swallow input while you wipe the keys. The handler increments a counter
and discards the event; key codes are not stored, logged, or written anywhere.
The tap is torn down when the session ends, when you hold `Esc`, when Perch
quits, and by an independent failsafe timer that fires even if the UI wedges.

**Clipboard history is local and permission-restricted.** It lives in
`~/Library/Application Support/Perch/`, with the directory at `0700` and the
history file at `0600`. It is not encrypted — treat it as readable by anything
running as you.

Three things reduce what lands in it:

- Content marked `org.nspasteboard.ConcealedType` (what password managers set)
  is skipped.
- A configurable list of bundle IDs is never recorded from.
- Anything matching a credential shape — `sk-`, `ghp_`, `AKIA`, `xoxb-`,
  bare JWTs, PEM private keys — is skipped, with a notice. Toggle in Settings.

This is a safety net, not a guarantee. A pattern matcher will miss secrets that
do not look like secrets. If you copy something truly sensitive, clear the
history afterwards.

**Disk cleaning cannot be pointed at anything dangerous.** Custom targets go
through a path guard that rejects `/`, `/System`, `/Users`, your home directory
and its important children (`Documents`, `Desktop`, `.ssh`, `Library`, …),
relative paths, and anything resolving outside your home or a temp directory.
The guard runs at scan time and again at clean time, not only in the UI, so a
hand-edited preference cannot slip past it. Removal always goes through
`FileManager.trashItem`.

**Accessibility access** is what makes window management possible; macOS has no
narrower permission for it. Perch reads window positions, titles, and app names,
and writes positions and sizes. It does not read window contents.

Run the built-in checks yourself:

```bash
/Applications/Perch.app/Contents/MacOS/Perch --selftest
```

---

## Building from source

```bash
git clone https://github.com/ishanmalu/perch.git
cd perch
Scripts/make-dmg.sh 1.0.0
```

That produces `dist/Perch.app` and `dist/Perch-1.0.0.dmg`.

Swift 6 and the macOS 14 SDK are all you need — full Xcode is not required,
Command Line Tools are enough. The universal binary is produced by building each
architecture separately and `lipo`-ing them together, which sidesteps Xcode's
multi-arch build system.

| Command | What it does |
| --- | --- |
| `swift build` | Debug build |
| `.build/debug/Perch --selftest` | Run the safety checks |
| `Scripts/build-app.sh [version]` | Universal, ad-hoc-signed `Perch.app` |
| `Scripts/make-dmg.sh [version]` | The above, wrapped in a DMG |
| `swift Scripts/makeicon.swift Resources` | Redraw the icon |

The icon is drawn in code (`Scripts/makeicon.swift`) rather than checked in as
a binary asset, so it can be regenerated at any size without design tooling.

### Layout of the source

```
Sources/Perch/
  Core/        preferences, global hotkeys, HUD notifications, login item
  Windows/     Accessibility wrapper, tiling engine, layouts, switcher
  Clipboard/   pasteboard watcher, persistence, history panel
  System/      CPU/memory/disk/network/battery sampling, disk cleaner
  Screen/      screen cleaning, keyboard lock, per-display brightness
  UI/          menu bar popover, settings, shared floating panel
```

---

## Known limitations

- **Ad-hoc signing** means Gatekeeper warns on first open, and because the
  signature changes every build, macOS may ask for Accessibility access again
  after you install a new version.
- **Clipboard capture polls** the pasteboard twice a second — macOS offers no
  change notification. An app that copies and immediately loses focus can be
  attributed to the wrong source app.
- **External display brightness** is a software overlay, not real backlight
  control. It cannot go fully black, and it will not survive a screenshot.
- **Window animation** issues one Accessibility call per frame and is off by
  default; some apps repaint poorly during it.
- **Stage Manager and full-screen windows** are not tiled — macOS owns their
  geometry.

## License

MIT. See [LICENSE](LICENSE).
