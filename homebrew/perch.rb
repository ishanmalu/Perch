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
    Perch is signed ad-hoc rather than with a paid Apple Developer certificate,
    so macOS quarantines it on first launch. Either install with:

      brew install --cask --no-quarantine perch

    or clear the flag afterwards:

      xattr -dr com.apple.quarantine "#{appdir}/Perch.app"

    Perch also needs Accessibility access for window management, the window
    switcher, and keyboard cleaning:
    System Settings -> Privacy & Security -> Accessibility.
  EOS
end
