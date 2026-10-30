#!/usr/bin/env bash
# Provas que exigem a nuvem montada (S1-S4 aplicadas). So leitura.
# Uso: bash project/tests/cloud-checks.sh <check> [...]   (sem argumento: todos)
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${PROJECT_DIR}/ansible/inventory/hosts.ini"
PKI="${PROJECT_DIR}/ansible/files/pki"
ANSIBLE="${VENV_PATH:-$HOME/venvs/kolla}/bin/ansible"
DOMAIN="larcerto.com.br"

fip() {
  grep -A1 "^\[$1\]" "${INVENTORY}" | grep -oE 'ansible_host=[0-9.]+' | cut -d= -f2
}

check_dns_www() {
  [[ "$(dig +short @"$(fip dns)" "www.${DOMAIN}")" == "$(fip web)" ]]
}

check_dns_cloud() {
  [[ "$(dig +short @"$(fip dns)" "cloud.${DOMAIN}")" == "192.168.1.250" ]]
}

check_dns_db_from_web() {
  (cd "${PROJECT_DIR}/ansible" && "${ANSIBLE}" web -m ansible.builtin.command \
    -a "getent hosts db.${DOMAIN}" 2>/dev/null) | grep -q '10\.11\.12\.12'
}

check_http_redirect() {
  local headers
  headers="$(curl -sS -o /dev/null -D - --resolve "${DOMAIN}:80:$(fip web)" "http://${DOMAIN}/")"
  grep -qE '^HTTP/[0-9.]+ 301' <<<"${headers}" \
    && grep -qiE "^location: https://${DOMAIN}/" <<<"${headers}"
}

check_https_ok() {
  curl -fsS --cacert "${PKI}/ca.crt" --resolve "${DOMAIN}:443:$(fip web)" "https://${DOMAIN}/" \
    | grep -q 'Banco: conectado'
}

[[ -f "${INVENTORY}" ]] || { echo "Sem ${INVENTORY}: rode terraform apply primeiro." >&2; exit 2; }

ALL=(dns_www dns_cloud dns_db_from_web http_redirect https_ok)
selected=("$@")
[[ "${#selected[@]}" -eq 0 ]] && selected=("${ALL[@]}")

failed=0
for name in "${selected[@]}"; do
  if ! declare -F "check_${name}" >/dev/null; then
    echo "Check desconhecido: ${name}" >&2
    exit 2
  fi
  if "check_${name}"; then echo "PASS ${name}"; else echo "FAIL ${name}"; failed=1; fi
done
exit "${failed}"
