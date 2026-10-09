cask "kampsis" do
  version "0.4.3"
  sha256 "4d68023d7ec46636776997609991185323ae920878a6ef9d9ce637500653b3fc"

  url "https://github.com/boundlessend/kampsis/releases/download/v#{version}/Kampsis-v#{version}-macos-arm64.dmg"
  name "Kampsis"
  desc "Desktop fold effect driven by the MacBook lid angle"
  homepage "https://github.com/boundlessend/kampsis"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Kampsis.app"
end
