# Changelog

All notable changes to Perch. Versions follow [semver](https://semver.org),
and each heading below corresponds to a published
[release](https://github.com/ishanmalu/Perch/releases).

## [1.9.1] — 2026-09-04

Homepage only — the app binary is unchanged from 1.9.0. It is tagged as a
release so the published site and the version it names stay in step.

### Added
- **The panel demos on the homepage actually work.** Dragging the brightness
  slider dims the page and Night Mode warms it, using the same mechanism the
  app uses: where Perch has no backlight to move it floats a black overlay
  above everything, click-through and clamped at 0.85 so the slider never
  disappears. Night Mode needs two layers, because multiplying an amber pane
  against a near-black backdrop gives near-black — a screen layer lifts red and
  green in the shadows so the dark theme warms too.
- **The Sound tab is on the site.** The headline feature of 1.9.0 had not made
  it onto the homepage at all.

### Fixed
- **The demo showed a GPU feature that does not exist.** It drew a ranked list
  of processes using the GPU; Perch has never had a per-process GPU breakdown,
  and the caption printed beside it already said so. Disk and network had a
  milder version of the same problem, rendering as bars what the app renders as
  values. Only CPU and memory rank anything, so only they keep bars now.
- **The panel footer read 1.8.0**, through two releases. The release workflow
  now refuses to publish when the homepage does not name the version being
  tagged.
- **The site drew no graph for anyone who asked for reduced motion.** The trace
  only ever got its path from the animation frame, so the gauge was empty.
- The metric tabs, and the brightness slider, were unreachable by keyboard.
- Memory was tinted purple on the site against green in the app; the download
  size was stated as 4 MB, which was neither the 2.5 MB download nor the 7 MB
  install; the build-from-source step said `cd perch` after cloning `Perch`,
  which fails on a case-sensitive volume; and the privacy section counted two
  network features when installing an update makes three.
- An unclosed `<div>` in the privacy section.

## [1.9.0] — 2026-09-02

### Added
- **A Sound tab**, at the end of the System row. Output volume and mute, output
  device switching, and a live list of the apps making noise, with helpers
  folded into the app that owns them so a browser playing in a tab reads as the
  browser.
- **A one-command install.** Perch is signed but not notarized, so macOS
  quarantines the download and blocks the first launch, and the instructions
  ended by asking a stranger to paste an `xattr` command. Now:

  ```
  curl -fsSL https://ishanmalu.github.io/Perch/install.sh | bash
  ```

  It reads the latest release, verifies the download against the published
  checksum and refuses to continue without one, installs it, clears the
  quarantine flag and starts it. No privileges are requested, and it falls back
  to `~/Applications` when `/Applications` is not writable.

### Fixed
- **The audio sampler never stopped.** It started when the System tab appeared
  and then kept walking every audio process on the machine every two seconds
  for the life of the app. It now runs only while the Sound metric is on
  screen. Every other sampler already stopped with the panel.

### Notes
- There are no per-application volume sliders, and there cannot be without
  shipping an audio driver. macOS has no per-application volume: a process
  audio object carries no level control, and there is no private equivalent.
  The only route is a virtual output device the whole system is routed
  through — a driver, an installer and an approval prompt, which is what
  Background Music and SoundSource are. Perch reports rather than mixes.

## [1.8.5] — 2026-08-31

### Changed
- **Screenshot moved from the Tools grid to the panel header.** As a tile it
  was a seventh item in a three-column grid, so it sat alone on a row with two
  empty cells beside it. It is a small icon button now, ahead of the clipboard
  one, and the grid is an even two by three again. `⌃⌥⇧4` is unchanged.

### Fixed
- The site's copy of the panel still read 1.6.0 in its footer, two releases
  behind, because that version is written into the page rather than rendered.
- The Screenshot caption on the site listed six modes and overflowed a caption
  box sized for the descriptions that existed when it was built, so it was cut
  off mid-sentence. The feature is described in the capability grid and the
  shortcut table instead, where there is room for it.

## [1.8.0] — 2026-08-31

### Added
- **Updates install themselves.** Perch downloads, verifies, replaces itself and
  restarts. No mounting, no dragging, no clearing the quarantine flag by hand —
  which was the same work as a first install, every time. The checksum is not
  what makes this safe: it comes from the same release over the same connection,
  so it only proves the bytes arrived intact. The control is the code signature,
  which must satisfy the running app's own designated requirement, so a
  substituted build cannot be signed to match and is refused before anything
  moves.
- **A screenshot tool that stays armed.** macOS already takes screenshots; the
  reason for another is what happens after one. Drag and it captures, and the
  crosshair is still there for the next. Six grabs off a page is six drags
  rather than six trips to the keyboard.
- **Capture a window, a display, or on a delay.** `W` takes the window under the
  pointer without whatever sits behind it, `F` takes the whole display, and `D`
  counts down first — the only way to photograph a menu, since reaching for the
  mouse closes it.
- **Read the text out of a capture.** `T` copies the words instead of the
  picture. Vision normalises a double hyphen to an em dash, which silently
  breaks any command line put through it, so that is repaired.
- **Sample a colour** with `C`, copied as hex.
- **Pin a capture** with `P` and it floats above everything, which is the point
  of taking it when you need to read it while working somewhere else.
  Double-click to copy.
- **Quarters have shortcuts** — `⌃⌥U I J K`, the layout Rectangle and Magnet
  use. They were reachable only from the panel before.

### Fixed
- **The site advertised shortcuts that did not exist.** Fourteen of twenty-three
  were wrong, nine bound to nothing, and one documented `⌃⌥K` as "bottom right"
  when it blanked every display. Every caption is now checked against the
  binding table rather than written from memory, and actions with no global
  shortcut say so instead of naming a key that does nothing.
- Screen cleaning moves to `⌃⌥⇧S`, freeing `⌃⌥K` for the bottom-right quarter
  and putting it beside the other two cleaning modes.

## [1.7.0] — 2026-08-29

### Added
- **Keep-awake sessions.** Prevent Sleep was on until you turned it off,
  which is the least useful shape for it — the reason you want a Mac awake
  almost always has an end. The switch still holds indefinitely, and the
  clock beside it offers 15 minutes through 8 hours, with the time left shown
  in the row.
- **A choice about the display.** Keeping the screen on is wrong for a long
  download, so a preference holds the machine awake while letting the display
  sleep. Changing it re-applies the assertion instead of waiting for the next
  session.
- **Sessions that start themselves** — while plugged in, while a chosen app is
  running, or while the CPU sits above a threshold. A trigger only retracts
  what a trigger started, so switching it on by hand outranks it, and a
  session ends on its own below a battery floor.
- **Choose which window goes in which pane.** Layouts filled panes from the
  stacking order, which is right only when the windows you want are already in
  front; the rest of the time you tiled and then dragged things back. Picking a
  layout now asks, prefilled front to back so confirming unchanged does what
  tiling used to. It only asks when there is a decision to make — more windows
  than panes — and Option flips that either way.
- **Fill Screen With All Windows**, sizing every window on the display to the
  whole usable area. Not macOS full screen: no Space is created, the menu bar
  stays, and Alt-Tab still walks them.

### Fixed
- **A keep-awake restart loop.** The battery floor ended a session, a trigger
  whose condition still held restarted it on the next tick, and the floor ended
  it again — a notification every two seconds and the power assertion thrashing
  for as long as the battery stayed low. The floor now fires once and stays
  quiet until the charger goes in or the charge recovers past a margin.
- **A timer that ran for the life of the app.** It now ticks once a second only
  while a session counts down, drops to five seconds while a trigger is watched,
  and stops entirely when neither applies — which is most installs.
- **Silently empty panes.** The layout picker can sit open long enough for a
  chosen window to close, and a dead accessibility element accepts the calls
  while reporting nothing. Perch now says how many panes it could not fill.
- **The Homebrew cask told people to run a command that fails.** It advised
  `--no-quarantine`, which Homebrew 6 removed, and described Perch as ad-hoc
  signed, which stopped being true at 1.5.0.

## [1.6.0] — 2026-08-23

### Added
- **The System tab drills down.** Pick CPU, GPU, memory, disk or network and
  get that subsystem on its own: per-core load, GPU utilisation, disk
  throughput, per-interface network, each with a history trace.
- **Processes are grouped under the app that owns them**, with usage
  aggregated to the parent, so Chrome's dozen helpers read as one row. End a
  process from the context menu without opening Activity Monitor.
- **The Wi-Fi link is reported, not just its traffic.** Negotiated rate,
  signal and noise as a signal-to-noise ratio, channel, band, width, standard
  and security. The bars rate SNR rather than raw signal, because a strong
  signal in a noisy room is not a good link.
- **A speed test**, because the negotiated rate is only a ceiling — a link can
  report 780 Mbps and move 116. It downloads a block of bytes from Cloudflare's
  open endpoint and times it, reporting megabits. It runs when you press Run
  and never on its own. This is the second and last thing in Perch that opens
  a socket; `SECURITY.md` says so.

### Fixed
- **Network throughput could be wildly wrong.** The kernel's byte counters are
  32-bit and wrap every 4.29 GB, which on a fast link is minutes. The readings
  were widened before subtracting, so each wrap produced a delta of about
  1.8e19 instead of a small number.
- **Layouts tiled the wrong windows.** The ordering used a comparison that
  ignored its second argument and so was not a strict weak ordering, which is
  undefined behaviour. Window order now comes from the real z-order.
- **Panels did not take the keyboard when opened by shortcut**, so Escape and
  typing went to whatever was underneath.
- **Closing a window from the switcher could crash.** A value from the
  accessibility API was force-cast without a type check.
- **Ending a task could hit the wrong process.** Readings can be seconds old
  and macOS reuses pids, so the process is now re-verified before it is
  signalled.
- **`shasum -a 256 -c SHA256SUMS.txt` failed for everyone who downloaded a
  release.** The file recorded `dist/`-prefixed paths. The published checksums
  for 1.4.0 and 1.5.0 have been corrected in place; the DMGs were never wrong.

## [1.5.0] — 2026-08-22

### Fixed
- **Accessibility stopped working after every update.** Releases were ad-hoc
  signed, and an ad-hoc signature is derived from the binary, so each release
  was a different code identity and macOS dropped the grant recorded against
  the previous one — while still showing the app as enabled, which made the
  usual advice useless. Releases are now signed with a consistent certificate.
- Perch now recognises that state and says so, instead of asking you to enable
  a permission that already looks enabled. It inspects its own signature: a
  build with a certificate has a stable identity, so a denial genuinely means
  the permission was never granted; an ad-hoc build's identity changes every
  release, so a denial after an update means a stale entry.
- The Homebrew instructions did not work. The tap did not exist, third-party
  taps must now be trusted before Homebrew will load them, and Homebrew 6
  removed `--no-quarantine` altogether. All three corrected, and the tap is
  published.

### Added
- Notarization pipeline (`Scripts/notarize.sh` plus release-workflow steps),
  inert until Apple Developer credentials are supplied. See
  [docs/NOTARIZING.md](docs/NOTARIZING.md).
- A landing page at <https://ishanmalu.github.io/Perch/>, served from `docs/`.

### Changed
- Screen Recording, added in 1.4.0 and documented nowhere, is now covered in
  the README and SECURITY.md.
- `⌃⌥=` had a default shortcut but no handler; removed.

## [1.4.0] — 2026-08-22

### Added
- **Alt-Tab now shows live window thumbnails**, in an auto-sizing grid — fewer
  windows means bigger previews. Type to filter, arrows and Tab to move.
- **Per-window actions while the modifier is held**: `W` closes the window, `M`
  minimises it, `Q` quits the app. The list refreshes in place rather than
  closing.
- **The title list is now a separate switcher** on its own shortcut, and can be
  switched off entirely in Settings → Windows for anyone who only wants Alt-Tab.
- Settings → Windows chooses what Alt-Tab shows: Thumbnails or Titles.

### Fixed
- `⌃⌥=` had a default shortcut but no handler behind it, so it silently did
  nothing while occupying a combination.
- Alt-Tab lost hold mode as it opened, because `open()` calls `close()`, which
  cleared the modifier that had just been set. The per-window actions never
  appeared as a result.
- The switcher could not be dismissed if another app took focus, since its key
  monitor only sees events aimed at Perch. It now closes when focus leaves,
  after a short grace period so it cannot close itself while appearing.
- Window previews were missing for anything on another Space: both the
  ScreenCaptureKit query and the window-ID lookup were filtering to on-screen
  windows only.

## [1.3.1] — 2026-08-21

### Added
- Clipboard button in the panel header, beside the gear.
- **Trackpad cleaning** (`⌃⌥⇧T`) — freezes the pointer (movement, clicks,
  drags, scrolling) while leaving the keyboard live, so `Esc` or the shortcut
  unlocks it. The escape hatch is on the keyboard precisely because your hands
  are not near it while wiping a trackpad.

### Changed
- "Load Average" and "Memory Pressure" title-cased to match the rest.
- `KeyboardCleaner` is now `InputCleaner`, with `keyboard`, `trackpad`, and
  `both` modes over a single event tap. Which events are suppressed and how you
  exit are the only differences; the countdown, overlay, and failsafe are shared.
- Tool and switch labels are title-cased ("Trackpad Clean", "Prevent Sleep").
- The two network rows are labelled "Network Down" / "Network Up". Sitting
  beside the disk ring, plain "Download" / "Upload" read as storage.
- The Tools grid swaps its Settings tile for Trackpad Clean — Settings was
  already one click away on the header gear.

### Fixed
- **The System tab scrolled for no reason.** The content area had been sized
  from a `--render-ui` measurement taken before the monitor sampled, so the
  battery row was missing from the count and the budget came out short.
- **Every tab now sizes to its own content** — no dead space and no scrollbar
  on any of them. The popover follows because its hosting controller tracks the
  SwiftUI size via `sizingOptions` instead of being handed one fixed size up
  front, which is what previously went stale on a tab change and left the
  popover clipping its own header.

## [1.2.1] — 2026-08-21

### Changed
- Perch no longer scans disk-clean targets at launch. It walked a dozen cache
  trees on every start for data only needed once Disk clean is opened.

### Security
- **Clipboard images were written world-readable (`0644`)** while the history
  file was correctly `0600`. The permission call had never applied. Images are
  now `0600`, and existing files are repaired on launch. The `0700` parent
  directory limited real exposure, but the store was not what the docs claimed.

## [1.2.0] — 2026-08-21

### Added
- **Prevent sleep** switch — holds an `IOPMAssertion` so the Mac and display
  stay awake, released on quit.
- Quick switches on the Tools tab: prevent sleep, record clipboard, launch at
  login.
- System tab now also shows load average, thermal state, swap, and memory
  pressure.
- Close buttons on the clipboard and switcher panels.
- `--regular` debug flag, which runs Perch with a Dock icon so screen-automation
  tooling (which cannot address accessory apps) can drive it.

### Changed
- Windows and Display merged into a single **Screen** tab; three tabs total.
- System tab redrawn with circular ring gauges.
- Clipboard panel is a compact single column (420pt) instead of a two-pane
  660pt window.
- Panel height is constant across tabs and sized so no tab has dead space.

### Fixed
- **Window tiles in the panel did nothing.** With the panel open Perch is the
  frontmost app, so `AX.focusedWindow()` returned Perch's own popover and tried
  to resize that. The panel now records the previously frontmost app and targets
  it, and Perch excludes its own windows from every window query.
- **Escape and type-to-filter leaked to the app underneath.** The floating
  panels used `.nonactivatingPanel`, which does not reliably become key.
- **Popover clipped its own header.** `preferredContentSize` was set once at
  creation while each tab had a different natural height.
- Night-mode temperature and brightness values wrapped onto two lines.
- `setup-signing-identity.sh` failed on OpenSSL 3, which exports PKCS#12 with a
  MAC macOS cannot verify — now passes `-legacy`. Without a stable identity
  every rebuild is a new code identity and macOS silently drops the
  Accessibility grant, which is why permissions kept appearing to reset.

### Security
- **Updater now fails closed.** A release without a published checksum was
  previously downloaded unverified; it is now refused.
- **Updater validates URLs.** The release JSON is attacker-controlled if GitHub
  is compromised, so download and page URLs must be HTTPS on a known GitHub
  host before Perch fetches or opens them. Covered by `--selftest`.
- Removed an unguarded index into the Downloads directory list.

## [1.1.1] — 2026-08-21

### Added
- `Perch --render-ui <dir>` renders each panel tab offscreen and reports its
  measured height against the screen budget. A popover cannot be screenshotted
  from a script, so this gives the layout a real regression check.

### Changed
- **The panel is now tabbed and compact** — System, Windows, Display, Tools.
  It was a single 852pt column, taller than the usable height of a scaled
  display, so macOS had nowhere to put it and the top was cut off above the
  screen. Each tab is now 203–295pt.
- System tab redrawn with circular ring gauges for CPU, memory, and disk, and
  a compact list for network, battery, and uptime.
- Panel width reduced to 300pt.

### Fixed
- **Popover could be laid out taller than the screen.** The hosting controller
  now reports an explicit `preferredContentSize` capped to the display, and the
  scroll area has a hard ceiling, so neither presentation path can overflow.
- **Fallback panel could sit partly off-screen.** It now shrinks and clamps
  fully inside the visible frame.
- **Notification banner had a broken border.** It was laid out with manual
  frames on a visual-effect view, which masks its material but not a border
  drawn on it. Rebuilt with Auto Layout and a clipping container, so corners
  and border are correct at any size.
- `ByteCountFormatter` rendered zero as the word "Zero".

## [1.1.0] — 2026-08-21

First published release. Development versions 1.0.0 and 1.0.1 were
built locally and never tagged; their contents ship here.

### Added
- **Night mode** — warms the display via gamma ramps (the f.lux mechanism), so
  it needs no overlay and stays out of screenshots. 2400K–6500K, manual (`⌃⌥N`),
  sunset-to-sunrise, or custom hours.
- **Alt-Tab** (`⌥Tab`) — hold Option, tap Tab to walk the window list, release
  to switch. Lists windows rather than apps. `⌥\`` walks backwards.
- **In-app updates** — Updates row in the panel, a menu bar item, and a Settings
  section. Off by default; checks GitHub, verifies the download against the
  release checksum, and reveals the DMG in Finder rather than self-installing.
- **Homebrew cask** plus `Scripts/publish-cask.sh` to update the tap from a
  published release.
- **`Scripts/install.sh`** — build, self-test, install, relaunch in one step.
- **`Scripts/setup-signing-identity.sh`** — creates a self-signed certificate so
  local rebuilds keep a stable code identity, and macOS keeps the Accessibility
  grant.

### Changed
- Design pass across the whole app: a shared `Theme` (spacing, radii, type) with
  `Card`, `SectionHeader`, `KeyCap`, `GlyphBadge`, and `HoverButton` primitives,
  applied to the popover, clipboard panel, switcher, and settings.
- Icon redrawn as a minimal monochrome silhouette.
- Menu bar item is icon-only by default — a narrower item is less likely to be
  pushed off a crowded menu bar.
- The panel now detects an unreachable status item (notch, full menu bar) and
  presents itself as a floating window at the top right instead.
- README and SECURITY.md corrected: Perch previously claimed no network access
  at all, which the update check made untrue.

### Fixed
- **Crash roughly eight seconds after launch.** Programmatically created
  `NSWindow`s default to `isReleasedWhenClosed = true`, so closing one released
  it while ARC still held a reference. The second release segfaulted when the
  autorelease pool drained — reliably when the launch HUD dismissed itself.
  Affected the notification HUD, both cleaning overlays, the brightness dimmer,
  and the floating panel.
- **Popover taller than the screen.** The panel had no height bound and ran off
  the top of the display. It now measures its content and caps to the screen the
  menu bar item sits on, scrolling beyond that.
- **System Settings opening on every launch.** Startup called the Accessibility
  check with prompting enabled. It now shows a notice only; the system prompt
  appears when a feature actually needs the permission.
- Guarded against a blank status item if the SF Symbol is unavailable.

[1.3.1]: https://github.com/ishanmalu/Perch/releases/tag/v1.3.1
[1.2.1]: https://github.com/ishanmalu/Perch/releases/tag/v1.2.1
[1.2.0]: https://github.com/ishanmalu/Perch/releases/tag/v1.2.0
[1.1.1]: https://github.com/ishanmalu/Perch/releases/tag/v1.1.1
[1.1.0]: https://github.com/ishanmalu/Perch/releases/tag/v1.1.0
