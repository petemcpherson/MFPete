cask "mfpete" do
  version "1.0.0"
  sha256 "88a81881e1c0edf82c340c1574441a15ea2e6a31dda5c78522d30d96694e63a1"

  url "https://github.com/petemcpherson/MFPete/releases/download/v#{version}/MFPete-#{version}.dmg"
  name "MFPete"
  desc "Menu bar app that tidies files with simple When/If/Then rules"
  homepage "https://github.com/petemcpherson/MFPete"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Add `auto_updates true` once Sparkle is live (SUPublicEDKey set in Config/Info.plist).
  # Until then, `brew upgrade` is the update path.
  depends_on macos: ">= :sonoma"

  app "MFPete.app"

  uninstall quit: "com.mftpete.MFPete"

  zap trash: [
    "~/Library/Application Support/MFPete",
    "~/Library/Caches/com.mftpete.MFPete",
    "~/Library/HTTPStorages/com.mftpete.MFPete",
    "~/Library/Preferences/com.mftpete.MFPete.plist",
  ]
end
