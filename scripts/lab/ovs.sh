# OVS do host e containers openvswitch_*: fix-ovs, test-ovs e leitura das portas da br-ex.
# Carregado pelo larcerto.sh; so define funcoes e variaveis.
# shellcheck shell=bash


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


# Imprime portas indentadas, ou "(vazio)".
print_br_ex_ports() {
  local ports
  ports="$(br_ex_ports)"
  if [[ -z "${ports}" ]]; then
    echo "    (vazio)"
  else
    printf '%s\n' "${ports}" | sed 's/^/    /'
  fi
}


warn_or_fail_mgmt_on_br_ex() {
  # $1 = warn | fail
  local mode="${1:-warn}"
  local nif
  nif="$(network_iface)"
  if ! ovs_db_running; then
    return 0
  fi
  step "Portas br-ex (externa deve ser só $(external_iface))"
  local ports
  ports="$(br_ex_ports)"
  if [[ -z "${ports}" ]]; then
    echo "    (vazio ou br-ex indisponivel)"
    return 0
  fi
  printf '%s\n' "${ports}" | sed 's/^/    /'
  if printf '%s\n' "${ports}" | grep -qx "${nif}"; then
    echo "    AVISO: ${nif} (network_interface) esta em br-ex — cabo sem IPv4"
    echo "    Corre: ./larcerto.sh fix-wired"
    if [[ "${mode}" == "fail" ]]; then
      return 1
    fi
  fi
  return 0
}


cmd_fix_ovs() {
  step "Parar e desabilitar openvswitch-switch do host"
  run_as_root systemctl stop openvswitch-switch 2>/dev/null || true
  run_as_root systemctl disable openvswitch-switch 2>/dev/null || true

  step "Limpar runtime em /run/openvswitch"
  run_as_root mkdir -p /run/openvswitch
  run_as_root chmod 770 /run/openvswitch
  run_as_root rm -f \
    /run/openvswitch/ovsdb-server.pid \
    /run/openvswitch/ovs-vswitchd.pid \
    /run/openvswitch/db.sock \
    /run/openvswitch/ovsdb-server.*.ctl \
    /run/openvswitch/ovs-vswitchd.*.ctl

  step "Remover containers Kolla OVS (serão recriados no deploy)"
  docker_cmd rm -f openvswitch_db openvswitch_vswitchd 2>/dev/null || true

  step "Estado"
  systemctl is-active openvswitch-switch 2>/dev/null || true
  ls -la /run/openvswitch 2>/dev/null || true
  docker_cmd ps -a --filter name=openvswitch --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true
  echo "Pronto. Depois: ./larcerto.sh deploy   (ou ./larcerto.sh test-ovs se já tiveres OVS)"
}


cmd_test_ovs() {
  local fail=0
  step "Host openvswitch-switch (deve estar inactive)"
  local host_ovs
  host_ovs="$(systemctl is-active openvswitch-switch 2>/dev/null || true)"
  echo "    status: ${host_ovs:-unknown}"
  if [[ "${host_ovs}" == "active" ]]; then
    echo "    FALHA: OVS do host ativo — ./larcerto.sh fix-ovs"
    fail=1
  fi

  step "Containers"
  docker_cmd ps -a --filter name=openvswitch --format '    {{.Names}}\t{{.Status}}' || true
  local c
  for c in openvswitch_db openvswitch_vswitchd; do
    if ! docker_cmd ps --format '{{.Names}}' | grep -qx "$c"; then
      echo "    FALHA: $c nao esta Up"
      fail=1
    fi
  done

  step "ovs-vsctl --no-wait show (mesmo check do Kolla)"
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

  step "/run/openvswitch"
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
    echo "OVS NAO OK. pidfile/host: ./larcerto.sh fix-ovs · cabo no br-ex: ./larcerto.sh fix-wired"
    exit 1
  fi
  echo
  echo "OVS OK"
}
