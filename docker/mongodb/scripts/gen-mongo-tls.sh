#!/usr/bin/env bash
# Generates the MongoDB TLS test fixtures in docker/mongodb/tls (gitignored):
# ca.crt/ca.key, server.crt/server.key (localhost, 127.0.0.1) and server.pem
# (certificate + key, what mongod's --tlsCertificateKeyFile wants).
#
# Only the compose profile tls (mongo-tls-test, requireTLS) needs these files. The
# container copies the certs at start, so after running this script (re)create it:
#   docker compose -f docker/mongodb/docker-compose.test.yml --profile tls up -d --force-recreate mongo-tls-test
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${script_dir}/../tls"
mkdir -p "${output_dir}"
umask 077

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
  -subj "/CN=Dblore MongoDB Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "${output_dir}/ca.key" -out "${output_dir}/ca.crt" >/dev/null 2>&1

openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -subj "/CN=localhost" \
  -keyout "${output_dir}/server.key" -out "${output_dir}/server.csr" >/dev/null 2>&1
cat > "${output_dir}/server.ext" <<'EXT'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EXT
openssl x509 -req -sha256 -days 30 \
  -in "${output_dir}/server.csr" -CA "${output_dir}/ca.crt" \
  -CAkey "${output_dir}/ca.key" -CAcreateserial \
  -extfile "${output_dir}/server.ext" -out "${output_dir}/server.crt" >/dev/null 2>&1

cat "${output_dir}/server.crt" "${output_dir}/server.key" > "${output_dir}/server.pem"

rm -f "${output_dir}"/*.csr "${output_dir}"/*.ext "${output_dir}"/*.srl
chmod 600 "${output_dir}"/*.key "${output_dir}/server.pem"
chmod 644 "${output_dir}"/*.crt
echo "Generated MongoDB TLS fixtures in docker/mongodb/tls (gitignored)."
echo "Start or recreate the TLS container: docker compose -f docker/mongodb/docker-compose.test.yml --profile tls up -d --force-recreate mongo-tls-test"
