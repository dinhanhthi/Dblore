#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${script_dir}/../data/mtls"
server_dir="${output_dir}/server"
mkdir -p "${server_dir}"
umask 077

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
  -subj "/CN=Dblore mTLS Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "${output_dir}/ca.key" -out "${output_dir}/ca.crt" >/dev/null 2>&1

openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -subj "/CN=localhost" \
  -keyout "${server_dir}/server.key" -out "${output_dir}/server.csr" >/dev/null 2>&1
cat > "${output_dir}/server.ext" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EOF
openssl x509 -req -sha256 -days 30 \
  -in "${output_dir}/server.csr" -CA "${output_dir}/ca.crt" \
  -CAkey "${output_dir}/ca.key" -CAcreateserial \
  -extfile "${output_dir}/server.ext" -out "${server_dir}/server.crt" >/dev/null 2>&1

openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -subj "/CN=dblore_mtls" \
  -keyout "${output_dir}/client.key" -out "${output_dir}/client.csr" >/dev/null 2>&1
cat > "${output_dir}/client.ext" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
EOF
openssl x509 -req -sha256 -days 30 \
  -in "${output_dir}/client.csr" -CA "${output_dir}/ca.crt" \
  -CAkey "${output_dir}/ca.key" -CAcreateserial \
  -extfile "${output_dir}/client.ext" -out "${output_dir}/client.crt" >/dev/null 2>&1

cp "${output_dir}/ca.crt" "${server_dir}/ca.crt"
cat > "${server_dir}/pg_hba.conf" <<'EOF'
local all all trust
hostssl all all 0.0.0.0/0 scram-sha-256 clientcert=verify-full
hostssl all all ::/0 scram-sha-256 clientcert=verify-full
host all all 0.0.0.0/0 reject
host all all ::/0 reject
EOF
rm -f "${output_dir}"/*.csr "${output_dir}"/*.ext "${output_dir}"/*.srl
chmod 600 "${output_dir}/ca.key" "${output_dir}/client.key" "${server_dir}/server.key"
chmod 644 "${output_dir}/ca.crt" "${output_dir}/client.crt" "${server_dir}"/*.crt \
  "${server_dir}/pg_hba.conf"
echo "Generated mTLS fixtures in docker/postgresql/data/mtls (gitignored)."
