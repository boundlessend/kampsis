#!/bin/zsh
# подписывает приложение постоянным сертификатом выпусков через rcodesign, без изменения доверия в системе
set -euo pipefail
umask 077

(( $# == 1 )) || { print -u2 'Использование: scripts/sign-selfsigned.sh Kampsis.app'; exit 2 }
root=${0:A:h:h}
app=${1:A}
private_dir=${KAMPSIS_SIGNING_DIR:-$HOME/Library/Application Support/Kampsis/Signing}
certificate=$root/signing/kampsis-release.crt
service=io.github.boundlessend.kampsis.signing

[[ -f $certificate && -f $private_dir/identity.p12 ]] || {
  print -u2 "Нет сертификата выпусков: нужны $certificate и $private_dir/identity.p12."
  print -u2 'Первый раз создайте их scripts/create-signing-identity.sh, дальше только восстанавливайте.'
  exit 2
}

stage=$(mktemp -d ${TMPDIR:-/tmp}/KampsisSign.XXXXXX)
trap 'rm -rf $stage' EXIT
security find-generic-password -a release -s $service -w > $stage/password
/usr/bin/openssl pkcs12 -in $private_dir/identity.p12 -passin file:$stage/password -clcerts -nokeys \
  -out $stage/certificate.pem
expected=$(/usr/bin/openssl x509 -in $certificate -noout -fingerprint -sha256)
actual=$(/usr/bin/openssl x509 -in $stage/certificate.pem -noout -fingerprint -sha256)
[[ $actual == $expected ]] || {
  print -u2 "Закрытая часть ($actual) не от сертификата в репозитории ($expected)."
  exit 2
}

rcodesign=$($root/scripts/fetch-rcodesign.sh)
$rcodesign sign --p12-file $private_dir/identity.p12 --p12-password-file $stage/password \
  --entitlements-xml-file $root/Kampsis/Kampsis.entitlements --code-signature-flags runtime --timestamp-url none $app
$root/scripts/verify-release-signature.sh $app
