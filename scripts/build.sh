#!/bin/zsh
# собирает Release и упаковывает zip с контрольной суммой; режим определяет подпись
set -euo pipefail

usage='Использование: scripts/build.sh check|adhoc|selfsigned|development|developer-id'
(( $# == 1 )) || { print -u2 -- $usage; exit 2 }
mode=$1
root=${0:A:h:h}
bundle_id=io.github.boundlessend.lidfold

case $mode in
  check|adhoc|selfsigned) ;;
  development|developer-id)
    : ${LIDFOLD_SIGN_IDENTITY:?укажите LIDFOLD_SIGN_IDENTITY: имя или SHA-1 сертификата}
    : ${LIDFOLD_TEAM_ID:?укажите LIDFOLD_TEAM_ID: идентификатор команды Apple}
    [[ $LIDFOLD_TEAM_ID =~ '^[A-Z0-9]{10}$' ]] || { print -u2 "LIDFOLD_TEAM_ID=$LIDFOLD_TEAM_ID: нужно 10 заглавных букв и цифр"; exit 2 }
    ;;
  *) print -u2 -- $usage; exit 2 ;;
esac
command -v xcodegen >/dev/null || { print -u2 'нужен XcodeGen: brew install xcodegen'; exit 2 }

cd $root
xcodegen generate --quiet
derived=${LIDFOLD_DERIVED_DATA:-$(mktemp -d ${TMPDIR:-/tmp}/LidfoldBuild.XXXXXX)}
xcodebuild -project Lidfold.xcodeproj -scheme Lidfold -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived \
  CODE_SIGNING_ALLOWED=NO build
built=$derived/Build/Products/Release/Lidfold.app

if [[ $mode == check ]]; then
  print "Сборка без подписи: $built"
  exit 0
fi

stage=$(mktemp -d ${TMPDIR:-/tmp}/LidfoldPackage.XXXXXX)
app=$stage/Lidfold.app
ditto --noextattr --norsrc $built $app

case $mode in
  adhoc)
    codesign --force --options runtime --timestamp=none --sign - $app
    codesign --verify --deep --strict -R "=identifier \"$bundle_id\"" $app
    suffix=-adhoc
    ;;
  selfsigned)
    $root/scripts/sign-selfsigned.sh $app
    suffix=
    ;;
  development)
    codesign --force --options runtime --timestamp=none --sign $LIDFOLD_SIGN_IDENTITY $app
    codesign --verify --deep --strict \
      -R "=identifier \"$bundle_id\" and anchor apple generic and certificate leaf[subject.OU] = \"$LIDFOLD_TEAM_ID\"" $app
    suffix=-development
    ;;
  developer-id)
    codesign --force --options runtime --timestamp --sign $LIDFOLD_SIGN_IDENTITY $app
    codesign --verify --deep --strict \
      -R "=identifier \"$bundle_id\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$LIDFOLD_TEAM_ID\"" $app
    suffix=-unnotarized
    ;;
esac

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $app/Contents/Info.plist)
mkdir -p $root/dist
archive=$root/dist/Lidfold-v$version-macos-arm64$suffix.zip
[[ ! -e $archive ]] || { print -u2 "архив уже существует: $archive"; exit 2 }
ditto -c -k --norsrc --noextattr --keepParent $app $archive
(cd ${archive:h} && shasum -a 256 ${archive:t} > ${archive:t}.sha256)
print "Готово: $archive"
case $mode in
  adhoc) print 'Подпись ad-hoc: после каждого обновления macOS заново спросит доступ к записи экрана.' ;;
  developer-id) print 'Перед публикацией пропустите архив через scripts/notarize.sh.' ;;
esac
