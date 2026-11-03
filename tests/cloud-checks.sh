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
  local page
  page="$(curl -fsS --cacert "${PKI}/ca.crt" --resolve "${DOMAIN}:443:$(fip web)" "https://${DOMAIN}/")" || return 1
  grep -q 'LarCerto' <<<"${page}" && grep -qE 'class="resumo">[1-9][0-9]* imóve' <<<"${page}"
}

# ad-hoc na VM: imprime so o stdout de um comando que deu certo (rc=0);
# linha FAILED do callback -o traz o stderr, que nao pode virar prova.
on_vm() {
  (cd "${PROJECT_DIR}/ansible" && "${ANSIBLE}" "$1" -b -o -m ansible.builtin.command -a "$2" 2>/dev/null) \
    | sed -nE 's/^[^ ]+ \| (CHANGED|SUCCESS) \| rc=0 \| \(stdout\) //p'
}

check_php_version() {
  # CLI e o modulo do Apache (o que serve a app) no 8.4
  on_vm web 'php -v' | grep -q '^PHP 8\.4' \
    && on_vm web 'ls /etc/apache2/mods-enabled/php8.4.load' | grep -qx '/etc/apache2/mods-enabled/php8.4.load'
}

check_db_version_seed() {
  local out
  out="$(on_vm db "mariadb --batch --skip-column-names -e 'SELECT VERSION(); SELECT COUNT(*) FROM larcerto.imoveis'")"
  grep -qE '^12\.3' <<<"${out}" && [[ "$(sed 's/\\n/\n/g' <<<"${out}" | tail -1)" -gt 0 ]]
}

check_php_gd_uploads() {
  # GD e exif no PHP da VM web, limites das fotos no PHP do Apache e pasta das fotos
  # so do Apache. Saida de varias linhas chega com \n literal (callback -o).
  local mods gd ini dono
  mods="$(on_vm web 'php -m' | sed 's/\\n/\n/g')"
  grep -qx gd <<<"${mods}" && grep -qx exif <<<"${mods}" || return 1
  gd="$(on_vm web "php -r 'echo gd_info()[\"WebP Support\"] && gd_info()[\"JPEG Support\"] ? \"ok\" : \"nao\";'")"
  [[ "${gd}" == ok ]] || return 1
  # Limites com o php.ini e o conf.d do Apache (o que serve a app), nao os do CLI.
  ini="$(on_vm web "env PHP_INI_SCAN_DIR=/etc/php/8.4/apache2/conf.d php -c /etc/php/8.4/apache2/php.ini -r 'echo implode(\" \", array_map(\"ini_get\", [\"upload_max_filesize\", \"post_max_size\", \"max_file_uploads\", \"memory_limit\"]));'")"
  [[ "${ini}" == "20M 64M 11 256M" ]] || return 1
  dono="$(on_vm web 'stat -c %U:%a /var/www/larcerto/storage/uploads')"
  [[ "${dono}" == "www-data:750" ]]
}

# Imprime a contagem de imoveis na VM db (para comparar antes e depois do playbook).
check_seed_count() {
  local n
  n="$(on_vm db "mariadb --batch --skip-column-names -e 'SELECT COUNT(*) FROM larcerto.imoveis'")"
  [[ "${n}" =~ ^[0-9]+$ ]] && echo "${n}"
}

[[ -f "${INVENTORY}" ]] || { echo "Sem ${INVENTORY}: rode terraform apply primeiro." >&2; exit 2; }

ALL=(dns_www dns_cloud dns_db_from_web http_redirect https_ok php_version db_version_seed php_gd_uploads)
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
