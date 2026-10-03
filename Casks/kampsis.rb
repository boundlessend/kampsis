cask "kampsis" do
  version "0.1.0"
  sha256 "a46cc7b237c46e25fb63ecba7c69f2752d61b624f058a3a87781a526fd3f8ba0"

  url "https://github.com/boundlessend/kampsis/releases/download/v#{version}/Kampsis-v#{version}-macos-arm64.dmg"
  name "Kampsis"
  desc "Desktop fold effect driven by the MacBook lid angle"
  homepage "https://github.com/boundlessend/kampsis"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Kampsis.app"
end
