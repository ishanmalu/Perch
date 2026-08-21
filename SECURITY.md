# Security

Perch is a personal macOS utility, distributed as source and as an ad-hoc-signed
DMG. It holds capabilities worth scrutinising: it can read window titles, read
the clipboard, and intercept keyboard and trackpad input.

## What the app can and cannot do

| Capability | How it is used | Bounded by |
| --- | --- | --- |
| Accessibility (AX) | Read window frames, titles, and app names; set frames | Never reads window contents |
| Screen Recording | Window previews in the Alt-Tab switcher | Optional. Captures a window only while the switcher is on screen; images are held in memory, never written to disk |
| Event tap | Swallow input during keyboard or trackpad cleaning | Counts events only; key codes are discarded, never stored or logged. In trackpad mode keyboard events pass through untouched so the unlock shortcut can reach Perch |
| Pasteboard | Record clipboard history | Local file, `0600`; concealed types, ignored apps, and credential-shaped strings are skipped |
| Filesystem | Measure and clear cache folders | Path guard + `trashItem` only; nothing is unlinked |
| Private `DisplayServices` | Built-in display brightness | Resolved via `dlsym`; falls back to a software overlay if absent |
| Network | Update check only | Off by default; `api.github.com` plus GitHub's asset CDN, nothing else. No analytics, no telemetry, no subprocess execution |

## Deliberate design choices

- **The event tap is the highest-risk surface.** It is created only for a
  cleaning session and torn down on completion, on `Esc`-hold, on app
  termination, and by an independent `DispatchQueue` failsafe that runs even if
  the main run loop is starved. The callback never retains event contents.
- **Disk targets are validated in the model, not the view.** `PathGuard` runs at
  both scan and clean time, so editing `UserDefaults` by hand cannot widen the
  blast radius.
- **Updates are checked, never applied.** Perch downloads the DMG, verifies it
  against the checksum published with the release, and reveals it in Finder. It
  does not replace its own bundle. A utility holding Accessibility and event-tap
  permissions should not also be able to rewrite itself from the network.
- **Window previews are captured on demand, not continuously.** Screen Recording
  is only used while the switcher is open, one capture per listed window, and
  the images live in memory for the life of that switcher session. Nothing is
  written to disk. Decline the permission and the switcher uses app icons.
- **Clipboard history is not encrypted.** Encrypting it with a key that also
  lives on the same disk would be theatre. It is instead permission-restricted
  and filtered, and documented as plaintext so you can decide accordingly.

## Gatekeeper status

Perch is **ad-hoc signed and not notarized**, which is why a fresh download is
blocked until you clear the quarantine flag:

```
$ spctl -a -t exec Perch.app
Perch.app: rejected
$ codesign -dv Perch.app
TeamIdentifier=not set
```

That is the honest state of it: the signature proves the bundle has not been
altered since it was built, but nothing ties it to a verified developer
identity, and Apple has not scanned it. Build it yourself if that matters to
you — `Scripts/make-dmg.sh` takes about a minute and needs no Xcode.

## Verifying a build

```bash
shasum -a 256 Perch-1.0.0.dmg          # compare against SHA256SUMS.txt
codesign -dv --verbose=4 /Applications/Perch.app
/Applications/Perch.app/Contents/MacOS/Perch --selftest
```

Release DMGs are built by GitHub Actions from a tagged commit — see
`.github/workflows/release.yml`. Or build it yourself with
`Scripts/make-dmg.sh`; it takes about a minute and needs no Xcode.

## Reporting

Open an issue, or for anything you would rather not post publicly, use GitHub's
private vulnerability reporting on this repository.
