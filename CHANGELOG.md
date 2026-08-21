# Changelog

All notable changes to Perch. Versions follow [semver](https://semver.org).

## [1.3.1]

### Fixed
- **The System tab scrolled for no reason.** The content area was sized from a
  measurement taken before the monitor had sampled, so the battery row was
  missing from the count — ~10pt short. Measured properly (System 306, Screen
  296, Tools 306 with real data) and sized so no tab scrolls.

### Changed
- "Load Average" and "Memory Pressure" title-cased to match the rest.

## [1.3.0]

### Added
- **Trackpad cleaning** (`⌃⌥⇧T`) — freezes the pointer (movement, clicks,
  drags, scrolling) while leaving the keyboard live, so `Esc` or the shortcut
  unlocks it. The escape hatch is on the keyboard precisely because your hands
  are not near it while wiping a trackpad.

### Changed
- `KeyboardCleaner` is now `InputCleaner`, with `keyboard`, `trackpad`, and
  `both` modes over a single event tap. Which events are suppressed and how you
  exit are the only differences; the countdown, overlay, and failsafe are shared.
- Tool and switch labels are title-cased ("Trackpad Clean", "Prevent Sleep").
- The two network rows are labelled "Network Down" / "Network Up". Sitting
  beside the disk ring, plain "Download" / "Upload" read as storage.
- The Tools grid swaps its Settings tile for Trackpad Clean — Settings was
  already one click away on the header gear.

## [1.2.1]

### Security
- **Clipboard images were written world-readable (`0644`)** while the history
  file was correctly `0600`. The permission call had never applied. Images are
  now `0600`, and existing files are repaired on launch. The `0700` parent
  directory limited real exposure, but the store was not what the docs claimed.

### Changed
- Perch no longer scans disk-clean targets at launch. It walked a dozen cache
  trees on every start for data only needed once Disk clean is opened.

## [1.2.0]

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

## [1.1.1]

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

### Added
- `Perch --render-ui <dir>` renders each panel tab offscreen and reports its
  measured height against the screen budget. A popover cannot be screenshotted
  from a script, so this gives the layout a real regression check.

## [1.1.0]

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

## [1.0.1]

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

## [1.0.0]

Initial release — window tiling with size cycling and custom layouts, a
searchable window switcher, clipboard history, system monitoring, disk cleaning
with a path guard, screen cleaning, keyboard cleaning, and per-display
brightness. Universal binary, no third-party dependencies, no Xcode project.
