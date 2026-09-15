#!/bin/zsh
# проверяет, что приложение подписано именно сертификатом выпусков Lidfold
set -euo pipefail

(( $# == 1 )) || { print -u2 'Использование: scripts/verify-release-signature.sh Lidfold.app'; exit 2 }
root=${0:A:h:h}
fingerprint=$(/usr/bin/openssl x509 -in $root/signing/lidfold-release.crt -noout -fingerprint -sha1 | cut -d = -f 2 | tr -d :)
[[ $fingerprint =~ '^[0-9A-F]{40}$' ]] || { print -u2 "Отпечаток сертификата выпусков не прочитан: «$fingerprint»"; exit 2 }
codesign --verify --deep --strict \
  -R "=identifier \"io.github.boundlessend.lidfold\" and certificate root = H\"$fingerprint\"" $1
