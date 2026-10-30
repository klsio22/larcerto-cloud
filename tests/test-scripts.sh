#!/usr/bin/env bash
# Testes de lab.sh e run-kolla.sh sem tocar no host.
# Copia os scripts para um diretorio temporario e coloca comandos falsos
# (docker, sudo, systemctl, ip, nmcli, curl, sleep, kolla-ansible, ansible,
# pip, python3 do venv) na frente do PATH. O sudo falso so executa `env ...`
# (a chamada do kolla-ansible); qualquer outro comando de root e so registrado.
#
# Uso: bash project/tests/test-scripts.sh [teste ...]   (sem argumento: todos)
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_PY="$(command -v python3)"
REAL_BASH="${BASH}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Nao rode como root: os testes dependem do sudo falso." >&2
  exit 2
fi

# ---------------------------------------------------------------- sandbox

fake() {
  # fake <nome> <corpo>
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"${T}/bin/$1"
  chmod +x "${T}/bin/$1"
}

setup_sandbox() {
  T="$(mktemp -d)"
  mkdir -p "${T}/bin" "${T}/tmp" "${T}/venv/bin" "${T}/project/kolla-config"
  cp "${PROJECT_DIR}/lab.sh" "${PROJECT_DIR}/run-kolla.sh" "${T}/project/"
  cp -r "${PROJECT_DIR}/lib" "${T}/project/lib"
  : >"${T}/project/all-in-one"
  : >"${T}/project/kolla-config/passwords.yml"
  write_globals 'network_interface: "enp9s0"' 'neutron_external_interface: "dummy0"' \
    'kolla_internal_vip_address: "192.168.1.250"'
  echo 'ID=ubuntu' >"${T}/os-release"
  : >"${T}/log"

  fake docker '
echo "docker $*" >>"$FAKE_LOG"
case "$1" in
  info) exit 0 ;;
  ps)
    case " $* " in
      *" -q "*|*" -aq "*) [[ -n "${FAKE_CONTAINER_IDS:-}" ]] && printf "%s\n" ${FAKE_CONTAINER_IDS} ;;
      *) [[ -n "${FAKE_DOCKER_NAMES:-}" ]] && printf "%s\n" ${FAKE_DOCKER_NAMES} ;;
    esac
    exit 0 ;;
  exec)
    if [[ "$*" == "exec openvswitch_db ovs-vsctl list-ports br-ex" && -n "${FAKE_BR_EX_PORTS:-}" ]]; then
      printf "%s\n" ${FAKE_BR_EX_PORTS}
    fi
    exit 0 ;;
esac
exit 0'
  # So executa `env ...` (kolla-ansible) e comandos falsos do proprio sandbox.
  fake sudo '
echo "sudo $*" >>"$FAKE_LOG"
[[ "$1" == "-n" ]] && exit 0
[[ "$1" == "env" ]] && exec "$@"
[[ -x "'"${T}"'/bin/$1" ]] && exec "'"${T}"'/bin/$1" "${@:2}"
exit 0'
  # iptables com estado em $T/rules: "tabela chain regra..."
  fake iptables '
echo "iptables $*" >>"$FAKE_LOG"
rules="'"${T}"'/rules"; touch "$rules"
table=filter
if [[ "$1" == "-t" ]]; then table="$2"; shift 2; fi
if [[ "$1" == "-S" ]]; then
  [[ -n "${FAKE_IPTABLES_S_FAIL:-}" ]] && exit 1
  awk -v t="$table" "\$1 == t { \$1 = \"-A\"; print }" "$rules"
  exit 0
fi
[[ -n "${FAKE_IPTABLES_FAIL:-}" && "$1" == "-I" ]] && exit 1
op="$1"; chain="$2"; shift 2
case "$op" in
  -nL) [[ "${FAKE_DOCKER_USER:-1}" == 1 && "$chain" == DOCKER-USER ]] ; exit ;;
  -C) grep -qxF "$table $chain $*" "$rules"; exit ;;
  -I) shift; echo "$table $chain $*" >>"$rules" ;;
  -A) echo "$table $chain $*" >>"$rules" ;;
  -D) awk -v r="$table $chain $*" "!d && \$0 == r { d = 1; next } { print }" "$rules" >"$rules.tmp"; mv "$rules.tmp" "$rules" ;;
esac
exit 0'
  fake sysctl 'echo "sysctl $*" >>"$FAKE_LOG"'
  fake resolvectl 'echo "resolvectl $*" >>"$FAKE_LOG"'
  fake systemctl '
echo "systemctl $*" >>"$FAKE_LOG"
[[ "$1" == "is-active" ]] && { echo inactive; exit 3; }
exit 0'
  # br-ex: existe salvo FAKE_NO_BREX=1; o IP fica em $T/brex_addr.
  fake ip '
echo "ip $*" >>"$FAKE_LOG"
brex="'"${T}"'/brex_addr"
case "$*" in
  "link show br-ex") [[ "${FAKE_NO_BREX:-0}" != 1 ]]; exit ;;
  "addr add "*" dev br-ex") [[ -n "${FAKE_IP_ADD_FAIL:-}" ]] && exit 1; echo "$3" >"$brex" ;;
  "addr del "*" dev br-ex") rm -f "$brex" ;;
  "-4 -o addr show br-ex") [[ -s "$brex" ]] && echo "9: br-ex    inet $(cat "$brex") scope global br-ex" ;;
  "-4 -br addr show br-ex") echo "br-ex UNKNOWN $(cat "$brex" 2>/dev/null)" ;;
  "-4 -o addr show "*) [[ "${FAKE_IPV4:-1}" == 1 ]] && echo "2: $5    inet 192.168.1.10/24" ;;
  "-br addr show "*) echo "$4 UP 192.168.1.10/24" ;;
  "-br link show "*) echo "$4 UNKNOWN <BROADCAST,NOARP,UP,LOWER_UP>" ;;
esac
exit 0'
  fake nmcli '
echo "nmcli $*" >>"$FAKE_LOG"
[[ "$*" == "-t -f NAME,DEVICE connection show" ]] && echo "Cabo:enp9s0"
exit 0'
  fake curl 'echo "curl $*" >>"$FAKE_LOG"; echo "    HTTP 200"'
  fake sleep 'exit 0'

  cat >"${T}/venv/bin/kolla-ansible" <<'EOF'
#!/usr/bin/env bash
echo "kolla $*" >>"$FAKE_LOG"
exit "${FAKE_KOLLA_RC:-0}"
EOF
  cat >"${T}/venv/bin/ansible" <<'EOF'
#!/usr/bin/env bash
echo "ansible $*" >>"$FAKE_LOG"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--tree" ]]; then
    mkdir -p "$2"
    echo '{"ansible_facts": {"ansible_hostname": "lab"}}' >"$2/localhost"
  fi
  shift
done
EOF
  cat >"${T}/venv/bin/pip" <<EOF
#!/usr/bin/env bash
echo "pip \$*" >>"\$FAKE_LOG"
touch "${T}/venv/installed_\$2"
EOF
  cat >"${T}/venv/bin/python3" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-c" && "\$2" == *"import docker"* ]]; then
  [[ "\${FAKE_NO_DOCKER:-0}" == 1 && ! -e "${T}/venv/installed_docker" ]] && exit 1
  exit 0
fi
if [[ "\$1" == "-c" && "\$2" == *"import dbus"* ]]; then
  [[ "\${FAKE_NO_DBUS:-0}" == 1 && ! -e "${T}/venv/installed_dbus-python" ]] && exit 1
  exit 0
fi
exec "${REAL_PY}" "\$@"
EOF
  chmod +x "${T}/venv/bin/"*

  export FAKE_LOG="${T}/log"
  export PATH="${T}/bin:${PATH}"
  export TMPDIR="${T}/tmp"
  export VENV_PATH="${T}/venv"
  export KOLLA_BIN="${T}/venv/bin/kolla-ansible"
  export OS_RELEASE="${T}/os-release"
  export AUTO_STOP_HOST_LIBVIRT=false
  echo 1 >"${T}/ip_forward"
  export IP_FORWARD_FILE="${T}/ip_forward"
}

write_globals() {
  printf '%s\n' "$@" >"${T}/project/kolla-config/globals.yml"
}

# run_lab / run_kolla <args>: guardam stdout, stderr e codigo de saida
run_lab() { run_script lab.sh "$@"; }
run_kolla() { run_script run-kolla.sh "$@"; }
run_script() {
  local script="$1"
  shift
  "${REAL_BASH}" "${T}/project/${script}" "$@" >"${T}/out" 2>"${T}/err"
  RC=$?
}

fail() {
  echo "    $*" >&2
  echo "    --- stdout" >&2; sed 's/^/    /' "${T}/out" >&2 2>/dev/null || true
  echo "    --- stderr" >&2; sed 's/^/    /' "${T}/err" >&2 2>/dev/null || true
  echo "    --- log" >&2; sed 's/^/    /' "${T}/log" >&2 2>/dev/null || true
  return 1
}

expect_rc() { [[ "${RC}" -eq "$1" ]] || fail "esperado exit $1, obtido ${RC}"; }

# ---------------------------------------------------------------- S1

test_deploy_ok_fixwired_fail_exits_0() {
  export FAKE_IPV4=0
  run_lab deploy
  expect_rc 0 || return 1
  grep -q '^AVISO: fix-wired nao confirmou IPv4' "${T}/err" || fail "AVISO ausente no stderr"
}

test_kolla_failure_propagates_code() {
  export FAKE_KOLLA_RC=4
  run_lab deploy
  expect_rc 4 || return 1
  ! grep -q '^nmcli' "${T}/log" || fail "fix-wired rodou apos falha do Kolla"
}

test_fixwired_without_ipv4_exits_1() {
  export FAKE_IPV4=0
  run_lab fix-wired
  expect_rc 1
}

test_fixwired_with_ipv4_exits_0() {
  run_lab fix-wired
  expect_rc 0 || return 1
  grep -q '^Cabo OK$' "${T}/out" || fail "'Cabo OK' ausente"
}

test_fixwired_same_ifaces_exits_1() {
  write_globals 'network_interface: "dummy0"' 'neutron_external_interface: "dummy0"'
  run_lab fix-wired
  expect_rc 1
}

test_fixwired_without_nmcli_exits_1() {
  # PATH restrito: comandos falsos (sem nmcli) + so as ferramentas que o lab.sh usa.
  rm -f "${T}/bin/nmcli"
  mkdir -p "${T}/tools"
  local tool
  for tool in env dirname cat grep sed head tr awk mktemp rm ls; do
    ln -s "$(command -v "${tool}")" "${T}/tools/${tool}"
  done
  PATH="${T}/bin:${T}/tools" run_lab fix-wired
  expect_rc 1 || return 1
  grep -q 'nmcli nao encontrado' "${T}/err" || fail "mensagem de nmcli ausente"
}

test_fixwired_empty_br_ex_prints_vazio() {
  export FAKE_DOCKER_NAMES=openvswitch_db FAKE_BR_EX_PORTS=""
  run_lab fix-wired
  expect_rc 0 || return 1
  local n
  n="$(grep -cx '    (vazio)' "${T}/out")"
  [[ "${n}" -eq 2 ]] || fail "esperado 2 linhas '    (vazio)', obtido ${n}"
}

test_runkolla_failure_cleans_facts() {
  echo 'ID=zorin' >"${OS_RELEASE}"
  export FAKE_KOLLA_RC=3
  run_kolla deploy
  expect_rc 3 || return 1
  grep -q '^ansible .*-m setup' "${T}/log" || fail "facts do Zorin nao foram gerados (teste invalido)" || return 1
  local left
  left="$(find "${TMPDIR}" -mindepth 1 | wc -l)"
  [[ "${left}" -eq 0 ]] || fail "sobraram ${left} arquivos em TMPDIR: $(ls -A "${TMPDIR}")"
}

# ---------------------------------------------------------------- S2

test_helpers_defined_once() {
  local fn defs
  for fn in run_as_root docker_cmd; do
    defs="$(grep -lE "^${fn}\(\)" "${PROJECT_DIR}"/*.sh "${PROJECT_DIR}"/lib/*.sh 2>/dev/null)"
    [[ "$(grep -hcE "^${fn}\(\)" "${PROJECT_DIR}"/*.sh "${PROJECT_DIR}"/lib/*.sh 2>/dev/null \
      | awk '{ s += $1 } END { print s + 0 }')" -eq 1 ]] || fail "${fn}: esperado 1 definicao" || return 1
    [[ "${defs}" == "${PROJECT_DIR}/lib/common.sh" ]] || fail "${fn} fora de lib/common.sh: ${defs}" || return 1
  done
  local s
  for s in lab.sh run-kolla.sh; do
    grep -qE '^(source|\.) "\$\{SCRIPT_DIR\}/lib/common\.sh"' "${PROJECT_DIR}/${s}" \
      || fail "${s} nao carrega lib/common.sh" || return 1
  done
}

test_zorin_facts_generated_once() {
  echo 'ID=zorin' >"${OS_RELEASE}"
  export FORCE_UBUNTU_FACTS=true
  run_kolla all
  expect_rc 0 || return 1
  local n
  n="$(grep -c '^ansible .*-m setup' "${T}/log")"
  [[ "${n}" -eq 1 ]] || fail "setup chamado ${n} vezes" || return 1
  local step
  for step in bootstrap-servers prechecks deploy; do
    grep -qE "^kolla ${step} .*-e @" "${T}/log" || fail "${step} sem -e @facts" || return 1
  done
  n="$(grep '^kolla ' "${T}/log" | grep -oE -- '-e @[^ ]+' | sort -u | wc -l)"
  [[ "${n}" -eq 1 ]] || fail "esperado 1 arquivo de facts, obtido ${n}"
}

test_missing_py_modules_installed() {
  export FAKE_NO_DOCKER=1 FAKE_NO_DBUS=1
  run_kolla deploy
  expect_rc 0 || return 1
  local first_kolla pip_docker pip_dbus
  first_kolla="$(grep -n '^kolla ' "${T}/log" | head -1 | cut -d: -f1)"
  pip_docker="$(grep -nx 'pip install docker' "${T}/log" | head -1 | cut -d: -f1)"
  pip_dbus="$(grep -nx 'pip install dbus-python' "${T}/log" | head -1 | cut -d: -f1)"
  [[ -n "${first_kolla}" && -n "${pip_docker}" && -n "${pip_dbus}" ]] || fail "chamadas ausentes" || return 1
  [[ "${pip_docker}" -lt "${first_kolla}" && "${pip_dbus}" -lt "${first_kolla}" ]] \
    || fail "pip install depois do kolla-ansible"
}

test_status_uses_vip_from_globals() {
  write_globals 'network_interface: "enp9s0"' 'neutron_external_interface: "dummy0"' \
    'kolla_internal_vip_address: "10.9.8.7"'
  run_lab status
  expect_rc 0 || return 1
  grep -q '^curl .*http://10\.9\.8\.7/auth/login/' "${T}/log" || fail "curl nao usou o VIP do globals"
}

test_status_vip_fallback() {
  write_globals 'network_interface: "enp9s0"' 'neutron_external_interface: "dummy0"'
  run_lab status
  expect_rc 0 || return 1
  grep -q '^curl .*http://192\.168\.1\.250/auth/login/' "${T}/log" || fail "curl nao usou o VIP padrao"
}

LAB_COMMANDS=(help prep dummy0 fix-ovs fix-wired test-ovs fix-horizon status stop start
  deploy bootstrap prechecks post-deploy all stop-kolla)
KOLLA_ENV_VARS=(VENV_PATH KOLLA_BIN INVENTORY CONFIG_DIR PASSWORDS_FILE EXTRA_VARS
  FORCE_UBUNTU_FACTS USE_TEST_IMAGES AUTO_STOP_HOST_LIBVIRT)

test_commands_and_env_names_kept() {
  [[ "${#LAB_COMMANDS[@]}" -eq 16 && "${#KOLLA_ENV_VARS[@]}" -eq 9 ]] || fail "tabela do teste errada" || return 1
  run_lab help
  local help_out cmd var
  help_out="$(cat "${T}/out")"
  for cmd in "${LAB_COMMANDS[@]}"; do
    grep -qwF -- "${cmd}" <<<"${help_out}" || fail "help nao lista ${cmd}" || return 1
    run_lab "${cmd}"
    ! grep -q 'Comando desconhecido' "${T}/err" || fail "lab.sh nao despacha ${cmd}" || return 1
  done
  for var in "${KOLLA_ENV_VARS[@]}"; do
    grep -qE "^${var}=\"\\\$\\{${var}:-" "${PROJECT_DIR}/run-kolla.sh" || fail "run-kolla.sh nao le ${var}" || return 1
  done
}

test_unknown_command_exits_1() {
  run_lab bogus
  expect_rc 1
}

test_runkolla_invalid_input_exits_1() {
  run_kolla bogus
  expect_rc 1 || return 1
  KOLLA_BIN="${T}/project/all-in-one" run_kolla deploy
  expect_rc 1
}

test_stop_targets_all_containers() {
  export FAKE_CONTAINER_IDS="a1 b2"
  run_lab stop
  expect_rc 0 || return 1
  grep -qx 'docker stop a1 b2' "${T}/log" || fail "docker stop a1 b2 ausente" || return 1
  grep -qx 'docker ps -q' "${T}/log" || fail "docker ps -q sem filtro ausente" || return 1
  ! grep -E '^docker ps -q' "${T}/log" | grep -q -- '--filter' || fail "stop usou --filter"
}

test_syntax_and_unused_vars() {
  local f
  for f in lab.sh run-kolla.sh lib/common.sh; do
    bash -n "${PROJECT_DIR}/${f}" || fail "bash -n falhou em ${f}" || return 1
  done
  local hits
  hits="$(grep -nwE 'REPO_DIR|effective_extra_vars|virtlogd_active_before|docker_import_out|dbus_import_out' \
    "${PROJECT_DIR}/lab.sh" "${PROJECT_DIR}/run-kolla.sh" "${PROJECT_DIR}/lib/common.sh")"
  [[ -z "${hits}" ]] || fail "variaveis sem uso ainda presentes: ${hits}"
}

# ---------------------------------------------------------------- S3

test_docs_cite_common_sh() {
  local doc
  for doc in lab.sh.md run-kolla.sh.md; do
    grep -qF 'lib/common.sh' "${PROJECT_DIR}/docs/${doc}" || fail "${doc} nao cita lib/common.sh" || return 1
    ! grep -qw 'REPO_DIR' "${PROJECT_DIR}/docs/${doc}" || fail "${doc} ainda cita REPO_DIR" || return 1
  done
}

# ---------------------------------------------------------------- Trabalho 1: S1 ext-net

masq_count() { grep -c 'MASQUERADE' "${T}/rules" 2>/dev/null || true; }

test_extnet_adds_ip_and_nat() {
  run_lab ext-net
  expect_rc 0 || return 1
  [[ "$(cat "${T}/brex_addr" 2>/dev/null)" == "172.24.4.1/24" ]] || fail "br-ex sem 172.24.4.1/24" || return 1
  grep -qx 'nat POSTROUTING -s 172.24.4.0/24 ! -d 172.24.4.0/24 -o enp9s0 -m comment --comment lab-ext-net -j MASQUERADE' \
    "${T}/rules" || fail "regra MASQUERADE ausente" || return 1
  grep -q '^filter DOCKER-USER -i br-ex -o enp9s0 ' "${T}/rules" || fail "FORWARD br-ex -> enp9s0 ausente"
}

test_extnet_idempotent() {
  run_lab ext-net && run_lab ext-net
  expect_rc 0 || return 1
  [[ "$(masq_count)" -eq 1 ]] || fail "MASQUERADE $(masq_count) vezes" || return 1
  local adds
  adds="$(grep -c '^ip addr add 172.24.4.1/24 dev br-ex' "${T}/log")"
  [[ "${adds}" -eq 1 ]] || fail "ip addr add ${adds} vezes"
}

test_extnet_down_removes() {
  run_lab ext-net
  run_lab ext-net --down
  expect_rc 0 || return 1
  [[ ! -s "${T}/brex_addr" ]] || fail "IP continua na br-ex" || return 1
  ! grep -q 'lab-ext-net' "${T}/rules" || fail "sobraram regras: $(cat "${T}/rules")"
}

test_extnet_forward_fallback() {
  # Host real: Docker com "iptables": false -> sem DOCKER-USER; o UFW deixa o FORWARD em DROP.
  export FAKE_DOCKER_USER=0
  run_lab ext-net
  expect_rc 0 || return 1
  grep -q '^filter FORWARD -i br-ex -o enp9s0 ' "${T}/rules" || fail "regra nao foi para o FORWARD" || return 1
  ! grep -q 'DOCKER-USER' "${T}/rules" || fail "usou DOCKER-USER inexistente"
}

test_extnet_down_after_iface_change() {
  run_lab ext-net
  write_globals 'network_interface: "eth9"' 'neutron_external_interface: "dummy0"'
  run_lab ext-net --down
  expect_rc 0 || return 1
  ! grep -q 'lab-ext-net' "${T}/rules" || fail "sobraram regras da interface antiga: $(cat "${T}/rules")"
}

test_start_reports_extnet_failure() {
  export FAKE_CONTAINER_IDS="k1"
  local inject
  for inject in FAKE_IPTABLES_FAIL FAKE_IP_ADD_FAIL; do
    rm -f "${T}/rules" "${T}/brex_addr"
    env "${inject}=1" "${REAL_BASH}" "${T}/project/lab.sh" start >"${T}/out" 2>"${T}/err"
    grep -q '^AVISO: ext-net falhou' "${T}/err" || fail "${inject}: falha do ext-net ficou silenciosa" || return 1
    ! grep -q '^ext-net OK' "${T}/out" || fail "${inject}: imprimiu ext-net OK apesar da falha" || return 1
  done
}

test_extnet_down_reports_iptables_failure() {
  run_lab ext-net
  FAKE_IPTABLES_S_FAIL=1 run_lab ext-net --down
  expect_rc 1 || return 1
  ! grep -q '^ext-net removido' "${T}/out" || fail "disse removido sem conseguir listar as regras"
}

test_extnet_ip_forward_untouched() {
  # 1 -> nao chama sysctl; 0 -> sysctl -w =1; --down nunca chama sysctl (o Docker depende dele).
  run_lab ext-net
  ! grep -q '^sysctl' "${T}/log" || fail "chamou sysctl com ip_forward=1" || return 1
  echo 0 >"${IP_FORWARD_FILE}"
  run_lab ext-net
  grep -qx 'sysctl -w net.ipv4.ip_forward=1' "${T}/log" || fail "nao ligou ip_forward" || return 1
  : >"${T}/log"
  run_lab ext-net --down
  ! grep -q '^sysctl' "${T}/log" || fail "--down mexeu no ip_forward"
}

test_extnet_without_brex_fails() {
  export FAKE_NO_BREX=1 EXT_NET_WAIT=1
  run_lab ext-net
  expect_rc 1
}

test_start_applies_extnet() {
  export FAKE_CONTAINER_IDS="k1"
  run_lab start
  expect_rc 0 || return 1
  grep -q '^ip addr add 172.24.4.1/24 dev br-ex' "${T}/log" || fail "start nao aplicou ext-net"
}

test_dnshost_split_dns() {
  run_lab dns-host 172.24.4.150
  expect_rc 0 || return 1
  grep -qx 'resolvectl dns br-ex 172.24.4.150' "${T}/log" || fail "dns nao configurado" || return 1
  grep -qx 'resolvectl domain br-ex ~larcerto.com.br' "${T}/log" || fail "dominio de roteamento ausente" || return 1
  ! grep -E '^resolvectl (dns|domain) ' "${T}/log" | grep -vq 'br-ex' || fail "mexeu em outra interface" || return 1
  run_lab dns-host --down
  grep -qx 'resolvectl revert br-ex' "${T}/log" || fail "--down nao reverteu"
}

# ---------------------------------------------------------------- Trabalho 1: arquivos

test_bootstrap_is_guarded() {
  local f="${PROJECT_DIR}/cloud/bootstrap.sh"
  bash -n "${f}" || fail "bash -n falhou" || return 1
  # Todo "os <recurso> create" fica dentro de um "if ! exists <recurso> ...".
  local creates guarded kind
  creates="$(grep -cE '^\s*os (network|subnet|flavor|image|project|group|user) create' "${f}")"
  guarded=0
  for kind in network subnet flavor image project group user; do
    if grep -qE "^\s*os ${kind} create" "${f}"; then
      grep -B8 -E "^\s*os ${kind} create" "${f}" | grep -qE "if ! exists ${kind} " && guarded=$((guarded + 1))
    fi
  done
  [[ "${creates}" -ge 7 && "${guarded}" -eq "${creates}" ]] || fail "creates=${creates} protegidos=${guarded}"
}

test_terraform_declares_topology() {
  local tf="${PROJECT_DIR}/terraform"
  local vm
  for vm in dns ca db web; do
    grep -qE "^\s*${vm}\s*=\s*\{ ip = \"10\.11\.12\.[0-9]+\"" "${tf}/variables.tf" || fail "VM ${vm} ausente" || return 1
  done
  grep -q 'resource "openstack_compute_instance_v2" "vm"' "${tf}/main.tf" || fail "instancias ausentes" || return 1
  grep -A2 'resource "openstack_networking_floatingip_v2" "fip"' "${tf}/main.tf" | grep -q 'for_each = var.vms' \
    || fail "floating IP nao e por VM" || return 1
  grep -qE 'db = \[\{ proto = "tcp", port = 3306, cidr = var.subnet_cidr \}\]' "${tf}/main.tf" \
    || fail "SG db nao restringe 3306 a subnet"
}

test_dns_zone_records() {
  local z="${PROJECT_DIR}/ansible/roles/dns/templates/db.zone.j2"
  local name
  for name in @ www web dns ca db cloud; do
    grep -qE "^${name}\s+IN\s+A\s" "${z}" || fail "registro ${name} ausente" || return 1
  done
  grep -qE '^cloud\s+IN\s+A\s+\{\{ cloud_vip \}\}' "${z}" || fail "cloud nao usa o VIP" || return 1
  grep -qE '^db\s+IN\s+A\s+\{\{ private_ips.db \}\}' "${z}" || fail "db nao usa IP privado" || return 1
  grep -q '^cloud_vip: 192.168.1.250$' "${PROJECT_DIR}/ansible/group_vars/all/main.yml" || fail "VIP errado"
}

test_ca_role_restores_pki() {
  local r="${PROJECT_DIR}/ansible/roles/ca/tasks/main.yml"
  grep -q 'path: "{{ pki_local_dir }}/ca.key"' "${r}" || fail "nao procura a CA salva" || return 1
  # Bloco de restauracao: entre "Restaurar a PKI salva" e "Criar CA nova".
  local restore create
  restore="$(sed -n '/name: Restaurar a PKI salva/,/name: Criar CA nova/p' "${r}")"
  create="$(sed -n '/name: Criar CA nova/,/name: Certificado wildcard/p' "${r}")"
  grep -q 'when: local_ca.stat.exists' <<<"${restore}" || fail "restauracao nao depende da copia" || return 1
  grep -q 'src: "{{ pki_local_dir }}/{{ item | basename }}"' <<<"${restore}" || fail "restauracao nao copia a PKI salva" || return 1
  grep -q 'loop: "{{ pki_files }}"' <<<"${restore}" || fail "restauracao nao cobre ca.crt/ca.key" || return 1
  grep -q 'when: not local_ca.stat.exists' <<<"${create}" || fail "build-ca roda mesmo com copia salva" || return 1
  grep -q 'build-ca' <<<"${create}" || fail "build-ca fora do bloco de criacao" || return 1
  grep -q 'ansible.builtin.fetch' "${r}" || fail "nao salva a PKI no host" || return 1
  local member
  for member in '"ca.crt"' '"private/ca.key"' '"issued/{{ cert_name }}.crt"' '"private/{{ cert_name }}.key"'; do
    grep -E '^\s*pki_files:' "${r}" | grep -qF -- "${member}" || fail "pki_files sem ${member}" || return 1
  done
}

test_crud_pending_documented() {
  grep -qiE 'CRUD.*pendente|pendente.*CRUD' "${PROJECT_DIR}/../TASKS.md" || fail "TASKS.md nao marca o CRUD pendente" || return 1
  grep -q 'CREATE TABLE imoveis' "${PROJECT_DIR}/app/README.md" || fail "app/README.md sem o esquema" || return 1
  [[ ! -e "${PROJECT_DIR}/app/public/index.php" ]] || fail "app ja existe: este check deve ser trocado pelos criterios da S5"
}

test_no_secrets_tracked() {
  # Escopo do criterio 30: segredos desta feature (devops1, BD, PKI, tfstate), nao os do Kolla.
  local repo="${PROJECT_DIR}/.."
  local hits
  hits="$(git -C "${repo}" ls-files --cached --others --exclude-standard \
    'project/cloud/secrets/*' 'project/ansible/group_vars/all/secrets.yml' 'project/ansible/files/pki/*.key' \
    'project/ansible/files/pki/*.crt' 'project/terraform/*.tfstate*' 'project/ansible/inventory/hosts.ini')"
  [[ -z "${hits}" ]] || fail "segredos visiveis para o git: ${hits}" || return 1
  # Conteudo: nenhum arquivo que o git veria nas pastas da feature tem chave ou senha literal.
  local f
  while read -r f; do
    [[ -f "${repo}/${f}" ]] || continue
    if grep -qiE 'BEGIN [A-Z ]*PRIVATE KEY|password:\s*[^ {$]|db_password:\s*[^ {]|OS_PASSWORD=[^$ ]|token:\s*[^ {$]|\$[a-z_]*(pass|senha|token)[a-z_]*\s*=\s*["'\''][^"'\'']+' "${repo}/${f}" \
      && [[ "${f}" != *.example ]]; then
      fail "segredo literal em ${f}" || return 1
    fi
  done < <(git -C "${repo}" ls-files --cached --others --exclude-standard \
    project/cloud project/terraform project/ansible project/app)
  ! grep -rqE 'password\s*=\s*"[^"]+"' "${PROJECT_DIR}/terraform" || fail "senha no Terraform"
}

test_extnet_dnshost_dispatched() {
  run_lab help
  grep -qw 'ext-net' "${T}/out" && grep -qw 'dns-host' "${T}/out" || fail "help sem ext-net/dns-host" || return 1
  run_lab ext-net --bogus
  expect_rc 1 || return 1
  ! grep -q 'Comando desconhecido' "${T}/err" || fail "ext-net nao despachado" || return 1
  run_lab dns-host --down
  ! grep -q 'Comando desconhecido' "${T}/err" || fail "dns-host nao despachado"
}

test_video_script_timing() {
  local f="${PROJECT_DIR}/docs/roteiro-video.md"
  [[ -f "${f}" ]] || fail "roteiro ausente" || return 1
  grep -qi 'DevOps' "${f}" && grep -qi 'cliente' "${f}" || fail "faltam cenas DevOps/cliente" || return 1
  # Soma a coluna "Duracao (s)" da tabela de cenas.
  local total
  total="$(awk -F'|' '/^\| *[0-9]+ *\|/ { gsub(/ /, "", $4); s += $4 } END { print s + 0 }' "${f}")"
  [[ "${total}" -ge 300 && "${total}" -le 420 ]] || fail "roteiro soma ${total}s (esperado 300-420)"
}

# ---------------------------------------------------------------- runner

ALL_TESTS=()
while read -r name; do
  ALL_TESTS+=("${name#test_}")
done < <(declare -F | awk '{ print $3 }' | grep '^test_')

selected=("$@")
[[ "${#selected[@]}" -eq 0 ]] && selected=("${ALL_TESTS[@]}")

failed=0
for name in "${selected[@]}"; do
  if ! declare -F "test_${name}" >/dev/null; then
    echo "Teste desconhecido: ${name}" >&2
    exit 2
  fi
  if (setup_sandbox && "test_${name}"; rc=$?; rm -rf "${T}"; exit "${rc}"); then
    echo "PASS ${name}"
  else
    echo "FAIL ${name}"
    failed=1
  fi
done
exit "${failed}"
