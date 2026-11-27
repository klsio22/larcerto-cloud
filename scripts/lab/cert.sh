# cert: ver (status), renovar (renew, com --new-ca para trocar a CA) e confiar no navegador (trust)
# do certificado wildcard da LarCerto, e emitir e entregar ao HAProxy do Kolla o do Horizon (cloud).
# A CA e os certificados saem da VM ca (papel ca, easy-rsa) e ficam em ansible/files/pki/ (fora do git).
# Carregado pelo larcerto.sh (SCRIPT_DIR = raiz do repo); so define funcoes e variaveis. Funcoes sem o prefixo cmd_, que fica para os comandos do ciclo do lab.
# shellcheck shell=bash

# Mesmos valores do install.sh, para o modulo funcionar sem depender da ordem dos source no larcerto.sh.
HOSTS_INI="${HOSTS_INI:-${SCRIPT_DIR}/ansible/inventory/hosts.ini}"
ANSIBLE_PLAYBOOK_BIN="${ANSIBLE_PLAYBOOK_BIN:-${VENV_PATH:-$HOME/venvs/kolla}/bin/ansible-playbook}"
CERT_PKI_DIR="${SCRIPT_DIR}/ansible/files/pki"
CERT_CA="${CERT_PKI_DIR}/ca.crt"
CERT_LEAF="${CERT_PKI_DIR}/larcerto.crt"
CERT_DOMAIN="larcerto.com.br"
CERT_NOME_NSS="CA LarCerto"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-30}"
CERT_BANCOS=()
# Horizon (cert cloud): certificado proprio, servido pelo HAProxy do Kolla no VIP.
CERT_CLOUD="${CERT_PKI_DIR}/cloud.crt"
CERT_CLOUD_KEY="${CERT_PKI_DIR}/cloud.key"
CERT_CLOUD_FQDN="cloud.${CERT_DOMAIN}"
KOLLA_NODE_CONFIG="${KOLLA_NODE_CONFIG:-/etc/kolla}"


cert_uso() {
  echo "Uso: ./larcerto.sh cert [status|renew [--new-ca [--yes]]|trust|cloud]" >&2
}


# CN de um certificado (sem o prefixo "commonName").
cert_cn() {
  openssl x509 -in "$1" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p' || true
}


# Primeira linha da extensao SAN, sem espacos; vazio se o certificado nao tem SAN (a CA).
cert_san() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | sed -n '2s/^ *//p' || true
}


# Impressao digital SHA-256 de um certificado local.
cert_fp() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true
}


# Data de fim (epoch) de um certificado; sai 1 se o arquivo nao le.
cert_fim_epoch() {
  local end
  end="$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2)" || return 1
  [[ -n "${end}" ]] || return 1
  date -d "${end}" +%s
}


# IP do floating IP do web no hosts.ini (vazio se o inventario nao existe).
cert_web_ip() {
  [[ -f "${HOSTS_INI}" ]] || return 0
  awk '/^\[/{f = ($0 == "[web]")} f && /ansible_host=/{sub(/.*ansible_host=/, ""); print $1; exit}' "${HOSTS_INI}"
}


# Impressao digital do certificado servido em <ip>:443 com o SNI <nome> (padrao: o dominio da app);
# vazio = sem resposta em 5 s.
cert_fp_servido() {
  [[ -n "$1" ]] || return 0
  timeout 5 openssl s_client -connect "$1:443" -servername "${2:-${CERT_DOMAIN}}" </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true
}


# Uma entrada do status. Grava CERT_DIAS (dias restantes), CERT_VENCIDO (1 se ja expirou) e
# CERT_ILEGIVEL (1 se o arquivo nao le como certificado).
cert_mostra() {
  local rotulo="$1" arq="$2" agora="$3" fim cn san
  cn="$(cert_cn "${arq}")"
  san="$(cert_san "${arq}")"
  printf '%s: CN=%s\n' "${rotulo}" "${cn:-?}"
  printf '  SAN: %s\n' "${san:--}"
  CERT_ILEGIVEL=0
  CERT_VENCIDO=0
  CERT_DIAS=0
  if ! fim="$(cert_fim_epoch "${arq}")"; then
    CERT_ILEGIVEL=1
    echo "  validade: nao consegui ler o certificado"
    return 0
  fi
  CERT_DIAS=$(( (fim - agora) / 86400 ))
  if [[ "${fim}" -le "${agora}" ]]; then
    CERT_VENCIDO=1
  fi
  printf '  valido ate: %s (dias restantes: %s)\n' "$(date -u -d "@${fim}" '+%Y-%m-%d %H:%M UTC')" "${CERT_DIAS}"
}


# status: so le. Sai 1 se falta arquivo; 2 se a cadeia nao confere, expirou ou o web serve outro; 0 no resto.
cert_status() {
  local agora rc=0 faltam=0 f saida ip fp_local fp_servido
  for f in "${CERT_CA}" "${CERT_LEAF}"; do
    if [[ ! -f "${f}" ]]; then
      echo "Falta: ${f} -> ./larcerto.sh install-app --from nuvem" >&2
      faltam=1
    fi
  done
  [[ "${faltam}" -eq 0 ]] || return 1

  agora="${CERT_NOW:-$(date +%s)}"
  cert_mostra "CA" "${CERT_CA}" "${agora}"
  local ilegivel_ca="${CERT_ILEGIVEL}" venc_ca="${CERT_VENCIDO}" dias_ca="${CERT_DIAS}"
  cert_mostra "Certificado" "${CERT_LEAF}" "${agora}"
  local ilegivel_leaf="${CERT_ILEGIVEL}" venc_leaf="${CERT_VENCIDO}" dias_leaf="${CERT_DIAS}"

  if saida="$(openssl verify -CAfile "${CERT_CA}" "${CERT_LEAF}" 2>&1)"; then
    echo "openssl verify: ${saida}"
  else
    echo "openssl verify: ${saida}"
    rc=2
  fi

  if [[ "${ilegivel_ca}" -eq 1 || "${ilegivel_leaf}" -eq 1 ]]; then
    echo "AVISO: nao consegui ler a CA ou o certificado (arquivo corrompido?)" >&2
    rc=2
  elif [[ "${venc_ca}" -eq 1 || "${venc_leaf}" -eq 1 ]]; then
    echo "AVISO: certificado expirado" >&2
    rc=2
  elif [[ "${dias_leaf}" -lt "${CERT_WARN_DAYS}" || "${dias_ca}" -lt "${CERT_WARN_DAYS}" ]]; then
    echo "AVISO: faltam menos de ${CERT_WARN_DAYS} dias: ./larcerto.sh cert renew" >&2
  fi

  ip="$(cert_web_ip)"
  fp_local="$(cert_fp "${CERT_LEAF}")"
  fp_servido="$(cert_fp_servido "${ip}")"
  if [[ -z "${fp_servido}" ]]; then
    echo "servido: inacessivel"
  elif [[ "${fp_servido}" == "${fp_local}" ]]; then
    echo "servido: igual"
  else
    echo "servido: diferente"
    rc=2
  fi

  cert_status_cloud "${agora}" || rc=2
  return "${rc}"
}


# Bloco do Horizon no status. Sem cloud.crt so informa; sai 1 se a cadeia nao confere, venceu,
# nao le ou o VIP serve outro certificado.
cert_status_cloud() {
  local agora="$1" saida fp_servido ruim=0
  if [[ ! -f "${CERT_CLOUD}" ]]; then
    echo "Horizon (cloud): nao emitido (./larcerto.sh cert cloud)"
    return 0
  fi
  cert_mostra "Horizon (cloud)" "${CERT_CLOUD}" "${agora}"
  if [[ "${CERT_ILEGIVEL}" -eq 1 || "${CERT_VENCIDO}" -eq 1 ]]; then
    ruim=1
  fi
  if saida="$(openssl verify -CAfile "${CERT_CA}" "${CERT_CLOUD}" 2>&1)"; then
    echo "  openssl verify: ${saida}"
  else
    echo "  openssl verify: ${saida}"
    ruim=1
  fi
  fp_servido="$(cert_fp_servido "$(cert_vip)" "${CERT_CLOUD_FQDN}")"
  if [[ -z "${fp_servido}" ]]; then
    echo "  servido: inacessivel"
  elif [[ "${fp_servido}" == "$(cert_fp "${CERT_CLOUD}")" ]]; then
    echo "  servido: igual"
  else
    echo "  servido: diferente"
    ruim=1
  fi
  return "${ruim}"
}


# VIP do Kolla (onde o HAProxy serve o Horizon).
cert_vip() {
  read_globals kolla_internal_vip_address 192.168.1.250
}


# Roda o site.yml so nas VMs ca e web, com as variaveis extra recebidas.
cert_ansible() {
  cert_ansible_em ca,web "$@"
}

# Roda o site.yml so nas VMs de <limit>, com as variaveis extra recebidas.
cert_ansible_em() {
  local limite="$1"
  shift
  (cd "${SCRIPT_DIR}/ansible" && "${ANSIBLE_PLAYBOOK_BIN}" site.yml --limit "${limite}" "$@")
}


cert_exige_hosts() {
  if [[ ! -f "${HOSTS_INI}" ]]; then
    echo "Falta: ${HOSTS_INI} -> ./larcerto.sh install-app (o inventario sai do Terraform)" >&2
    return 1
  fi
}

# Renovar sem a CA guardada faria a VM criar outra CA sem aviso: so o --new-ca pode fazer isso.
cert_exige_ca() {
  if [[ ! -f "${CERT_PKI_DIR}/ca.key" ]]; then
    echo "Falta: ${CERT_PKI_DIR}/ca.key -> ./larcerto.sh install-app --from nuvem" >&2
    echo "Sem a CA guardada, a VM ca criaria outra CA sem aviso. Para trocar a CA de propósito: cert renew --new-ca" >&2
    return 1
  fi
}


# Troca a CA: confirmacao, copia de seguranca de files/pki/ e so depois o Ansible com ca_new=true.
cert_troca_ca() {
  local sem_pergunta="$1" resp backup f rc=0
  if [[ "${sem_pergunta}" -eq 0 ]]; then
    echo "ATENCAO: a CA LarCerto importada nos navegadores deixa de valer."
    echo "Para trocar, digite nova-ca:"
    IFS= read -r resp || resp=""
    if [[ "${resp}" != "nova-ca" ]]; then
      echo "Nada foi alterado." >&2
      return 1
    fi
  fi

  backup="${CERT_PKI_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${backup}"
  for f in "${CERT_PKI_DIR}"/*.crt "${CERT_PKI_DIR}"/*.key; do
    if [[ -f "${f}" ]]; then
      cp "${f}" "${backup}/"
    fi
  done
  find "${backup}" -name '*.key' -exec chmod 600 {} +
  step "Copia de seguranca da CA atual: ${backup}"

  step "Trocando a CA (VM ca apaga a PKI e cria outra)"
  cert_ansible -e ca_new=true || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "FALHOU: cert renew --new-ca (ansible), codigo ${rc}" >&2
    return "${rc}"
  fi
  cert_status || rc=$?
  echo "Reimporte a CA: ./larcerto.sh cert trust"
  echo "Reemita o do Horizon: ./larcerto.sh cert cloud"
  return "${rc}"
}


# renew [--new-ca [--yes]]: emite de novo o certificado com a mesma CA, ou troca a CA.
cert_renew() {
  local nova=0 sem_pergunta=0 arg rc=0
  for arg in "$@"; do
    case "${arg}" in
      --new-ca) nova=1 ;;
      --yes) sem_pergunta=1 ;;
      *) cert_uso; return 1 ;;
    esac
  done
  if [[ "${sem_pergunta}" -eq 1 && "${nova}" -eq 0 ]]; then
    cert_uso
    return 1
  fi
  cert_exige_hosts || return 1

  if [[ "${nova}" -eq 1 ]]; then
    cert_troca_ca "${sem_pergunta}"
    return
  fi
  cert_exige_ca || return 1

  step "Renovando o certificado do servidor (mesma CA, VM ca)"
  cert_ansible -e cert_renew=true || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "FALHOU: cert renew (ansible), codigo ${rc}" >&2
    return "${rc}"
  fi
  cert_status
}


# Bancos NSS do usuario: Firefox (nativo, flatpak, snap), ~/.pki/nssdb (Brave/Chromium nativos) e
# <app>/data/pki/nssdb dos Chromium em flatpak (ex.: com.brave.Browser), que nao leem o ~/.pki do host.
cert_bancos_nss() {
  local d
  CERT_BANCOS=()
  shopt -s nullglob
  for d in "${HOME}"/.mozilla/firefox/*/ "${HOME}"/.var/app/org.mozilla.firefox/.mozilla/firefox/*/ \
    "${HOME}"/snap/firefox/common/.mozilla/firefox/*/ "${HOME}"/.pki/nssdb/ \
    "${HOME}"/.var/app/*/data/pki/nssdb/; do
    if [[ -f "${d}cert9.db" ]]; then
      CERT_BANCOS+=("${d%/}")
    fi
  done
  shopt -u nullglob
}


# Importa ca.crt num banco: imprime importado, ja estava, substituido ou falhou. Sempre sai 0.
cert_importa() {
  local db="sql:$1" nova_fp atual_fp trocou=0
  nova_fp="$(cert_fp "${CERT_CA}")"
  if certutil -L -d "${db}" -n "${CERT_NOME_NSS}" >/dev/null 2>&1; then
    atual_fp="$(certutil -L -d "${db}" -n "${CERT_NOME_NSS}" -a 2>/dev/null \
      | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)" || true
    if [[ "${atual_fp}" == "${nova_fp}" ]]; then
      echo "ja estava"
      return 0
    fi
    if ! certutil -D -d "${db}" -n "${CERT_NOME_NSS}" >/dev/null 2>&1; then
      echo "falhou"
      return 0
    fi
    trocou=1
  fi
  if certutil -A -d "${db}" -n "${CERT_NOME_NSS}" -t "C,," -i "${CERT_CA}" >/dev/null 2>&1; then
    if [[ "${trocou}" -eq 1 ]]; then
      echo "substituido"
    else
      echo "importado"
    fi
  else
    echo "falhou"
  fi
}


# trust: grava a CA nos bancos NSS do usuario (sem sudo). Sai 1 sem certutil, sem ca.crt ou se um banco falhar.
cert_trust() {
  local db status falhou=0
  if ! command -v certutil >/dev/null 2>&1; then
    echo "Falta: certutil -> sudo apt install libnss3-tools" >&2
    echo "Sem ele, importe a mao: Configuracoes > Certificados > Autoridades > Importar > ${CERT_CA} (confiar para identificar sites)." >&2
    return 1
  fi
  if [[ ! -f "${CERT_CA}" ]]; then
    echo "Falta: ${CERT_CA} -> ./larcerto.sh install-app --from nuvem" >&2
    return 1
  fi

  cert_bancos_nss
  if [[ "${#CERT_BANCOS[@]}" -eq 0 ]]; then
    echo "Nenhum banco NSS do usuario encontrado (abra o navegador uma vez e rode de novo)." >&2
    return 1
  fi
  for db in "${CERT_BANCOS[@]}"; do
    status="$(cert_importa "${db}")"
    printf '%s: %s\n' "${db}" "${status}"
    if [[ "${status}" == falhou ]]; then
      falhou=1
    fi
  done

  echo "Opcional, para o curl e outros programas do sistema (nao executado aqui):"
  echo "  sudo cp ${CERT_CA} /usr/local/share/ca-certificates/larcerto-ca.crt"
  echo "  sudo update-ca-certificates"
  echo "Reinicie o navegador que estiver aberto para ele ler a CA."
  echo "Vale para https://larcerto.com.br e https://${CERT_CLOUD_FQDN} (mesma CA)."
  return "${falhou}"
}


# 0 se cloud.crt e cloud.key existem, o certificado confere com a CA, nao venceu e a chave e do par.
cert_cloud_valido() {
  [[ -f "${CERT_CLOUD}" && -f "${CERT_CLOUD_KEY}" ]] || return 1
  openssl verify -CAfile "${CERT_CA}" "${CERT_CLOUD}" >/dev/null 2>&1 || return 1
  openssl x509 -in "${CERT_CLOUD}" -noout -checkend 0 >/dev/null 2>&1 || return 1
  [[ "$(openssl x509 -in "${CERT_CLOUD}" -noout -pubkey 2>/dev/null)" \
    == "$(openssl pkey -in "${CERT_CLOUD_KEY}" -pubout 2>/dev/null)" ]]
}


# Entrega o certificado ao HAProxy do Kolla: <node_config>/haproxy/haproxy.pem (cert + CA + chave,
# root 600), que o kolla_set_configs copia para dentro do container a cada start. Com o frontend 443 ja
# criado pelo deploy, reinicia o haproxy para ler o .pem novo; sem ele, o proximo deploy cria o frontend
# (o template so sai com o .pem presente) e o proprio Kolla reinicia o haproxy.
cert_cloud_instala() {
  local destino="${KOLLA_NODE_CONFIG}/haproxy/haproxy.pem"
  local frontend="${KOLLA_NODE_CONFIG}/haproxy/services.d/horizon-https.cfg"
  local tmp rc=0
  tmp="$(umask 077 && mktemp)"
  if ! cat "${CERT_CLOUD}" "${CERT_CA}" "${CERT_CLOUD_KEY}" >"${tmp}"; then
    rm -f "${tmp}"
    echo "FALHOU: montar o .pem do Horizon" >&2
    return 1
  fi
  run_as_root install -D -m 600 "${tmp}" "${destino}" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    run_as_root chown root:root "${destino}" || rc=$?
  fi
  rm -f "${tmp}"
  if [[ "${rc}" -ne 0 ]]; then
    echo "FALHOU: gravar ${destino}, codigo ${rc}" >&2
    return "${rc}"
  fi
  echo "Certificado do Horizon: ${destino} (root, 600)"

  if ! run_as_root grep -q horizon_https_front "${frontend}" 2>/dev/null; then
    echo "Falta o frontend 443 do Horizon: rode ./larcerto.sh deploy uma vez"
    return 0
  fi
  docker_cmd restart haproxy >/dev/null || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "FALHOU: docker restart haproxy, codigo ${rc}" >&2
    return "${rc}"
  fi
  echo "haproxy reiniciado"
  echo "Pronto: https://${CERT_CLOUD_FQDN}"
}


# cloud: emite (se preciso) na VM ca o certificado do Horizon e entrega ao HAProxy do Kolla.
cert_cloud() {
  local rc=0
  cert_exige_hosts || return 1
  cert_exige_ca || return 1
  if cert_cloud_valido; then
    echo "Horizon (cloud): ja existia"
  else
    step "Emitindo o certificado do Horizon (${CERT_CLOUD_FQDN}) na VM ca"
    cert_ansible_em ca -e cert_cloud=true || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      echo "FALHOU: cert cloud (ansible), codigo ${rc}" >&2
      return "${rc}"
    fi
    if ! cert_cloud_valido; then
      echo "FALHOU: ${CERT_CLOUD} nao confere com ${CERT_CA} ou com a chave" >&2
      return 2
    fi
    chmod 600 "${CERT_CLOUD_KEY}"
    echo "Horizon (cloud): emitido"
  fi
  cert_cloud_instala
}


# Ponto de entrada de ./larcerto.sh cert [subcomando]
cert_main() {
  local sub="${1:-status}"
  if [[ $# -gt 0 ]]; then
    shift
  fi
  case "${sub}" in
    status)
      if [[ $# -gt 0 ]]; then cert_uso; return 1; fi
      cert_status
      ;;
    renew) cert_renew "$@" ;;
    trust)
      if [[ $# -gt 0 ]]; then cert_uso; return 1; fi
      cert_trust
      ;;
    cloud)
      if [[ $# -gt 0 ]]; then cert_uso; return 1; fi
      cert_cloud
      ;;
    *) cert_uso; return 1 ;;
  esac
}
