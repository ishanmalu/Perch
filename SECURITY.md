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
| Network | Update check and speed test, both manual | The update check uses `api.github.com` plus GitHub's asset CDN. The speed test downloads a block of bytes from `speed.cloudflare.com` and only when you press Run — no account, no key, nothing sent about you. Nothing else contacts the network. No analytics, no telemetry |

## Installing an update in place

Replacing your own bundle from the network is a capability worth being careful
with, so it is worth being exact about what makes it safe here.

The published checksum is **not** what makes it safe. It travels from the same
release over the same connection as the download, so it proves the bytes
arrived intact and nothing more.

The control that matters is the code signature. Before anything is moved, the
downloaded app must satisfy the **running app's own designated requirement**,
which pins the signing certificate. Whoever substituted the download cannot
produce a bundle signed with that key, so a swapped app is refused while the
working copy is still untouched. The check runs twice: once on the app inside
the image, and again on the staged copy after the quarantine flag is cleared.

Everything is staged before anything is replaced, and the old bundle is kept
until the new one is in place. A failure at any step — mount, verification,
copy, move — leaves the app exactly as it was. An app that cannot write to its
own directory, or that is running from a disk image, does not attempt this at
all and falls back to revealing the download in Finder.

Perch runs three system binaries to do it, with fixed paths and no user input
in their arguments: `hdiutil` to mount the image, `ditto` to copy the bundle
with its signature intact, and `xattr` to clear the quarantine flag from a
build it has just verified against its own signing key. Nothing else in Perch
executes a subprocess.

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
