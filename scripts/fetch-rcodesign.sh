#!/bin/zsh
# кладёт закреплённую версию rcodesign в .build/ после проверки SHA-256 и печатает путь к ней
set -euo pipefail

root=${0:A:h:h}
version=0.29.0
name=apple-codesign-$version-aarch64-apple-darwin
checksum=d1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a
archive=$root/.build/$name.tar.gz
tool=$root/.build/$name/rcodesign

mkdir -p $root/.build
if [[ ! -f $archive ]]; then
  partial=$archive.partial
  curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --retry 3 \
    --connect-timeout 15 --max-time 180 --output $partial \
    https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/$version/$name.tar.gz
  mv $partial $archive
fi
actual=$(shasum -a 256 $archive | cut -d ' ' -f 1)
[[ $actual == $checksum ]] || { print -u2 "rcodesign: SHA-256 $actual вместо $checksum в $archive"; exit 1 }
[[ -x $tool ]] || tar -xzf $archive -C $root/.build
print -r -- $tool
