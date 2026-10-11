cask "kampsis" do
  version "0.4.4"
  sha256 "dbb96d666839fbcab2b779c136c8ad3bf9eb2471e9c32db5b5966769f1efa293"

  url "https://github.com/boundlessend/kampsis/releases/download/v#{version}/Kampsis-v#{version}-macos-arm64.dmg"
  name "Kampsis"
  desc "Desktop fold effect driven by the MacBook lid angle"
  homepage "https://github.com/boundlessend/kampsis"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Kampsis.app"
end
