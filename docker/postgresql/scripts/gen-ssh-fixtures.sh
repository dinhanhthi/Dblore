#!/usr/bin/env bash
# Generates SSH tunnel test fixtures in docker/postgresql/data/ssh (gitignored).
# Idempotent: existing keys are kept so the host fingerprint stays stable.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${script_dir}/../data/ssh"
mkdir -p "${output_dir}"
umask 077

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
