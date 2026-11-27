# Ciclo de vida do lab: prep, status, start, stop e fix-horizon.
# Carregado pelo larcerto.sh; so define funcoes e variaveis.
# shellcheck shell=bash

# Unidades systemd kolla-* (list-unit-files sobrevive a reboot / disable).
list_kolla_unit_files() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  systemctl list-unit-files --type=service --no-legend 'kolla-*' 2>/dev/null \
    | awk '$1 ~ /^kolla-.*\.service$/ { print $1 }'
}


cmd_fix_horizon() {
  step "Remover container horizon (resolve 409 Conflict no recreate)"
  docker_cmd rm -f horizon 2>/dev/null || true
  docker_cmd ps -a --filter name=horizon --format 'table {{.Names}}\t{{.Status}}' || true
  echo "Pronto. Recria com: ./larcerto.sh deploy"
  echo "(Se Horizon já abria no browser e estava healthy, podes ignorar e só usar o login.)"
}


cmd_prep() {
  step "prep: dummy0 + OVS do host fora do caminho"
  cmd_dummy0
  cmd_fix_ovs
  echo
  echo "Prep OK. Fluxo: bootstrap → prechecks → deploy → post-deploy"
  echo "  ./larcerto.sh bootstrap"
  echo "  ./larcerto.sh prechecks"
  echo "  ./larcerto.sh deploy"
  echo "  ./larcerto.sh post-deploy"
  echo "(deploy/all/post-deploy ja aplicam fix-wired no fim)"
}


cmd_status() {
  local nif ext
  nif="$(network_iface)"
  ext="$(external_iface)"

  step "interfaces (globals)"
  echo "    network_interface=${nif}"
  echo "    neutron_external=${ext}"

  step "${ext}"
  if ip link show "${ext}" >/dev/null 2>&1; then
    ip -br link show "${ext}" | sed 's/^/    /'
  else
    echo "    ausente — ./larcerto.sh dummy0"
  fi

  step "${nif} (cabo / gestao)"
  if ip link show "${nif}" >/dev/null 2>&1; then
    ip -br addr show "${nif}" | sed 's/^/    /'
  else
    echo "    interface ausente"
  fi

  step "openvswitch-switch (host)"
  echo "    $(systemctl is-active openvswitch-switch 2>/dev/null || true)"

  step "containers OVS / Horizon"
  docker_cmd ps -a --filter name=openvswitch --format '    {{.Names}}\t{{.Status}}' 2>/dev/null || true
  docker_cmd ps -a --filter name=horizon --format '    {{.Names}}\t{{.Status}}' 2>/dev/null || true

  warn_or_fail_mgmt_on_br_ex warn || true

  local vip
  vip="$(vip_address)"
  step "VIP Horizon http://${vip}"
  if curl -s -o /dev/null -w '    HTTP %{http_code}\n' --connect-timeout 3 "http://${vip}/auth/login/" 2>/dev/null; then
    :
  else
    echo "    sem resposta (deploy/post-deploy ainda nao prontos?)"
  fi
}


cmd_stop() {
  local REMOVE_AFTER_STOP=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remove) REMOVE_AFTER_STOP=true; shift ;;
      --disable-kolla-services) shift ;; # já é o padrão (compat)
      -h|--help)
        echo "Uso: larcerto.sh stop [--remove]"
        echo "Para kolla-*, desabilita autostart no boot e para os containers."
        exit 0
        ;;
      *)
        echo "Opcao invalida: $1" >&2
        exit 1
        ;;
    esac
  done

  local kolla_services=()
  mapfile -t kolla_services < <(list_kolla_unit_files)

  if [[ "${#kolla_services[@]}" -gt 0 ]]; then
    echo "Parando e desabilitando servicos kolla-* (nao voltam no boot)..."
    run_as_root systemctl stop "${kolla_services[@]}" 2>/dev/null || true
    run_as_root systemctl disable "${kolla_services[@]}" 2>/dev/null || true
  else
    echo "Nenhuma unidade kolla-* encontrada."
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
  else
    local remain_ids
    remain_ids="$("${DOCKER[@]}" ps -aq)"
    if [[ -n "${remain_ids}" ]]; then
      echo "Desativando restart automatico dos containers..."
      "${DOCKER[@]}" ps -aq | xargs -r "${DOCKER[@]}" update --restart=no
    fi
  fi
}


cmd_start() {
  init_docker
  local kolla_ids
  kolla_ids="$("${DOCKER[@]}" ps -aq --filter label=kolla_version 2>/dev/null || true)"
  if [[ -z "${kolla_ids}" ]]; then
    echo "Nenhum container Kolla encontrado (larcerto.sh stop --remove ou ainda sem deploy)." >&2
    echo "Corre: ./larcerto.sh deploy" >&2
    exit 1
  fi

  step "dummy0 (some no reboot; Neutron precisa dela)"
  cmd_dummy0

  local kolla_services=()
  mapfile -t kolla_services < <(list_kolla_unit_files)
  if [[ "${#kolla_services[@]}" -gt 0 ]]; then
    step "Habilitar e iniciar servicos kolla-*"
    run_as_root systemctl enable --now "${kolla_services[@]}" 2>/dev/null || true
  else
    step "Nenhuma unidade kolla-* — a subir containers via Docker"
  fi

  step "libvirt do host (conflita com o nova_libvirt)"
  local libvirt_up=0
  "${DOCKER[@]}" ps --format '{{.Names}}' | grep -qx nova_libvirt && libvirt_up=1
  if stop_host_libvirt; then
    # O nova_libvirt que ja rodava ficou ligado ao virtlogd do host: reinicia para ele usar o proprio.
    if [[ "${libvirt_up}" -eq 1 ]]; then
      "${DOCKER[@]}" restart nova_libvirt >/dev/null
      "${DOCKER[@]}" restart nova_compute >/dev/null
      echo "nova_libvirt e nova_compute reiniciados."
    fi
  elif ! host_libvirt_active; then
    echo "libvirt do host ja parado."
  fi

  step "Garantir containers Kolla Up"
  "${DOCKER[@]}" ps -aq --filter label=kolla_version | xargs -r "${DOCKER[@]}" start >/dev/null
  echo "Containers Kolla iniciados."

  echo
  if ! cmd_ext_net; then
    echo "AVISO: ext-net falhou; VMs sem acesso pelo host. Tente: ./larcerto.sh ext-net" >&2
  fi

  echo
  step "Padrao do lab: cabo (network_interface) fora do br-ex"
  cmd_fix_wired

  echo
  wait_vip
}
