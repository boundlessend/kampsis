#!/bin/zsh
# нотаризует архив, подписанный Developer ID, и пишет рядом архив со штампом Apple
set -euo pipefail

(( $# == 1 )) || { print -u2 'Использование: scripts/notarize.sh dist/Lidfold-vВЕРСИЯ-macos-arm64-unnotarized.zip'; exit 2 }
: ${LIDFOLD_NOTARY_PROFILE:?укажите LIDFOLD_NOTARY_PROFILE: профиль notarytool в связке ключей}
archive=${1:A}
[[ -f $archive && $archive == *-unnotarized.zip ]] || { print -u2 "нужен архив из scripts/build.sh developer-id, получено $archive"; exit 2 }
output=${archive%-unnotarized.zip}-notarized.zip
[[ ! -e $output ]] || { print -u2 "архив уже существует: $output"; exit 2 }

stage=$(mktemp -d ${TMPDIR:-/tmp}/LidfoldNotarize.XXXXXX)
ditto -x -k $archive $stage
app=$stage/Lidfold.app
codesign --verify --strict -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' $app
codesign -d --entitlements $stage/entitlements.plist --xml $app 2>/dev/null
if [[ -s $stage/entitlements.plist ]] \
   && /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' $stage/entitlements.plist 2>/dev/null | grep -qx true; then
  print -u2 'в выпуске включён get-task-allow, Apple его не примет'
  exit 1
fi

# учётные данные остаются в связке ключей, в аргументах только имя профиля
xcrun notarytool submit $archive --keychain-profile $LIDFOLD_NOTARY_PROFILE --wait --output-format json > $stage/notarization.json
notary_status=$(/usr/bin/plutil -extract status raw -o - $stage/notarization.json)
[[ $notary_status == Accepted ]] || { print -u2 "нотаризация: $notary_status"; cat $stage/notarization.json >&2; exit 1 }
xcrun stapler staple $app
xcrun stapler validate $app
spctl --assess --type execute --verbose=2 $app
ditto -c -k --norsrc --noextattr --keepParent $app $output
(cd ${output:h} && shasum -a 256 ${output:t} > ${output:t}.sha256)
print "Нотаризованный архив: $output"
print "Ответ Apple: $stage/notarization.json"
