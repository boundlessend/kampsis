#!/bin/zsh
# один раз за жизнь проекта создаёт постоянный самоподписанный сертификат выпусков
#
# macOS привязывает доступ к записи экрана к подписи: пока выпуски подписаны этим сертификатом,
# обновление не сбрасывает разрешение, а новый сертификат сбросит его у всех установок
set -euo pipefail
umask 077

root=${0:A:h:h}
private_dir=${KAMPSIS_SIGNING_DIR:-$HOME/Library/Application Support/Kampsis/Signing}
certificate=$root/signing/kampsis-release.crt
service=io.github.boundlessend.kampsis.signing

[[ ! -e $certificate && ! -e $private_dir/identity.p12 ]] || {
  print -u2 'Сертификат выпусков уже есть. Восстановите его закрытую часть, новый создавать нельзя.'
  exit 2
}

stage=$(mktemp -d ${TMPDIR:-/tmp}/KampsisIdentity.XXXXXX)
trap 'rm -rf $stage' EXIT
cat > $stage/openssl.cnf <<'EOF'
[req]
prompt = no
distinguished_name = release_name
x509_extensions = release_extensions
[release_name]
CN = Kampsis Release Signing
O = Kampsis
[release_extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl rand -base64 48 > $stage/password
/usr/bin/openssl req -x509 -new -newkey rsa:3072 -nodes -days 7300 -config $stage/openssl.cnf \
  -keyout $stage/key.pem -out $stage/certificate.pem
/usr/bin/openssl pkcs12 -export -name 'Kampsis Release Signing' -inkey $stage/key.pem -in $stage/certificate.pem \
  -out $stage/identity.p12 -passout file:$stage/password
security add-generic-password -a release -s $service -w "$(cat $stage/password)" -T /usr/bin/security

mkdir -p $private_dir ${certificate:h}
chmod 700 $private_dir
cp $stage/identity.p12 $private_dir/identity.p12
cp $stage/certificate.pem $certificate
chmod 644 $certificate
print "Закрытая часть: $private_dir/identity.p12"
print "Пароль: связка ключей, служба $service, учётная запись release"
print "Открытый сертификат для репозитория: $certificate"
print 'Сохраните копию identity.p12 и пароля вне репозитория.'
