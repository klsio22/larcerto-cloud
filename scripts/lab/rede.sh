# Rede do lab: dummy0, br-ex (fix-wired), ext-net (NAT das floating IPs) e split DNS do host.
# Carregado pelo larcerto.sh; so define funcoes e variaveis.
# shellcheck shell=bash


network_iface() {
  read_globals network_interface enp9s0
}


external_iface() {
  read_globals neutron_external_interface dummy0
}


vip_address() {
  read_globals kolla_internal_vip_address 192.168.1.250
}

# wait_vip: espera o Keystone responder no VIP. Ao reativar o cabo, o NetworkManager tira o VIP e o
# keepalived so o devolve alguns segundos depois; sem esperar, o Terraform logo em seguida falha
# com "no route to host". VIP_WAIT = segundos (padrao 90).
wait_vip() {
  local vip t0="${SECONDS}"
  vip="$(vip_address)"
  step "Esperar a API da nuvem em ${vip}:5000"
  until curl -s -o /dev/null --noproxy '*' --max-time 3 "http://${vip}:5000/"; do
    if [[ $((SECONDS - t0)) -ge "${VIP_WAIT:-90}" ]]; then
      echo "AVISO: a API em ${vip}:5000 nao respondeu em ${VIP_WAIT:-90}s (o VIP saiu da interface?); veja ./larcerto.sh status" >&2
      return 1
    fi
    sleep 2
  done
  echo "API respondendo em ${vip}:5000."
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


cmd_fix_wired() {
  local nif ext
  nif="$(network_iface)"
  ext="$(external_iface)"
  step "Rede: network_interface=${nif} neutron_external=${ext}"

  if [[ "${nif}" == "${ext}" ]]; then
    echo "Erro: network_interface e neutron_external_interface sao iguais (${nif}). Corrige globals.yml." >&2
    return 1
  fi

  if ovs_db_running; then
    step "Portas br-ex antes"
    print_br_ex_ports
    if mgmt_on_br_ex; then
      step "Removendo ${nif} de br-ex (nao remove ${ext})"
      docker_cmd exec openvswitch_db ovs-vsctl --if-exists del-port br-ex "${nif}"
    else
      echo "    ${nif} nao esta em br-ex"
    fi
    step "Portas br-ex depois"
    print_br_ex_ports
  else
    step "openvswitch_db nao esta Up — so a restaurar NetworkManager"
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    echo "Erro: nmcli nao encontrado." >&2
    return 1
  fi

  step "NetworkManager: ativar cabo em ${nif}"
  local conn
  conn="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="${nif}" '$2 == d { print $1; exit }')"
  if [[ -n "${conn}" ]]; then
    echo "    ligacao: ${conn}"
    nmcli connection up "${conn}"
  else
    nmcli device connect "${nif}"
  fi

  sleep 2
  step "Enderecos em ${nif}"
  ip -br addr show "${nif}" | sed 's/^/    /'
  if ! ip -4 -o addr show "${nif}" 2>/dev/null | grep -q 'inet '; then
    echo "FALHA: ${nif} sem IPv4. Verifica cabo/DHCP." >&2
    return 1
  fi
  echo "Cabo OK"
}


# Rede externa do Neutron (public) alcancavel pelo host, como a br-ex do DevStack nas aulas (M06/M07).
EXT_NET_CIDR="172.24.4.0/24"
EXT_NET_GW="172.24.4.1/24"
EXT_NET_TAG="lab-ext-net"
EXT_NET_WAIT="${EXT_NET_WAIT:-30}"
IP_FORWARD_FILE="${IP_FORWARD_FILE:-/proc/sys/net/ipv4/ip_forward}"

# Chain para liberar o trafego da br-ex: DOCKER-USER se o Docker gerir o iptables, senao
# FORWARD (a policy dele pode estar em DROP pelo UFW ou pelo Docker). Regras vao na posicao 1.
forward_chain() {
  if run_as_root iptables -t filter -nL DOCKER-USER >/dev/null 2>&1; then
    echo DOCKER-USER
  else
    echo FORWARD
  fi
}


# ext_net_rules <nif> <chain>: imprime "tabela chain regra..." de cada regra do ext-net.
ext_net_rules() {
  local nif="$1" chain="$2"
  local tag=(-m comment --comment "${EXT_NET_TAG}")
  printf '%s\n' \
    "nat POSTROUTING -s ${EXT_NET_CIDR} ! -d ${EXT_NET_CIDR} -o ${nif} ${tag[*]} -j MASQUERADE" \
    "filter ${chain} -i br-ex -o ${nif} ${tag[*]} -j ACCEPT" \
    "filter ${chain} -i ${nif} -o br-ex -m conntrack --ctstate RELATED,ESTABLISHED ${tag[*]} -j ACCEPT"
}


cmd_ext_net() {
  local mode="up"
  case "${1:-}" in
    "") ;;
    --down) mode="down" ;;
    *) echo "Uso: larcerto.sh ext-net [--down]" >&2; return 1 ;;
  esac

  local nif chain i
  nif="$(network_iface)"
  for ((i = 0; i < EXT_NET_WAIT; i++)); do
    ip link show br-ex >/dev/null 2>&1 && break
    sleep 1
  done
  if ! ip link show br-ex >/dev/null 2>&1; then
    echo "Erro: br-ex nao existe (lab parado? ./larcerto.sh start)" >&2
    return 1
  fi
  chain="$(forward_chain)"

  # Cada comando de root termina em "|| return 1": chamada dentro de "if !" (start/deploy),
  # a funcao roda sem set -e e uma falha passaria em silencio.
  local table ch rule line
  if [[ "${mode}" == "down" ]]; then
    step "ext-net --down: removendo ${EXT_NET_GW} da br-ex e regras ${EXT_NET_TAG}"
    # Remove pelo comentario (vale mesmo se interface ou chain mudaram desde o "up").
    local current
    for table in nat filter; do
      current="$(run_as_root iptables -t "${table}" -S)" || return 1
      while read -r line; do
        [[ -n "${line}" ]] || continue
        # shellcheck disable=SC2086
        run_as_root iptables -t "${table}" ${line/#-A /-D } || return 1
      done < <(grep -- "--comment ${EXT_NET_TAG}" <<<"${current}")
    done
    if ip -4 -o addr show br-ex 2>/dev/null | grep -q "inet ${EXT_NET_GW} "; then
      run_as_root ip addr del "${EXT_NET_GW}" dev br-ex || return 1
    fi
    echo "ext-net removido. (net.ipv4.ip_forward fica como esta: o Docker tambem depende dele)"
    return 0
  fi

  step "ext-net: br-ex com ${EXT_NET_GW} e NAT de ${EXT_NET_CIDR} via ${nif}"
  if ! ip -4 -o addr show br-ex 2>/dev/null | grep -q "inet ${EXT_NET_GW} "; then
    run_as_root ip addr add "${EXT_NET_GW}" dev br-ex || return 1
  fi
  run_as_root ip link set br-ex up || return 1
  if [[ "$(cat "${IP_FORWARD_FILE}" 2>/dev/null)" != "1" ]]; then
    run_as_root sysctl -w net.ipv4.ip_forward=1 >/dev/null || return 1
  fi
  while read -r table ch rule; do
    # shellcheck disable=SC2086
    if ! run_as_root iptables -t "${table}" -C "${ch}" ${rule} 2>/dev/null; then
      run_as_root iptables -t "${table}" -I "${ch}" 1 ${rule} || return 1
    fi
  done < <(ext_net_rules "${nif}" "${chain}")
  ip -4 -br addr show br-ex | sed 's/^/    /'
  echo "ext-net OK (desfazer: ./larcerto.sh ext-net --down)"
}


# Split DNS do host: so *.larcerto.com.br vai para a VM dns (nao persiste no reboot).
DNS_DOMAIN="larcerto.com.br"
INVENTORY_INI="${SCRIPT_DIR}/ansible/inventory/hosts.ini"

cmd_dns_host() {
  if [[ "${1:-}" == "--down" ]]; then
    step "dns-host --down: removendo DNS de ${DNS_DOMAIN} da br-ex"
    run_as_root resolvectl revert br-ex
    return 0
  fi
  local ip="${1:-}"
  if [[ -z "${ip}" && -f "${INVENTORY_INI}" ]]; then
    ip="$(grep -A1 '^\[dns\]' "${INVENTORY_INI}" | grep -oE 'ansible_host=[0-9.]+' | cut -d= -f2)"
  fi
  if [[ -z "${ip}" ]]; then
    echo "Uso: larcerto.sh dns-host [<ip da VM dns>|--down] (sem ip: le ${INVENTORY_INI})" >&2
    return 1
  fi
  step "dns-host: ~${DNS_DOMAIN} -> ${ip} (via br-ex)"
  run_as_root resolvectl dns br-ex "${ip}"
  run_as_root resolvectl domain br-ex "~${DNS_DOMAIN}"
  echo "Teste: resolvectl query www.${DNS_DOMAIN}   (desfazer: ./larcerto.sh dns-host --down)"
}
