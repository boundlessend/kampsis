cask "kampsis" do
  version "0.2.0"
  sha256 "b578df0d47784775a08da432c4efca5ed286347c53f66df5dcb909c914d821af"

  url "https://github.com/boundlessend/kampsis/releases/download/v#{version}/Kampsis-v#{version}-macos-arm64.dmg"
  name "Kampsis"
  desc "Desktop fold effect driven by the MacBook lid angle"
  homepage "https://github.com/boundlessend/kampsis"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Kampsis.app"
end
