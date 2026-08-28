# Notarizing Perch

Perch currently ships **ad-hoc signed and not notarized**, so macOS quarantines
every download and the first launch needs one extra step. Notarizing removes
that step entirely — the app opens on a double-click, like any other Mac app.

Everything on the build side is already in place. What is missing is an Apple
Developer Program membership, which costs **$99/year** and can only be set up by
you: it involves a payment and signing in to your Apple account.

---

## What notarization actually buys

| | Now | Notarized |
| --- | --- | --- |
| First launch | Gatekeeper blocks it | Opens normally |
| Terminal step | `xattr -dr com.apple.quarantine` required | None |
| `spctl -a -t exec` | `rejected` | `accepted` |
| Accessibility grant | Already stable since 1.5.0 | Unchanged |

That last row used to be the strongest argument here, and it no longer is.
Releases were ad-hoc signed up to 1.4.0: an ad-hoc signature is derived from
the binary, so every build was a different code identity and macOS forgot the
Accessibility permission each time. Since 1.5.0 releases are signed with a
consistent self-signed certificate, and the designated requirement pins the
certificate rather than the binary, so the grant already survives updates
without paying anything.

What the money actually buys is the first launch. Everything else on this page
is already solved.

---

## One-time setup

### 1. Enrol in the Apple Developer Program

<https://developer.apple.com/programs/enroll/> — $99/year. Enrolment takes
anywhere from minutes to a couple of days.

### 2. Create a Developer ID Application certificate

In Xcode: **Settings → Accounts → Manage Certificates → + → Developer ID
Application**. Without Xcode, create a CSR in Keychain Access and upload it at
<https://developer.apple.com/account/resources/certificates/list>.

Confirm it landed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 3. Create an app-specific password

<https://appleid.apple.com> → Sign-In and Security → App-Specific Passwords.
This is *not* your Apple ID password; notarization will not accept that.

### 4. Find your Team ID

<https://developer.apple.com/account> → Membership Details. Ten characters.

---

## Notarizing a build locally

```bash
export SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

Scripts/build-app.sh 1.4.0
Scripts/notarize.sh dist/Perch.app 1.4.0
```

`build-app.sh` picks up a Developer ID automatically when one exists and signs
with the hardened runtime, which notarization requires. `notarize.sh` then
signs the DMG, submits it, waits for the result, staples the ticket, and
verifies the outcome the way Gatekeeper will see it.

Stapling matters: it writes the ticket into the DMG so Gatekeeper clears the app
even when the machine is offline.

---

## Notarizing in CI

Add four repository secrets under **Settings → Secrets and variables →
Actions**:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | Developer ID `.p12`, base64-encoded |
| `MACOS_CERTIFICATE_PWD` | Password you set when exporting the `.p12` |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | Ten-character team ID |
| `APPLE_APP_PASSWORD` | App-specific password |

Export and encode the certificate like this:

```bash
# Keychain Access → your Developer ID cert → right-click → Export → .p12
base64 -i DeveloperID.p12 | pbcopy
```

The release workflow checks for `MACOS_CERTIFICATE` and **skips signing
entirely when it is absent**, so releases keep working exactly as they do today
until the secrets exist. Nothing needs to change in the workflow when you add
them — the next tag notarizes itself.

---

## After the first notarized release

Update the install instructions, which currently tell people to clear the
quarantine flag:

- `README.md` — the Homebrew and DMG sections
- `docs/index.html` — the install tabs
- `.github/workflows/release.yml` — the release notes template

And drop `--no-quarantine` guidance from the Homebrew cask caveats in
`homebrew/perch.rb`.

---

## Verifying it worked

```bash
spctl -a -t open --context context:primary-signature -vv Perch-1.4.0.dmg
xcrun stapler validate Perch-1.4.0.dmg
codesign -dv --verbose=4 /Applications/Perch.app 2>&1 | grep -E "Authority|TeamIdentifier"
```

`spctl` should say **accepted** with a `Developer ID` source, and
`TeamIdentifier` should be your team rather than `not set`.
