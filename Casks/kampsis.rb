cask "kampsis" do
  version "0.2.0"
  sha256 "69ad61332a1344a250b18ca94ed9fe5e3e75106b202073c049b3876834d06db4"

  url "https://github.com/boundlessend/kampsis/releases/download/v#{version}/Kampsis-v#{version}-macos-arm64.dmg"
  name "Kampsis"
  desc "Desktop fold effect driven by the MacBook lid angle"
  homepage "https://github.com/boundlessend/kampsis"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Kampsis.app"
end
