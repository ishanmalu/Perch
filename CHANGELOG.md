# Changelog

All notable changes to Perch. Versions follow [semver](https://semver.org).

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
