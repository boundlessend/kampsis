#!/bin/zsh
# упаковывает zip выпуска в DMG с ярлыком «Программы» и инструкцией, затем проверяет содержимое образа
set -euo pipefail

(( $# == 1 )) || { print -u2 'Использование: scripts/build-dmg.sh dist/Lidfold-vВЕРСИЯ-macos-arm64.zip'; exit 2 }
root=${0:A:h:h}
archive=${1:A}
[[ -f $archive && ${archive:t} == Lidfold-v*-macos-arm64.zip ]] || {
  print -u2 "нужен zip из scripts/build.sh selfsigned, получено $archive"
  exit 2
}
image=${archive:r}.dmg
[[ ! -e $image && ! -e $image.sha256 ]] || { print -u2 "образ уже существует: $image"; exit 2 }
command -v uv >/dev/null || { print -u2 'для сборки DMG нужен uv: brew install uv'; exit 2 }

stage=$(mktemp -d ${TMPDIR:-/tmp}/LidfoldDMG.XXXXXX)
mountpoint=$stage/mounted
trap '[[ -d $mountpoint/Lidfold.app ]] && hdiutil detach -quiet $mountpoint' EXIT

ditto -x -k $archive $stage/source
app=$stage/source/Lidfold.app
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $app/Contents/Info.plist)
[[ ${archive:t} == Lidfold-v$version-macos-arm64.zip ]] || {
  print -u2 "версия в имени архива не совпадает с приложением ($version)"
  exit 2
}
$root/scripts/verify-release-signature.sh $app

UV_CACHE_DIR=$root/.build/uv-cache UV_TOOL_DIR=$root/.build/uv-tools \
  uv tool run --from dmgbuild==1.6.7 dmgbuild \
  -s $root/installer/dmg/settings.py -D app=$app -D assets=$root/installer/dmg \
  "Lidfold $version" $stage/Lidfold.dmg
hdiutil verify -quiet $stage/Lidfold.dmg

mkdir $mountpoint
hdiutil attach -readonly -nobrowse -quiet -mountpoint $mountpoint $stage/Lidfold.dmg
$root/scripts/verify-release-signature.sh $mountpoint/Lidfold.app
changes=$(/usr/bin/rsync -rlcn --delete --itemize-changes $app/ $mountpoint/Lidfold.app/)
[[ -z $changes ]] || { print -u2 "приложение в образе отличается от архива: $changes"; exit 2 }
[[ -L $mountpoint/Программы && $(readlink $mountpoint/Программы) == /Applications ]] || {
  print -u2 'в образе нет ярлыка «Программы»'
  exit 2
}
cmp $root/installer/dmg/guide.html $mountpoint/Установка.html
[[ -f $mountpoint/.DS_Store ]] || { print -u2 'в образе нет раскладки окна Finder'; exit 2 }
hdiutil detach -quiet $mountpoint

mv $stage/Lidfold.dmg $image
(cd ${image:h} && shasum -a 256 ${image:t} > ${image:t}.sha256)
print "Образ собран и проверен: $image"
