#!/usr/bin/env bash
# Generates the MySQL TLS / mTLS test fixtures in docker/mysql/data/tls (gitignored):
# ca.crt/ca.key, server.crt/server.key (localhost, 127.0.0.1) and client.crt/client.key
# for the REQUIRE X509 user dblore_x509.
#
# Optional: docker-compose.test.yml starts without these files (MySQL then uses its
# auto-generated certs and dblore_x509 cannot log in). The container copies the certs
# at start, so after running this script recreate it:
#   docker compose -f docker/mysql/docker-compose.test.yml up -d --force-recreate mysql-test
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${script_dir}/../data/tls"
mkdir -p "${output_dir}"
umask 077

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
  -subj "/CN=Dblore MySQL Test CA" \
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

openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -subj "/CN=dblore_x509" \
  -keyout "${output_dir}/client.key" -out "${output_dir}/client.csr" >/dev/null 2>&1
cat > "${output_dir}/client.ext" <<'EXT'
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
EXT
openssl x509 -req -sha256 -days 30 \
  -in "${output_dir}/client.csr" -CA "${output_dir}/ca.crt" \
  -CAkey "${output_dir}/ca.key" -CAcreateserial \
  -extfile "${output_dir}/client.ext" -out "${output_dir}/client.crt" >/dev/null 2>&1

rm -f "${output_dir}"/*.csr "${output_dir}"/*.ext "${output_dir}"/*.srl
chmod 600 "${output_dir}"/*.key
chmod 644 "${output_dir}"/*.crt
echo "Generated MySQL TLS fixtures in docker/mysql/data/tls (gitignored)."
echo "Recreate the container: docker compose -f docker/mysql/docker-compose.test.yml up -d --force-recreate mysql-test"
