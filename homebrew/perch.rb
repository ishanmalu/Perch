cask "perch" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/ishanmalu/Perch/releases/download/v#{version}/Perch-#{version}.dmg",
      verified: "github.com/ishanmalu/Perch/"
  name "Perch"
  desc "Menu bar utility for window tiling, clipboard history, and system tools"
  homepage "https://github.com/ishanmalu/Perch"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Minimum version; the string form is deprecated in current Homebrew.
  depends_on macos: :sonoma

  app "Perch.app"

  uninstall quit: "com.ishanmalu.perch"

  zap trash: [
    "~/Library/Application Support/Perch",
    "~/Library/Preferences/com.ishanmalu.perch.plist",
    "~/Library/Caches/com.ishanmalu.perch",
  ]

  caveats <<~EOS
      Perch is signed with its own certificate but not notarized, which needs a
      paid Apple Developer account. macOS therefore quarantines the download and
      refuses the first launch. Clear the flag:

        xattr -dr com.apple.quarantine "#{appdir}/Perch.app"

      Without a terminal: open Perch, dismiss the warning, then System Settings ->
      Privacy & Security -> Open Anyway. On macOS 15 and later, Control-clicking
      the app no longer offers this.

      Perch also needs Accessibility access for window management, the window
      switcher, and the cleaning modes:
      System Settings -> Privacy & Security -> Accessibility.
    EOS
end
