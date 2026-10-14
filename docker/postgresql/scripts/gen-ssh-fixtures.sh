#!/usr/bin/env bash
# Generates SSH tunnel test fixtures in docker/postgresql/data/ssh (gitignored).
# Idempotent: existing keys are kept so the host fingerprint stays stable.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${script_dir}/../data/ssh"
mkdir -p "${output_dir}"
umask 077

# A Docker bind mount of a missing file leaves a directory in its place; the -f checks
# below would then regenerate into it and fail with openssl's output hidden.
for path in ca.crt ca.key ca.srl mysql/server.crt mysql/server.key \
  mongo/server.crt mongo/server.key mongo/server.pem; do
  if [[ -d "${output_dir}/${path}" ]]; then
    echo "error: docker/postgresql/data/ssh/${path} is a directory (likely left by a Docker" \
      "bind mount); remove it and re-run this script." >&2
    exit 1
  fi
done

gen_key() {
  local file="$1" comment="$2" passphrase="$3"
  shift 3
  if [[ ! -f "${output_dir}/${file}" ]]; then
    ssh-keygen -q "$@" -N "${passphrase}" -C "${comment}" -f "${output_dir}/${file}"
  fi
}

# Client keys. id_rsa is for negative tests and is NOT authorized.
gen_key id_ed25519 dblore-ed25519 "" -t ed25519
gen_key id_ecdsa dblore-ecdsa-p256 "" -t ecdsa -b 256
gen_key id_ed25519_enc dblore-ed25519-enc dblore-pass -t ed25519
gen_key id_rsa dblore-rsa "" -t rsa -b 3072

# Server host keys. The ed25519 key is the default; the RSA key backs the
# RSA-only sshd variant used to test unsupported host key algorithms.
gen_key ssh_host_ed25519_key dblore-sshd "" -t ed25519
gen_key ssh_host_rsa_key dblore-sshd-rsa "" -t rsa -b 3072

# Self-signed TLS certificate for the tunneled PostgreSQL (TLS over the SSH channel).
mkdir -p "${output_dir}/postgres"
if [[ ! -f "${output_dir}/postgres/server.crt" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj "/CN=postgres" -addext "subjectAltName=DNS:postgres" \
    -keyout "${output_dir}/postgres/server.key" \
    -out "${output_dir}/postgres/server.crt" 2>/dev/null
fi

# Fixture CA for the tunneled MySQL and MongoDB (verified TLS over the SSH channel).
if [[ ! -f "${output_dir}/ca.crt" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj "/CN=Dblore SSH Fixture CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "${output_dir}/ca.key" -out "${output_dir}/ca.crt" 2>/dev/null
fi

# Server certificate for CN/SAN $1, signed by the fixture CA, in data/ssh/$2. DNS SAN only:
# NIOSSL accepts an IP SAN matching the channel's remote address whatever serverHostname says.
issue_server_cert() {
  local name="$1" dir="${output_dir}/$2"
  mkdir -p "${dir}"
  if [[ ! -f "${dir}/server.crt" ]]; then
    openssl req -new -newkey rsa:2048 -nodes -sha256 -subj "/CN=${name}" \
      -keyout "${dir}/server.key" -out "${dir}/server.csr" 2>/dev/null
    printf '%s\n' "basicConstraints=CA:FALSE" \
      "keyUsage=digitalSignature,keyEncipherment" "extendedKeyUsage=serverAuth" \
      "subjectAltName=DNS:${name}" > "${dir}/server.ext"
    openssl x509 -req -sha256 -days 3650 -in "${dir}/server.csr" \
      -CA "${output_dir}/ca.crt" -CAkey "${output_dir}/ca.key" -CAcreateserial \
      -CAserial "${output_dir}/ca.srl" -extfile "${dir}/server.ext" \
      -out "${dir}/server.crt" 2>/dev/null
    rm -f "${dir}/server.csr" "${dir}/server.ext"
  fi
  chmod 600 "${dir}/server.key"
  chmod 644 "${dir}/server.crt"
}

issue_server_cert mysql-ssh mysql
issue_server_cert mongo-ssh mongo
# mongod's --tlsCertificateKeyFile wants the certificate and key in one file.
cat "${output_dir}/mongo/server.crt" "${output_dir}/mongo/server.key" \
  > "${output_dir}/mongo/server.pem"
chmod 600 "${output_dir}/ca.key" "${output_dir}/mongo/server.pem"
chmod 644 "${output_dir}/ca.crt"

cat "${output_dir}/id_ed25519.pub" "${output_dir}/id_ecdsa.pub" \
  "${output_dir}/id_ed25519_enc.pub" > "${output_dir}/authorized_keys"
ssh-keygen -lf "${output_dir}/ssh_host_ed25519_key.pub" -E sha256 \
  | awk '{print $2}' > "${output_dir}/host_fingerprint.txt"
ssh-keygen -lf "${output_dir}/ssh_host_rsa_key.pub" -E sha256 \
  | awk '{print $2}' > "${output_dir}/host_rsa_fingerprint.txt"

chmod 600 "${output_dir}"/id_ed25519 "${output_dir}"/id_ecdsa \
  "${output_dir}"/id_ed25519_enc "${output_dir}"/id_rsa \
  "${output_dir}"/ssh_host_ed25519_key "${output_dir}"/ssh_host_rsa_key
chmod 600 "${output_dir}/postgres/server.key"
chmod 644 "${output_dir}/postgres/server.crt"
chmod 644 "${output_dir}"/*.pub "${output_dir}/authorized_keys" \
  "${output_dir}"/host_*fingerprint.txt
echo "Generated SSH fixtures in docker/postgresql/data/ssh (gitignored)."
echo "Host key fingerprint: $(cat "${output_dir}/host_fingerprint.txt")"
