#!/usr/bin/env bash
# Entrypoint único do lab AIO (dummy0, OVS host, testes, stop, fixes).
# Uso: ./project/lab.sh <comando> [opções]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GLOBALS_YML="${SCRIPT_DIR}/kolla-config/globals.yml"

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return 0
  fi
  # Preferir sudo sem senha (NOPASSWD); senao Docker privilegiado (grupo docker).
  if sudo -n true 2>/dev/null; then
    sudo "$@"
    return $?
  fi
  if docker info >/dev/null 2>&1; then
    docker run --rm --privileged --pid=host alpine:3.20 \
      nsenter -t 1 -m -u -i -n "$@"
    return $?
  fi
  echo "Precisa de root: configure sudo NOPASSWD, entre no grupo docker, ou digite a senha." >&2
  sudo "$@"
}

DOCKER=()
init_docker() {
  if [[ "${#DOCKER[@]}" -gt 0 ]]; then
    return 0
  fi
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    echo "Erro: sem permissao para acessar o Docker." >&2
    exit 1
  fi
}

docker_cmd() {
  init_docker
  "${DOCKER[@]}" "$@"
}

# Lê "key: value" ativo (não comentado) de globals.yml.
read_globals_iface() {
  local key="$1"
  local default="$2"
  local val=""
  if [[ -f "${GLOBALS_YML}" ]]; then
    val="$(grep -E "^${key}:" "${GLOBALS_YML}" 2>/dev/null | head -1 \
      | sed -E 's/^[^:]+:[[:space:]]*"?([^"#]+)"?.*/\1/' \
      | tr -d '[:space:]')"
  fi
  if [[ -z "${val}" ]]; then
    printf '%s\n' "${default}"
  else
    printf '%s\n' "${val}"
  fi
}

network_iface() {
  read_globals_iface network_interface enp9s0
}

external_iface() {
  read_globals_iface neutron_external_interface dummy0
}

ovs_db_running() {
  docker_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx openvswitch_db
}

br_ex_ports() {
  if ! ovs_db_running; then
    return 0
  fi
  docker_cmd exec openvswitch_db ovs-vsctl list-ports br-ex 2>/dev/null || true
}

mgmt_on_br_ex() {
  local nif
  nif="$(network_iface)"
  br_ex_ports | grep -qx "${nif}"
}

warn_or_fail_mgmt_on_br_ex() {
  # $1 = warn | fail
  local mode="${1:-warn}"
  local nif
  nif="$(network_iface)"
  if ! ovs_db_running; then
    return 0
  fi
  echo "==> Portas br-ex (externa deve ser só $(external_iface))"
  local ports
  ports="$(br_ex_ports)"
  if [[ -z "${ports}" ]]; then
    echo "    (vazio ou br-ex indisponivel)"
    return 0
  fi
  printf '%s\n' "${ports}" | sed 's/^/    /'
  if printf '%s\n' "${ports}" | grep -qx "${nif}"; then
    echo "    AVISO: ${nif} (network_interface) esta em br-ex — cabo sem IPv4"
    echo "    Corre: ./project/lab.sh fix-wired"
    if [[ "${mode}" == "fail" ]]; then
      return 1
    fi
  fi
  return 0
}

usage() {
  cat <<'EOF'
Uso: ./project/lab.sh <comando> [opções]

Comandos:
  prep           dummy0 + desativa OVS do host (antes do 1º deploy / após conflito OVS)
  dummy0         Cria/ativa interface dummy0 (neutron_external_interface)
  fix-ovs        Para OVS do host, limpa /run/openvswitch, remove containers OVS Kolla
  fix-wired      Tira network_interface de br-ex e reativa a cabo no NetworkManager
  test-ovs       Teste rápido (segundos) do openvswitch_db / vswitchd
  fix-horizon    Remove container horizon em conflito 409 (depois: lab.sh deploy)
  status         Estado rápido: dummy0, OVS, br-ex, Horizon, VIP
  stop           Para containers Docker [--remove] [--disable-kolla-services]
  deploy | bootstrap | prechecks | post-deploy | all | stop-kolla
                 Encaminha para ./project/run-kolla.sh
                 (deploy / all / post-deploy: depois corre fix-wired automaticamente)

Exemplos:
  chmod +x project/lab.sh
  ./project/lab.sh prep
  ./project/lab.sh bootstrap && ./project/lab.sh prechecks && ./project/lab.sh deploy
  ./project/lab.sh post-deploy
  ./project/lab.sh test-ovs
  ./project/lab.sh fix-wired
  ./project/lab.sh status
EOF
}

cmd_dummy0() {
  local ext
  ext="$(external_iface)"
  if ! command -v ip >/dev/null 2>&1; then
    echo "Erro: comando 'ip' nao encontrado." >&2
    exit 1
  fi
  if ip link show "${ext}" >/dev/null 2>&1; then
    echo "${ext} ja existe."
  else
    run_as_root ip link add "${ext}" type dummy
    echo "${ext} criada."
  fi
  # Evita sudo/Docker se ja estiver UP
  if ip -br link show "${ext}" 2>/dev/null | grep -q 'UP'; then
    echo "${ext} esta ativa."
    return 0
  fi
  run_as_root ip link set "${ext}" up
  echo "${ext} esta ativa."
}

cmd_fix_ovs() {
  echo "==> Parar e desabilitar openvswitch-switch do host"
  run_as_root systemctl stop openvswitch-switch 2>/dev/null || true
  run_as_root systemctl disable openvswitch-switch 2>/dev/null || true

  echo "==> Limpar runtime em /run/openvswitch"
  run_as_root mkdir -p /run/openvswitch
  run_as_root chmod 770 /run/openvswitch
  run_as_root rm -f \
    /run/openvswitch/ovsdb-server.pid \
    /run/openvswitch/ovs-vswitchd.pid \
    /run/openvswitch/db.sock \
    /run/openvswitch/ovsdb-server.*.ctl \
    /run/openvswitch/ovs-vswitchd.*.ctl

  echo "==> Remover containers Kolla OVS (serão recriados no deploy)"
  docker_cmd rm -f openvswitch_db openvswitch_vswitchd 2>/dev/null || true

  echo "==> Estado"
  systemctl is-active openvswitch-switch 2>/dev/null || true
  ls -la /run/openvswitch 2>/dev/null || true
  docker_cmd ps -a --filter name=openvswitch --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true
  echo "Pronto. Depois: ./project/lab.sh deploy   (ou ./project/lab.sh test-ovs se já tiveres OVS)"
}

cmd_fix_wired() {
  local nif ext
  nif="$(network_iface)"
  ext="$(external_iface)"
  echo "==> Rede: network_interface=${nif} neutron_external=${ext}"

  if [[ "${nif}" == "${ext}" ]]; then
    echo "Erro: network_interface e neutron_external_interface sao iguais (${nif}). Corrige globals.yml." >&2
    exit 1
  fi

  if ovs_db_running; then
    echo "==> Portas br-ex antes"
    br_ex_ports | sed 's/^/    /' || echo "    (vazio)"
    if br_ex_ports | grep -qx "${nif}"; then
      echo "==> Removendo ${nif} de br-ex (nao remove ${ext})"
      docker_cmd exec openvswitch_db ovs-vsctl --if-exists del-port br-ex "${nif}"
    else
      echo "    ${nif} nao esta em br-ex"
    fi
    echo "==> Portas br-ex depois"
    br_ex_ports | sed 's/^/    /' || echo "    (vazio)"
  else
    echo "==> openvswitch_db nao esta Up — so a restaurar NetworkManager"
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    echo "Erro: nmcli nao encontrado." >&2
    exit 1
  fi

  echo "==> NetworkManager: ativar cabo em ${nif}"
  local conn
  conn="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="${nif}" '$2 == d { print $1; exit }')"
  if [[ -n "${conn}" ]]; then
    echo "    ligacao: ${conn}"
    nmcli connection up "${conn}"
  else
    nmcli device connect "${nif}"
  fi

  sleep 2
  echo "==> Enderecos em ${nif}"
  ip -br addr show "${nif}" | sed 's/^/    /'
  if ! ip -4 -o addr show "${nif}" 2>/dev/null | grep -q 'inet '; then
    echo "FALHA: ${nif} sem IPv4. Verifica cabo/DHCP." >&2
    exit 1
  fi
  echo "Cabo OK"
}

cmd_test_ovs() {
  local fail=0
  echo "==> Host openvswitch-switch (deve estar inactive)"
  local host_ovs
  host_ovs="$(systemctl is-active openvswitch-switch 2>/dev/null || true)"
  echo "    status: ${host_ovs:-unknown}"
  if [[ "${host_ovs}" == "active" ]]; then
    echo "    FALHA: OVS do host ativo — ./project/lab.sh fix-ovs"
    fail=1
  fi

  echo "==> Containers"
  docker_cmd ps -a --filter name=openvswitch --format '    {{.Names}}\t{{.Status}}' || true
  local c
  for c in openvswitch_db openvswitch_vswitchd; do
    if ! docker_cmd ps --format '{{.Names}}' | grep -qx "$c"; then
      echo "    FALHA: $c nao esta Up"
      fail=1
    fi
  done

  echo "==> ovs-vsctl --no-wait show (mesmo check do Kolla)"
  local tmp
  tmp="$(mktemp)"
  if docker_cmd exec openvswitch_db ovs-vsctl --no-wait show >"${tmp}" 2>&1; then
    head -n 20 "${tmp}"
    echo "    OK"
  else
    echo "    FALHA:"
    cat "${tmp}" || true
    fail=1
  fi
  rm -f "${tmp}"

  echo "==> /run/openvswitch"
  if ls -la /run/openvswitch >/dev/null 2>&1; then
    ls -la /run/openvswitch | sed 's/^/    /'
  else
    run_as_root ls -la /run/openvswitch 2>&1 | sed 's/^/    /' || true
  fi

  if ! warn_or_fail_mgmt_on_br_ex fail; then
    fail=1
  fi

  if [[ "${fail}" -ne 0 ]]; then
    echo
    echo "OVS NAO OK. pidfile/host: ./project/lab.sh fix-ovs · cabo no br-ex: ./project/lab.sh fix-wired"
    exit 1
  fi
  echo
  echo "OVS OK"
}

cmd_fix_horizon() {
  echo "==> Remover container horizon (resolve 409 Conflict no recreate)"
  docker_cmd rm -f horizon 2>/dev/null || true
  docker_cmd ps -a --filter name=horizon --format 'table {{.Names}}\t{{.Status}}' || true
  echo "Pronto. Recria com: ./project/lab.sh deploy"
  echo "(Se Horizon já abria no browser e estava healthy, podes ignorar e só usar o login.)"
}

cmd_prep() {
  echo "==> prep: dummy0 + OVS do host fora do caminho"
  cmd_dummy0
  cmd_fix_ovs
  echo
  echo "Prep OK. Fluxo: bootstrap → prechecks → deploy → post-deploy"
  echo "  ./project/lab.sh bootstrap"
  echo "  ./project/lab.sh prechecks"
  echo "  ./project/lab.sh deploy"
  echo "  ./project/lab.sh post-deploy"
  echo "(deploy/all/post-deploy ja aplicam fix-wired no fim)"
}

cmd_status() {
  local nif ext
  nif="$(network_iface)"
  ext="$(external_iface)"

  echo "==> interfaces (globals)"
  echo "    network_interface=${nif}"
  echo "    neutron_external=${ext}"

  echo "==> ${ext}"
  if ip link show "${ext}" >/dev/null 2>&1; then
    ip -br link show "${ext}" | sed 's/^/    /'
  else
    echo "    ausente — ./project/lab.sh dummy0"
  fi

  echo "==> ${nif} (cabo / gestao)"
  if ip link show "${nif}" >/dev/null 2>&1; then
    ip -br addr show "${nif}" | sed 's/^/    /'
  else
    echo "    interface ausente"
  fi

  echo "==> openvswitch-switch (host)"
  echo "    $(systemctl is-active openvswitch-switch 2>/dev/null || true)"

  echo "==> containers OVS / Horizon"
  docker_cmd ps -a --filter name=openvswitch --format '    {{.Names}}\t{{.Status}}' 2>/dev/null || true
  docker_cmd ps -a --filter name=horizon --format '    {{.Names}}\t{{.Status}}' 2>/dev/null || true

  warn_or_fail_mgmt_on_br_ex warn || true

  echo "==> VIP Horizon http://192.168.1.250"
  if curl -s -o /dev/null -w '    HTTP %{http_code}\n' --connect-timeout 3 http://192.168.1.250/auth/login/ 2>/dev/null; then
    :
  else
    echo "    sem resposta (deploy/post-deploy ainda nao prontos?)"
  fi
}

cmd_stop() {
  local REMOVE_AFTER_STOP=false
  local DISABLE_KOLLA_SERVICES=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remove) REMOVE_AFTER_STOP=true; shift ;;
      --disable-kolla-services) DISABLE_KOLLA_SERVICES=true; shift ;;
      -h|--help)
        echo "Uso: lab.sh stop [--remove] [--disable-kolla-services]"
        exit 0
        ;;
      *)
        echo "Opcao invalida: $1" >&2
        exit 1
        ;;
    esac
  done

  if command -v systemctl >/dev/null 2>&1; then
    mapfile -t kolla_services < <(systemctl list-units --type=service --all 'kolla-*' --no-legend 2>/dev/null | awk '{print $1}')
  else
    kolla_services=()
  fi

  if [[ "${#kolla_services[@]}" -gt 0 ]]; then
    echo "Parando servicos kolla-* ..."
    run_as_root systemctl stop "${kolla_services[@]}" 2>/dev/null || true
    if [[ "${DISABLE_KOLLA_SERVICES}" == "true" ]]; then
      run_as_root systemctl disable "${kolla_services[@]}" 2>/dev/null || true
    fi
  fi

  init_docker
  local running_ids
  running_ids="$("${DOCKER[@]}" ps -q)"
  if [[ -z "${running_ids}" ]]; then
    echo "Nenhum container em execucao."
  else
    echo "Parando containers..."
    "${DOCKER[@]}" ps -q | xargs -r "${DOCKER[@]}" stop
    echo "Containers parados."
  fi

  if [[ "${REMOVE_AFTER_STOP}" == "true" ]]; then
    local all_ids
    all_ids="$("${DOCKER[@]}" ps -aq)"
    if [[ -z "${all_ids}" ]]; then
      echo "Nenhum container para remover."
    else
      echo "Removendo containers..."
      "${DOCKER[@]}" ps -aq | xargs -r "${DOCKER[@]}" rm
      echo "Containers removidos."
    fi
  fi
}

cmd_kolla() {
  local action="$1"
  shift || true
  "${SCRIPT_DIR}/run-kolla.sh" "${action}" "$@"
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    return "${rc}"
  fi
  # Padrao do lab AIO: apos subir a nuvem, NIC de gestao fora do br-ex.
  case "${action}" in
    deploy|all|post-deploy)
      echo
      echo "==> Padrao do lab: cabo (network_interface) fora do br-ex"
      if ! cmd_fix_wired; then
        echo "AVISO: fix-wired nao confirmou IPv4 (cabo desligado?). Deploy Kolla terminou OK." >&2
      fi
      ;;
  esac
}

ACTION="${1:-help}"
shift || true

case "${ACTION}" in
  help|-h|--help) usage ;;
  prep) cmd_prep ;;
  dummy0) cmd_dummy0 ;;
  fix-ovs) cmd_fix_ovs ;;
  fix-wired) cmd_fix_wired ;;
  test-ovs) cmd_test_ovs ;;
  fix-horizon) cmd_fix_horizon ;;
  status) cmd_status ;;
  stop) cmd_stop "$@" ;;
  deploy|bootstrap|prechecks|post-deploy|all) cmd_kolla "${ACTION}" "$@" ;;
  stop-kolla) cmd_kolla stop "$@" ;;
  *)
    echo "Comando desconhecido: ${ACTION}" >&2
    usage >&2
    exit 1
    ;;
esac
