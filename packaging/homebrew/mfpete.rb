cask "mfpete" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_DMG"

  url "https://github.com/petemcpherson/MFPete/releases/download/v#{version}/MFPete-#{version}.dmg"
  name "MFPete"
  desc "Menu bar app that tidies files with simple When/If/Then rules"
  homepage "https://github.com/petemcpherson/MFPete"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
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
