#!/usr/bin/env bash
# Testes de lab.sh e dos modulos de scripts/ sem tocar no host.
# Copia os scripts para um diretorio temporario e coloca comandos falsos
# (docker, sudo, systemctl, ip, nmcli, curl, sleep, kolla-ansible, ansible,
# pip, python3 do venv) na frente do PATH. O sudo falso so executa `env ...`
# (a chamada do kolla-ansible); qualquer outro comando de root e so registrado.
#
# Uso: bash tests/test-scripts.sh [teste ...]   (sem argumento: todos)
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_PY="$(command -v python3)"
REAL_BASH="${BASH}"
# Python com Playwright dos testes de navegador: .venv do proprio repo (outro: PW_PYTHON=/caminho/python).
PW_PYTHON="${PW_PYTHON:-${PROJECT_DIR}/.venv/bin/python}"
# Os testes da app usam o docker, o php e o curl de verdade (so leitura); o sandbox troca docker e curl por falsos.
REAL_DOCKER="$(command -v docker || true)"
REAL_PHP="$(command -v php || true)"
REAL_CURL="$(command -v curl)"
REAL_OPENSSL="$(command -v openssl)"

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
  cp "${PROJECT_DIR}/lab.sh" "${T}/project/"
  cp -r "${PROJECT_DIR}/scripts" "${T}/project/scripts"
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
  start) [[ "${FAKE_FAIL:-}" == start ]] && exit 7; [[ -n "${FAKE_SLOW_START:-}" ]] && /bin/sleep "${FAKE_SLOW_START}"; exit 0 ;;
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
# libvirt do host: ativo com FAKE_LIBVIRT_ACTIVE=1 ate um stop (que nao pega com FAKE_LIBVIRT_STUCK=1)
if [[ "$1" == "stop" && "$*" == *virt* && "${FAKE_LIBVIRT_STUCK:-0}" != 1 ]]; then
  touch "'"${T}"'/libvirt_stopped"
fi
if [[ "$1" == "is-active" ]]; then
  [[ "${FAKE_LIBVIRT_ACTIVE:-0}" == 1 && "$2" == *virt* && ! -e "'"${T}"'/libvirt_stopped" ]] && { echo active; exit 0; }
  echo inactive; exit 3
fi
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
  fake curl 'echo "curl $*" >>"$FAKE_LOG"
# API no VIP (:5000): FAKE_VIP_FAILS=n falha as n primeiras; FAKE_VIP_DOWN=1 falha sempre
if [[ "$*" == *":5000/"* ]]; then
  n=$(( $(cat "'"${T}"'/curl5000" 2>/dev/null || echo 0) + 1 )); echo "$n" >"'"${T}"'/curl5000"
  [[ "${FAKE_VIP_DOWN:-0}" == 1 || "$n" -le "${FAKE_VIP_FAILS:-0}" ]] && exit 7
  exit 0
fi
echo "    HTTP 200"'
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
run_kolla() { run_script lab.sh "$@"; }
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

test_kolla_missing_passwords_hint() {
  rm -f "${T}/project/kolla-config/passwords.yml"
  run_lab deploy
  expect_rc 1 || return 1
  grep -qF 'kolla-genpwd -p' "${T}/err" || fail "sem o comando que gera o passwords.yml" || return 1
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
  local fn defs files
  files="$(find "${PROJECT_DIR}/lab.sh" "${PROJECT_DIR}/scripts" -name '*.sh')"
  for fn in run_as_root docker_cmd; do
    defs="$(grep -lE "^${fn}\(\)" ${files})"
    [[ "$(grep -hcE "^${fn}\(\)" ${files} | awk '{ s += $1 } END { print s + 0 }')" -eq 1 ]] \
      || fail "${fn}: esperado 1 definicao" || return 1
    [[ "${defs}" == "${PROJECT_DIR}/scripts/common.sh" ]] || fail "${fn} fora de scripts/common.sh: ${defs}" || return 1
  done
  grep -qE '^# shellcheck source=scripts/common.sh' "${PROJECT_DIR}/lab.sh" \
    && grep -qE '^source "\$\{SCRIPT_DIR\}/scripts/common\.sh"' "${PROJECT_DIR}/lab.sh" \
    || fail "lab.sh nao carrega scripts/common.sh" || return 1
}

test_zorin_facts_generated_once() {
  echo 'ID=zorin' >"${OS_RELEASE}"
  export FORCE_UBUNTU_FACTS=true
  run_kolla deploy
  expect_rc 0 || return 1
  local n
  n="$(grep -c '^ansible .*-m setup' "${T}/log")"
  [[ "${n}" -eq 1 ]] || fail "setup chamado ${n} vezes" || return 1
  grep -qE "^kolla deploy .*-e @" "${T}/log" || fail "deploy sem -e @facts" || return 1
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
    grep -qE "^${var}=\"\\\$\\{${var}:-" "${PROJECT_DIR}/scripts/kolla/kolla.sh" || fail "kolla.sh nao le ${var}" || return 1
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

test_stopkolla_args() {
  run_lab stop-kolla
  expect_rc 0 || return 1
  grep -qE "^kolla stop -i .*/all-in-one --configdir .*/kolla-config --passwords .*/passwords\.yml$" "${T}/log" \
    || fail "stop-kolla nao chamou kolla-ansible stop com inventario, configdir e passwords" || return 1
}

test_nonkolla_no_kolla_calls() {
  run_lab status
  ! grep -qE '^(kolla|ansible|pip) ' "${T}/log" || fail "status chamou kolla/ansible/pip" || return 1
}

test_syntax_and_unused_vars() {
  local f
  for f in lab.sh $(cd "${PROJECT_DIR}" && find scripts -name '*.sh'); do
    bash -n "${PROJECT_DIR}/${f}" || fail "bash -n falhou em ${f}" || return 1
  done
  local hits
  hits="$(grep -nwE 'REPO_DIR|effective_extra_vars|virtlogd_active_before|docker_import_out|dbus_import_out' \
    "${PROJECT_DIR}/lab.sh" $(find "${PROJECT_DIR}/scripts" -name '*.sh'))"
  [[ -z "${hits}" ]] || fail "variaveis sem uso ainda presentes: ${hits}"
}

# ---------------------------------------------------------------- S3

test_docs_cite_common_sh() {
  local doc
  for doc in lab.sh.md; do
    grep -qF 'scripts/common.sh' "${PROJECT_DIR}/docs/${doc}" || fail "${doc} nao cita scripts/common.sh" || return 1
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

# Sandbox do cloud/bootstrap.sh real com um cliente openstack falso.
# FAKE_API_DOWN=N: as N primeiras chamadas de "network list" falham (VIP fora do ar).
# FAKE_NET_SHOW_FAIL=1: "network show" falha; FAKE_NET_CREATE=in-use|other: erro no create.
bootstrap_sandbox() {
  mkdir -p "${T}/project/cloud/secrets" "${T}/cache" "${T}/state"
  cp "${PROJECT_DIR}/cloud/bootstrap.sh" "${T}/project/cloud/bootstrap.sh"
  : >"${T}/admin-clouds.yaml"
  echo 'senha-falsa' >"${T}/project/cloud/secrets/devops1.password"
  rm -f "${T}/state/api" "${T}/project/cloud/secrets/clouds.yaml"
  : >"${T}/log"
  cat >"${T}/bin/openstack-fake" <<'EOF'
#!/usr/bin/env bash
echo "openstack $*" >>"$FAKE_LOG"
case "$1 $2" in
  "network list")
    n=$(( $(cat "${FAKE_STATE}/api" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"${FAKE_STATE}/api"
    [[ "$n" -le "${FAKE_API_DOWN:-0}" ]] && { echo "Unable to establish connection" >&2; exit 1; }
    ;;
  "network show") [[ "${FAKE_NET_SHOW_FAIL:-0}" == 1 ]] && exit 1 ;;
  "network create")
    case "${FAKE_NET_CREATE:-}" in
      in-use) echo "ConflictException: 409: Client Error, Unable to create the flat network. Physical network physnet1 is in use." >&2; exit 1 ;;
      other) echo "BadRequestException: 400: outro erro" >&2; exit 1 ;;
    esac
    ;;
  "endpoint list") echo "http://192.168.1.250:5000" ;;
  "image show") echo active ;;
esac
exit 0
EOF
  chmod +x "${T}/bin/openstack-fake"
  unset FAKE_API_DOWN FAKE_NET_SHOW_FAIL FAKE_NET_CREATE API_WAIT_TRIES
  export OPENSTACK="${T}/bin/openstack-fake" OS_CLIENT_CONFIG_FILE="${T}/admin-clouds.yaml" OS_CLOUD=kolla-admin \
    SECRETS_DIR="${T}/project/cloud/secrets" IMAGE_CACHE="${T}/cache" FAKE_STATE="${T}/state"
}

run_bootstrap() {
  "${REAL_BASH}" "${T}/project/cloud/bootstrap.sh" >"${T}/out" 2>"${T}/err"
  RC=$?
}

test_bootstrap_waits_for_api() {
  bootstrap_sandbox
  export FAKE_API_DOWN=3
  run_bootstrap
  expect_rc 0 || return 1
  [[ "$(grep -c '^openstack network list' "${T}/log")" -eq 4 ]] || fail "esperado 4 tentativas de network list" || return 1
  # A primeira checagem de recurso so vem depois de a API responder.
  local first_show last_list
  first_show="$(grep -n '^openstack network show' "${T}/log" | head -1 | cut -d: -f1)"
  last_list="$(grep -n '^openstack network list' "${T}/log" | tail -1 | cut -d: -f1)"
  [[ -n "${first_show}" && "${first_show}" -gt "${last_list}" ]] || fail "show antes da API responder" || return 1
  # API que nunca responde: para com exit 1 e nao cria nada.
  bootstrap_sandbox
  export FAKE_API_DOWN=999 API_WAIT_TRIES=3
  run_bootstrap
  expect_rc 1 || return 1
  grep -q 'nao respondeu' "${T}/err" || fail "sem mensagem da API fora do ar" || return 1
  ! grep -q '^openstack [a-z]* create' "${T}/log" || fail "criou recurso sem a API responder" || return 1
}

test_bootstrap_skips_physnet_in_use() {
  bootstrap_sandbox
  export FAKE_NET_SHOW_FAIL=1 FAKE_NET_CREATE=in-use
  run_bootstrap
  expect_rc 0 || return 1
  grep -q 'pulando a criacao' "${T}/out" || fail "sem aviso de que pulou a rede" || return 1
  local c
  for c in 'subnet show' 'flavor show' 'image show' 'project show' 'quota set'; do
    grep -q "^openstack ${c}" "${T}/log" || fail "nao seguiu para: ${c}" || return 1
  done
  [[ -s "${T}/project/cloud/secrets/clouds.yaml" ]] || fail "clouds.yaml nao gravado" || return 1
  # Outro erro no create continua parando, com a mensagem visivel.
  bootstrap_sandbox
  export FAKE_NET_SHOW_FAIL=1 FAKE_NET_CREATE=other
  run_bootstrap
  [[ "${RC}" -ne 0 ]] || fail "erro diferente de 'in use' nao parou" || return 1
  grep -q 'outro erro' "${T}/err" || fail "erro do create escondido" || return 1
  ! grep -q '^openstack subnet show' "${T}/log" || fail "seguiu depois de um erro real" || return 1
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

test_dns_coringa() {
  local z="${PROJECT_DIR}/ansible/roles/dns/templates/db.zone.j2" c="${PROJECT_DIR}/tests/cloud-checks.sh"
  grep -qE "^\*\s+IN\s+A\s+\{\{ hostvars\[groups\['web'\]\[0\]\]\.ansible_host \}\}$" "${z}" || fail "zona sem o coringa para a web" || return 1
  grep -qE '^horizon\s+IN\s+CNAME\s+cloud\.\{\{ domain \}\}\.$' "${z}" || fail "zona sem horizon CNAME cloud" || return 1
  grep -qE '^ALL=\(.*\bdns_coringa\b.*\bdns_horizon\b' "${c}" && grep -q '^check_dns_coringa()' "${c}" && grep -q '^check_dns_horizon()' "${c}" \
    || fail "cloud-checks sem dns_coringa/dns_horizon" || return 1
  grep -qF 'qualquer.larcerto.com.br' "${PROJECT_DIR}/docs/nuvem-larcerto.md" && grep -qF 'horizon.larcerto.com.br' "${PROJECT_DIR}/docs/nuvem-larcerto.md" \
    || fail "guia sem o coringa e o horizon"
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

# ---------------------------------------------------------------- app (CRUD e MVC)

APP="${PROJECT_DIR}/app"

app_php_files() { find "${APP}" -name '*.php' -not -path '*/vendor/*'; }

# colunas "nome TIPO..." entre CREATE TABLE e ") ENGINE", sem espacos repetidos
table_columns() {
  sed -n '/CREATE TABLE/,/) ENGINE/p' "$1" | grep -E '^\s+[a-z_]+\s' | sed -E 's/^\s+//; s/\s+/ /g; s/,$//'
}

# Harness da app no PHP do host, sem MariaDB nem GD: copia backend/, frontend/views/ e public/ para
# $T/w, troca o PDO por LogPDO (registra todo SQL em $T/sql.log) sobre um SQLite, troca o
# ProcessadorImagem (GD) por um falso que grava os .webp com "LxA" da foto recebida e registra o que
# chegou em $T/fotos.log, e sobe o php -S com os limites de php/larcerto.ini e um roteador que imita
# apache/larcerto.conf. O ValidadorImagem, o FotosImovel e o resto da app sao os de verdade.
app_harness() {
  [[ -n "${REAL_PHP}" ]] && "${REAL_PHP}" -m | grep -x pdo_sqlite >/dev/null || fail "php do host sem pdo_sqlite" || return 1
  local w="${T}/w"
  mkdir -p "${w}/frontend" "${w}/storage/uploads" "${T}/sess"
  cp -r "${APP}/backend" "${APP}/public" "${w}/"
  cp -r "${APP}/frontend/views" "${w}/frontend/views"
  sed -i 's/new \\PDO(/new \\LogPDO(/' "${w}/backend/Core/Database.php"
  grep -q 'new \\LogPDO(' "${w}/backend/Core/Database.php" || fail "Database.php nao cria o PDO" || return 1
  printf "<?php\nreturn ['dsn' => 'sqlite:%s/db.sqlite', 'user' => null, 'password' => null];\n" "${T}" >"${w}/config.php"
  cat >"${w}/backend/Services/ProcessadorImagem.php" <<'PHP'
<?php
declare(strict_types=1);

namespace LarCerto\Services;

final class ProcessadorImagem
{
    public function processar(string $tmp, string $destino): void
    {
        $conteudo = file_get_contents($tmp);
        if (str_contains($conteudo, 'QUEBRA')) {
            throw new \RuntimeException('Não foi possível ler a foto.');
        }
        [$l, $a] = getimagesize($tmp);
        file_put_contents(getenv('FOTOS_LOG'), json_encode(['l' => $l, 'a' => $a, 'bytes' => strlen($conteudo),
            'mime' => mime_content_type($tmp)]) . "\n", FILE_APPEND);
        file_put_contents($destino . '.webp', "{$l}x{$a}");
        file_put_contents($destino . '_thumb.webp', "{$l}x{$a}");
    }
}
PHP
  cat >"${T}/prepend.php" <<'PHP'
<?php
class LogPDO extends PDO
{
    public function __construct(string $dsn, ?string $user = null, ?string $pass = null, array $opt = [])
    {
        unset($opt[PDO::ATTR_EMULATE_PREPARES]);   // o SQLite nao aceita
        parent::__construct($dsn, $user, $pass, $opt);
    }
    private static function log(string $sql): void
    {
        file_put_contents(getenv('LOG'), json_encode($sql) . "\n", FILE_APPEND);
    }
    public function prepare(string $query, array $options = []): PDOStatement|false
    {
        self::log($query);
        return parent::prepare($query, $options);
    }
    public function query(string $query, ?int $fetchMode = null, mixed ...$args): PDOStatement|false
    {
        self::log($query);
        return $fetchMode === null ? parent::query($query) : parent::query($query, $fetchMode, ...$args);
    }
    public function exec(string $statement): int|false
    {
        self::log($statement);
        return parent::exec($statement);
    }
}
PHP
  cat >"${T}/router.php" <<'PHP'
<?php
// Imita apache/larcerto.conf: arquivo de public/ sai como esta, /uploads so serve os .webp da app,
// o resto vai para o front controller. (auto_prepend_file nao vale para o roteador do php -S.)
require __DIR__ . '/prepend.php';
$w = getenv('W');
$p = rawurldecode((string) parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH));
if (str_starts_with($p, '/uploads/')) {
    $f = $w . '/storage/uploads/' . substr($p, 9);
    if (preg_match('#^/uploads/\d+/[0-9a-f]{32}(_thumb)?\.webp$#', $p) !== 1) {
        http_response_code(403);
    } elseif (is_file($f)) {
        header('Content-Type: image/webp');
        readfile($f);
    } else {
        http_response_code(404);
    }
    return true;
}
if ($p !== '/' && is_file($w . '/public' . $p)) {
    return false;
}
require $w . '/public/index.php';
PHP
  "${REAL_PHP}" -r '
    $db = new PDO("sqlite:" . $argv[1] . "/db.sqlite");
    $db->exec("CREATE TABLE imoveis (id INTEGER PRIMARY KEY AUTOINCREMENT, titulo TEXT, tipo TEXT, preco REAL,
      bairro TEXT, campus TEXT, verificado INTEGER, anunciante_nome TEXT, anunciante_tipo TEXT, capa TEXT)");
    $db->exec("INSERT INTO imoveis (titulo, tipo, preco, bairro, campus, verificado, anunciante_nome, anunciante_tipo) VALUES
      (\"Kitnet Centro\", \"kitnet\", 780, \"Centro\", \"UTFPR\", 1, \"Maria\", \"locador\"),
      (\"Ap Batel\", \"apartamento\", 950, \"Batel\", \"Unicentro\", 0, \"Imob\", \"imobiliaria\"),
      (\"<script>alert(1)</script>\", \"republica\", 600, \"<b>Vila</b>\", \"Qualquer campus\", 1, \"<i>x</i>\", \"locador\")");
  ' "${T}" || fail "nao criou o SQLite" || return 1
  # Limites e erros de php/larcerto.ini (os mesmos do Compose e da VM).
  local ini=() linha
  while read -r linha; do
    ini+=(-d "${linha// /}")
  done < <(grep -E '^[a-z_]+ = ' "${APP}/php/larcerto.ini")
  local port
  port="$("${REAL_PY}" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  BASE="http://127.0.0.1:${port}"
  W="${w}" LOG="${T}/sql.log" FOTOS_LOG="${T}/fotos.log" "${REAL_PHP}" "${ini[@]}" \
    -d session.save_path="${T}/sess" -d error_log="${T}/php.err" \
    -S "127.0.0.1:${port}" -t "${w}/public" "${T}/router.php" >"${T}/server.out" 2>&1 &
  echo $! >"${T}/server.pid"
  "${REAL_PY}" - "${port}" <<'PY' || fail "php -S nao subiu: $(cat "${T}/server.out")"
import socket, sys, time
for _ in range(100):
    try:
        socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2).close()
        sys.exit(0)
    except OSError:
        time.sleep(0.05)
sys.exit(1)
PY
}

# app_req <metodo> <caminho> [args do curl]: codigo HTTP em $T/code, corpo em $T/page.html, cabecalhos em $T/hdr
app_req() {
  local metodo="$1" caminho="$2"
  shift 2
  "${REAL_CURL}" -sS -o "${T}/page.html" -D "${T}/hdr" -w '%{http_code}' -b "${T}/jar" -c "${T}/jar" \
    -X "${metodo}" "$@" "${BASE}${caminho}" >"${T}/code"
}

# a pagina renderizada tem o logo e o nome LarCerto (REQ02), inclusive as de erro
tem_layout() {
  grep -q 'src="/assets/logo.svg"' "${T}/page.html" && grep -q 'Lar<span>Certo</span>' "${T}/page.html" \
    || fail "$1 sem logo/nome LarCerto"
}

code_is() { [[ "$(cat "${T}/code")" == "$1" ]] || fail "$2: HTTP $(cat "${T}/code"), esperado $1 $(head -c 300 "${T}/page.html")"; }

# token CSRF da sessao do cookie jar (le do formulario de anunciar)
app_token() {
  app_req GET /imoveis/novo
  grep -oP -m1 'name="csrf" value="\K[0-9a-f]+' "${T}/page.html"
}

# app_campos [titulo]: campos validos de um imovel, em multipart (como o formulario)
app_campos() {
  printf '%s\n' --form-string "titulo=${1:-Kitnet teste}" --form-string tipo=kitnet --form-string preco=750 \
    --form-string bairro=Centro --form-string campus=UTFPR --form-string anunciante_nome=Ana \
    --form-string anunciante_tipo=locador --form-string verificado=1
}

app_sql() {
  "${REAL_PHP}" -r '$d = new PDO("sqlite:" . $argv[1] . "/db.sqlite"); foreach ($d->query($argv[2])->fetchAll(PDO::FETCH_NUM) as $r) { echo implode("|", $r), "\n"; }' "${T}" "$1"
}

# app_png <arquivo> <largura> <altura> [texto]: PNG valido; acima de 1 MP so o cabecalho e real
# (basta para finfo e getimagesize); [texto] vai num chunk tEXt.
app_png() {
  "${REAL_PHP}" -r '
    [, $f, $l, $a] = $argv; $txt = $argv[4] ?? "";
    $chunk = fn ($t, $d) => pack("N", strlen($d)) . $t . $d . pack("N", crc32($t . $d));
    $raw = ($l * $a <= 1000000) ? str_repeat("\0" . str_repeat("\x40\x80\xc0", (int) $l), (int) $a) : "x";
    $png = "\x89PNG\r\n\x1a\n" . $chunk("IHDR", pack("NNCCCCC", $l, $a, 8, 2, 0, 0, 0))
      . ($txt !== "" ? $chunk("tEXt", "Comment\0" . $txt) : "") . $chunk("IDAT", gzcompress($raw)) . $chunk("IEND", "");
    file_put_contents($f, $png);
  ' "$@"
}

# arquivos de foto no disco (fora .tmp-*) e pastas temporarias que sobraram
fotos_no_disco() { find "${T}/w/storage/uploads" -type f -name '*.webp' -not -path '*/.tmp-*' | sort; }
tmp_sobrando() { find "${T}/w/storage/uploads" -maxdepth 1 -name '.tmp-*' | grep -q .; }

# nenhum SQL registrado contem o marcador de injecao nem valor literal comparado
sql_clean() {
  [[ -s "${T}/sql.log" ]] || { fail "nenhum SQL registrado"; return 1; }
  ! grep -qE 'INJ|1=1' "${T}/sql.log" || fail "entrada do usuario no texto SQL: $(cat "${T}/sql.log")" || return 1
  # valor comparado tem que ser placeholder: "id = 3" ou "tipo = 'kitnet'" no texto SQL e concatenacao,
  # mesmo de valor ja validado (a unica string fixa permitida e a regra de 'Qualquer campus')
  ! grep -qE '[=<>] *-?[0-9]' "${T}/sql.log" || fail "valor literal no SQL: $(cat "${T}/sql.log")" || return 1
  ! grep -qP "[=<>] *'(?!Qualquer campus')" "${T}/sql.log" || fail "string literal no SQL: $(cat "${T}/sql.log")"
}

test_mvc_structure() {
  local html
  html="$(grep -rnE '<(!doctype|html|head|body|div|p|a|form|span|h[1-6]|ul|li|img|input|select|section|main|label)[ >]|\?>' "${APP}/backend")"
  [[ -z "${html}" ]] || fail "HTML no backend: ${html}" || return 1
  local views
  views="$(grep -rnE 'SELECT |INSERT INTO|DELETE FROM|UPDATE [a-z_]+ SET|\$_(GET|POST|FILES|SESSION|SERVER|REQUEST|COOKIE)\b' "${APP}/frontend/views")"
  [[ -z "${views}" ]] || fail "SQL ou superglobal nas views: ${views}" || return 1
  [[ "$(find "${APP}/public" -name '*.php')" == "${APP}/public/index.php" ]] || fail "public/ com outro .php: $(find "${APP}/public" -name '*.php')" || return 1
  local velho
  for velho in src public/anunciar.php public/editar.php public/excluir.php public/imovel.php public/assets/styles.css; do
    [[ ! -e "${APP}/${velho}" ]] || fail "sobrou ${velho}" || return 1
  done
  [[ -f "${APP}/backend/Controllers/ImoveisController.php" && -f "${APP}/backend/Models/Imovel.php" \
    && -f "${APP}/backend/Core/Router.php" && -f "${APP}/frontend/views/layout.php" ]] || fail "estrutura MVC incompleta"
}

test_mvc_routes() {
  grep -qx '    FallbackResource /index.php' "${APP}/apache/larcerto.conf" || fail "conf sem FallbackResource" || return 1
  app_harness || return 1
  local caso metodo caminho esperado token args
  for caso in "GET / 200" "GET /imoveis/novo 200" "GET /imoveis/1 200" "GET /imoveis/1/editar 200" \
              "GET /nada 404" "GET /imoveis/abc 404" "GET /imoveis/0 404" "GET /imoveis/999 404" \
              "GET /imoveis/1/editar/x 404" "GET /index.php/x 404"; do
    read -r metodo caminho esperado <<<"${caso}"
    app_req "${metodo}" "${caminho}"
    code_is "${esperado}" "${metodo} ${caminho}" || return 1
    if [[ "${esperado}" == 404 ]]; then
      grep -q 'Lar<span>Certo</span>' "${T}/page.html" && grep -q 'src="/assets/logo.svg"' "${T}/page.html" \
        || fail "404 de ${caminho} sem logo/nome" || return 1
    fi
  done
  app_req GET /imoveis/1/excluir
  code_is 405 "GET excluir" || return 1
  grep -qix 'Allow: POST' <(tr -d '\r' <"${T}/hdr") || fail "405 sem Allow: POST" || return 1
  token="$(app_token)"
  mapfile -t args < <(app_campos "Nova")
  app_req POST /imoveis --form-string "csrf=${token}" "${args[@]}"
  code_is 303 "POST /imoveis" || return 1
  grep -qix 'Location: /imoveis/4' <(tr -d '\r' <"${T}/hdr") || fail "criar nao redireciona para /imoveis/4" || return 1
  app_req POST /imoveis/1 --form-string "csrf=${token}" "${args[@]}"
  code_is 303 "POST /imoveis/1" || return 1
  app_req POST /imoveis/1/excluir --form-string "csrf=${token}"
  code_is 303 "POST excluir" || return 1
  app_req POST /imoveis/999 --form-string "csrf=${token}" "${args[@]}"
  code_is 404 "POST /imoveis/999" && tem_layout "404 do POST /imoveis/999" || return 1
  app_req POST /imoveis/999/excluir --form-string "csrf=${token}"
  code_is 404 "POST /imoveis/999/excluir" && tem_layout "404 do excluir" || return 1
  app_req GET "/imoveis/2%0A"
  code_is 404 "id com quebra de linha" && tem_layout "404 do id com quebra de linha" || return 1
  app_req PUT /imoveis/2
  code_is 405 "PUT /imoveis/2"
}

test_mvc_sql_only_model() {
  local hits
  hits="$(grep -rlE 'SELECT |INSERT INTO|DELETE FROM|UPDATE [a-z_]+ SET|ALTER TABLE' --include='*.php' "${APP}" | sort)"
  [[ "${hits}" == "${APP}/backend/Models/Imovel.php" ]] || fail "SQL fora do Model: ${hits}"
}

test_app_pdo_prepared() {
  local bad
  bad="$(app_php_files | xargs grep -nE -- '->(query|exec)\(' | grep -vE -- "->(query|exec)\('[^'\$]*'\)")"
  [[ -z "${bad}" ]] || fail "query/exec com algo alem de um literal: ${bad}" || return 1
  grep -qE 'ATTR_EMULATE_PREPARES +=> false' "${APP}/backend/Core/Database.php" || fail "prepares emulados" || return 1
  # Comportamental: payloads em todo GET/POST das rotas nunca chegam ao texto SQL.
  app_harness || return 1
  local inj="INJ' OR '1'='1" token args n
  : >"${T}/sql.log"
  app_req GET "/?max=1%20OR%201%3D1&bairro=INJ%27%20OR%20%271%27%3D%271&campus=INJ%27&tipo=INJ%27"
  code_is 200 "lista com injecao" && sql_clean || return 1
  grep -q 'class="resumo">0 imóveis' "${T}/page.html" || fail "filtro com injecao nao zerou a listagem" || return 1
  : >"${T}/sql.log"
  app_req GET "/?bairro=Centro&max=800&tipo=kitnet&campus=UTFPR"
  sql_clean || return 1
  grep -q 'class="resumo">1 imóvel' "${T}/page.html" || fail "filtro bairro+max+tipo+campus errado" || return 1
  app_req GET "/imoveis/1%20OR%201%3D1"
  code_is 404 "id injetado na URL" || return 1
  token="$(app_token)"
  n="$(app_sql 'SELECT COUNT(*) FROM imoveis')"
  : >"${T}/sql.log"
  app_req POST /imoveis --form-string "csrf=${token}" --form-string "titulo=${inj}" --form-string tipo=kitnet \
    --form-string preco=700 --form-string "bairro=${inj}" --form-string campus=UTFPR \
    --form-string "anunciante_nome=${inj}" --form-string anunciante_tipo=locador --form-string "capa=h:${inj}"
  code_is 303 "anunciar com injecao" && sql_clean || return 1
  [[ "$(app_sql 'SELECT COUNT(*) FROM imoveis')" -eq $((n + 1)) ]] || fail "anunciar nao gravou" || return 1
  : >"${T}/sql.log"
  mapfile -t args < <(app_campos "${inj}")
  app_req POST /imoveis/1 --form-string "csrf=${token}" "${args[@]}" --form-string "remover[]=${inj}" --form-string "capa=n:${inj}"
  code_is 303 "editar com injecao" && sql_clean || return 1
  app_req POST "/imoveis/1%20OR%201%3D1/excluir" --form-string "csrf=${token}"
  code_is 404 "excluir com id injetado" || return 1
  [[ "$(app_sql 'SELECT COUNT(*) FROM imoveis')" -eq $((n + 1)) ]] || fail "excluir com id injetado apagou algo"
}

test_app_single_table_no_framework() {
  [[ ! -e "${APP}/composer.json" && ! -d "${APP}/vendor" ]] || fail "framework/composer na app" || return 1
  local externo
  externo="$(app_php_files | xargs grep -nE '^\s*(use|namespace) ' | grep -vE ':\s*(use|namespace) LarCerto\\')"
  [[ -z "${externo}" ]] || fail "use/namespace fora de LarCerto\\: ${externo}" || return 1
  [[ "$(app_php_files | xargs grep -l 'spl_autoload_register')" == "${APP}/backend/bootstrap.php" ]] \
    && [[ "$(grep -c 'spl_autoload_register' "${APP}/backend/bootstrap.php")" -eq 1 ]] || fail "autoload fora do bootstrap.php" || return 1
  local tables
  tables="$(app_php_files | xargs grep -hoE '\b(FROM|INTO|UPDATE|JOIN) +[A-Za-z_]+' | awk '{ print $2 }' | sort -u)"
  [[ "${tables}" == "imoveis" ]] || fail "tabelas consultadas: ${tables}"
}

test_app_escape_and_logo() {
  # Tokenizer: todo "<?=" e exatamente "<?= e(...) ?>", e nao ha echo/print/printf no app.
  app_php_files | "${REAL_PHP}" -r '
    $bad = [];
    while (($f = fgets(STDIN)) !== false) {
        $f = trim($f);
        $t = array_values(array_filter(token_get_all(file_get_contents($f)), fn ($x) => !is_array($x) || $x[0] !== T_WHITESPACE));
        foreach ($t as $i => $tok) {
            if (is_array($tok) && in_array($tok[0], [T_ECHO, T_PRINT], true)) { $bad[] = "$f:$tok[2] echo/print"; }
            if (is_array($tok) && $tok[0] === T_EXIT && ($t[$i + 1] ?? null) === "("
                && !(is_array($t[$i + 2]) && $t[$i + 2][0] === T_CONSTANT_ENCAPSED_STRING && ($t[$i + 3] ?? null) === ")")
                && ($t[$i + 2] ?? null) !== ")") { $bad[] = "$f:$tok[2] exit/die com valor nao literal"; }
            if (is_array($tok) && $tok[0] === T_STRING && in_array(strtolower($tok[1]), ["printf", "print_r", "var_dump", "vprintf", "readfile", "fpassthru"], true)) { $bad[] = "$f:$tok[2] $tok[1]"; }
            if (!is_array($tok) || $tok[0] !== T_OPEN_TAG_WITH_ECHO) { continue; }
            $ok = is_array($t[$i + 1]) && $t[$i + 1][1] === "e" && $t[$i + 2] === "(";
            $j = $i + 3; $depth = 1;
            while ($ok && $depth > 0 && isset($t[$j])) { if ($t[$j] === "(") $depth++; if ($t[$j] === ")") $depth--; $j++; }
            if ($ok && isset($t[$j]) && $t[$j] === ";") { $j++; }
            if (!$ok || !isset($t[$j]) || !is_array($t[$j]) || $t[$j][0] !== T_CLOSE_TAG) { $bad[] = "$f:$tok[2] <?= sem e(...) ?>"; }
        }
    }
    if ($bad) { fwrite(STDERR, implode("\n", $bad) . "\n"); exit(1); }
  ' || fail "saida sem escape" || return 1
  grep -qE 'htmlspecialchars\(\(string\) \$valor, ENT_QUOTES' "${APP}/backend/Core/helpers.php" || fail "e() sem htmlspecialchars" || return 1
  # Renderizado: dado com <script>/<b>/<i> no banco sai escapado; logo e nome em toda pagina.
  app_harness || return 1
  local caminho
  for caminho in / /imoveis/3; do
    app_req GET "${caminho}"
    ! grep -qE '<script>alert|<b>Vila|<i>x' "${T}/page.html" || fail "XSS em ${caminho}" || return 1
    grep -q '&lt;script&gt;alert(1)&lt;/script&gt;' "${T}/page.html" || fail "titulo nao renderizado em ${caminho}" || return 1
  done
  for caminho in / /imoveis/1 /imoveis/novo /imoveis/1/editar /nada; do
    app_req GET "${caminho}"
    grep -q 'src="/assets/logo.svg"' "${T}/page.html" && grep -q 'Lar<span>Certo</span>' "${T}/page.html" \
      && grep -q '· LarCerto</title>' "${T}/page.html" || fail "${caminho} sem logo/nome LarCerto" || return 1
  done
  [[ -f "${APP}/public/assets/logo.svg" ]] || fail "logo.svg fora de public/assets" || return 1
  app_req GET /imoveis/1
  grep -q '>Verificado</span>' "${T}/page.html" || fail "imovel verificado sem selo" || return 1
  app_req GET /imoveis/2
  ! grep -q 'class="selo' "${T}/page.html" || fail "selo em imovel nao verificado"
}

test_app_csrf() {
  local c="${APP}/backend/Controllers/ImoveisController.php"
  grep -q 'is_string($token) && hash_equals(self::token(), $token)' "${APP}/backend/Core/Csrf.php" || fail "Csrf sem hash_equals" || return 1
  sed -n '/function exigirCsrf/,/^    }/p' "${APP}/backend/Core/Controller.php" | grep -q ', 403);' || fail "exigirCsrf sem 403" || return 1
  local acao corpo
  for acao in criar atualizar excluir; do
    corpo="$(sed -n "/public function ${acao}(/,/^    }/p" "${c}")"
    [[ "$(grep -n 'exigirCsrf();' <<<"${corpo}" | head -1 | cut -d: -f1)" -lt \
       "$(grep -nE 'Imovel::(validar|excluir)|preparar\(' <<<"${corpo}" | head -1 | cut -d: -f1)" ]] \
      || fail "${acao} nao confere o token antes de validar/gravar" || return 1
  done
  grep -q 'name="csrf" value="<?= e($csrf) ?>"' "${APP}/frontend/views/imoveis/_form.php" \
    && grep -q 'name="csrf" value="<?= e($csrf) ?>"' "${APP}/frontend/views/imoveis/mostrar.php" || fail "formularios sem token" || return 1
  # Comportamental: sem token ou com token errado, nada muda (linha nem arquivo).
  app_harness || return 1
  app_png "${T}/a.png" 40 30
  local args
  mapfile -t args < <(app_campos "Sem token")
  app_token >/dev/null
  app_req POST /imoveis "${args[@]}" -F "fotos[]=@${T}/a.png"
  code_is 403 "criar sem token" || return 1
  app_req POST /imoveis --form-string csrf=errado "${args[@]}" -F "fotos[]=@${T}/a.png"
  code_is 403 "criar com token errado" || return 1
  app_req POST /imoveis/1 "${args[@]}"
  code_is 403 "editar sem token" || return 1
  app_req POST /imoveis/1/excluir
  code_is 403 "excluir sem token" || return 1
  [[ "$(app_sql 'SELECT COUNT(*) FROM imoveis')" == 3 && "$(app_sql 'SELECT titulo FROM imoveis WHERE id = 1')" == "Kitnet Centro" ]] \
    || fail "POST sem token mudou o banco" || return 1
  [[ -z "$(fotos_no_disco)" ]] && ! tmp_sobrando || fail "POST sem token deixou arquivo"
}

test_app_validation() {
  [[ -n "${REAL_PHP}" ]] || fail "php do host ausente" || return 1
  APP_MODEL="${APP}/backend/Models/Imovel.php" "${REAL_PHP}" <<'PHP' >&2 || fail "validacao errada" || return 1
<?php
require getenv('APP_MODEL');
use LarCerto\Models\Imovel;
$ok = ['titulo' => 'Kitnet teste', 'tipo' => 'kitnet', 'preco' => '750', 'bairro' => 'Centro',
       'campus' => 'UTFPR', 'anunciante_nome' => 'Ana', 'anunciante_tipo' => 'locador'];
[, $erros] = Imovel::validar($ok);
if ($erros) { echo "recusou imovel valido: ", json_encode($erros), "\n"; exit(1); }
$casos = [['titulo', '   '], ['preco', '0'], ['preco', '-5'], ['preco', 'abc'], ['tipo', 'castelo'],
          ['campus', 'USP'], ['anunciante_tipo', 'corretor'], ['titulo', str_repeat('a', 121)], ['preco', '0.001']];
foreach ($casos as [$campo, $valor]) {
    $in = $ok;
    $in[$campo] = $valor;
    [, $erros] = Imovel::validar($in);
    if (!isset($erros[$campo])) { echo "aceitou {$campo}=", substr($valor, 0, 10), "\n"; exit(1); }
}
PHP
  app_harness || return 1
  local token
  token="$(app_token)"
  app_req POST /imoveis --form-string "csrf=${token}" --form-string titulo=X --form-string tipo=castelo \
    --form-string preco=0 --form-string bairro=Centro --form-string campus=UTFPR \
    --form-string anunciante_nome=Ana --form-string anunciante_tipo=locador
  code_is 422 "anunciar invalido" || return 1
  grep -q 'Corrija os campos' "${T}/page.html" || fail "422 sem mensagem" || return 1
  [[ "$(app_sql 'SELECT COUNT(*) FROM imoveis')" == 3 ]] || fail "anunciar invalido gravou"
}

test_app_php_lint_host() {
  [[ -n "${REAL_PHP}" ]] || fail "php do host ausente" || return 1
  local f
  while read -r f; do
    "${REAL_PHP}" -l "${f}" >/dev/null 2>&1 || fail "php -l falhou: ${f}" || return 1
  done < <(app_php_files)
}

test_app_schema_matches_plan() {
  local sql="${APP}/sql/01-schema.sql"
  [[ "$(cat "${APP}"/sql/*.sql | grep -c 'CREATE TABLE')" -eq 1 ]] || fail "mais de uma tabela" || return 1
  grep -q 'CREATE TABLE IF NOT EXISTS imoveis (' "${sql}" || fail "tabela imoveis ausente" || return 1
  local names
  names="$(table_columns "${sql}" | cut -d' ' -f1 | tr '\n' ' ')"
  [[ "${names}" == "id titulo tipo preco bairro campus verificado anunciante_nome anunciante_tipo capa " ]] \
    || fail "colunas: ${names}" || return 1
  grep -qF "tipo            ENUM('kitnet','apartamento','casa','quarto','republica') NOT NULL" "${sql}" || fail "ENUM tipo" || return 1
  grep -qF "campus          ENUM('UTFPR','Unicentro','Qualquer campus') NOT NULL" "${sql}" || fail "ENUM campus" || return 1
  grep -qF "anunciante_tipo ENUM('locador','imobiliaria') NOT NULL," "${sql}" || fail "ENUM anunciante_tipo" || return 1
  grep -qF 'preco           DECIMAL(8,2) NOT NULL' "${sql}" || fail "preco" || return 1
  grep -qxF '  capa            CHAR(32) NULL' "${sql}" || fail "coluna capa" || return 1
  grep -qxF 'ALTER TABLE imoveis ADD COLUMN IF NOT EXISTS capa CHAR(32) NULL;' "${sql}" || fail "ALTER para banco antigo"
}

test_app_compose_config() {
  [[ -n "${REAL_DOCKER}" ]] || fail "docker ausente" || return 1
  local json
  json="$("${REAL_DOCKER}" compose -f "${APP}/compose.yml" --env-file "${APP}/.env.example" config --format json)" \
    || fail "docker compose config falhou" || return 1
  "${REAL_PY}" - "${json}" <<'PY' >&2 || fail "compose fora do plano" || return 1
import json, sys
c = json.loads(sys.argv[1])
s = c["services"]
assert set(s) == {"web", "db"}, set(s)
assert s["db"]["image"] == "mariadb:12.3", s["db"]["image"]
# web na rede do db (sem bridge entre containers neste host); nada em network_mode host
assert s["web"].get("network_mode") == "service:db", s["web"].get("network_mode")
assert "network_mode" not in s["db"], s["db"].get("network_mode")
assert s["web"]["build"].get("network") == "host", s["web"]["build"]
ports = {n: sorted((p.get("host_ip"), str(p["published"]), int(p["target"])) for p in svc.get("ports", [])) for n, svc in s.items()}
assert ports == {"web": [], "db": [("127.0.0.1", "3307", 3306), ("127.0.0.1", "8088", 80)]}, ports
vols = {v["target"]: v for v in s["web"]["volumes"]}
for alvo in ("/var/www/larcerto/public", "/var/www/larcerto/backend", "/var/www/larcerto/frontend/views", "/var/www/larcerto/config.php"):
    assert vols[alvo].get("read_only") is True, (alvo, vols[alvo])
up = vols["/var/www/larcerto/storage/uploads"]
assert up["type"] == "volume" and up["source"] == "uploads" and not up.get("read_only"), up
assert c["volumes"]["uploads"]["name"] == "larcerto_uploads", c["volumes"]["uploads"]
PY
  local d="${APP}/Dockerfile"
  [[ "$(grep -m1 '^FROM ' "${d}")" == "FROM php:8.4-apache" ]] || fail "Dockerfile fora do PHP 8.4" || return 1
  grep -q 'docker-php-ext-configure gd --with-jpeg --with-webp' "${d}" && grep -q 'docker-php-ext-install gd exif pdo_mysql' "${d}" \
    || fail "Dockerfile sem gd/exif/pdo_mysql" || return 1
  grep -qx 'COPY apache/larcerto.conf /etc/apache2/conf-available/larcerto.conf' "${d}" && grep -qx 'RUN a2enconf larcerto' "${d}" \
    && grep -qx 'COPY php/larcerto.ini $PHP_INI_DIR/conf.d/larcerto.ini' "${d}" || fail "Dockerfile sem as configs comuns"
}

test_app_dev_secret_separate() {
  local repo="${PROJECT_DIR}"
  git -C "${repo}" check-ignore -q app/.env || fail ".env da app nao e ignorado" || return 1
  grep -qx 'DB_PASSWORD=troque-esta-senha-local' "${APP}/.env.example" || fail ".env.example sem placeholder" || return 1
  grep -q '"MARIADB_PASSWORD=${DB_PASSWORD?' "${APP}/compose.yml" && grep -q '"DB_PASSWORD=${DB_PASSWORD?' "${APP}/compose.yml" \
    || fail "compose nao le a senha do .env" || return 1
  ! grep -E 'PASSWORD=' "${APP}/compose.yml" | grep -vE 'PASSWORD=\$\{DB_PASSWORD\?|MARIADB_RANDOM_ROOT_PASSWORD=1' | grep -q . \
    || fail "senha literal no compose" || return 1
  grep -q "'password' => getenv('DB_PASSWORD')" "${APP}/dev/config.php" || fail "dev/config.php sem getenv" || return 1
  local secrets="${PROJECT_DIR}/ansible/group_vars/all/secrets.yml" cloud dev
  if [[ -f "${secrets}" ]]; then
    cloud="$(sed -nE 's/^db_password:\s*"?([^"]*)"?\s*$/\1/p' "${secrets}")"
    dev="$(sed -n 's/^DB_PASSWORD=//p' "${APP}/.env" 2>/dev/null)"
    [[ -n "${cloud}" && "${cloud}" != "troque-esta-senha-local" && "${cloud}" != "${dev}" ]] \
      || fail "senha da nuvem igual a de dev" || return 1
  fi
}

test_app_documented() {
  local r="${APP}/README.md"
  [[ -f "${APP}/public/index.php" ]] || fail "app ausente" || return 1
  diff <(table_columns "${r}") <(table_columns "${APP}/sql/01-schema.sql") >&2 \
    || fail "esquema do README difere do 01-schema.sql" || return 1
  local rota
  for rota in 'GET /' 'GET /imoveis/novo' 'POST /imoveis' 'GET /imoveis/{id}' 'GET /imoveis/{id}/editar' \
              'POST /imoveis/{id}' 'POST /imoveis/{id}/excluir'; do
    grep -qF "\`${rota}\`" "${r}" || fail "README sem a rota ${rota}" || return 1
  done
  grep -q '├── backend/' "${r}" && grep -q '├── frontend/' "${r}" && grep -q '├── public/' "${r}" || fail "README sem a estrutura" || return 1
  grep -q '10 fotos' "${r}" && grep -q '20 MB' "${r}" && grep -q '40 MP' "${r}" || fail "README sem os limites das fotos" || return 1
  grep -q 'docker compose -f app/compose.yml up' "${r}" || fail "README sem o Compose" || return 1
  grep -q '127.0.0.1:8088' "${r}" && grep -q '127.0.0.1:3307' "${r}" || fail "README sem as portas locais" || return 1
  ! grep -qiE 'CRUD.*pendente|pendente.*CRUD' "${PROJECT_DIR}/../TASKS.md" || fail "TASKS.md ainda marca o CRUD pendente"
}

# ---------------------------------------------------------------- app: CSS sem framework

# pw_run: roda o script Python da entrada padrao com o Playwright do .venv. O script ja recebe
# `browser` aberto, `BASE` e `fotos_reais(pasta)` (troca os .webp falsos do harness por imagens reais).
pw_run() {
  local py="${PW_PYTHON}"
  [[ -x "${py}" ]] && "${py}" -c 'import playwright' 2>/dev/null || fail "Playwright ausente em ${py} (python3 -m venv .venv && .venv/bin/pip install playwright)" || return 1
  cat >"${T}/pw_body.py"
  "${py}" - "${T}/pw_body.py" <<'PY'
import base64, glob, os, sys
from playwright.sync_api import Error, sync_playwright

with sync_playwright() as p:
    try:
        browser = p.chromium.launch()
    except Error:
        cache = sorted(glob.glob(os.path.expanduser("~/.cache/ms-playwright/chromium-*/chrome-linux*/chrome")))
        assert cache, "nenhum Chromium do Playwright no cache"
        browser = p.chromium.launch(executable_path=cache[-1])

    def fotos_reais(pasta):
        pg = browser.new_page()
        for i, f in enumerate(sorted(glob.glob(pasta + "/*.webp"))):
            b64 = pg.evaluate("""(i) => { const c = document.createElement('canvas'); c.width = 400; c.height = 300;
                const g = c.getContext('2d'); g.fillStyle = `hsl(${i * 70} 60% 45%)`; g.fillRect(0, 0, 400, 300);
                return c.toDataURL('image/webp').split(',')[1]; }""", i)
            open(f, "wb").write(base64.b64decode(b64))
        pg.close()

    try:
        exec(compile(open(sys.argv[1]).read(), "teste", "exec"),
             {"browser": browser, "p": p, "BASE": os.environ.get("BASE"), "os": os, "fotos_reais": fotos_reais})
    finally:
        browser.close()
PY
}

test_css_sem_framework() {
  local f pat="tail""wind" achou
  for f in frontend/css bin/build-css.sh bin; do
    [[ ! -e "${APP}/${f}" ]] || fail "sobrou ${f}" || return 1
  done
  "${APP}/run.sh" css >/dev/null 2>"${T}/err"
  [[ $? -eq 2 ]] || fail "run.sh css nao sai 2" || return 1
  ! grep -qE '^  css ' "${T}/err" || fail "ajuda do run.sh ainda lista o css" || return 1
  achou="$(grep -rliI "${pat}" "${APP}" "${PROJECT_DIR}/ansible" "${PROJECT_DIR}/tests" \
    --exclude-dir=node_modules --exclude-dir=vendor --exclude=composer.lock)"
  [[ -z "${achou}" ]] || fail "ainda cita ${pat}:" "${achou}"
}

test_css_puro() {
  local c="${APP}/public/assets/app.css" cor
  [[ -s "${c}" ]] || fail "app.css ausente" || return 1
  ! grep -qE '@apply|@theme|@import|@source|@layer|@tail[w]ind' "${c}" || fail "app.css com diretiva de framework" || return 1
  sed -n '/^:root {/,/^}/p' "${c}" >"${T}/root.css"
  for cor in '--ink: #1a2420;' '--muted: #5a6b62;' '--paper: #f3f5f3;' '--brand: #1a6b4a;' '--brand-deep: #0f3d2c;' '--accent: #c45c26;'; do
    grep -qF -- "${cor}" "${T}/root.css" || fail ":root sem ${cor}" || return 1
  done
  grep -qF -- '--font-display: "Fraunces"' "${T}/root.css" && grep -qF -- '--font-sans: "Source Sans 3"' "${T}/root.css" \
    || fail ":root sem as fontes" || return 1
  local l="${APP}/frontend/views/layout.php"
  grep -q '<link rel="stylesheet" href="/assets/app.css">' "${l}" || fail "layout sem /assets/app.css" || return 1
  [[ "$(grep -c 'rel="stylesheet"' "${l}")" -eq 2 ]] || fail "layout com outro CSS alem de app.css e da fonte"
}

test_css_classes_definidas() {
  "${REAL_PY}" - "${APP}" <<'PY' >&2 || fail "classes sem regra no app.css ou utilitarias"
import pathlib, re, sys
app = pathlib.Path(sys.argv[1])
css = re.sub(r"/\*.*?\*/", "", (app / "public/assets/app.css").read_text(), flags=re.S)
definidas = set(re.findall(r"\.([A-Za-z_][\w-]*)", css))
usadas = {}
def junta(origem, texto):
    for c in texto.split():
        usadas.setdefault(c, origem)
for v in (app / "frontend/views").rglob("*.php"):
    s = v.read_text()
    chamadas = set()
    for attr in re.findall(r'class="([^"]*)"', s):
        junta(v.name, re.sub(r"<\?=.*?\?>", " ", attr))
        chamadas |= set(re.findall(r"\$(\w+)\(", attr))
    # classes montadas em PHP: closures chamados dentro de class="..." ($nav, $erro)
    for nome, corpo in re.findall(r"\$(\w+) = fn \([^)]*\): string => ([^;]+);", s):
        if nome in chamadas:
            for lit in re.findall(r"'([^']*)'", corpo):
                junta(v.name + " ($" + nome + ")", lit)
m = re.search(r"function thumbClass.*?\{(.*?)\n    \}", (app / "backend/Models/Imovel.php").read_text(), re.S)
for lit in re.findall(r"=>\s*'([^']*)'", m.group(1)):
    junta("Imovel::thumbClass", lit)
for j in (app / "public/assets/js").glob("*.js"):
    s = j.read_text()
    for lit in re.findall(r"className = '([^']*)'", s):
        junta(j.name, lit)
    for lit in re.findall(r"classList\.(?:add|remove|toggle|contains)\('([^']*)'", s):
        junta(j.name, lit)
UTIL = re.compile(r"[:\[\]/]|^-?(m[trblxy]?|p[trblxy]?|gap(-[xy])?|w|h|size|max-[wh]|min-[wh]|top|left|right|bottom|inset|z|text|font|bg|"
                  r"border(-[trblxy])?|rounded(-[trbl]{1,2})?|shadow|grid-cols|col-span|row-span|items|justify(-self)?|self|leading|tracking|"
                  r"opacity|translate(-[xy])?|scale|space-[xy]|aspect|object|overflow|accent|ring|outline|from|to|via)-|"
                  r"^(flex|grid|block|inline|hidden|relative|absolute|fixed|sticky|sr-only|container|group|underline|uppercase|"
                  r"truncate|transition|antialiased|shadow|border|rounded|italic|grow|shrink)$")
erros = [f"{c} ({o}): sem regra no app.css" for c, o in usadas.items() if c not in definidas]
erros += [f"{c} ({o}): forma utilitaria" for c, o in usadas.items() if UTIL.search(c)]
assert len(usadas) > 60, f"so {len(usadas)} classes lidas: o parser nao achou as views"
print("\n".join(erros) or f"{len(usadas)} classes, todas com regra")
sys.exit(1 if erros else 0)
PY
}

test_css_aparencia() {
  app_harness || return 1
  BASE="${BASE}" pw_run <<'PY' >&2 || fail "aparencia fora do esperado"
telas = ["/", "/imoveis/1", "/imoveis/novo", "/imoveis/1/editar", "/nao-existe"]
pg = browser.new_page(viewport={"width": 1280, "height": 900})
for t in telas:
    pg.goto(BASE + t)
    assert pg.evaluate("getComputedStyle(document.body).backgroundColor") == "rgb(243, 245, 243)", t
    assert pg.evaluate("getComputedStyle(document.querySelector('.cabecalho-acao')).backgroundColor") == "rgb(26, 107, 74)", t
    assert pg.locator("nav.menu").is_visible(), t + ": menu oculto em 1280"
pg.goto(BASE + "/imoveis/1")
assert pg.evaluate("getComputedStyle(document.querySelector('h1')).fontFamily").startswith("Fraunces"), "titulo sem Fraunces"
assert pg.evaluate("document.querySelector('aside').getBoundingClientRect().width") == 320, "lateral sem 320 px"
pg = browser.new_page(viewport={"width": 390, "height": 900})
for t in telas:
    pg.goto(BASE + t)
    assert not pg.locator("nav.menu").is_visible(), t + ": menu visivel em 390"
    assert pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth"), t + ": rolagem horizontal em 390"
pg.goto(BASE + "/imoveis/1")
assert pg.evaluate("""document.querySelector('aside').getBoundingClientRect().top
    >= document.querySelector('.imovel-principal').getBoundingClientRect().bottom"""), "lateral nao fica abaixo em 390"
print("aparencia ok em 1280 e 390")
PY
}

test_css_estados_form() {
  app_harness || return 1
  BASE="${BASE}" pw_run <<'PY' >&2 || fail "estados do formulario"
pg = browser.new_page(viewport={"width": 1280, "height": 900})
pg.goto(BASE + "/imoveis/novo")
pg.evaluate("document.querySelectorAll('[required]').forEach((e) => e.removeAttribute('required'))")
pg.fill('input[name="titulo"]', "")
pg.click('form button[type="submit"]')
pg.wait_for_selector(".alerta-erro")
campo = ".rotulo.campo-erro .campo"
assert pg.locator(campo).count() >= 1, "nenhum campo marcado com erro"
assert pg.evaluate(f"getComputedStyle(document.querySelector('{campo}')).borderTopColor") == "rgb(220, 38, 38)", "borda do erro"
assert pg.evaluate("getComputedStyle(document.querySelector('.erro-msg')).color") == "rgb(185, 28, 28)", "mensagem do erro"
pg.evaluate("document.querySelector('form button[type=submit]').disabled = true")
assert pg.evaluate("getComputedStyle(document.querySelector('form button[type=submit]')).opacity") == "0.6", "botao desabilitado"
print("estados ok")
PY
}

# ---------------------------------------------------------------- app: fotos

# app_anunciar <args do curl...>: anuncia com campos validos + os args; id do novo imovel em $ID
app_anunciar() {
  local token args
  token="$(app_token)"
  mapfile -t args < <(app_campos "Com fotos")
  app_req POST /imoveis --form-string "csrf=${token}" "${args[@]}" "$@"
  ID="$(tr -d '\r' <"${T}/hdr" | sed -n 's#^Location: /imoveis/\([0-9]*\)$#\1#p')"
}

# app_editar <id> <args do curl...>: edita com campos validos + os args
app_editar() {
  local id="$1" token args
  shift
  token="$(app_token)"
  mapfile -t args < <(app_campos "Com fotos")
  app_req POST "/imoveis/${id}" --form-string "csrf=${token}" "${args[@]}" "$@"
}

# conteudo dos .webp grandes da pasta do imovel, em ordem de nome ("LxA" de cada foto)
fotos_de() { local f; for f in $(ls "${T}/w/storage/uploads/$1/" 2>/dev/null | grep -E '^[0-9a-f]{32}\.webp$' | sort); do cat "${T}/w/storage/uploads/$1/${f}"; echo; done; }
capa_de() { app_sql "SELECT capa FROM imoveis WHERE id = $1"; }
foto_n() { ls "${T}/w/storage/uploads/$1/" | grep -E '^[0-9a-f]{32}\.webp$' | sort | sed -n "$2p" | cut -c1-32; }

test_fotos_fluxo() {
  app_harness || return 1
  local n
  for n in 10 11 12 13 14 15 16 17 18 19 20; do app_png "${T}/f${n}.png" "${n}" 30; done
  # 3 fotos: pares .webp/_thumb.webp, ordem de envio, capa = 1a
  app_anunciar -F "fotos[]=@${T}/f10.png" -F "fotos[]=@${T}/f11.png" -F "fotos[]=@${T}/f12.png"
  code_is 303 "anunciar com 3 fotos" && [[ -n "${ID}" ]] || return 1
  local a="${ID}" pasta="${T}/w/storage/uploads/${ID}"
  [[ "$(ls "${pasta}" | grep -cE '^[0-9a-f]{32}\.webp$')" -eq 3 && "$(ls "${pasta}" | grep -cE '^[0-9a-f]{32}_thumb\.webp$')" -eq 3 \
    && "$(ls "${pasta}" | wc -l)" -eq 6 ]] || fail "pasta do imovel: $(ls "${pasta}")" || return 1
  [[ "$(fotos_de "${a}" | tr '\n' ' ')" == "10x30 11x30 12x30 " ]] || fail "ordem de envio perdida: $(fotos_de "${a}")" || return 1
  [[ "$(capa_de "${a}")" == "$(foto_n "${a}" 1)" ]] || fail "capa padrao nao e a 1a" || return 1
  ! tmp_sobrando || fail "pasta temporaria sobrou" || return 1
  # remover[] mal formado (array dentro de array) num imovel com fotos: ignorado, sem aviso do PHP
  : >"${T}/php.err"
  app_editar "${a}" --form-string "remover[][]=x"
  code_is 303 "remover[][]" || return 1
  ! grep -q 'Array to string' "${T}/php.err" || fail "remover[][] gerou aviso: $(cat "${T}/php.err")" || return 1
  [[ "$(fotos_de "${a}" | wc -l)" -eq 3 ]] || fail "remover[][] apagou foto" || return 1
  # capa escolhida entre as novas (n:1 = 2a)
  app_anunciar -F "fotos[]=@${T}/f13.png" -F "fotos[]=@${T}/f14.png" --form-string capa=n:1
  code_is 303 "anunciar com capa n:1" || return 1
  [[ "$(cat "${T}/w/storage/uploads/${ID}/$(capa_de "${ID}").webp")" == "14x30" ]] || fail "capa n:1 nao e a 2a foto" || return 1
  local b="${ID}"
  # editar removendo a capa: a proxima (11x30) vira capa e os dois arquivos somem
  local capa
  capa="$(capa_de "${a}")"
  app_editar "${a}" --form-string "remover[]=${capa}"
  code_is 303 "editar removendo a capa" || return 1
  [[ ! -e "${pasta}/${capa}.webp" && ! -e "${pasta}/${capa}_thumb.webp" ]] || fail "arquivos da foto removida ficaram" || return 1
  [[ "$(cat "${pasta}/$(capa_de "${a}").webp")" == "11x30" ]] || fail "capa nao passou para a proxima" || return 1
  # adicionar 2 fotos na edicao, capa = 1a nova; e escolher capa existente (h:)
  app_editar "${a}" -F "fotos[]=@${T}/f15.png" -F "fotos[]=@${T}/f16.png" --form-string capa=n:0
  code_is 303 "editar adicionando fotos" || return 1
  [[ "$(fotos_de "${a}" | tr '\n' ' ')" == "11x30 12x30 15x30 16x30 " ]] || fail "fotos depois de adicionar: $(fotos_de "${a}")" || return 1
  [[ "$(cat "${pasta}/$(capa_de "${a}").webp")" == "15x30" ]] || fail "capa n:0 na edicao" || return 1
  app_editar "${a}" --form-string "capa=h:$(foto_n "${a}" 2)"
  [[ "$(cat "${pasta}/$(capa_de "${a}").webp")" == "12x30" ]] || fail "capa h: existente" || return 1
  # editar sem escolher capa mantem a atual
  app_editar "${a}"
  [[ "$(cat "${pasta}/$(capa_de "${a}").webp")" == "12x30" ]] || fail "editar sem capa trocou a capa" || return 1
  # chegar a exatamente 10 fotos na edicao e permitido
  app_editar "${a}" -F "fotos[]=@${T}/f17.png" -F "fotos[]=@${T}/f18.png" -F "fotos[]=@${T}/f19.png" \
    -F "fotos[]=@${T}/f20.png" -F "fotos[]=@${T}/f10.png" -F "fotos[]=@${T}/f11.png"
  code_is 303 "editar ate 10 fotos" || return 1
  [[ "$(fotos_de "${a}" | wc -l)" -eq 10 ]] || fail "nao chegou a 10 fotos" || return 1
  # com 10 fotos, trocar uma (remover 1 + adicionar 1) e permitido: o limite conta so as que ficam
  app_editar "${a}" --form-string "remover[]=$(foto_n "${a}" 3)" -F "fotos[]=@${T}/f13.png"
  code_is 303 "trocar uma foto com 10" || return 1
  [[ "$(fotos_de "${a}" | wc -l)" -eq 10 && "$(fotos_de "${a}" | tail -1)" == "13x30" ]] || fail "troca com 10 fotos: $(fotos_de "${a}")" || return 1
  # remover todas: capa NULL e nenhuma foto
  local todas=() f
  for f in $(ls "${pasta}" | grep -E '^[0-9a-f]{32}\.webp$'); do todas+=(--form-string "remover[]=${f%.webp}"); done
  app_editar "${a}" "${todas[@]}"
  code_is 303 "remover todas" || return 1
  [[ -z "$(capa_de "${a}")" && -z "$(ls "${pasta}")" ]] || fail "remover todas: capa=$(capa_de "${a}") arquivos=$(ls "${pasta}")" || return 1
  # excluir o imovel apaga a pasta
  local token
  token="$(app_token)"
  app_req POST "/imoveis/${b}/excluir" --form-string "csrf=${token}"
  code_is 303 "excluir com fotos" || return 1
  [[ ! -e "${T}/w/storage/uploads/${b}" ]] || fail "pasta do imovel excluido ficou"
}

test_fotos_recusas() {
  app_harness || return 1
  local n0 token args
  n0="$(app_sql 'SELECT COUNT(*) FROM imoveis')"
  app_png "${T}/ok.png" 40 30
  printf '<?php echo "pwned";' >"${T}/foto.png"
  app_png "${T}/grande.png" 8000 6000
  app_png "${T}/quebrada.png" 40 30 QUEBRA
  truncate -s 21M "${T}/21mb.jpg"
  local caso arq msg
  for caso in "foto.png|não é uma foto JPEG, PNG ou WebP" "grande.png|passa de 40 megapixels" \
              "21mb.jpg|passa de 20 MB" "quebrada.png|Não foi possível ler a foto"; do
    arq="${caso%%|*}" msg="${caso#*|}"
    app_anunciar -F "fotos[]=@${T}/ok.png" -F "fotos[]=@${T}/${arq}"
    code_is 422 "anunciar com ${arq}" || return 1
    grep -qF "${msg}" "${T}/page.html" || fail "${arq}: sem a mensagem '${msg}'" || return 1
    [[ "$(app_sql 'SELECT COUNT(*) FROM imoveis')" == "${n0}" ]] || fail "${arq}: gravou a linha" || return 1
    [[ -z "$(fotos_no_disco)" ]] && ! tmp_sobrando || fail "${arq}: deixou arquivo $(find "${T}/w/storage" -type f)" || return 1
  done
  # campo invalido com foto valida: 422, nada gravado nem processado
  : >"${T}/fotos.log"
  token="$(app_token)"
  app_req POST /imoveis --form-string "csrf=${token}" --form-string titulo= --form-string tipo=kitnet --form-string preco=700 \
    --form-string bairro=Centro --form-string campus=UTFPR --form-string anunciante_nome=Ana --form-string anunciante_tipo=locador \
    -F "fotos[]=@${T}/ok.png"
  code_is 422 "campo invalido com foto" || return 1
  [[ ! -s "${T}/fotos.log" && -z "$(fotos_no_disco)" ]] || fail "processou foto de anuncio invalido" || return 1
  # anunciar com 11 fotos: o PHP entrega as 11 (max_file_uploads = 11) e a app recusa sem gravar nada
  local onze=() i
  for i in 1 2 3 4 5 6 7 8 9 10 11; do onze+=(-F "fotos[]=@${T}/ok.png"); done
  app_anunciar "${onze[@]}"
  code_is 422 "anunciar com 11 fotos" || return 1
  grep -qF 'Cada imóvel pode ter até 10 fotos.' "${T}/page.html" || fail "11 fotos sem mensagem do limite" || return 1
  [[ "$(app_sql 'SELECT COUNT(*) FROM imoveis')" == "${n0}" && -z "$(fotos_no_disco)" ]] && ! tmp_sobrando \
    || fail "11 fotos gravou linha ou arquivo" || return 1
  grep -qx 'max_file_uploads = 11' "${APP}/php/larcerto.ini" || fail "max_file_uploads nao e 11" || return 1
  # imovel com 9 fotos + 2 novas: 422 e as 9 ficam
  local nove=()
  for i in 1 2 3 4 5 6 7 8 9; do nove+=(-F "fotos[]=@${T}/ok.png"); done
  app_anunciar "${nove[@]}"
  code_is 303 "anunciar com 9 fotos" || return 1
  local id="${ID}" antes
  antes="$(fotos_no_disco)"
  app_editar "${id}" -F "fotos[]=@${T}/ok.png" -F "fotos[]=@${T}/ok.png"
  code_is 422 "passar de 10 fotos" || return 1
  grep -qF 'Cada imóvel pode ter até 10 fotos.' "${T}/page.html" || fail "sem mensagem do limite" || return 1
  [[ "$(fotos_no_disco)" == "${antes}" ]] && ! tmp_sobrando || fail "limite estourado mexeu nas fotos" || return 1
  # envio acima de post_max_size: 413 com mensagem, nao 403
  truncate -s 65M "${T}/65mb.jpg"
  app_anunciar -F "fotos[]=@${T}/65mb.jpg"
  code_is 413 "envio de 65 MB" || return 1
  grep -qF 'Envie menos fotos por vez' "${T}/page.html" || fail "413 sem a mensagem" || return 1
  [[ "$(fotos_no_disco)" == "${antes}" ]] || fail "envio de 65 MB gravou arquivo" || return 1
  app_editar "${id}" -F "fotos[]=@${T}/65mb.jpg"
  code_is 413 "edicao de 65 MB" || return 1
  # sem token, com foto: 403 sem arquivo
  mapfile -t args < <(app_campos "Sem token")
  app_req POST /imoveis "${args[@]}" -F "fotos[]=@${T}/ok.png"
  code_is 403 "foto sem token" || return 1
  [[ "$(fotos_no_disco)" == "${antes}" ]] && ! tmp_sobrando || fail "POST sem token deixou arquivo"
}

test_fotos_capa_render() {
  app_harness || return 1
  app_png "${T}/a.png" 40 30
  app_png "${T}/b.png" 41 30
  app_anunciar -F "fotos[]=@${T}/a.png" -F "fotos[]=@${T}/b.png" --form-string capa=n:1
  code_is 303 "anunciar" || return 1
  local id="${ID}" capa outra
  capa="$(capa_de "${id}")"
  outra="$(foto_n "${id}" 1)"
  [[ "${capa}" == "$(foto_n "${id}" 2)" ]] || fail "capa n:1" || return 1
  app_sql "UPDATE imoveis SET capa = 'ffffffffffffffffffffffffffffffff' WHERE id = 2" >/dev/null
  app_req GET /
  # imovel 1 (sem foto) e 2 (capa sem arquivo): desenho do tipo; imovel novo: miniatura da capa
  local card1 card2 cardn
  card1="$(grep -A5 'href="/imoveis/1"' "${T}/page.html")"
  card2="$(grep -A5 'href="/imoveis/2"' "${T}/page.html")"
  cardn="$(grep -A5 "href=\"/imoveis/${id}\"" "${T}/page.html")"
  grep -q 'class="thumb ' <<<"${card1}" && ! grep -q '/uploads/' <<<"${card1}" || fail "card sem foto nao usa o desenho" || return 1
  grep -q 'class="thumb ' <<<"${card2}" && ! grep -q '/uploads/' <<<"${card2}" || fail "capa ausente nao cai no desenho" || return 1
  grep -qF "src=\"/uploads/${id}/${capa}_thumb.webp\"" <<<"${cardn}" || fail "card nao usa a miniatura da capa" || return 1
  app_req GET "/imoveis/${id}"
  [[ "$(grep -oE 'src="/uploads/[^"]+"' "${T}/page.html" | head -1)" == "src=\"/uploads/${id}/${capa}.webp\"" ]] \
    || fail "detalhe nao mostra a capa primeiro" || return 1
  sed -n '/class="slider-trilho/,/<\/ul>/p' "${T}/page.html" | grep -qF "/uploads/${id}/${outra}.webp" || fail "galeria sem a outra foto" || return 1
  app_req GET /imoveis/2
  grep -q 'class="thumb ' "${T}/page.html" && ! grep -q 'src="/uploads/' "${T}/page.html" || fail "detalhe com capa ausente" || return 1
  # capa apagada do disco, outra foto ainda la: desenho no topo e a outra na galeria
  app_anunciar -F "fotos[]=@${T}/a.png" -F "fotos[]=@${T}/b.png"
  local sem="${ID}" capa_sem
  capa_sem="$(capa_de "${sem}")"
  rm "${T}/w/storage/uploads/${sem}/${capa_sem}.webp" "${T}/w/storage/uploads/${sem}/${capa_sem}_thumb.webp"
  app_req GET "/imoveis/${sem}"
  sed -n '/class="imovel-midia"/,/<\/div>/p' "${T}/page.html" | grep -q 'class="thumb ' \
    || fail "capa ausente com outras fotos: topo nao mostra o desenho" || return 1
  sed -n '/class="slider-trilho/,/<\/ul>/p' "${T}/page.html" | grep -qF "/uploads/${sem}/$(foto_n "${sem}" 1).webp" \
    || fail "capa ausente: a outra foto sumiu da galeria" || return 1
  app_req GET "/uploads/${id}/${capa}_thumb.webp"
  code_is 200 "miniatura servida" || return 1
  app_req GET "/imoveis/${id}/editar"
  grep -qF "value=\"h:${capa}\" checked" "${T}/page.html" && grep -qF "name=\"remover[]\" value=\"${outra}\"" "${T}/page.html" \
    || fail "editar sem radio de capa / remover"
}

test_fotos_processador_estatico() {
  local v="${APP}/backend/Services/ValidadorImagem.php" p="${APP}/backend/Services/ProcessadorImagem.php"
  grep -qF 'public const MAX_BYTES = 20 * 1024 * 1024;' "${v}" && grep -qF 'public const MAX_PIXELS = 40_000_000;' "${v}" \
    || fail "limites do validador" || return 1
  grep -qF "public const TIPOS = ['image/jpeg' => IMAGETYPE_JPEG, 'image/png' => IMAGETYPE_PNG, 'image/webp' => IMAGETYPE_WEBP];" "${v}" \
    || fail "tipos aceitos" || return 1
  grep -qF '(new \finfo(FILEINFO_MIME_TYPE))->file($tmp)' "${v}" && grep -q 'getimagesize(\$tmp)' "${v}" || fail "validador sem finfo/getimagesize" || return 1
  ! grep -qE 'imagecreate|imagewebp|exif_read_data' "${v}" || fail "validador decodifica a imagem" || return 1
  grep -qF 'public const LADO_MAX = 1920;' "${p}" && grep -qF 'public const MINI_L = 640;' "${p}" && grep -qF 'public const MINI_A = 480;' "${p}" \
    && grep -qF 'public const QUALIDADE = 82;' "${p}" && grep -qF 'public const QUALIDADE_MINI = 75;' "${p}" || fail "constantes do processador" || return 1
  grep -qF "imagewebp(\$grande, \$destino . '.webp', self::QUALIDADE)" "${p}" \
    && grep -qF "imagewebp(\$mini, \$destino . '_thumb.webp', self::QUALIDADE_MINI)" "${p}" || fail "saida nao e WebP" || return 1
  grep -q 'exif_read_data(\$tmp)' "${p}" || fail "sem orientacao do EXIF" || return 1
  ! grep -qE 'imagejpeg|imagepng|imagegif|copy\(|rename\(\$tmp' "${p}" || fail "processador grava outro formato/copia o original" || return 1
  ! app_php_files | xargs grep -n 'move_uploaded_file' | grep -q . || fail "app guarda o original com move_uploaded_file" || return 1
  local c="${APP}/apache/larcerto.conf"
  grep -qx 'Alias /uploads/ /var/www/larcerto/storage/uploads/' "${c}" && grep -qx '        php_admin_flag engine off' "${c}" \
    || fail "conf sem Alias/engine off" || return 1
  sed -n '/<Directory \/var\/www\/larcerto\/storage\/uploads>/,/^<\/Directory>/p' "${c}" >"${T}/up.conf"
  grep -qx '    Require all denied' "${T}/up.conf" && grep -qx '    <FilesMatch "^\[0-9a-f\]{32}(_thumb)?\\.webp$">' "${T}/up.conf" \
    && [[ "$(grep -c 'Require all granted' "${T}/up.conf")" -eq 1 ]] || fail "uploads sem negar tudo menos os .webp"
}

test_fotos_js_browser() {
  local py="${PW_PYTHON}"
  [[ -x "${py}" ]] && "${py}" -c 'import playwright' 2>/dev/null || fail "Playwright ausente em ${py} (python3 -m venv .venv && .venv/bin/pip install playwright)" || return 1
  app_harness || return 1
  BASE="${BASE}" FOTOS_LOG="${T}/fotos.log" OUT="${T}" "${py}" - <<'PY' >&2 || fail "teste no navegador falhou"
import base64, glob, json, os, re, sys
from playwright.sync_api import Error, sync_playwright

base, log, out = os.environ["BASE"], os.environ["FOTOS_LOG"], os.environ["OUT"]

def campos(page, titulo):
    page.fill('input[name="titulo"]', titulo)
    page.fill('input[name="preco"]', "750")
    page.fill('input[name="bairro"]', "Centro")
    page.fill('input[name="anunciante_nome"]', "Ana")

def ultima():
    return json.loads(open(log).read().splitlines()[-1])

with sync_playwright() as p:
    try:
        browser = p.chromium.launch()
    except Error:
        # navegador da versao do Playwright ausente: usa o Chromium mais novo ja baixado no cache
        cache = sorted(glob.glob(os.path.expanduser("~/.cache/ms-playwright/chromium-*/chrome-linux*/chrome")))
        assert cache, "nenhum Chromium do Playwright no cache"
        browser = p.chromium.launch(executable_path=cache[-1])
    # Com JS: foto 4000x3000 gerada no proprio navegador; fotos.js reduz antes do envio.
    page = browser.new_page()
    page.goto(base + "/imoveis/novo")
    campos(page, "Com JS")
    b64 = page.evaluate("""async () => {
        const c = document.createElement('canvas'); c.width = 4000; c.height = 3000;
        const g = c.getContext('2d');
        const grad = g.createLinearGradient(0, 0, 4000, 3000);
        grad.addColorStop(0, '#1a6b4a'); grad.addColorStop(1, '#c45c26');
        g.fillStyle = grad; g.fillRect(0, 0, 4000, 3000);
        for (let i = 0; i < 4000; i++) { g.fillStyle = `hsl(${i % 360} 60% 50%)`; g.fillRect((i * 97) % 4000, (i * 61) % 3000, 40, 40); }
        const blob = await new Promise((r) => c.toBlob(r, 'image/jpeg', 0.95));
        const file = new File([blob], 'grande.jpg', { type: 'image/jpeg' });
        const input = document.querySelector('input[name="fotos[]"]');
        const dt = new DataTransfer(); dt.items.add(file); input.files = dt.files;
        input.dispatchEvent(new Event('change'));
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let s = ''; for (const x of bytes) s += String.fromCharCode(x);
        return btoa(s);
    }""")
    original = base64.b64decode(b64)
    open(out + "/grande.jpg", "wb").write(original)
    page.wait_for_selector('#previa-fotos figure')
    page.wait_for_function("!document.querySelector('form button[type=submit]').disabled")
    radio = page.locator('#previa-fotos input[name="capa"]')
    assert radio.count() == 1 and radio.get_attribute("value") == "n:0" and radio.is_checked(), "previa sem radio de capa"
    page.click('form button[type="submit"]')
    page.wait_for_url(re.compile(r".*/imoveis/\d+$"))
    r = ultima()
    print("com JS:", r, "original:", len(original), "bytes", file=sys.stderr)
    assert max(r["l"], r["a"]) <= 1920 and r["bytes"] < 2 * 1024 * 1024, r
    assert (r["l"], r["a"]) == (1920, 1440), r

    # Sem JS: a mesma foto chega inteira e o anuncio e criado.
    ctx = browser.new_context(java_script_enabled=False)
    page = ctx.new_page()
    page.goto(base + "/imoveis/novo")
    campos(page, "Sem JS")
    page.set_input_files('input[name="fotos[]"]', out + "/grande.jpg")
    page.click('form button[type="submit"]')
    page.wait_for_url(re.compile(r".*/imoveis/\d+$"))
    r = ultima()
    print("sem JS:", r, file=sys.stderr)
    assert (r["l"], r["a"]) == (4000, 3000) and r["bytes"] == len(original), r
    browser.close()
PY
}

# ---------------------------------------------------------------- galeria do imovel

# anuncia "Com fotos" com 3 PNGs e capa na terceira; id em $ID
galeria_3() {
  app_harness || return 1
  app_png "${T}/a.png" 40 30
  app_png "${T}/b.png" 41 30
  app_png "${T}/c.png" 42 30
  app_anunciar -F "fotos[]=@${T}/a.png" -F "fotos[]=@${T}/b.png" -F "fotos[]=@${T}/c.png" --form-string capa=n:2
  code_is 303 "anunciar 3 fotos"
}

# slides do slider em $T/page.html, um por linha: "src|alt|loading", ou "thumb" para o desenho do tipo
slides() {
  "${REAL_PHP}" -r '
    $d = new DOMDocument(); libxml_use_internal_errors(true);
    $d->loadHTML(mb_encode_numericentity(file_get_contents($argv[1]), [0x80, 0x10FFFF, 0, 0x1FFFFF], "UTF-8"));
    $x = new DOMXPath($d);
    foreach ($x->query("//ul[contains(concat(\" \", @class, \" \"), \" slider-trilho \")]/li[contains(@class, \"slider-slide\")]") as $li) {
        $img = $x->query(".//img", $li)->item(0);
        if ($img === null) { echo $x->query(".//div[contains(@class, \"thumb\")]", $li)->length ? "thumb" : "?", "\n"; continue; }
        echo $img->getAttribute("src"), "|", $img->getAttribute("alt"), "|", $img->getAttribute("loading"), "\n";
    }' "${T}/page.html"
}

xpath_count() {
  "${REAL_PHP}" -r '
    $d = new DOMDocument(); libxml_use_internal_errors(true);
    $d->loadHTML(mb_encode_numericentity(file_get_contents($argv[1]), [0x80, 0x10FFFF, 0, 0x1FFFFF], "UTF-8"));
    echo (new DOMXPath($d))->query($argv[2])->length;' "${T}/page.html" "$1"
}

test_galeria_slides() {
  galeria_3 || return 1
  local id="${ID}" capa n nome esperado=() k=2
  capa="$(capa_de "${id}")"
  [[ "${capa}" == "$(foto_n "${id}" 3)" ]] || fail "capa n:2 nao e a terceira foto" || return 1
  esperado+=("/uploads/${id}/${capa}.webp|Foto principal de Com fotos|")
  for n in 1 2 3; do
    nome="$(foto_n "${id}" "${n}")"
    [[ "${nome}" == "${capa}" ]] && continue
    esperado+=("/uploads/${id}/${nome}.webp|Foto ${k} de Com fotos|lazy")
    k=$((k + 1))
  done
  app_req GET "/imoveis/${id}"
  code_is 200 "detalhe" || return 1
  [[ "$(slides)" == "$(printf '%s\n' "${esperado[@]}")" ]] || fail "slides: $(slides | tr '\n' ' ')"
}

test_galeria_lugar() {
  galeria_3 || return 1
  app_req GET "/imoveis/${ID}"
  [[ "$(xpath_count "//div[@class='imovel-midia']//*[@data-slider and contains(@class, 'slider') and contains(@class, 'imovel-slider')]")" == 1 ]] \
    || fail "slider fora da caixa 4:3 da foto" || return 1
  [[ "$(xpath_count "//h1[preceding-sibling::div[@class='imovel-midia']]")" == 1 ]] \
    || fail "slider nao vem antes do titulo, na mesma coluna" || return 1
  [[ "$(xpath_count "//ul")" == 1 ]] || fail "sobrou outra lista de fotos (grade)"
}

test_galeria_uma_foto() {
  app_harness || return 1
  app_png "${T}/a.png" 40 30
  app_anunciar -F "fotos[]=@${T}/a.png"
  code_is 303 "anunciar 1 foto" || return 1
  app_req GET "/imoveis/${ID}"
  [[ "$(slides)" == "/uploads/${ID}/$(capa_de "${ID}").webp|Foto principal de Com fotos|" ]] || fail "slide unico: $(slides)" || return 1
  ! grep -qE 'slider-(anterior|proxima|contador)' "${T}/page.html" || fail "controles com 1 foto"
}

test_galeria_capa_ausente() {
  app_harness || return 1
  app_png "${T}/a.png" 40 30
  app_png "${T}/b.png" 41 30
  app_anunciar -F "fotos[]=@${T}/a.png" -F "fotos[]=@${T}/b.png"
  code_is 303 "anunciar 2 fotos" || return 1
  local capa outra
  capa="$(capa_de "${ID}")"
  outra="$(foto_n "${ID}" 1)"
  [[ "${outra}" == "${capa}" ]] && outra="$(foto_n "${ID}" 2)"
  rm "${T}/w/storage/uploads/${ID}/${capa}.webp" "${T}/w/storage/uploads/${ID}/${capa}_thumb.webp"
  app_req GET "/imoveis/${ID}"
  [[ "$(slides)" == "$(printf 'thumb\n/uploads/%s/%s.webp|Foto 2 de Com fotos|lazy' "${ID}" "${outra}")" ]] || fail "slides: $(slides | tr '\n' ' ')"
}

test_galeria_sem_fotos() {
  app_harness || return 1
  app_req GET /imoveis/1
  code_is 200 "detalhe sem fotos" || return 1
  grep -q 'class="thumb ' "${T}/page.html" || fail "sem o desenho do tipo" || return 1
  ! grep -qE 'data-slider|slider-slide|slider-anterior|slider\.js' "${T}/page.html" || fail "slider ou slider.js sem fotos"
}

test_slider_assets() {
  galeria_3 || return 1
  local tres="${ID}" uma p
  app_png "${T}/d.png" 43 30
  app_anunciar -F "fotos[]=@${T}/d.png"
  uma="${ID}"
  for p in "/imoveis/${tres}" "/imoveis/${uma}"; do
    app_req GET "${p}"
    [[ "$(grep -c 'src="/assets/js/slider.js"' "${T}/page.html")" -eq 1 ]] || fail "${p} sem slider.js" || return 1
  done
  for p in / /imoveis/novo "/imoveis/${tres}/editar" /imoveis/1; do
    app_req GET "${p}"
    ! grep -qF 'slider.js' "${T}/page.html" || fail "${p} carrega o slider.js" || return 1
  done
  app_req GET /assets/js/slider.js
  code_is 200 "slider.js servido" || return 1
  app_req GET /assets/js/galeria.js
  code_is 404 "galeria.js ainda servido"
}

test_slider_sem_terceiros() {
  local pat="swi""per" achou
  [[ ! -e "${APP}/public/assets/vendor" && ! -e "${APP}/public/assets/js/galeria.js" ]] || fail "sobrou vendor/ ou galeria.js" || return 1
  achou="$(grep -rliI "${pat}" "${APP}" "${PROJECT_DIR}/tests" --exclude-dir=node_modules --exclude-dir=vendor --exclude=composer.lock)"
  [[ -z "${achou}" ]] || fail "ainda cita ${pat}:" "${achou}"
}

test_slider_lib() {
  local js="${APP}/public/assets/js/slider.js"
  [[ -f "${js}" ]] || fail "slider.js ausente" || return 1
  [[ "$(wc -l <"${js}")" -le 200 ]] || fail "slider.js com $(wc -l <"${js}") linhas (maximo 200)" || return 1
  ! grep -qE '\bimport\b|\brequire\(|https?://|fetch\(' "${js}" || fail "slider.js com dependencia externa" || return 1
  [[ "$(grep -oE 'window\.[A-Za-z]+ =' "${js}" | sort -u)" == "window.LarCertoSlider =" ]] || fail "slider.js cria outro global" || return 1
  [[ "$(grep -c '^})();$' "${js}")" -eq 1 && "$(head -3 "${js}" | grep -c '^(function () {$')" -eq 1 ]] || fail "slider.js fora de uma IIFE"
}

test_slider_a11y() {
  galeria_3 || return 1
  app_req GET "/imoveis/${ID}"
  [[ "$(xpath_count "//*[@data-slider and @aria-roledescription='carrossel' and @aria-label='Fotos de Com fotos']")" == 1 ]] \
    || fail "slider sem aria-roledescription/aria-label" || return 1
  local k
  for k in 1 2 3; do
    [[ "$(xpath_count "//li[contains(@class, 'slider-slide') and @aria-label='Foto ${k} de 3']")" == 1 ]] || fail "slide ${k} sem aria-label" || return 1
  done
  [[ "$(xpath_count "//*[contains(@class, 'slider-contador') and @aria-live='polite' and normalize-space(.)='1 / 3']")" == 1 ]] \
    || fail "contador sem aria-live ou sem 1 / 3" || return 1
  [[ "$(xpath_count "//button[contains(@class, 'slider-anterior') and @aria-label='Foto anterior']")" == 1 ]] \
    && [[ "$(xpath_count "//button[contains(@class, 'slider-proxima') and @aria-label='Próxima foto']")" == 1 ]] \
    || fail "botoes sem rotulo"
}

test_slider_navegador() {
  galeria_3 || return 1
  BASE="${BASE}" ID="${ID}" W="${T}/w" pw_run <<'PY' >&2 || fail "slider no navegador"
fotos_reais(os.environ["W"] + "/storage/uploads/" + os.environ["ID"])
url = BASE + "/imoveis/" + os.environ["ID"]
erros = []

def abrir(ctx):
    pg = ctx.new_page()
    pg.on("pageerror", lambda e: erros.append(str(e)))
    pg.on("console", lambda m: m.type == "error" and erros.append(m.text))
    pg.goto(url)
    pg.wait_for_selector(".slider-pronto")
    return pg

def estado(pg):
    return pg.evaluate("""() => [document.querySelector('.slider-contador').textContent.trim(),
        document.querySelector('.slider-anterior').disabled, document.querySelector('.slider-proxima').disabled]""")

def esperar(pg, texto):
    pg.wait_for_function("(t) => document.querySelector('.slider-contador').textContent.trim() === t", arg=texto)

ctx = browser.new_context(viewport={"width": 1280, "height": 900})
pg = abrir(ctx)
assert pg.locator(".slider-slide").count() == 3
assert estado(pg) == ["1 / 3", True, False], estado(pg)
pg.click(".slider-proxima"); esperar(pg, "2 / 3")
pg.focus("[data-slider]"); pg.keyboard.press("ArrowRight"); esperar(pg, "3 / 3")
assert estado(pg) == ["3 / 3", False, True], estado(pg)
caixa = pg.locator("[data-slider]").bounding_box()
cx, cy = caixa["x"] + caixa["width"] / 2, caixa["y"] + caixa["height"] / 2
def arrastar(dx):
    pg.mouse.move(cx, cy); pg.mouse.down(); pg.mouse.move(cx + dx / 2, cy, steps=4); pg.mouse.move(cx + dx, cy, steps=4); pg.mouse.up()
# sem loop: no ultimo slide, tecla e arrasto para a esquerda nao voltam ao primeiro
pg.keyboard.press("ArrowRight"); arrastar(-120); pg.wait_for_timeout(400)
assert estado(pg) == ["3 / 3", False, True], ("voltou ao inicio depois do ultimo", estado(pg))
pg.keyboard.press("ArrowLeft"); esperar(pg, "2 / 3")
# limiar de 50 px: 40 e 50 nao mudam, 60 muda (nos dois sentidos)
for dx in (-40, -50, 40, 50):
    arrastar(dx); pg.wait_for_timeout(400)
    assert estado(pg)[0] == "2 / 3", f"arrasto de {dx} px mudou o slide"
arrastar(-60); esperar(pg, "3 / 3")
arrastar(60); esperar(pg, "2 / 3")
pg.wait_for_timeout(400)
img = pg.locator(".slider-slide").nth(1).bounding_box()
assert abs(img["x"] - caixa["x"]) < 1, ("slide 2 fora da caixa", img, caixa)
quebradas = pg.evaluate("[...document.querySelectorAll('.slider-slide img')].filter((i) => i.complete && i.naturalWidth === 0).length")
assert quebradas == 0, f"{quebradas} imagem(ns) quebrada(s)"

# toque: eventos de toque reais pelo CDP (o navegador gera os pointer events)
tctx = browser.new_context(viewport={"width": 390, "height": 844}, has_touch=True, is_mobile=True)
tp = abrir(tctx)
cdp = tctx.new_cdp_session(tp)
b = tp.locator("[data-slider]").bounding_box()
x, y = b["x"] + b["width"] * 0.8, b["y"] + b["height"] / 2
cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x, "y": y}]})
for k in range(1, 9):
    cdp.send("Input.dispatchTouchEvent", {"type": "touchMove", "touchPoints": [{"x": x - 20 * k, "y": y}]})
cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
tp.wait_for_function("document.querySelector('.slider-contador').textContent.trim() === '2 / 3'")
assert not erros, erros
print("slider ok:", estado(pg), "toque:", tp.evaluate("document.querySelector('.slider-contador').textContent"))
PY
}

test_galeria_no_js() {
  galeria_3 || return 1
  BASE="${BASE}" ID="${ID}" pw_run <<'PY' >&2 || fail "slider sem JS"
page = browser.new_context(java_script_enabled=False, viewport={"width": 1280, "height": 900}).new_page()
page.goto(BASE + "/imoveis/" + os.environ["ID"])
caixa = page.locator("[data-slider]").bounding_box()
imgs = page.locator(".slider-slide img")
um, dois = imgs.nth(0).bounding_box(), imgs.nth(1).bounding_box()
assert caixa and um and dois, (caixa, um, dois)
assert abs(um["x"] - caixa["x"]) < 1 and abs(um["width"] - caixa["width"]) < 1, (caixa, um)
assert abs(caixa["height"] - caixa["width"] * 3 / 4) < 1, ("caixa fora de 4:3", caixa)
assert dois["x"] >= caixa["x"] + caixa["width"] - 1, (caixa, dois)
for sel in (".slider-anterior", ".slider-proxima", ".slider-contador"):
    assert not page.locator(sel).is_visible(), sel + " visivel sem JS"
page.mouse.move(caixa["x"] + caixa["width"] / 2, caixa["y"] + caixa["height"] / 2)
page.mouse.wheel(caixa["width"], 0)
page.wait_for_timeout(600)
dois = imgs.nth(1).bounding_box()
assert abs(dois["x"] - caixa["x"]) < 2, ("rolagem horizontal nao trouxe a 2a foto", caixa, dois)
print("sem JS ok")
PY
}

test_ansible_web_sem_slider_antigo() {
  local r="${PROJECT_DIR}/ansible/roles/web/tasks/main.yml" bloco
  bloco="$(sed -n '/name: Tirar da VM os arquivos de versoes antigas/,/^- name:/p' "${r}")"
  grep -q 'state: absent' <<<"${bloco}" || fail "limpeza sem state: absent" || return 1
  grep -q 'public/assets/vendor' <<<"${bloco}" && grep -q 'public/assets/js/galeria.js' <<<"${bloco}" \
    || fail "limpeza nao tira vendor/ e galeria.js da VM" || return 1
  grep -q 'loop: \[public, backend, frontend/views\]' "${r}" || fail "papel web nao copia public/ inteiro"
}

test_docs_sem_frameworks() {
  local pat="tail""wind|swi""per" f
  for f in "${APP}/README.md" "${PROJECT_DIR}/README.md"; do
    ! grep -qiE "${pat}" "${f}" || fail "${f} ainda cita ${pat}" || return 1
  done
  ! grep -qiE "${pat}" "${PROJECT_DIR}/../TASKS.md" || fail "TASKS.md ainda cita ${pat}" || return 1
  grep -qF 'public/assets/js/slider.js' "${APP}/README.md" && grep -qF 'CSS puro' "${APP}/README.md" || fail "README da app sem o CSS/slider novos"
}

# ---------------------------------------------------------------- formulario de fotos

# galeria_form_2: anuncia com 2 fotos e capa na segunda; id em $ID
galeria_form_2() {
  app_harness || return 1
  app_png "${T}/a.png" 40 30
  app_png "${T}/b.png" 41 30
  app_anunciar -F "fotos[]=@${T}/a.png" -F "fotos[]=@${T}/b.png" --form-string capa=n:1
  code_is 303 "anunciar 2 fotos"
}

test_galeria_form_markup() {
  galeria_form_2 || return 1
  local id="${ID}" capa outra
  capa="$(capa_de "${id}")"
  outra="$(foto_n "${id}" 1)"
  [[ "${outra}" == "${capa}" ]] && outra="$(foto_n "${id}" 2)"
  app_req GET "/imoveis/${id}/editar"
  code_is 200 "editar" || return 1
  local f1="//div[@id='previa-fotos']/figure[1]" f2="//div[@id='previa-fotos']/figure[2]"
  [[ "$(xpath_count "//div[@id='previa-fotos']/p[normalize-space(.)='Capa']")" == 1 ]] || fail "sem o titulo Capa" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/p[normalize-space(.)='Galeria do anúncio (1)']")" == 1 ]] || fail "sem o titulo da galeria com 1 foto" || return 1
  [[ "$(xpath_count "${f1}/figcaption//input[@name='capa' and @value='h:${capa}' and @checked]")" == 1 ]] || fail "a capa nao e a primeira figura, marcada" || return 1
  [[ "$(xpath_count "${f2}/figcaption//input[@name='capa' and @value='h:${outra}' and not(@checked)]")" == 1 ]] || fail "galeria sem o radio da outra foto" || return 1
  [[ "$(xpath_count "${f2}/figcaption//input[@name='remover[]' and @value='${outra}']")" == 1 ]] || fail "galeria sem o remover da outra" || return 1
  [[ "$(xpath_count "${f2}//label[contains(., 'Usar como capa')]")" == 1 ]] || fail "galeria sem Usar como capa" || return 1
  [[ "$(xpath_count "${f1}//label[contains(., 'Usar como capa')]")" == 0 ]] || fail "capa com Usar como capa" || return 1
  [[ "$(xpath_count "${f1}/figcaption//input[@name='capa' and contains(@class, 'so-leitor')]")" == 1 ]] || fail "radio da capa visivel" || return 1
  [[ "$(xpath_count "${f1}/figcaption//input[@name='remover[]' and @value='${capa}']")" == 1 ]] || fail "capa sem o Remover" || return 1
  # ordem: Capa, foto da capa, Galeria do anuncio (1), foto da galeria
  [[ "$(xpath_count "//div[@id='previa-fotos']/*[1][self::p and normalize-space(.)='Capa']")" == 1 ]] || fail "Capa nao e o primeiro bloco" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/*[2][self::figure]/img[@alt='Capa do anúncio']")" == 1 ]] || fail "foto da capa sem alt Capa do anúncio" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/*[3][self::p and normalize-space(.)='Galeria do anúncio (1)']")" == 1 ]] || fail "titulo da galeria fora de ordem" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/*[4][self::figure]/figcaption//input[@value='h:${outra}']")" == 1 ]] || fail "galeria fora de ordem" || return 1
}

test_galeria_form_uma_foto() {
  app_harness || return 1
  app_png "${T}/a.png" 40 30
  app_anunciar -F "fotos[]=@${T}/a.png"
  code_is 303 "anunciar 1 foto" || return 1
  app_req GET "/imoveis/${ID}/editar"
  code_is 200 "editar" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/p[normalize-space(.)='Capa']")" == 1 ]] || fail "uma foto sem o titulo Capa" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/p[contains(., 'Galeria do anúncio')]")" == 0 ]] || fail "uma foto com titulo de galeria" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/figure")" == 1 ]] || fail "uma foto sem exatamente uma figura" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/figure/figcaption//input[@name='remover[]']")" == 1 ]] || fail "uma foto sem o Remover" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/figure/figcaption//input[@name='capa' and @checked]")" == 1 ]] || fail "uma foto sem o radio da capa marcado" || return 1
}

test_galeria_form_ordem() {
  galeria_3 || return 1
  local id="${ID}" capa n nome esperado=() obtido
  capa="$(capa_de "${id}")"
  for n in 1 2 3; do
    nome="$(foto_n "${id}" "${n}")"
    [[ "${nome}" == "${capa}" ]] || esperado+=("h:${nome}")
  done
  app_req GET "/imoveis/${id}/editar"
  obtido="$("${REAL_PHP}" -r '
    $d = new DOMDocument(); libxml_use_internal_errors(true);
    $d->loadHTML(mb_encode_numericentity(file_get_contents($argv[1]), [0x80, 0x10FFFF, 0, 0x1FFFFF], "UTF-8"));
    foreach ((new DOMXPath($d))->query("//div[@id=\"previa-fotos\"]/figure[@data-papel=\"galeria\"]//input[@name=\"capa\"]") as $r) { echo $r->getAttribute("value"), "\n"; }' "${T}/page.html")"
  [[ "${obtido}" == "$(printf '%s\n' "${esperado[@]}")" ]] || fail "galeria fora da ordem de nome: ${obtido}"
}

test_galeria_form_sem_fotos() {
  app_harness || return 1
  app_req GET /imoveis/novo
  code_is 200 "novo" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/p[normalize-space(.)='Nenhuma foto ainda']")" == 1 ]] || fail "novo sem o aviso de nenhuma foto" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/p[normalize-space(.)='Galeria do anúncio']")" == 0 ]] || fail "novo com titulo de galeria" || return 1
  app_anunciar
  code_is 303 "anunciar sem fotos" || return 1
  app_req GET "/imoveis/${ID}/editar"
  [[ "$(xpath_count "//div[@id='previa-fotos']/p[normalize-space(.)='Nenhuma foto ainda']")" == 1 ]] || fail "editar sem fotos sem o aviso" || return 1
  [[ "$(xpath_count "//div[@id='previa-fotos']/p[contains(., 'Galeria do anúncio')]")" == 0 ]] || fail "editar sem fotos com galeria"
}

test_galeria_form_no_js() {
  local py="${PW_PYTHON}"
  [[ -x "${py}" ]] && "${py}" -c 'import playwright' 2>/dev/null || fail "Playwright ausente em ${py} (python3 -m venv .venv && .venv/bin/pip install playwright)" || return 1
  galeria_form_2 || return 1
  BASE="${BASE}" ID="${ID}" "${py}" - <<'PY' >&2 || fail "formulario sem JS"
import glob, os
from playwright.sync_api import Error, sync_playwright

with sync_playwright() as p:
    try:
        browser = p.chromium.launch()
    except Error:
        cache = sorted(glob.glob(os.path.expanduser("~/.cache/ms-playwright/chromium-*/chrome-linux*/chrome")))
        assert cache, "nenhum Chromium do Playwright no cache"
        browser = p.chromium.launch(executable_path=cache[-1])
    page = browser.new_context(java_script_enabled=False).new_page()
    page.goto(os.environ["BASE"] + "/imoveis/" + os.environ["ID"] + "/editar")
    figuras = page.locator("#previa-fotos > figure")
    assert figuras.count() == 2, "sem as duas fotos"
    assert figuras.nth(0).locator("input[name=capa]").is_checked(), "capa nao marcada"
    outra = figuras.nth(1).locator("input[name=capa]")
    assert outra.count() == 1 and not outra.is_checked(), "galeria sem o radio"
    assert figuras.nth(1).get_by_text("Usar como capa").is_visible(), "sem o texto Usar como capa"
    valor = outra.get_attribute("value")
    outra.check()
    page.click('form button[type="submit"]')
    page.wait_for_url(lambda u: "/editar" not in u)
    primeira = page.locator("[data-slider] .slider-slide img").first.get_attribute("src")
    assert primeira.endswith("/" + valor[2:] + ".webp"), (primeira, valor)
    browser.close()
PY
}

# ---------------------------------------------------------------- comentarios da app

APP_COMMENTS="${PROJECT_DIR}/tests/app_comments.py"

test_app_comments_english() {
  local bad n
  bad="$("${REAL_PY}" "${APP_COMMENTS}" pt)" || { fail "comentarios em portugues:" "${bad}"; return 1; }
  # O detector enxerga cada sintaxe de comentario: um comentario em portugues por tipo de arquivo.
  local d="${T}/app"
  mkdir -p "${d}"
  printf '<?php\n// Confere a foto antes de gravar.\necho 1;\n' >"${d}/a.php"
  printf 'let x = 1; // valida o campo do formulario\n' >"${d}/b.js"
  printf '/* Cores da pagina */\nbody { color: red; }\n' >"${d}/c.css"
  printf -- '-- Tabela unica da app\nSELECT 1;\n' >"${d}/d.sql"
  printf 'services:\n  web:   # sobe o servico da app\n    image: x\n' >"${d}/compose.yml"
  printf '; Limite das fotos\nmemory_limit = 1M\n' >"${d}/e.ini"
  printf '#!/usr/bin/env bash\n# Gera o CSS sem Node\ntrue\n' >"${d}/f.sh"
  n="$(APP_DIR="${d}" "${REAL_PY}" "${APP_COMMENTS}" pt | cut -d: -f1 | sort -u | wc -l)"
  [[ "${n}" -eq 7 ]] || fail "detector achou ${n} de 7 arquivos com comentario em portugues"
}

test_app_comments_lean() {
  local list n
  list="$("${REAL_PY}" "${APP_COMMENTS}" list)" || { fail "app_comments.py list falhou"; return 1; }
  n="$(grep -c . <<<"${list}")"
  [[ "${n}" -le 60 ]] || fail "${n} linhas de comentario (maximo 60)" || return 1
  ! grep -iE '\bspec\b|\bporta [0-9]|criterio|@param|@return|@var' <<<"${list}" \
    || fail "comentario com rastreabilidade ou docblock de tipo"
}

# ---------------------------------------------------------------- run.sh da app

APPRUN_SECRET_LOCAL="0123456789abcdef0123456789abcdef"
APPRUN_SECRET_SERVER="S3gredo-do-servidor"

# apprun_sandbox local|server: copia do run.sh + sql/, com docker, mariadb, systemctl e tail falsos.
# O banco falso guarda a contagem de imoveis em ${T}/count; o SQL recebido por stdin vira
# "STDIN schema|seed|outro" no log, e a senha recebida por MYSQL_PWD vai para ${T}/env.log.
apprun_sandbox() {
  local a="${T}/app"
  mkdir -p "${a}/sql" "${a}/storage/uploads/7" "${T}/apache"
  cp "${APP}/run.sh" "${a}/"
  cp "${APP}/sql/01-schema.sql" "${APP}/sql/02-seed.sql" "${a}/sql/"
  : >"${a}/storage/uploads/7/foto.webp"
  echo 22 >"${T}/count"
  : >"${T}/env.log"
  if [[ "$1" == local ]]; then
    : >"${a}/compose.yml"
  else
    printf '%s\n' '<?php' 'return [' \
      "    'dsn'      => 'mysql:host=db.larcerto.com.br;dbname=larcerto;charset=utf8mb4'," \
      "    'user'     => 'larcerto'," "    'password' => '${APPRUN_SECRET_SERVER}'," '];' >"${a}/config.php"
  fi
  local banco='
case "$*" in
  *"SELECT COUNT(*) FROM imoveis"*) cat "$FAKE_DIR/count"; exit 0 ;;
  *"SELECT 1"*) echo 1; exit 0 ;;
  *"DROP TABLE IF EXISTS imoveis"*) echo 0 >"$FAKE_DIR/count"; exit 0 ;;
esac
if [[ "$*" == *" -T "* || "$1" != compose ]] && [[ ! -t 0 ]]; then
  sql="$(cat)"
  if grep -q "INSERT INTO imoveis" <<<"$sql"; then echo "STDIN seed" >>"$FAKE_LOG"; echo 22 >"$FAKE_DIR/count"
  elif grep -q "CREATE TABLE" <<<"$sql"; then echo "STDIN schema" >>"$FAKE_LOG"
  elif [[ -n "$sql" ]]; then echo "STDIN outro" >>"$FAKE_LOG"; fi
fi
exit 0'
  fake docker 'echo "docker $*" >>"$FAKE_LOG"'"${banco}"
  fake mariadb 'echo "mariadb $*" >>"$FAKE_LOG"; echo "MYSQL_PWD=${MYSQL_PWD:-}" >>"$FAKE_DIR/env.log"'"${banco}"
  fake systemctl '
echo "systemctl $*" >>"$FAKE_LOG"
if [[ "$1" == is-active ]]; then
  if [[ -f "$FAKE_DIR/apache_active" ]]; then echo active; exit 0; fi
  echo inactive; exit 3
fi'
  fake tail 'echo "tail $*" >>"$FAKE_LOG"'
}

# apprun [--in <texto>] <args do run.sh>
apprun() {
  local entrada=""
  [[ "${1:-}" == --in ]] && { entrada="$2"; shift 2; }
  FAKE_LOG="${T}/log" FAKE_DIR="${T}" APACHE_LOG_DIR="${T}/apache" PATH="${T}/bin:${PATH}" \
    "${REAL_BASH}" "${T}/app/run.sh" "$@" <<<"${entrada}" >"${T}/out" 2>"${T}/err"
  RC=$?
}

# linha do primeiro registro que casa com o padrao (0 = ausente)
log_line() { grep -nF -- "$1" "${T}/log" | head -1 | cut -d: -f1 || true; }
in_order() {
  local prev=0 n p
  for p in "$@"; do
    n="$(log_line "${p}")"
    [[ -n "${n}" && "${n}" -gt "${prev}" ]] || { fail "fora de ordem ou ausente: ${p}"; return 1; }
    prev="${n}"
  done
}

test_apprun_help() {
  "${REAL_BASH}" -n "${APP}/run.sh" || fail "bash -n" || return 1
  apprun_sandbox local
  apprun help
  expect_rc 0 || return 1
  local c
  for c in setup up down ps logs restart db:populate db:reset db:console check; do
    grep -qE "^  ${c}( |$)" "${T}/out" || fail "help sem ${c}" || return 1
  done
  apprun
  expect_rc 0 || return 1
  grep -q '^Uso: ./run.sh' "${T}/out" || fail "sem argumento nao mostra a ajuda" || return 1
  apprun comando-que-nao-existe
  expect_rc 2
}

test_apprun_setup() {
  apprun_sandbox local
  echo 0 >"${T}/count"
  apprun setup
  expect_rc 0 || return 1
  local env="${T}/app/.env"
  grep -qxE 'DB_PASSWORD=[0-9a-f]{32}' "${env}" || fail ".env sem senha de 32 hex" || return 1
  ! grep -q 'troque-esta-senha-local' "${env}" || fail ".env com o placeholder" || return 1
  [[ "$(stat -c %a "${env}")" == 600 ]] || fail ".env nao e 600" || return 1
  in_order 'docker build --network host -t larcerto-web '"${T}"'/app' 'compose -f '"${T}"'/app/compose.yml up -d --no-build --wait' 'SELECT COUNT(*) FROM imoveis' 'STDIN seed' || return 1
  grep -q '127.0.0.1:8088' "${T}/out" || fail "setup nao mostra o endereco" || return 1
  local antes
  antes="$(sha256sum <"${env}")"
  : >"${T}/log"
  apprun setup
  expect_rc 0 || return 1
  [[ "$(sha256sum <"${env}")" == "${antes}" ]] || fail "setup mudou o .env existente" || return 1
  ! grep -q 'STDIN seed' "${T}/log" || fail "setup repetido duplicou a semente"
}

test_apprun_populate_only_empty() {
  local modo
  for modo in local server; do
    rm -rf "${T}/app"; : >"${T}/log"
    apprun_sandbox "${modo}"
    apprun db:populate
    expect_rc 0 || return 1
    ! grep -q 'STDIN' "${T}/log" || fail "${modo}: mandou SQL com 22 imoveis" || return 1
    grep -q 'já tem 22' "${T}/out" || fail "${modo}: nao avisou" || return 1
    echo 0 >"${T}/count"
    apprun db:populate
    expect_rc 0 || return 1
    grep -qx 'STDIN seed' "${T}/log" || fail "${modo}: tabela vazia sem semente" || return 1
    grep -q 'populado: 22' "${T}/out" || fail "${modo}: sem a contagem final" || return 1
  done
}

test_apprun_reset_confirm() {
  local r
  apprun_sandbox local
  for r in n "" sim; do
    apprun --in "${r}" db:reset
    expect_rc 0 || return 1
    ! grep -q 'down -v' "${T}/log" || fail "local: apagou com a resposta '${r}'" || return 1
  done
  apprun db:reset --yes
  expect_rc 0 || return 1
  in_order 'compose -f '"${T}"'/app/compose.yml down -v' 'docker build --network host' 'up -d --no-build --wait' || return 1
  : >"${T}/log"
  apprun --in s db:reset
  grep -q 'down -v' "${T}/log" || fail "local: 's' nao confirmou" || return 1

  rm -rf "${T}/app"; : >"${T}/log"
  apprun_sandbox server
  apprun --in n db:reset
  expect_rc 0 || return 1
  ! grep -q 'DROP TABLE' "${T}/log" || fail "servidor: apagou sem confirmar" || return 1
  [[ -f "${T}/app/storage/uploads/7/foto.webp" ]] || fail "servidor: apagou fotos sem confirmar" || return 1
  apprun db:reset --yes
  expect_rc 0 || return 1
  in_order 'DROP TABLE IF EXISTS imoveis' 'STDIN schema' 'STDIN seed' || return 1
  [[ -d "${T}/app/storage/uploads" && -z "$(ls -A "${T}/app/storage/uploads")" ]] || fail "servidor: fotos nao apagadas"
}

test_apprun_no_password_echo() {
  apprun_sandbox local
  printf 'DB_PASSWORD=%s\n' "${APPRUN_SECRET_LOCAL}" >"${T}/app/.env"
  local c
  for c in setup db:populate db:console ps; do
    apprun "${c}"
    expect_rc 0 || return 1
  done
  ! grep -qF "${APPRUN_SECRET_LOCAL}" "${T}/log" "${T}/out" "${T}/err" || fail "local: senha em argumento ou saida" || return 1
  grep -qF 'MYSQL_PWD="$MARIADB_PASSWORD"' "${T}/log" || fail "local: cliente sem a senha do container" || return 1

  rm -rf "${T}/app"; : >"${T}/log"
  apprun_sandbox server
  touch "${T}/apache_active"
  for c in setup db:populate db:console ps; do
    apprun "${c}"
    expect_rc 0 || return 1
    ! grep -qF "${APPRUN_SECRET_SERVER}" "${T}/out" "${T}/err" || fail "servidor: senha na saida de ${c}" || return 1
  done
  ! grep -qF "${APPRUN_SECRET_SERVER}" "${T}/log" || fail "servidor: senha nos argumentos" || return 1
  local chamadas
  chamadas="$(grep -c '^mariadb ' "${T}/log")"
  [[ "${chamadas}" -ge 4 && "$(grep -cxF "MYSQL_PWD=${APPRUN_SECRET_SERVER}" "${T}/env.log")" -eq "${chamadas}" ]] \
    || fail "servidor: nem toda chamada recebeu MYSQL_PWD"
}

test_apprun_mode_detect() {
  apprun_sandbox local
  apprun ps
  grep -q '^docker compose' "${T}/log" || fail "com compose.yml nao usou o docker" || return 1

  rm -rf "${T}/app"; : >"${T}/log"
  apprun_sandbox server
  apprun ps
  expect_rc 0 || return 1
  ! grep -q '^docker' "${T}/log" && grep -q '^mariadb ' "${T}/log" || fail "sem compose.yml usou o docker" || return 1

  : >"${T}/log"
  : >"${T}/app/compose.yml"
  LARCERTO_MODE=server apprun ps
  ! grep -q '^docker' "${T}/log" || fail "LARCERTO_MODE=server usou o docker" || return 1
  rm "${T}/app/compose.yml"
  LARCERTO_MODE=local apprun ps
  grep -q '^docker compose' "${T}/log" || fail "LARCERTO_MODE=local nao usou o docker" || return 1
  LARCERTO_MODE=nuvem apprun ps
  expect_rc 1
}

test_apprun_server_setup() {
  apprun_sandbox server
  echo 0 >"${T}/count"
  apprun setup
  expect_rc 0 || return 1
  in_order 'STDIN schema' 'SELECT COUNT(*) FROM imoveis' 'STDIN seed' 'systemctl is-active --quiet apache2' 'systemctl start apache2' || return 1
  grep -q -- '-h db.larcerto.com.br -u larcerto larcerto' "${T}/log" || fail "nao usou host/usuario/banco do config.php" || return 1
  grep -q 'https://larcerto.com.br' "${T}/out" || fail "setup nao mostra o endereco" || return 1
  : >"${T}/log"; touch "${T}/apache_active"
  apprun setup
  expect_rc 0 || return 1
  ! grep -q 'systemctl start' "${T}/log" || fail "iniciou o Apache ja ativo" || return 1
  chmod 000 "${T}/app/config.php"
  apprun setup
  expect_rc 1 || return 1
  grep -q 'sudo' "${T}/err" || fail "config.php ilegivel sem pedir sudo"
}

test_apprun_server_commands() {
  apprun_sandbox server
  local c
  for c in up:start down:stop restart:restart; do
    : >"${T}/log"
    apprun "${c%%:*}"
    expect_rc 0 || return 1
    grep -qx "systemctl ${c##*:} apache2" "${T}/log" || fail "${c%%:*} nao chamou systemctl ${c##*:}" || return 1
  done
  apprun logs
  grep -qx "tail -n 100 ${T}/apache/larcerto-error.log" "${T}/log" || fail "logs sem o larcerto-error.log" || return 1
  apprun logs -f
  grep -qx "tail -f ${T}/apache/larcerto-error.log" "${T}/log" || fail "logs -f" || return 1
  for c in css check; do
    apprun "${c}"
    expect_rc 2 || return 1
  done
  ! grep -q '^docker' "${T}/log" || fail "servidor chamou o docker"
}

test_apprun_ansible_web() {
  local r="${PROJECT_DIR}/ansible/roles/web/tasks/main.yml" t
  t="$(sed -n '/name: Cliente do MariaDB/,/^$/p' "${r}")"
  grep -qx '    name: \[mariadb-client, php8.4-cli\]' <<<"${t}" || fail "sem mariadb-client e php8.4-cli" || return 1
  t="$(sed -n '/name: run.sh da app/,/^$/p' "${r}")"
  grep -qF 'src: "{{ playbook_dir }}/../app/run.sh"' <<<"${t}" && grep -qx '    dest: /var/www/larcerto/run.sh' <<<"${t}" \
    && grep -qx '    owner: root' <<<"${t}" && grep -qx '    mode: "0755"' <<<"${t}" || fail "run.sh na VM (root, 0755)" || return 1
  t="$(sed -n '/name: SQL da app/,/^$/p' "${r}")"
  grep -qF 'src: "{{ playbook_dir }}/../app/sql/"' <<<"${t}" && grep -qx '    dest: /var/www/larcerto/sql/' <<<"${t}" \
    || fail "sql/ na VM" || return 1
  ! grep -q 'compose.yml' "${r}" || fail "papel web cita compose.yml (o modo servidor depende de ele faltar)"
}

test_apprun_documented() {
  local r="${APP}/README.md" c
  grep -q '^\./app/run.sh setup\|^bash app/run.sh setup\|^\./run.sh setup' "${r}" || fail "README sem ./run.sh setup" || return 1
  for c in setup up down restart ps logs db:populate db:reset db:console check phpstan test:browser test composer; do
    grep -qE "^\| \`${c}( |\`)" "${r}" || fail "README sem ${c} na tabela" || return 1
  done
  grep -q 'sudo /var/www/larcerto/run.sh' "${r}" || fail "README sem o uso na VM" || return 1
  grep -q 'run.sh' "${PROJECT_DIR}/docs/nuvem-larcerto.md" || fail "nuvem-larcerto.md sem o run.sh"
}

# ---------------------------------------------------------------- PHPStan e E2E

# sandbox local com o projeto de testes ao lado (../tests/app), como no repo
apprun_qa_sandbox() {
  apprun_sandbox local
  mkdir -p "${T}/tests/app"
  : >"${T}/tests/app/Dockerfile"
}

test_apprun_test_order() {
  apprun_qa_sandbox
  apprun test
  expect_rc 0 || return 1
  in_order 'docker build -q --network host --label larcerto.dockerfile=' 'vendor/bin/phpstan analyse' \
    'docker build --network host -t larcerto-web' 'vendor/bin/pest' || return 1
  grep -q -- '--network none .*vendor/bin/phpstan analyse' "${T}/log" || fail "phpstan com rede" || return 1
  grep -q -- '--network host .*APP_URL=http://127.0.0.1:8088 .*vendor/bin/pest' "${T}/log" || fail "pest sem host/APP_URL" || return 1
  # imagem com o label do Dockerfile atual: nao reconstroi
  local hash
  hash="$(sha256sum "${T}/tests/app/Dockerfile" | cut -d' ' -f1)"
  sed -i "2i [[ \"\$1 \$2\" == 'image inspect' ]] \&\& { echo ${hash}; exit 0; }" "${T}/bin/docker"
  : >"${T}/log"
  apprun phpstan
  expect_rc 0 || return 1
  ! grep -q 'larcerto.dockerfile=' "${T}/log" || fail "reconstruiu a imagem em dia" || return 1
  : >"${T}/log"
  : >"${T}/phpstan_fail"
  sed -i '2i [[ "$*" == *phpstan* && -f "$FAKE_DIR/phpstan_fail" ]] && { echo "docker $*" >>"$FAKE_LOG"; exit 1; }' "${T}/bin/docker"
  apprun test
  [[ "${RC}" -ne 0 ]] || fail "test saiu 0 com o phpstan falhando" || return 1
  grep -q 'vendor/bin/phpstan analyse' "${T}/log" || fail "phpstan nao rodou" || return 1
  ! grep -q 'vendor/bin/pest' "${T}/log" || fail "rodou o pest com o phpstan falhando"
}

test_apprun_qa_server() {
  local c
  apprun_sandbox server
  for c in composer phpstan test test:browser; do
    : >"${T}/log"
    apprun "${c}"
    expect_rc 2 || return 1
    grep -q 'só funciona no local' "${T}/err" || fail "${c}: sem aviso" || return 1
    ! grep -q '^docker' "${T}/log" || fail "${c}: chamou o docker no servidor" || return 1
  done
}

test_apprun_local_schema() {
  apprun_sandbox local
  apprun up
  expect_rc 0 || return 1
  in_order 'compose -f '"${T}"'/app/compose.yml up -d --no-build --wait' 'STDIN schema'
}

test_qa_playwright_version() {
  local qa="${PROJECT_DIR}/tests/app" d p l
  d="$(sed -n 's/^ARG PLAYWRIGHT_VERSION=//p' "${qa}/Dockerfile")"
  p="$("${REAL_PY}" -c 'import json,sys; print(json.load(open(sys.argv[1]))["devDependencies"]["playwright"])' "${qa}/package.json")"
  l="$("${REAL_PY}" -c 'import json,sys; print(json.load(open(sys.argv[1]))["packages"]["node_modules/playwright"]["version"])' "${qa}/package-lock.json")"
  [[ -n "${d}" && "${d}" == "${p}" && "${p}" == "${l}" ]] || fail "Dockerfile ${d}, package.json ${p}, lock ${l}"
}

test_ansible_web_php84() {
  local r="${PROJECT_DIR}/ansible/roles/web/tasks/main.yml"
  # PPA sem a API do Launchpad: chave do keyserver pelo fingerprint, conferida, e linha deb com signed-by
  ! grep -q 'ppa:ondrej' <(grep -v '^ *#' "${r}") || fail "ainda usa ppa:ondrej (API do Launchpad)" || return 1
  grep -qx 'php_ppa_fingerprint: 14AA40EC0831756756D7F66C4F4EA0AAE5267A6C' "${PROJECT_DIR}/ansible/roles/web/defaults/main.yml" \
    || fail "fingerprint do PPA ausente" || return 1
  local chave fpr velho repo
  chave="$(sed -n '/name: Chave do PPA ondrej\/php/,/^$/p' "${r}")"
  grep -qF 'url: "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x{{ php_ppa_fingerprint }}"' <<<"${chave}" \
    && grep -qx '    dest: /root/ondrej-php.asc' <<<"${chave}" && grep -qx '  retries: 5' <<<"${chave}" \
    && grep -qx '  until: php_ppa_key is succeeded' <<<"${chave}" || fail "chave do PPA sem keyserver/retries" || return 1
  fpr="$(sed -n '/name: Conferir o fingerprint da chave do PPA/,/^$/p' "${r}")"
  grep -qF 'gpg --show-keys --with-colons /root/ondrej-php.asc' <<<"${fpr}" \
    && grep -qF "map(attribute=9) | list) != [php_ppa_fingerprint]" <<<"${fpr}" \
    || fail "fingerprint nao conferido (exatamente uma chave)" || return 1
  local inst
  inst="$(sed -n '/name: Instalar a chave do PPA em \/etc\/apt\/keyrings/,/^$/p' "${r}")"
  grep -qx '    src: /root/ondrej-php.gpg' <<<"${inst}" && grep -qx '    dest: /etc/apt/keyrings/ondrej-php.gpg' <<<"${inst}" \
    && grep -qF 'gpg --batch --yes --dearmor -o /root/ondrej-php.gpg /root/ondrej-php.asc' "${r}" \
    || fail "chave nao instalada em binario depois de conferida" || return 1
  velho="$(sed -n '/name: Tirar os .list antigos do PPA ondrej\/php/,/^$/p' "${r}")"
  grep -q 'state: absent' <<<"${velho}" && grep -qF 'ppa_ondrej_php_{{ ansible_distribution_release }}.list' <<<"${velho}" \
    && grep -qF 'ondrej-ubuntu-php-{{ ansible_distribution_release }}.list' <<<"${velho}" || fail "nao apaga os .list antigos" || return 1
  repo="$(sed -n '/name: PPA ondrej\/php/,/^$/p' "${r}")"
  grep -qx '  ansible.builtin.copy:' <<<"${repo}" && grep -qx '    dest: /etc/apt/sources.list.d/ondrej-php.list' <<<"${repo}" \
    && grep -qF 'content: "deb [signed-by=/etc/apt/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu {{ ansible_distribution_release }} main\n"' <<<"${repo}" \
    || fail "PPA nao e o arquivo inteiro (copy) com signed-by" || return 1
  ! grep -q 'apt_repository' <<<"$(sed -n '/name: Pasta de chaves do apt/,/name: Instalar Apache/p' "${r}")" || fail "PPA ainda via apt_repository (acrescenta linhas)" || return 1
  local upd
  upd="$(sed -n '/name: Atualizar o indice do apt com o PPA/,/^$/p' "${r}")"
  grep -qx '    update_cache: true' <<<"${upd}" && grep -qx '  until: php_ppa_repo is succeeded' <<<"${upd}" || fail "apt update do PPA sem retries" || return 1
  # ordem: chave -> fingerprint -> instalar -> .list antigos -> repo -> pacotes do PHP
  local n1 n2 n2b n3 n4 n5
  n2b="$(grep -n 'name: Instalar a chave do PPA' "${r}" | cut -d: -f1)"
  n1="$(grep -n 'name: Chave do PPA ondrej/php' "${r}" | cut -d: -f1)"
  n2="$(grep -n 'name: Conferir o fingerprint da chave do PPA' "${r}" | cut -d: -f1)"
  n3="$(grep -n 'name: Tirar os .list antigos' "${r}" | cut -d: -f1)"
  local n3b
  n3b="$(grep -n 'name: PPA ondrej/php' "${r}" | cut -d: -f1)"
  n4="$(grep -n 'name: Atualizar o indice do apt com o PPA' "${r}" | cut -d: -f1)"
  n5="$(grep -n 'name: Instalar Apache e PHP 8.4' "${r}" | cut -d: -f1)"
  [[ "${n1}" -lt "${n2}" && "${n2}" -lt "${n2b}" && "${n2b}" -lt "${n3}" && "${n3}" -lt "${n3b}" && "${n3b}" -lt "${n4}" && "${n4}" -lt "${n5}" ]] || fail "ordem das tarefas do PPA" || return 1
  grep -qF 'name: [apache2, php8.4, libapache2-mod-php8.4, php8.4-mysql, php8.4-gd]' "${r}" || fail "pacotes do PHP 8.4 + gd" || return 1
  ! grep -qE 'libapache2-mod-php[,\]]|php-mysql' "${r}" || fail "sobrou PHP generico (8.1)" || return 1
  local pub
  pub="$(sed -n '/name: Publicar a app/,/when:/p' "${r}")"
  grep -q 'src: "{{ playbook_dir }}/../app/{{ item }}/"' <<<"${pub}" && grep -q 'loop: \[public, backend, frontend/views\]' <<<"${pub}" \
    || fail "nao publica public/, backend/ e frontend/views/" || return 1
  grep -q 'src: "{{ playbook_dir }}/../app/apache/larcerto.conf"' "${r}" && grep -q 'dest: /etc/apache2/conf-available/larcerto.conf' "${r}" \
    && grep -q 'cmd: a2enconf larcerto' "${r}" || fail "conf comum do Apache" || return 1
  grep -q 'src: "{{ playbook_dir }}/../app/php/larcerto.ini"' "${r}" && grep -q 'dest: /etc/php/8.4/apache2/conf.d/99-larcerto.ini' "${r}" \
    || fail "ini comum do PHP" || return 1
  local up
  up="$(sed -n '/name: Pasta das fotos/,/^$/p' "${r}")"
  grep -qx '    path: /var/www/larcerto/storage/uploads' <<<"${up}" && grep -qx '    owner: www-data' <<<"${up}" \
    && grep -qx '    mode: "0750"' <<<"${up}" || fail "pasta das fotos (www-data, 0750)" || return 1
  grep -q 'src: "{{ playbook_dir }}/../app/public/assets/logo.svg"' "${r}" || fail "provisoria sem o logo" || return 1
  [[ -f "${APP}/public/assets/logo.svg" ]] || fail "logo ausente"
}

test_ansible_force_handlers() {
  grep -qx 'force_handlers = True' "${PROJECT_DIR}/ansible/ansible.cfg" || fail "ansible.cfg sem force_handlers = True" || return 1
  [[ "$(sed -n '/^\[defaults\]/,/^\[/p' "${PROJECT_DIR}/ansible/ansible.cfg" | grep -cx 'force_handlers = True')" -eq 1 ]] \
    || fail "force_handlers fora de [defaults]"
}

test_ansible_db_schema_seed() {
  local r="${PROJECT_DIR}/ansible/roles/db/tasks/main.yml"
  grep -qF 'deb [signed-by=/etc/apt/keyrings/mariadb-keyring.asc] https://deb.mariadb.org/12.3/ubuntu {{ ansible_distribution_release }} main' "${r}" \
    || fail "repositorio 12.3" || return 1
  grep -q 'dest: /etc/apt/keyrings/mariadb-keyring.asc' "${r}" || fail "chave do repositorio" || return 1
  ! grep -qE 'cmd: mysql\b' "${r}" || fail "ainda usa o cliente mysql" || return 1
  grep -qF "lookup('ansible.builtin.file', app_sql_dir ~ '/01-schema.sql')" "${r}" || fail "schema" || return 1
  local seed
  seed="$(sed -n '/name: Semente do MVP/,$p' "${r}")"
  grep -qF "app_sql_dir ~ '/02-seed.sql'" <<<"${seed}" && grep -qx '  when: imoveis_count.stdout | int == 0' <<<"${seed}" \
    || fail "semente nao depende da contagem" || return 1
  [[ "$(grep -n 'register: imoveis_count' "${r}" | cut -d: -f1)" -lt "$(grep -n 'name: Semente do MVP' "${r}" | cut -d: -f1)" ]] \
    || fail "contagem depois da semente" || return 1
  grep -q '^app_sql_dir: "{{ playbook_dir }}/../app/sql"$' "${PROJECT_DIR}/ansible/group_vars/all/main.yml" || fail "app_sql_dir" || return 1
  [[ -f "${APP}/sql/01-schema.sql" && -f "${APP}/sql/02-seed.sql" ]] || fail "SQL ausente"
}

test_no_secrets_tracked() {
  # Escopo: segredos desta nuvem (devops1, BD, PKI, tfstate) e as senhas do Kolla (passwords.yml, openrc, clouds.yaml).
  local repo="${PROJECT_DIR}"
  local hits
  hits="$(git -C "${repo}" ls-files --cached --others --exclude-standard \
    'cloud/secrets/*' 'ansible/group_vars/all/secrets.yml' 'ansible/files/pki/*.key' \
    'ansible/files/pki/*.crt' 'terraform/*.tfstate*' 'ansible/inventory/hosts.ini' \
    'app/.env' \
    'kolla-config/passwords.yml' 'kolla-config/clouds.yaml' 'kolla-config/*-openrc*.sh')"
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
    cloud terraform ansible app)
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

# ---------------------------------------------------------------- install-app / start-app

# Sandbox das etapas: HOME e PATH isolados, comandos falsos para terraform, openstack,
# ansible-playbook, bootstrap, cloud-checks, curl e resolvectl. FAKE_FAIL=<etapa> falha uma etapa.
install_sandbox() {
  # TMPDIR aponta para dentro do sandbox anterior: solta antes de apagar, senao o mktemp falha.
  unset TMPDIR
  [[ -n "${T:-}" ]] && rm -rf "${T}"
  setup_sandbox
  [[ -n "${T:-}" && -d "${T}" ]] || { echo "sandbox nao criado" >&2; return 1; }
  export HOME="${T}/home"
  export PATH="${T}/bin:${HOME}/.local/bin:/usr/bin:/bin"
  unset FAKE_FAIL FAKE_RC FAKE_DOWNLOAD_FAIL FAKE_SHA_BAD FAKE_STUCK START_APP_WAIT TERRAFORM_VERSION FAKE_LIBVIRT_ACTIVE FAKE_DOCKER_NAMES FAKE_LIBVIRT_STUCK FAKE_SLOW_START FAKE_VIP_DOWN FAKE_VIP_FAILS VIP_WAIT
  export FAKE_CONTAINER_IDS="kolla1" FAKE_VMS="${T}/vms" FAKE_FIXTURES="${T}/fixtures"
  mkdir -p "${HOME}/.ssh" "${T}/project/cloud/secrets" "${T}/project/ansible/group_vars/all" \
    "${T}/project/ansible/inventory" "${T}/project/terraform" "${T}/project/tests" \
    "${T}/vms" "${T}/fixtures/src"
  : >"${HOME}/.ssh/id_ed25519.pub"
  echo 'db_password: senha-de-teste' >"${T}/project/ansible/group_vars/all/secrets.yml"
  : >"${T}/project/cloud/secrets/clouds.yaml"
  printf '[dns]\ndns ansible_host=172.24.4.10\n[web]\nweb ansible_host=172.24.4.13\n' \
    >"${T}/project/ansible/inventory/hosts.ini"
  local vm
  for vm in dns ca db web; do echo ACTIVE >"${T}/vms/${vm}"; done

  # Fixture do Terraform: grava o caminho completo ($0) e os argumentos.
  printf '#!/usr/bin/env bash\necho "$0 $*" >>"$FAKE_LOG"\n[[ "$1" == version ]] && echo "Terraform v1.9.8"\nexit 0\n' \
    >"${T}/fixtures/src/terraform"
  chmod +x "${T}/fixtures/src/terraform"
  "${REAL_PY}" -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2],"terraform")' \
    "${T}/fixtures/terraform_1.9.8_linux_amd64.zip" "${T}/fixtures/src/terraform"
  (cd "${T}/fixtures" && sha256sum terraform_1.9.8_linux_amd64.zip >SHA256SUMS)
  echo "0000000000000000000000000000000000000000000000000000000000000000  terraform_1.9.8_linux_amd64.zip" \
    >"${T}/fixtures/SHA256SUMS.bad"

  fake resolvectl 'echo "resolvectl $*" >>"$FAKE_LOG"; [[ "${FAKE_FAIL:-}" == dns-host ]] && exit "${FAKE_RC:-7}"; exit 0'
  cat >"${T}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$FAKE_LOG"
out=""; prev=""; url=""
for a in "$@"; do
  [[ "$prev" == -o ]] && out="$a"
  prev="$a"; url="$a"
done
[[ "${FAKE_DOWNLOAD_FAIL:-}" == 1 ]] && exit 22
if [[ "$url" == *":5000/" ]]; then
  [[ "${FAKE_VIP_DOWN:-0}" == 1 ]] && exit 7
  exit 0
fi
case "$url" in
  *checkpoint*) echo '{"current_version":"1.9.8"}' ;;
  *SHA256SUMS)
    if [[ "${FAKE_SHA_BAD:-}" == 1 ]]; then cp "${FAKE_FIXTURES}/SHA256SUMS.bad" "$out"; else cp "${FAKE_FIXTURES}/SHA256SUMS" "$out"; fi ;;
  *.zip) cp "${FAKE_FIXTURES}/terraform_1.9.8_linux_amd64.zip" "$out" ;;
esac
exit 0
EOF
  cat >"${T}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $* cwd=$(basename "$PWD") cloud=${OS_CLOUD:-} cfg=${OS_CLIENT_CONFIG_FILE:-}" >>"$FAKE_LOG"
[[ "$1" == version ]] && { echo "Terraform v1.9.8"; exit 0; }
[[ "${FAKE_FAIL:-}" == terraform ]] && exit "${FAKE_RC:-7}"
# destroy / apply: falha so no subcomando (o init da etapa destroy passa)
[[ -n "${FAKE_FAIL:-}" && "${FAKE_FAIL}" == "$1" ]] && exit "${FAKE_RC:-7}"
exit 0
EOF
  cat >"${T}/venv/bin/openstack" <<'EOF'
#!/usr/bin/env bash
echo "openstack $* cloud=${OS_CLOUD:-}" >>"$FAKE_LOG"
if [[ "$1 $2" == "server show" ]]; then
  name="${@: -1}"
  [[ -f "${FAKE_VMS}/${name}" ]] || exit 1
  cat "${FAKE_VMS}/${name}"
elif [[ "$1 $2" == "server list" ]]; then
  [[ "${FAKE_FAIL:-}" == api ]] && exit 1
  if [[ -f "${FAKE_SERVERS:-}" ]]; then cat "${FAKE_SERVERS}"; else echo "[]"; fi
elif [[ "$1 $2" == "server start" ]]; then
  name="$3"
  if [[ ",${FAKE_STUCK:-}," == *",${name},"* ]]; then echo ERROR >"${FAKE_VMS}/${name}"; else echo ACTIVE >"${FAKE_VMS}/${name}"; fi
fi
exit 0
EOF
  cat >"${T}/venv/bin/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
s=""
case "$*" in *"dns,ca"*) s=nuvem ;; *"db,web"*) s=app ;; esac
echo "ansible-playbook $* cwd=$(basename "$PWD")" >>"$FAKE_LOG"
[[ -n "$s" && "${FAKE_FAIL:-}" == "$s" ]] && exit "${FAKE_RC:-7}"
exit 0
EOF
  printf '#!/usr/bin/env bash\necho bootstrap >>"$FAKE_LOG"\n[[ "${FAKE_FAIL:-}" == bootstrap ]] && exit "${FAKE_RC:-7}"\nexit 0\n' \
    >"${T}/project/cloud/bootstrap.sh"
  printf '#!/usr/bin/env bash\necho checks >>"$FAKE_LOG"\n[[ "${FAKE_FAIL:-}" == checks ]] && exit "${FAKE_RC:-7}"\nexit 0\n' \
    >"${T}/project/tests/cloud-checks.sh"
  chmod +x "${T}/bin/"* "${T}/venv/bin/"* "${T}/project/cloud/bootstrap.sh" "${T}/project/tests/cloud-checks.sh"
}

# Tira um pre-requisito por vez (ou todos, conforme o nome).
break_item() {
  case "$1" in
    openstack) rm -f "${VENV_PATH}/bin/openstack" ;;
    ssh) rm -f "${HOME}/.ssh/id_ed25519.pub" ;;
    secrets) rm -f "${T}/project/ansible/group_vars/all/secrets.yml" ;;
    containers) export FAKE_CONTAINER_IDS="" ;;
    terraform) rm -f "${T}/bin/terraform"; export FAKE_DOWNLOAD_FAIL=1 ;;
  esac
}

test_install_each_missing_exit_1() {
  local item
  for item in openstack ssh secrets containers terraform; do
    install_sandbox
    break_item "${item}"
    run_lab install-app
    expect_rc 1 || return 1
    grep -q '^Falta:' "${T}/err" || fail "${item}: sem linha Falta" || return 1
    ! grep -q '^terraform \|^bootstrap$\|^ansible-playbook \|^systemctl \|^docker start' "${T}/log" \
      || fail "${item}: alguma etapa rodou" || return 1
  done
}

test_install_all_missing_lists_each() {
  install_sandbox
  rm -f "${VENV_PATH}/bin/openstack" "${HOME}/.ssh/id_ed25519.pub" \
    "${T}/project/ansible/group_vars/all/secrets.yml" "${T}/bin/terraform"
  export FAKE_CONTAINER_IDS="" FAKE_DOWNLOAD_FAIL=1
  run_lab install-app
  expect_rc 1 || return 1
  [[ "$(grep -c '^Falta:' "${T}/err")" -eq 5 ]] || fail "esperado 5 linhas Falta" || return 1
  [[ "$(grep '^Falta:' "${T}/err" | grep -c ' -> ')" -eq 5 ]] || fail "linha Falta sem comando" || return 1
  ! grep -q '^bootstrap$' "${T}/log" || fail "bootstrap rodou" || return 1
}

test_install_example_secrets_is_missing() {
  install_sandbox
  echo 'db_password: troque-esta-senha' >"${T}/project/ansible/group_vars/all/secrets.yml"
  run_lab install-app
  expect_rc 1 || return 1
  grep -q '^Falta: senha do banco' "${T}/err" || fail "secrets de exemplo aceito" || return 1
}

test_install_secrets_from_app_env() {
  local secrets
  # Sem secrets.yml e com a app local criada: copia a senha do .env, modo 600, sem mostrar a senha.
  install_sandbox
  secrets="${T}/project/ansible/group_vars/all/secrets.yml"
  rm -f "${secrets}"
  mkdir -p "${T}/project/app"
  echo 'DB_PASSWORD=s3nh%&local' >"${T}/project/app/.env"
  run_lab install-app
  expect_rc 0 || return 1
  grep -qxF "db_password: 's3nh%&local'" "${secrets}" || fail "db_password nao veio do .env" || return 1
  [[ "$(stat -c %a "${secrets}")" == 600 ]] || fail "secrets.yml sem modo 600" || return 1
  ! grep -qF 's3nh%&local' "${T}/out" "${T}/err" || fail "a senha apareceu na saida" || return 1
  grep -q 'criado a partir de app/.env' "${T}/out" || fail "sem aviso da copia" || return 1
  # secrets.yml ainda com o valor de exemplo: troca pela senha do .env (aspas do .env saem).
  install_sandbox
  secrets="${T}/project/ansible/group_vars/all/secrets.yml"
  echo 'db_password: troque-esta-senha' >"${secrets}"
  mkdir -p "${T}/project/app"
  echo 'DB_PASSWORD="outra-senha"' >"${T}/project/app/.env"
  run_lab install-app
  expect_rc 0 || return 1
  grep -qxF "db_password: 'outra-senha'" "${secrets}" || fail "valor de exemplo nao foi trocado" || return 1
  # secrets.yml ja editado: fica como esta.
  install_sandbox
  secrets="${T}/project/ansible/group_vars/all/secrets.yml"
  mkdir -p "${T}/project/app"
  echo 'DB_PASSWORD=nao-usar' >"${T}/project/app/.env"
  run_lab install-app
  expect_rc 0 || return 1
  grep -qxF 'db_password: senha-de-teste' "${secrets}" || fail "secrets.yml editado foi alterado" || return 1
  ! grep -q 'criado a partir' "${T}/out" || fail "copiou por cima de um secrets.yml editado" || return 1
}

test_install_terraform_installs_verified() {
  install_sandbox
  rm -f "${T}/bin/terraform"
  run_lab install-app
  expect_rc 0 || return 1
  grep -q 'Terraform nao encontrado: instalando 1.9.8 em ~/.local/bin' "${T}/out" || fail "aviso de instalacao ausente" || return 1
  [[ -x "${HOME}/.local/bin/terraform" ]] || fail "binario nao gravado em ~/.local/bin" || return 1
  grep -q 'SHA256SUMS' "${T}/log" || fail "SHA256SUMS nao baixado" || return 1
  grep -q 'Terraform v1.9.8' "${T}/out" || fail "terraform version nao confirmou" || return 1
  # Com ~/.local/bin no PATH, o binario recem-instalado nao gera aviso de PATH.
  ! grep -q 'nao esta no PATH' "${T}/out" || fail "aviso de PATH com ~/.local/bin no PATH" || return 1
}

test_install_terraform_sha_mismatch_writes_nothing() {
  local mode
  for mode in FAKE_SHA_BAD FAKE_DOWNLOAD_FAIL; do
    install_sandbox
    rm -f "${T}/bin/terraform"
    export "${mode}=1"
    run_lab install-app
    expect_rc 1 || return 1
    [[ ! -e "${HOME}/.local/bin/terraform" ]] || fail "${mode}: gravou o binario" || return 1
    grep -q '^Falta: Terraform' "${T}/err" || fail "${mode}: sem linha Falta do Terraform" || return 1
  done
}

test_install_local_bin_not_on_path_warns() {
  install_sandbox
  rm -f "${T}/bin/terraform"
  mkdir -p "${HOME}/.local/bin"
  cp "${T}/fixtures/src/terraform" "${HOME}/.local/bin/terraform"
  export PATH="${T}/bin:/usr/bin:/bin"
  run_lab install-app
  expect_rc 0 || return 1
  grep -q 'nao esta no PATH' "${T}/out" || fail "sem aviso de PATH" || return 1
  grep -q "^${HOME}/.local/bin/terraform init" "${T}/log" || fail "init nao usou o caminho completo" || return 1
  ! grep -q '^curl .*\.zip' "${T}/log" || fail "baixou de novo com o binario presente" || return 1
}

test_install_full_order_8_steps() {
  install_sandbox
  run_lab install-app
  expect_rc 0 || return 1
  local i=0 name want="" got
  for name in prereqs start bootstrap terraform nuvem app dns-host checks; do
    i=$((i + 1))
    want+="==> [${i}/8] ${name}"$'\n'
  done
  got="$(grep -o '^==> \[[0-9]/8\] [a-z-]*' "${T}/out")"
  [[ "${got}" == "${want%$'\n'}" ]] || fail "ordem das etapas diferente" || return 1
}

test_install_terraform_args() {
  install_sandbox
  run_lab install-app
  expect_rc 0 || return 1
  grep -q '^terraform init cwd=terraform cloud=larcerto-devops1 cfg=.*/cloud/secrets/clouds.yaml$' "${T}/log" \
    || fail "terraform init sem argumentos" || return 1
  grep -q '^terraform apply -auto-approve cwd=terraform cloud=larcerto-devops1 cfg=.*/cloud/secrets/clouds.yaml$' "${T}/log" \
    || fail "terraform apply sem -auto-approve ou sem nuvem" || return 1
}

test_install_ansible_limits() {
  install_sandbox
  run_lab install-app
  expect_rc 0 || return 1
  grep -q '^ansible-playbook site.yml --limit dns,ca cwd=ansible$' "${T}/log" || fail "nuvem sem --limit dns,ca" || return 1
  grep -q '^ansible-playbook site.yml --limit db,web cwd=ansible$' "${T}/log" || fail "app sem --limit db,web" || return 1
}

test_install_step_failure_stops() {
  local pair step idx code
  for pair in start:2 bootstrap:3 terraform:4 nuvem:5 app:6 dns-host:7 checks:8; do
    step="${pair%%:*}"
    idx="${pair##*:}"
    install_sandbox
    export FAKE_FAIL="${step}" FAKE_RC=7
    run_lab install-app
    code="$(sed -n 's/^FALHOU na etapa .*codigo \([0-9]*\)$/\1/p' "${T}/err")"
    [[ -n "${code}" && "${RC}" -eq "${code}" && "${RC}" -ne 0 ]] \
      || fail "${step}: codigo no bloco (${code}) diferente do exit (${RC})" || return 1
    grep -q "^FALHOU na etapa ${idx}/8 (${step}), codigo" "${T}/err" || fail "${step}: bloco de falha ausente" || return 1
    grep -q "^Para continuar: ./lab.sh install-app --from ${step}$" "${T}/err" || fail "${step}: linha de continuacao" || return 1
    grep -q '^Dica: ' "${T}/err" || fail "${step}: sem dica" || return 1
    [[ "$(grep -c '^==> \[' "${T}/out")" -eq "${idx}" ]] || fail "${step}: etapa depois da falha rodou" || return 1
  done
  # Um comando que falha no meio da etapa para a etapa: o apply nao roda depois de um init com erro.
  install_sandbox
  export FAKE_FAIL=terraform FAKE_RC=7
  run_lab install-app
  grep -q '^terraform init ' "${T}/log" || fail "init nao chegou a rodar" || return 1
  ! grep -q '^terraform apply' "${T}/log" || fail "apply rodou depois do init com erro" || return 1
}

test_install_success_output() {
  install_sandbox
  run_lab install-app
  expect_rc 0 || return 1
  grep -q 'https://larcerto.com.br' "${T}/out" || fail "sem a URL" || return 1
  grep -q 'ansible/files/pki/ca.crt' "${T}/out" || fail "sem o caminho do ca.crt" || return 1
}

test_install_from_runs_tail() {
  install_sandbox
  run_lab install-app --from nuvem
  expect_rc 0 || return 1
  grep -q '^==> \[1/8\] prereqs' "${T}/out" || fail "prereqs nao rodou" || return 1
  grep -q '^==> \[5/8\] nuvem' "${T}/out" || fail "nuvem nao rodou" || return 1
  ! grep -q '^==> \[2/8\]' "${T}/out" || fail "start rodou com --from nuvem" || return 1
  ! grep -q '^bootstrap$\|^terraform ' "${T}/log" || fail "etapa anterior rodou" || return 1
  grep -q '^ansible-playbook site.yml --limit dns,ca' "${T}/log" || fail "nuvem nao chamou o ansible" || return 1
  # As etapas depois de nuvem tambem rodam: app, dns-host e checks.
  grep -q '^==> \[6/8\] app' "${T}/out" || fail "app nao rodou depois de nuvem" || return 1
  grep -q '^==> \[7/8\] dns-host' "${T}/out" || fail "dns-host nao rodou depois de nuvem" || return 1
  grep -q '^==> \[8/8\] checks' "${T}/out" || fail "checks nao rodou depois de nuvem" || return 1
  grep -q '^ansible-playbook site.yml --limit db,web' "${T}/log" || fail "app nao chamou o ansible" || return 1
  grep -q '^checks$' "${T}/log" || fail "checks nao chamou o cloud-checks" || return 1
}

test_install_from_unknown_exit_1() {
  install_sandbox
  run_lab install-app --from bogus
  expect_rc 1 || return 1
  local s
  for s in prereqs start bootstrap terraform nuvem app dns-host checks; do
    grep -q "${s}" "${T}/err" || fail "nome valido ${s} nao listado" || return 1
  done
  ! grep -q '^==> ' "${T}/out" || fail "alguma etapa rodou" || return 1
}

test_install_help_lists_commands() {
  install_sandbox
  run_lab help
  expect_rc 0 || return 1
  grep -qw 'install-app' "${T}/out" || fail "help sem install-app" || return 1
  grep -qF -- '--from' "${T}/out" || fail "help sem --from" || return 1
  grep -qw 'start-app' "${T}/out" || fail "help sem start-app" || return 1
}

test_start_app_order_no_rebuild() {
  install_sandbox
  run_lab start-app
  expect_rc 0 || return 1
  local got
  got="$(grep -o '^==> \[[0-9]/5\] [a-z-]*' "${T}/out" | tr '\n' ' ')"
  [[ "${got}" == "==> [1/5] prereqs ==> [2/5] start ==> [3/5] vms ==> [4/5] dns-host ==> [5/5] checks " ]] \
    || fail "ordem do start-app: ${got}" || return 1
  ! grep -q '^bootstrap$\|^terraform \|^ansible-playbook ' "${T}/log" || fail "start-app recriou a nuvem" || return 1
}

test_start_app_needs_previous_install() {
  install_sandbox
  local f
  for f in cloud/secrets/clouds.yaml ansible/inventory/hosts.ini; do
    install_sandbox
    rm -f "${T}/project/${f}"
    run_lab start-app
    expect_rc 1 || return 1
    grep -q 'install-app' "${T}/err" || fail "sem apontar para install-app (sem ${f})" || return 1
    ! grep -q '^==> \[2/5\]' "${T}/out" || fail "start rodou sem instalacao anterior (sem ${f})" || return 1
  done
}

test_start_app_starts_only_shutoff() {
  install_sandbox
  echo SHUTOFF >"${T}/vms/dns"
  echo ACTIVE >"${T}/vms/ca"
  echo SHUTOFF >"${T}/vms/db"
  echo SHUTOFF >"${T}/vms/web"
  run_lab start-app
  expect_rc 0 || return 1
  grep -q '^openstack server start dns cloud=larcerto-devops1$' "${T}/log" || fail "dns SHUTOFF nao foi ligada" || return 1
  grep -q '^openstack server start db cloud=larcerto-devops1$' "${T}/log" || fail "db nao foi ligada" || return 1
  grep -q '^openstack server start web cloud=larcerto-devops1$' "${T}/log" || fail "web nao foi ligada" || return 1
  ! grep -q '^openstack server start ca ' "${T}/log" || fail "ca ACTIVE foi ligada de novo" || return 1
}

test_start_app_vm_missing_or_error_fails() {
  install_sandbox
  rm -f "${T}/vms/db"
  run_lab start-app
  expect_rc 1 || return 1
  grep -q 'db: status ausente' "${T}/err" || fail "VM ausente sem nome e status" || return 1
  grep -q 'install-app --from terraform' "${T}/err" || fail "VM ausente sem a dica" || return 1
  install_sandbox
  echo ERROR >"${T}/vms/web"
  export START_APP_WAIT=1
  run_lab start-app
  expect_rc 1 || return 1
  grep -q 'web:ERROR' "${T}/err" || fail "VM em ERROR sem nome e status" || return 1
  grep -q 'install-app --from terraform' "${T}/err" || fail "VM em ERROR sem a dica" || return 1
}

test_start_app_failure_continuation() {
  install_sandbox
  export FAKE_FAIL=checks FAKE_RC=7
  run_lab start-app
  expect_rc 7 || return 1
  grep -q '^FALHOU na etapa 5/5 (checks), codigo 7$' "${T}/err" || fail "bloco de falha do start-app" || return 1
  grep -q '^Para continuar: ./lab.sh start-app$' "${T}/err" || fail "linha de continuacao do start-app" || return 1
}

test_docs_install_app() {
  local doc="${PROJECT_DIR}/docs/nuvem-larcerto.md" lab_doc="${PROJECT_DIR}/docs/lab.sh.md" first
  first="$(awk '/^## Subir tudo/{f=1; next} f && /\.\/lab\.sh/{print; exit}' "${doc}")"
  [[ "${first}" == *install-app* ]] || fail "primeiro comando de Subir tudo: ${first}" || return 1
  grep -q 'terraform apply' "${doc}" || fail "passos manuais sumiram do guia" || return 1
  grep -q 'start-app' "${doc}" || fail "guia sem start-app" || return 1
  grep -q '^| `install-app`' "${lab_doc}" || fail "lab.sh.md sem linha install-app" || return 1
  grep -q '^| `start-app`' "${lab_doc}" || fail "lab.sh.md sem linha start-app" || return 1
}

test_docs_requisitos_terraform() {
  local f="${PROJECT_DIR}/README.md" section term
  grep -q '^## Requisitos' "${f}" || fail "README sem a secao Requisitos" || return 1
  section="$(awk '/^## Requisitos/{f=1; next} /^## /{f=0} f' "${f}")"
  for term in '>= 1.5' '~/.local/bin/terraform' 'install-app' 'openstack' 'id_ed25519' 'secrets.yml'; do
    grep -qF -- "${term}" <<<"${section}" || fail "Requisitos sem: ${term}" || return 1
  done
}

# ---------------------------------------------------------------- lab.sh cert

# PKI de teste: CA "CA LarCerto" e certificado wildcard assinado por ela (SAN como o papel ca).
cert_gera_pki() {
  local dir="$1" dias="$2"
  mkdir -p "${dir}"
  "${REAL_OPENSSL}" req -x509 -newkey rsa:2048 -nodes -keyout "${dir}/ca.key" -out "${dir}/ca.crt" \
    -days 3650 -subj "/CN=CA LarCerto" 2>/dev/null
  "${REAL_OPENSSL}" req -newkey rsa:2048 -nodes -keyout "${dir}/larcerto.key" -out "${dir}/larcerto.csr" \
    -subj "/CN=larcerto" 2>/dev/null
  printf 'subjectAltName=DNS:larcerto.com.br,DNS:*.larcerto.com.br\n' >"${dir}/ext.cnf"
  "${REAL_OPENSSL}" x509 -req -in "${dir}/larcerto.csr" -CA "${dir}/ca.crt" -CAkey "${dir}/ca.key" \
    -CAcreateserial -days "${dias}" -extfile "${dir}/ext.cnf" -out "${dir}/larcerto.crt" 2>/dev/null
  rm -f "${dir}/larcerto.csr" "${dir}/ext.cnf" "${dir}/ca.srl"
}

# openssl falso: so o s_client e trocado (serve $FAKE_SERVED_PEM, ou nada com FAKE_SERVED_DOWN=1);
# o resto e o openssl de verdade.
cert_fake_openssl() {
  fake openssl '
if [[ "$1" == s_client && " $* " == *" -servername cloud.larcerto.com.br "* ]]; then
  # o Horizon so responde no VIP do Kolla
  [[ " $* " == *" -connect 192.168.1.250:443 "* && -n "${FAKE_SERVED_CLOUD_PEM:-}" ]] || exit 1
  cat "${FAKE_SERVED_CLOUD_PEM}"
  exit 0
fi
if [[ "$1" == s_client ]]; then
  [[ "${FAKE_SERVED_DOWN:-0}" == 1 ]] && exit 1
  # exec: o timeout do cert.sh mata este processo, e nao um filho que segure o pipe
  [[ -n "${FAKE_SERVED_SLEEP:-}" ]] && exec sleep "${FAKE_SERVED_SLEEP}"
  cat "${FAKE_SERVED_PEM}"
  exit 0
fi
exec "'"${REAL_OPENSSL}"'" "$@"'
}

# certutil falso: bancos NSS sao pastas com cert9.db; a CA fica em <banco>/larcerto-ca.pem.
# FAKE_CERTUTIL_FAIL_ADD=<fim do caminho>: o -A falha nesse banco.
cert_fake_certutil() {
  cat >"${T}/bin/certutil" <<'EOF'
#!/usr/bin/env bash
op=""; db=""; a=0; in=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -L|-D|-A) op="$1" ;;
    -d) db="${2#sql:}"; shift ;;
    -i) in="$2"; shift ;;
    -a) a=1 ;;
  esac
  shift
done
echo "certutil ${op} ${db}" >>"$FAKE_LOG"
store="${db}/larcerto-ca.pem"
case "${op}" in
  -L)
    [[ -f "${store}" ]] || exit 1
    [[ "${a}" -eq 1 ]] && cat "${store}"
    exit 0 ;;
  -D) rm -f "${store}"; exit 0 ;;
  -A)
    if [[ -n "${FAKE_CERTUTIL_FAIL_ADD:-}" && "${db}" == *"${FAKE_CERTUTIL_FAIL_ADD}" ]]; then exit 1; fi
    cp "${in}" "${store}" ;;
esac
EOF
  chmod +x "${T}/bin/certutil"
}

# cert_sandbox: HOME e PATH isolados, PKI de teste com 825 dias, web no hosts.ini, openssl falso e
# ansible-playbook falso: registra os argumentos e os backups na hora da chamada. Com ca_new, troca a
# PKI por $FAKE_NEW_PKI (como a VM faria). FAKE_ANSIBLE_RC=N falha a chamada.
cert_sandbox() {
  setup_sandbox
  export HOME="${T}/home" VENV_PATH="${T}/venv" FAKE_LOG="${T}/log"
  export PATH="${T}/bin:${PATH}"
  export FAKE_PKI="${T}/project/ansible/files/pki"
  export FAKE_SERVED_PEM="${FAKE_PKI}/larcerto.crt"
  unset FAKE_SERVED_DOWN FAKE_ANSIBLE_RC FAKE_NEW_PKI CERT_NOW CERT_WARN_DAYS FAKE_CLOUD_PKI FAKE_SERVED_CLOUD_PEM
  mkdir -p "${HOME}" "${T}/project/ansible/inventory" "${T}/venv/bin"
  printf '[web]\nweb ansible_host=172.24.4.199\n' >"${T}/project/ansible/inventory/hosts.ini"
  cert_gera_pki "${FAKE_PKI}" 825
  cert_fake_openssl
  cat >"${T}/venv/bin/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
echo "ansible-playbook $* cwd=$(basename "$PWD")" >>"$FAKE_LOG"
echo "backups-na-chamada=$(ls -d "$FAKE_PKI"/backup-* 2>/dev/null | wc -l)" >>"$FAKE_LOG"
if [[ "$*" == *ca_new=true* && -n "${FAKE_NEW_PKI:-}" ]]; then
  cp "$FAKE_NEW_PKI/ca.crt" "$FAKE_NEW_PKI/ca.key" "$FAKE_NEW_PKI/larcerto.crt" "$FAKE_NEW_PKI/larcerto.key" "$FAKE_PKI/"
fi
# cert_cloud: o fetch do papel ca traria cloud.crt e cloud.key (com o modo do umask)
if [[ "$*" == *cert_cloud=true* && -n "${FAKE_CLOUD_PKI:-}" && "${FAKE_ANSIBLE_RC:-0}" == 0 ]]; then
  cp "$FAKE_CLOUD_PKI/cloud.crt" "$FAKE_CLOUD_PKI/cloud.key" "$FAKE_PKI/"
  chmod 644 "$FAKE_PKI/cloud.key"
fi
exit "${FAKE_ANSIBLE_RC:-0}"
EOF
  chmod +x "${T}/venv/bin/ansible-playbook"
}

# Soma dos arquivos da PKI de teste, para ver se mudaram.
cert_soma_pki() {
  (cd "${FAKE_PKI}" && find . -type f | sort | xargs sha256sum)
}

test_cert_status_ok() {
  cert_sandbox
  run_lab cert status
  expect_rc 0 || return 1
  grep -qx 'CA: CN=CA LarCerto' "${T}/out" || fail "CN da CA" || return 1
  grep -qx 'Certificado: CN=larcerto' "${T}/out" || fail "CN do certificado" || return 1
  grep -qF 'SAN: DNS:larcerto.com.br, DNS:*.larcerto.com.br' "${T}/out" || fail "SAN do certificado" || return 1
  grep -qE 'dias restantes: 82[45]\)' "${T}/out" || fail "dias restantes do certificado" || return 1
  grep -qE '^openssl verify: .*: OK$' "${T}/out" || fail "openssl verify" || return 1
  grep -qx 'servido: igual' "${T}/out" || fail "servido: igual" || return 1
}

# cert.sh carregado sem o install.sh (so common.sh), com set -euo pipefail como no lab.sh.
test_cert_module_loads_alone() {
  cert_sandbox
  local sozinho='set -euo pipefail; SCRIPT_DIR="$1"; shift; source "${SCRIPT_DIR}/scripts/common.sh"; source "${SCRIPT_DIR}/scripts/lab/cert.sh"; cert_main "$@"'
  "${REAL_BASH}" -c "${sozinho}" _ "${T}/project" status >"${T}/out" 2>"${T}/err"
  RC=$?
  expect_rc 0 || return 1
  grep -qx 'servido: igual' "${T}/out" || fail "status sem o hosts.ini padrao" || return 1
  "${REAL_BASH}" -c "${sozinho}" _ "${T}/project" renew >"${T}/out" 2>"${T}/err"
  RC=$?
  expect_rc 0 || return 1
  grep -qx 'ansible-playbook site.yml --limit ca,web -e cert_renew=true cwd=ansible' "${T}/log" \
    || fail "renew sem o ansible-playbook padrao do venv" || return 1
}

test_cert_status_missing_file() {
  cert_sandbox
  rm -f "${FAKE_PKI}/ca.crt"
  run_lab cert status
  expect_rc 1 || return 1
  grep -qF 'Falta: ' "${T}/err" || fail "sem a linha Falta" || return 1
  grep -qF 'ca.crt' "${T}/err" || fail "nao diz qual arquivo falta" || return 1
  grep -qF 'install-app --from nuvem' "${T}/err" || fail "sem o comando de correcao" || return 1
}

test_cert_status_served_different() {
  cert_sandbox
  cert_gera_pki "${T}/outra" 825
  FAKE_SERVED_PEM="${T}/outra/larcerto.crt" run_lab cert status
  expect_rc 2 || return 1
  grep -qx 'servido: diferente' "${T}/out" || fail "servido: diferente" || return 1
}

test_cert_status_unreachable() {
  cert_sandbox
  FAKE_SERVED_DOWN=1 run_lab cert status
  expect_rc 0 || return 1
  grep -qx 'servido: inacessivel' "${T}/out" || fail "servido: inacessivel" || return 1
}

test_cert_status_served_timeout_5s() {
  cert_sandbox
  local inicio="${SECONDS}"
  FAKE_SERVED_SLEEP=30 run_lab cert status
  expect_rc 0 || return 1
  grep -qx 'servido: inacessivel' "${T}/out" || fail "servido sem resposta nao virou inacessivel" || return 1
  [[ $(( SECONDS - inicio )) -lt 12 ]] || fail "status esperou o web por mais de 5 s" || return 1
}

test_cert_status_warns_near_expiry() {
  cert_sandbox
  cert_gera_pki "${FAKE_PKI}" 10
  run_lab cert status
  expect_rc 0 || return 1
  grep -qF 'faltam menos de 30 dias' "${T}/err" || fail "sem o aviso de expiracao" || return 1
}

test_cert_status_expired() {
  cert_sandbox
  CERT_NOW=$(( $(date +%s) + 900 * 86400 )) run_lab cert status
  expect_rc 2 || return 1
  grep -qF 'expirado' "${T}/err" || fail "sem o aviso de expirado" || return 1
}

test_cert_status_writes_nothing() {
  cert_sandbox
  local antes depois
  antes="$(find "${T}/project" "${T}/home" "${T}/venv" -exec stat -c '%n %Y %s' {} + | sort)"
  run_lab cert status
  depois="$(find "${T}/project" "${T}/home" "${T}/venv" -exec stat -c '%n %Y %s' {} + | sort)"
  [[ "${antes}" == "${depois}" ]] || fail "status mudou arquivos" || return 1
  if grep -q ansible-playbook "${T}/log" 2>/dev/null; then fail "status chamou o ansible" || return 1; fi
}

test_cert_renew_calls_ansible() {
  cert_sandbox
  run_lab cert renew
  expect_rc 0 || return 1
  grep -qx 'ansible-playbook site.yml --limit ca,web -e cert_renew=true cwd=ansible' "${T}/log" \
    || fail "chamada do ansible" || return 1
  grep -qx 'servido: igual' "${T}/out" || fail "status nao rodou depois do renew" || return 1
}

test_cert_renew_ansible_fails() {
  cert_sandbox
  FAKE_ANSIBLE_RC=7 run_lab cert renew
  expect_rc 7 || return 1
  grep -qx 'FALHOU: cert renew (ansible), codigo 7' "${T}/err" || fail "mensagem de falha" || return 1
}

test_cert_renew_without_hosts() {
  cert_sandbox
  rm -f "${T}/project/ansible/inventory/hosts.ini"
  run_lab cert renew
  expect_rc 1 || return 1
  grep -qF 'install-app' "${T}/err" || fail "sem a dica do install-app" || return 1
  if grep -q ansible-playbook "${T}/log" 2>/dev/null; then fail "chamou o ansible sem inventario" || return 1; fi
}

test_cert_renew_without_ca_key() {
  cert_sandbox
  rm -f "${FAKE_PKI}/ca.key"
  run_lab cert renew
  expect_rc 1 || return 1
  grep -qF 'ca.key' "${T}/err" || fail "sem a mensagem do ca.key" || return 1
  if grep -q ansible-playbook "${T}/log" 2>/dev/null; then fail "renew sem CA chamou o ansible" || return 1; fi
}

test_cert_status_chain_invalid() {
  cert_sandbox
  cert_gera_pki "${T}/outra" 825
  cp "${T}/outra/larcerto.crt" "${FAKE_PKI}/larcerto.crt"
  run_lab cert status
  expect_rc 2 || return 1
  grep -qF 'error 20' "${T}/out" || fail "sem a saida do openssl verify" || return 1
}

test_cert_status_unreadable_cert() {
  cert_sandbox
  echo lixo >"${FAKE_PKI}/larcerto.crt"
  run_lab cert status
  expect_rc 2 || return 1
  grep -qF 'nao consegui ler' "${T}/out" || fail "certificado ilegivel sem aviso" || return 1
}

# So confere o TEXTO dos ramos do papel ca (presenca e padrao desligado). Nao executa o papel:
# a execucao real so roda na nuvem (cert renew e renew --new-ca); o --syntax-check so valida o YAML.
test_cert_role_ca_branches() {
  local f="${PROJECT_DIR}/ansible/roles/ca/tasks/main.yml"
  grep -q 'cert_renew | default(false) | bool' "${f}" || fail "ramo cert_renew sem padrao desligado" || return 1
  grep -q 'ca_new | default(false) | bool' "${f}" || fail "ramo ca_new sem padrao desligado" || return 1
  grep -q 'pki/renewed-{{ renew_stamp }}' "${f}" || fail "renew sem a pasta renewed-" || return 1
  grep -q "pki_local_dir }}/{{ item }}" "${f}" || fail "ca_new sem apagar a copia local" || return 1
}

test_cert_new_ca_wrong_answer() {
  cert_sandbox
  local antes depois
  antes="$(cert_soma_pki)"
  echo sim >"${T}/resposta"
  run_lab cert renew --new-ca <"${T}/resposta"
  expect_rc 1 || return 1
  grep -qF 'Nada foi alterado' "${T}/err" || fail "sem a mensagem de nada alterado" || return 1
  depois="$(cert_soma_pki)"
  [[ "${antes}" == "${depois}" ]] || fail "PKI mudou com resposta errada" || return 1
  if ls -d "${FAKE_PKI}"/backup-* >/dev/null 2>&1; then fail "criou backup com resposta errada" || return 1; fi
  if grep -q ansible-playbook "${T}/log" 2>/dev/null; then fail "chamou o ansible com resposta errada" || return 1; fi
}

test_cert_new_ca_backup_before_ansible() {
  cert_sandbox
  local novo="${T}/nova" backup
  cert_gera_pki "${novo}" 825
  export FAKE_NEW_PKI="${novo}"
  local ca_antiga
  ca_antiga="$(sha256sum "${FAKE_PKI}/ca.crt" | cut -d' ' -f1)"
  echo nova-ca >"${T}/resposta"
  run_lab cert renew --new-ca <"${T}/resposta"
  expect_rc 0 || return 1
  grep -qx 'backups-na-chamada=1' "${T}/log" || fail "backup nao existia na hora do ansible" || return 1
  grep -qF 'ca_new=true' "${T}/log" || fail "sem -e ca_new=true" || return 1
  backup="$(ls -d "${FAKE_PKI}"/backup-* | head -1)"
  [[ "$(sha256sum "${backup}/ca.crt" | cut -d' ' -f1)" == "${ca_antiga}" ]] || fail "backup nao guarda a CA antiga" || return 1
  [[ "$(stat -c %a "${backup}/ca.key")" == 600 ]] || fail "chave do backup sem modo 600" || return 1
  [[ "$(stat -c %a "${backup}/larcerto.key")" == 600 ]] || fail "chave do servidor no backup sem modo 600" || return 1
  grep -qx 'Reimporte a CA: ./lab.sh cert trust' "${T}/out" || fail "sem o aviso de reimportar" || return 1
}

test_cert_new_ca_backup_fixes_key_mode() {
  cert_sandbox
  local novo="${T}/nova"
  cert_gera_pki "${novo}" 825
  export FAKE_NEW_PKI="${novo}"
  chmod 644 "${FAKE_PKI}/ca.key" "${FAKE_PKI}/larcerto.key"
  run_lab cert renew --new-ca --yes </dev/null
  expect_rc 0 || return 1
  local backup
  backup="$(ls -d "${FAKE_PKI}"/backup-* | head -1)"
  [[ "$(stat -c %a "${backup}/ca.key")" == 600 ]] || fail "backup de ca.key ficou com o modo de origem" || return 1
  [[ "$(stat -c %a "${backup}/larcerto.key")" == 600 ]] || fail "backup de larcerto.key ficou com o modo de origem" || return 1
}

test_cert_new_ca_ansible_fails() {
  cert_sandbox
  FAKE_ANSIBLE_RC=7 run_lab cert renew --new-ca --yes </dev/null
  expect_rc 7 || return 1
  grep -qx 'FALHOU: cert renew --new-ca (ansible), codigo 7' "${T}/err" || fail "sem a mensagem de falha da troca" || return 1
}

test_cert_renew_propagates_served_rc() {
  cert_sandbox
  cert_gera_pki "${T}/outra" 825
  FAKE_SERVED_PEM="${T}/outra/larcerto.crt" run_lab cert renew
  expect_rc 2 || return 1
  grep -qx 'servido: diferente' "${T}/out" || fail "renew nao mostrou o status" || return 1
}

test_cert_new_ca_yes_skips_prompt() {
  cert_sandbox
  local novo="${T}/nova"
  cert_gera_pki "${novo}" 825
  export FAKE_NEW_PKI="${novo}"
  run_lab cert renew --new-ca --yes </dev/null
  expect_rc 0 || return 1
  grep -qF 'ca_new=true' "${T}/log" || fail "--yes nao chamou o ansible" || return 1
}

test_cert_trust_without_certutil() {
  cert_trust_sandbox
  # PATH sem nenhum certutil de verdade: links de /usr/bin e /bin, menos o certutil
  mkdir -p "${T}/semcert"
  local p
  for p in /usr/bin/* /bin/*; do
    [[ "$(basename "${p}")" == certutil ]] && continue
    ln -sfn "${p}" "${T}/semcert/$(basename "${p}")" 2>/dev/null
  done
  export PATH="${T}/semcert"
  run_lab cert trust
  expect_rc 1 || return 1
  grep -qxF 'Falta: certutil -> sudo apt install libnss3-tools' "${T}/err" || fail "sem a linha Falta do certutil" || return 1
  [[ -z "$(find "${HOME}" -name 'larcerto-ca.pem')" ]] || fail "gravou sem certutil" || return 1
}

test_cert_trust_flatpak_and_snap() {
  cert_trust_sandbox
  mkdir -p "${HOME}/.var/app/org.mozilla.firefox/.mozilla/firefox/xyz.default" \
    "${HOME}/snap/firefox/common/.mozilla/firefox/snp.default" "${HOME}/.mozilla/firefox/sem-banco"
  : >"${HOME}/.var/app/org.mozilla.firefox/.mozilla/firefox/xyz.default/cert9.db"
  : >"${HOME}/snap/firefox/common/.mozilla/firefox/snp.default/cert9.db"
  mkdir -p "${HOME}/.var/app/com.brave.Browser/data/pki/nssdb"
  : >"${HOME}/.var/app/com.brave.Browser/data/pki/nssdb/cert9.db"
  run_lab cert trust
  expect_rc 0 || return 1
  grep -qx "${HOME}/.var/app/com.brave.Browser/data/pki/nssdb: importado" "${T}/out" || fail "Brave flatpak" || return 1
  grep -qx "${HOME}/.var/app/org.mozilla.firefox/.mozilla/firefox/xyz.default: importado" "${T}/out" || fail "Firefox flatpak" || return 1
  grep -qx "${HOME}/snap/firefox/common/.mozilla/firefox/snp.default: importado" "${T}/out" || fail "Firefox snap" || return 1
  if grep -q 'sem-banco' "${T}/out"; then fail "perfil sem cert9.db foi tratado como banco" || return 1; fi
}

# Cria os bancos de teste: Firefox (perfil) e ~/.pki/nssdb.
cert_trust_sandbox() {
  cert_sandbox
  cert_fake_certutil
  mkdir -p "${HOME}/.mozilla/firefox/abc.default" "${HOME}/.pki/nssdb"
  : >"${HOME}/.mozilla/firefox/abc.default/cert9.db"
  : >"${HOME}/.pki/nssdb/cert9.db"
}

test_cert_trust_imports_each_db() {
  cert_trust_sandbox
  run_lab cert trust
  expect_rc 0 || return 1
  grep -qx "${HOME}/.mozilla/firefox/abc.default: importado" "${T}/out" || fail "perfil do Firefox" || return 1
  grep -qx "${HOME}/.pki/nssdb: importado" "${T}/out" || fail "~/.pki/nssdb" || return 1
  cmp -s "${FAKE_PKI}/ca.crt" "${HOME}/.pki/nssdb/larcerto-ca.pem" || fail "CA nao gravada em nssdb" || return 1
  if grep -q '^sudo' "${T}/log"; then fail "trust chamou sudo" || return 1; fi
}

test_cert_trust_no_database() {
  cert_sandbox
  cert_fake_certutil
  mkdir -p "${HOME}/.mozilla/firefox/sem-banco"
  run_lab cert trust
  expect_rc 1 || return 1
  grep -qF 'Nenhum banco NSS' "${T}/err" || fail "sem a mensagem de nenhum banco" || return 1
  if grep -q '^certutil -A' "${T}/log"; then fail "importou sem banco" || return 1; fi
}

test_cert_trust_already_there() {
  cert_trust_sandbox
  cp "${FAKE_PKI}/ca.crt" "${HOME}/.pki/nssdb/larcerto-ca.pem"
  run_lab cert trust
  expect_rc 0 || return 1
  grep -qx "${HOME}/.pki/nssdb: ja estava" "${T}/out" || fail "CA ja presente nao foi reconhecida" || return 1
}

test_cert_trust_replaces_old_ca() {
  cert_trust_sandbox
  cert_gera_pki "${T}/antiga" 825
  cp "${T}/antiga/ca.crt" "${HOME}/.pki/nssdb/larcerto-ca.pem"
  run_lab cert trust
  expect_rc 0 || return 1
  grep -qx "${HOME}/.pki/nssdb: substituido" "${T}/out" || fail "CA antiga nao foi substituida" || return 1
  cmp -s "${FAKE_PKI}/ca.crt" "${HOME}/.pki/nssdb/larcerto-ca.pem" || fail "banco nao ficou com a CA atual" || return 1
}

test_cert_trust_failed_db() {
  cert_trust_sandbox
  FAKE_CERTUTIL_FAIL_ADD=/.pki/nssdb run_lab cert trust
  expect_rc 1 || return 1
  grep -qx "${HOME}/.pki/nssdb: falhou" "${T}/out" || fail "falha nao aparece na linha do banco" || return 1
  grep -qx "${HOME}/.mozilla/firefox/abc.default: importado" "${T}/out" || fail "um banco com erro parou os outros" || return 1
}

test_cert_trust_prints_system_steps() {
  cert_trust_sandbox
  run_lab cert trust
  expect_rc 0 || return 1
  grep -qF 'sudo cp ' "${T}/out" || fail "sem o sudo cp" || return 1
  grep -qF '/usr/local/share/ca-certificates/larcerto-ca.crt' "${T}/out" || fail "sem o destino do repositorio" || return 1
  grep -qF 'sudo update-ca-certificates' "${T}/out" || fail "sem update-ca-certificates" || return 1
  grep -qF 'Reinicie o navegador' "${T}/out" || fail "sem o aviso de reiniciar" || return 1
  if grep -q '^sudo' "${T}/log"; then fail "trust executou sudo" || return 1; fi
}

test_cert_help_lists_subcommands() {
  setup_sandbox
  run_lab help
  expect_rc 0 || return 1
  grep -q '^  cert ' "${T}/out" || fail "help sem a linha do cert" || return 1
  grep -qF 'renew [--new-ca [--yes]]' "${T}/out" || fail "help sem os subcomandos do renew" || return 1
  grep -qF 'trust' "${T}/out" || fail "help sem o trust" || return 1
}

test_docs_cert() {
  local guia="${PROJECT_DIR}/docs/nuvem-larcerto.md" lab_doc="${PROJECT_DIR}/docs/lab.sh.md" readme="${PROJECT_DIR}/README.md"
  grep -qF './lab.sh cert trust' "${guia}" || fail "guia sem cert trust" || return 1
  grep -qF 'cert renew' "${guia}" || fail "guia sem cert renew" || return 1
  grep -q '^| `cert`' "${lab_doc}" || fail "lab.sh.md sem a linha do cert" || return 1
  grep -qF 'cert.sh' "${lab_doc}" || fail "lab.sh.md sem o modulo cert.sh" || return 1
  grep -qF 'lab.sh cert' "${readme}" || fail "README sem a linha do cert" || return 1
}

# ---------------------------------------------------------------- vms

# 4 VMs fora de ordem: db SHUTOFF, ca sem floating IP.
vms_sandbox() {
  install_sandbox
  export FAKE_SERVERS="${T}/servers.json"
  cat >"${FAKE_SERVERS}" <<'EOF'
[
  {"Name": "web", "Status": "ACTIVE", "Networks": {"larcerto-net": ["10.11.12.13", "172.24.4.199"]}},
  {"Name": "dns", "Status": "ACTIVE", "Networks": {"larcerto-net": ["10.11.12.10", "172.24.4.117"]}},
  {"Name": "db", "Status": "SHUTOFF", "Networks": {"larcerto-net": ["10.11.12.12", "172.24.4.147"]}},
  {"Name": "ca", "Status": "ACTIVE", "Networks": {"larcerto-net": ["10.11.12.11"]}}
]
EOF
}

test_vms_lists_sorted() {
  vms_sandbox
  run_lab vms
  expect_rc 0 || return 1
  local got
  got="$(awk '{$1=$1};1' "${T}/out" | grep -E '^(ca|db|dns|web) ' | tr '\n' '|')"
  [[ "${got}" == "ca ACTIVE 10.11.12.11 -|db SHUTOFF 10.11.12.12 172.24.4.147|dns ACTIVE 10.11.12.10 172.24.4.117|web ACTIVE 10.11.12.13 172.24.4.199|" ]] \
    || fail "tabela: ${got}" || return 1
}

test_vms_ssh_only_active_with_fip() {
  vms_sandbox
  run_lab vms
  expect_rc 0 || return 1
  local got
  got="$(grep '^ssh ' "${T}/out" | tr '\n' '|')"
  [[ "${got}" == "ssh -i ~/.ssh/id_ed25519 ubuntu@172.24.4.117   # dns|ssh -i ~/.ssh/id_ed25519 ubuntu@172.24.4.199   # web|" ]] \
    || fail "linhas de ssh: ${got}" || return 1
}

test_vms_needs_clouds_yaml() {
  vms_sandbox
  rm -f "${T}/project/cloud/secrets/clouds.yaml"
  run_lab vms
  expect_rc 1 || return 1
  grep -qF './cloud/bootstrap.sh' "${T}/err" || fail "sem apontar o bootstrap" || return 1
  ! grep -q '^openstack ' "${T}/log" || fail "openstack chamado sem clouds.yaml" || return 1
}

test_vms_needs_openstack_cli() {
  vms_sandbox
  rm -f "${VENV_PATH}/bin/openstack"
  run_lab vms
  expect_rc 1 || return 1
  grep -qF 'pip install python-openstackclient' "${T}/err" || fail "sem o pip install" || return 1
}

test_vms_api_down() {
  vms_sandbox
  export FAKE_FAIL=api
  run_lab vms
  expect_rc 1 || return 1
  grep -qF './lab.sh start' "${T}/err" || fail "sem apontar o lab.sh start" || return 1
}

test_vms_empty_project() {
  vms_sandbox
  echo '[]' >"${FAKE_SERVERS}"
  run_lab vms
  expect_rc 0 || return 1
  grep -qF 'Nenhuma VM no projeto larcerto' "${T}/out" || fail "sem a mensagem de projeto vazio" || return 1
  grep -qF 'terraform apply' "${T}/out" || fail "sem o terraform apply" || return 1
}

test_vms_rejects_args() {
  vms_sandbox
  run_lab vms extra
  expect_rc 1 || return 1
  grep -qxF 'Uso: ./lab.sh vms' "${T}/err" || fail "sem a linha de uso" || return 1
  ! grep -q '^openstack ' "${T}/log" || fail "openstack chamado com argumento invalido" || return 1
}

test_vms_read_only() {
  vms_sandbox
  run_lab vms
  expect_rc 0 || return 1
  grep -q '^openstack ' "${T}/log" || fail "openstack nao foi chamado" || return 1
  if grep '^openstack ' "${T}/log" | grep -qv '^openstack server list .* cloud=larcerto-devops1$'; then
    fail "chamada fora de server list/devops1: $(grep '^openstack ' "${T}/log" | tr '\n' '|')" || return 1
  fi
  ! grep -q '^sudo' "${T}/log" || fail "vms usou sudo" || return 1
}

test_vms_no_secret() {
  vms_sandbox
  echo 'password: segredo-de-teste' >"${T}/project/cloud/secrets/clouds.yaml"
  run_lab vms
  expect_rc 0 || return 1
  ! grep -qF 'segredo-de-teste' "${T}/out" "${T}/err" || fail "segredo na saida" || return 1
  export FAKE_FAIL=api
  run_lab vms
  ! grep -qF 'segredo-de-teste' "${T}/out" "${T}/err" || fail "segredo na saida de erro" || return 1
}

test_vms_help() {
  setup_sandbox
  run_lab help
  expect_rc 0 || return 1
  grep -q '^  vms ' "${T}/out" || fail "help sem a linha do vms" || return 1
}

test_docs_vms() {
  local guia="${PROJECT_DIR}/docs/nuvem-larcerto.md" lab_doc="${PROJECT_DIR}/docs/lab.sh.md" readme="${PROJECT_DIR}/README.md"
  grep -q '^| `vms`' "${lab_doc}" || fail "lab.sh.md sem a linha do vms" || return 1
  grep -qF 'vms.sh' "${lab_doc}" || fail "lab.sh.md sem o modulo vms.sh" || return 1
  grep -qF './lab.sh vms' "${guia}" || fail "guia sem lab.sh vms" || return 1
  grep -qF './lab.sh vms' "${readme}" || fail "README sem lab.sh vms" || return 1
}

# ---------------------------------------------------------------- libvirt do host e recreate-app

# linha (numero) da primeira ocorrencia no log; vazio se nao achar
linha_log() { grep -nxF -- "$1" "${T}/log" | head -1 | cut -d: -f1; }
linha_log_re() { grep -nE -- "$1" "${T}/log" | head -1 | cut -d: -f1; }

test_start_stops_host_libvirt() {
  export FAKE_CONTAINER_IDS="k1" FAKE_LIBVIRT_ACTIVE=1 AUTO_STOP_HOST_LIBVIRT=true
  run_lab start
  expect_rc 0 || return 1
  local parou subiu
  parou="$(linha_log 'systemctl stop libvirtd.socket libvirtd virtlogd.socket virtlogd')"
  subiu="$(linha_log_re '^docker start ')"
  [[ -n "${parou}" && -n "${subiu}" && "${parou}" -lt "${subiu}" ]] || fail "nao parou o libvirt antes do docker start (${parou}/${subiu})" || return 1
  grep -qx 'libvirt do host parado (conflita com o nova_libvirt)' "${T}/out" || fail "sem a linha do libvirt parado" || return 1
  ! grep -qE '^systemctl (disable|mask)' "${T}/log" || fail "start desabilitou ou mascarou unidade"
}

test_start_libvirt_stop_fails() {
  export FAKE_CONTAINER_IDS="k1" FAKE_LIBVIRT_ACTIVE=1 FAKE_LIBVIRT_STUCK=1 AUTO_STOP_HOST_LIBVIRT=true FAKE_DOCKER_NAMES="nova_libvirt"
  run_lab start
  expect_rc 0 || return 1
  grep -qx 'AVISO: o libvirt do host continua ativo (o stop precisa de root); as VMs podem nascer em ERROR' "${T}/err" \
    || fail "stop que nao pegou nao foi avisado" || return 1
  ! grep -qx 'libvirt do host parado (conflita com o nova_libvirt)' "${T}/out" || fail "disse que parou sem parar" || return 1
  ! grep -q '^docker restart' "${T}/log" || fail "reiniciou containers com o libvirt do host ainda ativo"
}

test_start_restarts_nova_after_libvirt() {
  export FAKE_CONTAINER_IDS="k1" FAKE_LIBVIRT_ACTIVE=1 AUTO_STOP_HOST_LIBVIRT=true FAKE_DOCKER_NAMES="nova_compute nova_libvirt"
  run_lab start
  expect_rc 0 || return 1
  local l c
  l="$(linha_log 'docker restart nova_libvirt')"
  c="$(linha_log 'docker restart nova_compute')"
  [[ -n "${l}" && -n "${c}" && "${l}" -lt "${c}" ]] || fail "nao reiniciou nova_libvirt e depois nova_compute" || return 1
  : >"${T}/log"
  # libvirt do host ativo de novo (outro boot): so o nova_libvirt parado decide que nao ha restart
  rm -f "${T}/libvirt_stopped"
  export FAKE_DOCKER_NAMES="nova_compute"
  run_lab start
  grep -qx 'libvirt do host parado (conflita com o nova_libvirt)' "${T}/out" || fail "2a rodada nao parou o libvirt" || return 1
  expect_rc 0 || return 1
  ! grep -q '^docker restart' "${T}/log" || fail "reiniciou container com o nova_libvirt parado"
}

test_start_libvirt_already_stopped() {
  export FAKE_CONTAINER_IDS="k1" FAKE_LIBVIRT_ACTIVE=0 AUTO_STOP_HOST_LIBVIRT=true FAKE_DOCKER_NAMES="nova_libvirt nova_compute"
  run_lab start
  expect_rc 0 || return 1
  ! grep -qE '^systemctl stop .*(libvirt|virtlog)' "${T}/log" || fail "parou libvirt ja parado" || return 1
  ! grep -q '^docker restart' "${T}/log" || fail "reiniciou container sem precisar" || return 1
  grep -qx 'libvirt do host ja parado.' "${T}/out" || fail "sem a linha de libvirt ja parado"
}

test_start_libvirt_auto_stop_off() {
  export FAKE_CONTAINER_IDS="k1" FAKE_LIBVIRT_ACTIVE=1 AUTO_STOP_HOST_LIBVIRT=false FAKE_DOCKER_NAMES="nova_libvirt"
  run_lab start
  expect_rc 0 || return 1
  ! grep -qE '^systemctl stop .*(libvirt|virtlog)' "${T}/log" || fail "parou o libvirt com AUTO_STOP_HOST_LIBVIRT=false" || return 1
  ! grep -q '^docker restart' "${T}/log" || fail "reiniciou container com AUTO_STOP_HOST_LIBVIRT=false" || return 1
  grep -qx 'AVISO: libvirt do host ativo; as VMs podem nascer em ERROR' "${T}/err" || fail "sem o aviso"
}

test_libvirt_single_function() {
  local s="${PROJECT_DIR}/scripts" defs
  defs="$(grep -rn '^stop_host_libvirt()' "${s}" "${PROJECT_DIR}/lab.sh")"
  [[ "$(grep -c . <<<"${defs}")" -eq 1 && "${defs}" == *"/scripts/common.sh:"* ]] || fail "stop_host_libvirt definida fora de common.sh ou mais de uma vez" || return 1
  grep -q 'stop_host_libvirt' "${s}/kolla/kolla.sh" && grep -q 'stop_host_libvirt' "${s}/lab/ciclo.sh" || fail "kolla.sh ou ciclo.sh nao usam a funcao" || return 1
  ! grep -rqE 'systemctl stop libvirtd' "${s}/kolla" "${s}/lab" "${PROJECT_DIR}/lab.sh" || fail "systemctl stop do libvirt fora da funcao" || return 1
  ! grep -rqE 'systemctl (disable|mask).*(libvirt|virtlog)|(libvirt|virtlog).*(disable|mask)' "${s}" "${PROJECT_DIR}/lab.sh" || fail "disable/mask no libvirt" || return 1
  # o caminho do kolla-ansible tambem para o libvirt (mesma funcao)
  export FAKE_LIBVIRT_ACTIVE=1 AUTO_STOP_HOST_LIBVIRT=true
  run_lab prechecks
  grep -qx 'systemctl stop libvirtd.socket libvirtd virtlogd.socket virtlogd' "${T}/log" || fail "prechecks nao parou o libvirt" || return 1
  ! grep -qE '^systemctl (disable|mask)' "${T}/log" || fail "prechecks desabilitou ou mascarou unidade"
}

test_recreate_confirm() {
  install_sandbox
  run_lab recreate-app <<<"nao"
  expect_rc 1 || return 1
  grep -qE '(^|confirmar: )Cancelado\.$' "${T}/out" || fail "sem Cancelado." || return 1
  grep -q 'Digite larcerto para confirmar' "${T}/out" || fail "sem a pergunta" || return 1
  ! grep -q '^terraform' "${T}/log" || fail "chamou terraform sem confirmar" || return 1
  run_lab recreate-app <<<""
  expect_rc 1 || return 1
  ! grep -q '^terraform' "${T}/log" || fail "chamou terraform com resposta vazia" || return 1
  run_lab recreate-app <<<"larcerto"
  expect_rc 0 || return 1
  grep -q '^terraform destroy -auto-approve' "${T}/log" || fail "nao destruiu depois de confirmar"
}

test_recreate_order_8_steps() {
  install_sandbox
  run_lab recreate-app --yes
  expect_rc 0 || return 1
  local i=0 name want="" got
  for name in prereqs start destroy terraform nuvem app dns-host checks; do
    i=$((i + 1))
    want+="==> [${i}/8] ${name}"$'\n'
  done
  got="$(grep -o '^==> \[[0-9]/8\] [a-z-]*' "${T}/out")"
  [[ "${got}" == "${want%$'\n'}" ]] || fail "ordem das etapas diferente: ${got}" || return 1
  ! grep -q 'Digite larcerto' "${T}/out" || fail "--yes perguntou"
}

test_recreate_destroy_args() {
  install_sandbox
  run_lab recreate-app --yes
  expect_rc 0 || return 1
  local cfg="${T}/project/cloud/secrets/clouds.yaml" ini des app
  ini="$(linha_log "terraform init cwd=terraform cloud=larcerto-devops1 cfg=${cfg}")"
  des="$(linha_log "terraform destroy -auto-approve cwd=terraform cloud=larcerto-devops1 cfg=${cfg}")"
  app="$(linha_log_re '^terraform apply -auto-approve ')"
  [[ -n "${ini}" && -n "${des}" && -n "${app}" && "${ini}" -lt "${des}" && "${des}" -lt "${app}" ]] \
    || fail "destroy sem init/clouds.yaml/devops1 ou depois do apply (${ini}/${des}/${app})"
}

test_recreate_success_output() {
  install_sandbox
  # o start demora 3 s; o tempo conta so do destroy em diante, entao fica em 0min00s/0min01s
  export FAKE_SLOW_START=3
  run_lab recreate-app --yes
  expect_rc 0 || return 1
  local fim
  fim="$(tail -3 "${T}/out")"
  grep -qE '^Recriado em 0min0[01]s$' <<<"${fim}" || fail "linha do tempo ausente ou contando o start: ${fim}" || return 1
  [[ "$(sed -n '2p' <<<"${fim}")" == "Pronto. Abra https://larcerto.com.br" ]] || fail "resumo fora de ordem: ${fim}"
}

test_recreate_failure_stops() {
  local pair step idx fake code cont
  for pair in start:2:start destroy:3:destroy terraform:4:apply nuvem:5:nuvem app:6:app dns-host:7:dns-host checks:8:checks; do
    IFS=: read -r step idx fake <<<"${pair}"
    install_sandbox
    export FAKE_FAIL="${fake}" FAKE_RC=7
    run_lab recreate-app --yes
    code="$(sed -n 's/^FALHOU na etapa .*codigo \([0-9]*\)$/\1/p' "${T}/err")"
    [[ -n "${code}" && "${RC}" -eq "${code}" && "${RC}" -ne 0 ]] || fail "${step}: codigo (${code}) diferente do exit (${RC})" || return 1
    grep -q "^FALHOU na etapa ${idx}/8 (${step}), codigo" "${T}/err" || fail "${step}: bloco de falha ausente" || return 1
    cont="./lab.sh install-app --from ${step}"
    [[ "${step}" == destroy ]] && cont="./lab.sh recreate-app"
    grep -qxF "Para continuar: ${cont}" "${T}/err" || fail "${step}: continuacao errada: $(grep 'Para continuar' "${T}/err")" || return 1
    [[ "$(grep -c '^==> \[' "${T}/out")" -eq "${idx}" ]] || fail "${step}: etapa depois da falha rodou" || return 1
    ! grep -q '^Recriado em' "${T}/out" || fail "${step}: mostrou o tempo depois de falhar" || return 1
    if [[ "${step}" == terraform ]]; then
      grep -q '^Dica: .*VM em ERROR.*\./lab\.sh vms' "${T}/err" || fail "dica do terraform sem VM em ERROR e lab.sh vms" || return 1
    fi
  done
}

test_recreate_needs_clouds_yaml() {
  install_sandbox
  rm -f "${T}/project/cloud/secrets/clouds.yaml"
  run_lab recreate-app --yes
  expect_rc 1 || return 1
  grep -q '^Falta: cloud/secrets/clouds.yaml do devops1 .* -> ./lab.sh install-app$' "${T}/err" || fail "sem a falta do clouds.yaml" || return 1
  ! grep -q '^terraform' "${T}/log" || fail "rodou terraform sem clouds.yaml"
}

test_start_waits_vip() {
  export FAKE_CONTAINER_IDS="k1" FAKE_VIP_FAILS=2
  run_lab start
  expect_rc 0 || return 1
  [[ "$(grep -c '^curl .*http://192.168.1.250:5000/' "${T}/log")" -eq 3 ]] || fail "nao repetiu ate a API responder" || return 1
  local cabo api
  cabo="$(linha_log_re '^nmcli .*(up|connection up)')"
  api="$(linha_log_re '^curl .*:5000/')"
  [[ -n "${api}" && ( -z "${cabo}" || "${cabo}" -lt "${api}" ) ]] || fail "esperou a API antes de reativar o cabo (${cabo}/${api})" || return 1
  grep -qx 'API respondendo em 192.168.1.250:5000.' "${T}/out" || fail "sem a linha da API"
}

test_start_vip_timeout() {
  export FAKE_CONTAINER_IDS="k1" FAKE_VIP_DOWN=1 VIP_WAIT=0
  run_lab start
  [[ "${RC}" -ne 0 ]] || fail "start saiu 0 sem a API" || return 1
  grep -q '^AVISO: a API em 192.168.1.250:5000 nao respondeu em 0s' "${T}/err" || fail "sem o aviso da API"
}

test_recreate_waits_api_before_destroy() {
  install_sandbox
  export FAKE_VIP_DOWN=1 VIP_WAIT=0
  run_lab recreate-app --yes
  [[ "${RC}" -ne 0 ]] || fail "seguiu sem a API" || return 1
  grep -q '^FALHOU na etapa 2/8 (start)' "${T}/err" || fail "nao parou no start" || return 1
  grep -qxF 'Para continuar: ./lab.sh install-app --from start' "${T}/err" || fail "continuacao errada" || return 1
  ! grep -q '^terraform' "${T}/log" || fail "rodou terraform sem a API" || return 1
  install_sandbox
  run_lab recreate-app --yes
  expect_rc 0 || return 1
  local api des
  api="$(linha_log_re '^curl .*:5000/')"
  des="$(linha_log_re '^terraform destroy')"
  [[ -n "${api}" && -n "${des}" && "${api}" -lt "${des}" ]] || fail "destroy antes de conferir a API (${api}/${des})"
}

test_recreate_bad_args() {
  install_sandbox
  local a
  for a in --bla "--yes extra" -y; do
    : >"${T}/log"
    # shellcheck disable=SC2086
    run_lab recreate-app ${a}
    expect_rc 1 || return 1
    grep -qx 'Uso: ./lab.sh recreate-app \[--yes\]' "${T}/err" || fail "${a}: sem a linha de uso" || return 1
    ! grep -q '^==> \[' "${T}/out" && ! grep -q '^terraform' "${T}/log" || fail "${a}: rodou etapa" || return 1
  done
  run_lab help
  grep -q '^  recreate-app ' "${T}/out" || fail "help sem recreate-app"
}

test_docs_recreate_app() {
  local d="${PROJECT_DIR}/docs" f
  for f in "${d}/lab.sh.md" "${d}/nuvem-larcerto.md" "${PROJECT_DIR}/README.md" "${d}/roteiro-video.md"; do
    grep -qF './lab.sh recreate-app' "${f}" || fail "$(basename "${f}") sem recreate-app" || return 1
  done
  grep -qF 'stop_host_libvirt` (root)' "${d}/lab.sh.md" && grep -qF 'Usa root no `start`' "${d}/lab.sh.md" \
    && grep -qF 'sudo systemctl start libvirtd.socket virtlogd.socket' "${d}/lab.sh.md" \
    || fail "lab.sh.md sem o passo do libvirt, o uso de root ou o rollback"
}

# ---------------------------------------------------------------- lab.sh cert cloud

# Certificado do Horizon (CN cloud, SAN cloud + horizon) assinado pela CA de <dir>; grava em <saida>.
cert_gera_cloud() {
  local dir="$1" saida="$2" dias="${3:-825}"
  mkdir -p "${saida}"
  "${REAL_OPENSSL}" req -newkey rsa:2048 -nodes -keyout "${saida}/cloud.key" -out "${saida}/cloud.csr" \
    -subj "/CN=cloud" 2>/dev/null
  printf 'subjectAltName=DNS:cloud.larcerto.com.br,DNS:horizon.larcerto.com.br\n' >"${saida}/ext.cnf"
  "${REAL_OPENSSL}" x509 -req -in "${saida}/cloud.csr" -CA "${dir}/ca.crt" -CAkey "${dir}/ca.key" \
    -CAcreateserial -days "${dias}" -extfile "${saida}/ext.cnf" -out "${saida}/cloud.crt" 2>/dev/null
  rm -f "${saida}/cloud.csr" "${saida}/ext.cnf" "${dir}/ca.srl"
}

# cert_sandbox + /etc/kolla falso, install que grava de verdade (pelo sudo falso), chown so registrado
# e grep real (o sudo falso so executa comandos do $T/bin).
cert_cloud_sandbox() {
  cert_sandbox
  export KOLLA_NODE_CONFIG="${T}/etc-kolla"
  mkdir -p "${KOLLA_NODE_CONFIG}/haproxy/services.d"
  export FAKE_CLOUD_PKI="${T}/cloud-pki"
  cert_gera_cloud "${FAKE_PKI}" "${FAKE_CLOUD_PKI}"
  local real_install real_grep
  real_install="$(command -v install)"
  real_grep="$(command -v grep)"
  fake install 'echo "install $*" >>"$FAKE_LOG"; exec "'"${real_install}"'" "$@"'
  fake chown 'echo "chown $*" >>"$FAKE_LOG"'
  fake grep 'exec "'"${real_grep}"'" "$@"'
}

test_cert_cloud_issues() {
  cert_cloud_sandbox
  run_lab cert cloud
  expect_rc 0 || return 1
  grep -qx 'ansible-playbook site.yml --limit ca -e cert_cloud=true cwd=ansible' "${T}/log" \
    || fail "chamada do ansible do cloud" || return 1
  grep -qx 'Horizon (cloud): emitido' "${T}/out" || fail "sem emitido" || return 1
  [[ "$(stat -c %a "${FAKE_PKI}/cloud.key")" == 600 ]] || fail "cloud.key sem modo 600" || return 1
}

test_cert_cloud_already_there() {
  cert_cloud_sandbox
  cp "${FAKE_CLOUD_PKI}/cloud.crt" "${FAKE_CLOUD_PKI}/cloud.key" "${FAKE_PKI}/"
  run_lab cert cloud
  expect_rc 0 || return 1
  grep -qx 'Horizon (cloud): ja existia' "${T}/out" || fail "sem ja existia" || return 1
  if grep -q ansible-playbook "${T}/log"; then fail "chamou o ansible com cloud.crt valido" || return 1; fi
}

test_cert_cloud_other_ca_reissues() {
  cert_cloud_sandbox
  cert_gera_pki "${T}/outra" 825
  cert_gera_cloud "${T}/outra" "${T}/outra-cloud"
  cp "${T}/outra-cloud/cloud.crt" "${T}/outra-cloud/cloud.key" "${FAKE_PKI}/"
  run_lab cert cloud
  expect_rc 0 || return 1
  grep -qF 'cert_cloud=true' "${T}/log" || fail "cloud.crt de outra CA nao foi reemitido" || return 1
  "${REAL_OPENSSL}" verify -CAfile "${FAKE_PKI}/ca.crt" "${FAKE_PKI}/cloud.crt" >/dev/null 2>&1 \
    || fail "cloud.crt final nao confere com a CA" || return 1
}

test_cert_cloud_without_hosts() {
  cert_cloud_sandbox
  rm -f "${T}/project/ansible/inventory/hosts.ini"
  run_lab cert cloud
  expect_rc 1 || return 1
  grep -qxF "Falta: ${T}/project/ansible/inventory/hosts.ini -> ./lab.sh install-app (o inventario sai do Terraform)" "${T}/err" \
    || fail "sem a mensagem exata do hosts.ini" || return 1
  if grep -q ansible-playbook "${T}/log"; then fail "chamou o ansible sem inventario" || return 1; fi
}

test_cert_cloud_without_ca_key() {
  cert_cloud_sandbox
  rm -f "${FAKE_PKI}/ca.key"
  run_lab cert cloud
  expect_rc 1 || return 1
  grep -qxF "Falta: ${FAKE_PKI}/ca.key -> ./lab.sh install-app --from nuvem" "${T}/err" \
    || fail "sem a mensagem exata do ca.key" || return 1
  if grep -q ansible-playbook "${T}/log"; then fail "chamou o ansible sem ca.key" || return 1; fi
}

test_cert_cloud_ansible_fails() {
  cert_cloud_sandbox
  FAKE_ANSIBLE_RC=7 run_lab cert cloud
  expect_rc 7 || return 1
  grep -qx 'FALHOU: cert cloud (ansible), codigo 7' "${T}/err" || fail "mensagem de falha" || return 1
  [[ ! -e "${KOLLA_NODE_CONFIG}/haproxy/haproxy.pem" ]] || fail "gravou o .pem com o ansible falhando" || return 1
  if grep -q 'docker restart' "${T}/log"; then fail "reiniciou o haproxy com o ansible falhando" || return 1; fi
}

test_cert_cloud_writes_pem() {
  cert_cloud_sandbox
  local pem="${KOLLA_NODE_CONFIG}/haproxy/haproxy.pem"
  run_lab cert cloud
  expect_rc 0 || return 1
  cat "${FAKE_PKI}/cloud.crt" "${FAKE_PKI}/ca.crt" "${FAKE_PKI}/cloud.key" >"${T}/esperado.pem"
  cmp -s "${T}/esperado.pem" "${pem}" || fail ".pem nao e cert + CA + chave" || return 1
  [[ "$(stat -c %a "${pem}")" == 600 ]] || fail ".pem sem modo 600" || return 1
  grep -qx "sudo install -D -m 600 .* ${pem}" "${T}/log" || fail "install sem run_as_root" || return 1
  grep -qx "chown root:root ${pem}" "${T}/log" || fail "sem chown root:root" || return 1
  [[ -z "$(find "${TMPDIR}" -type f)" ]] || fail "temporario com a chave ficou para tras" || return 1
}

# Sem o frontend (antes do primeiro deploy): grava o .pem, nao reinicia (o deploy reinicia) e pede o deploy.
test_cert_cloud_frontend_missing() {
  cert_cloud_sandbox
  : >"${KOLLA_NODE_CONFIG}/haproxy/services.d/horizon-https.cfg"
  run_lab cert cloud
  expect_rc 0 || return 1
  grep -qx 'Falta o frontend 443 do Horizon: rode ./lab.sh deploy uma vez' "${T}/out" || fail "sem o aviso do deploy" || return 1
  if grep -q 'docker restart' "${T}/log"; then fail "reiniciou o haproxy sem o frontend" || return 1; fi
  [[ -s "${KOLLA_NODE_CONFIG}/haproxy/haproxy.pem" ]] || fail "nao gravou o .pem" || return 1
}

test_cert_cloud_frontend_ready() {
  cert_cloud_sandbox
  printf 'frontend horizon_https_front\n' >"${KOLLA_NODE_CONFIG}/haproxy/services.d/horizon-https.cfg"
  run_lab cert cloud
  expect_rc 0 || return 1
  grep -qx 'docker restart haproxy' "${T}/log" || fail "nao reiniciou o haproxy" || return 1
  grep -qx 'haproxy reiniciado' "${T}/out" || fail "sem haproxy reiniciado" || return 1
  grep -qx 'Pronto: https://cloud.larcerto.com.br' "${T}/out" || fail "sem o endereco https" || return 1
  if grep -qF 'deploy uma vez' "${T}/out"; then fail "pediu deploy com o frontend pronto" || return 1; fi
  # /etc/kolla/haproxy e 0770 root no host: sem root o grep nunca acharia o frontend
  grep -qx "sudo grep -q horizon_https_front ${KOLLA_NODE_CONFIG}/haproxy/services.d/horizon-https.cfg" "${T}/log" \
    || fail "grep do frontend sem run_as_root" || return 1
}

test_cert_cloud_restart_fails() {
  cert_cloud_sandbox
  printf 'frontend horizon_https_front\n' >"${KOLLA_NODE_CONFIG}/haproxy/services.d/horizon-https.cfg"
  fake docker 'echo "docker $*" >>"$FAKE_LOG"; [[ "$1" == restart ]] && exit 5; exit 0'
  run_lab cert cloud
  expect_rc 5 || return 1
  grep -qx 'FALHOU: docker restart haproxy, codigo 5' "${T}/err" || fail "sem a mensagem do restart" || return 1
}

# Chave que nao e do par do cloud.crt: reemite.
test_cert_cloud_wrong_key_reissues() {
  cert_cloud_sandbox
  cert_gera_cloud "${FAKE_PKI}" "${T}/outro-par"
  cp "${FAKE_CLOUD_PKI}/cloud.crt" "${FAKE_PKI}/"
  cp "${T}/outro-par/cloud.key" "${FAKE_PKI}/"
  run_lab cert cloud
  expect_rc 0 || return 1
  grep -qF 'cert_cloud=true' "${T}/log" || fail "chave de outro par nao reemitiu" || return 1
}

# cloud.crt vencido (mesma CA e mesmo par): reemite. O openssl falso responde "vencido" ao -checkend.
test_cert_cloud_expired_reissues() {
  cert_cloud_sandbox
  cp "${FAKE_CLOUD_PKI}/cloud.crt" "${FAKE_CLOUD_PKI}/cloud.key" "${FAKE_PKI}/"
  fake openssl '
if [[ "$1" == x509 && " $* " == *" -checkend 0 "* ]]; then exit 1; fi
exec "'"${REAL_OPENSSL}"'" "$@"'
  run_lab cert cloud
  # o fetch falso traz o mesmo certificado, que segue "vencido": a checagem final deve recusar
  expect_rc 2 || return 1
  grep -qF 'cert_cloud=true' "${T}/log" || fail "cloud.crt vencido nao reemitiu" || return 1
}

test_cert_cloud_status_chain_invalid() {
  cert_cloud_sandbox
  cert_gera_pki "${T}/outra" 825
  cert_gera_cloud "${T}/outra" "${T}/outra-cloud"
  cp "${T}/outra-cloud/cloud.crt" "${T}/outra-cloud/cloud.key" "${FAKE_PKI}/"
  FAKE_SERVED_CLOUD_PEM="${FAKE_PKI}/cloud.crt" run_lab cert status
  expect_rc 2 || return 1
  grep -qF 'cloud.crt: verification failed' "${T}/out" || fail "verify do cloud nao falhou" || return 1
}

test_cert_cloud_status_expired() {
  cert_cloud_sandbox
  cp "${FAKE_CLOUD_PKI}/cloud.crt" "${FAKE_CLOUD_PKI}/cloud.key" "${FAKE_PKI}/"
  cert_gera_cloud "${FAKE_PKI}" "${T}/curto" 10
  cp "${T}/curto/cloud.crt" "${T}/curto/cloud.key" "${FAKE_PKI}/"
  # daqui a 100 dias: o wildcard (825) vale, o cloud (10) venceu
  CERT_NOW=$(( $(date +%s) + 100 * 86400 )) FAKE_SERVED_CLOUD_PEM="${FAKE_PKI}/cloud.crt" run_lab cert status
  expect_rc 2 || return 1
  grep -qx '  servido: igual' "${T}/out" || fail "servido deveria ser igual" || return 1
}

test_cert_cloud_new_ca_reminder() {
  cert_sandbox
  local novo="${T}/nova"
  cert_gera_pki "${novo}" 825
  export FAKE_NEW_PKI="${novo}"
  run_lab cert renew --new-ca --yes </dev/null
  expect_rc 0 || return 1
  grep -qx 'Reemita o do Horizon: ./lab.sh cert cloud' "${T}/out" || fail "sem o lembrete do cloud" || return 1
}

test_cert_cloud_status_ok() {
  cert_cloud_sandbox
  cp "${FAKE_CLOUD_PKI}/cloud.crt" "${FAKE_CLOUD_PKI}/cloud.key" "${FAKE_PKI}/"
  FAKE_SERVED_CLOUD_PEM="${FAKE_PKI}/cloud.crt" run_lab cert status
  expect_rc 0 || return 1
  grep -qx 'Horizon (cloud): CN=cloud' "${T}/out" || fail "CN do cloud" || return 1
  grep -qF 'SAN: DNS:cloud.larcerto.com.br, DNS:horizon.larcerto.com.br' "${T}/out" || fail "SAN do cloud" || return 1
  grep -qE '^  openssl verify: .*cloud.crt: OK$' "${T}/out" || fail "verify do cloud" || return 1
  grep -qx '  servido: igual' "${T}/out" || fail "servido do cloud" || return 1
}

test_cert_cloud_status_served_different() {
  cert_cloud_sandbox
  cp "${FAKE_CLOUD_PKI}/cloud.crt" "${FAKE_CLOUD_PKI}/cloud.key" "${FAKE_PKI}/"
  cert_gera_cloud "${FAKE_PKI}" "${T}/outro-cloud"
  FAKE_SERVED_CLOUD_PEM="${T}/outro-cloud/cloud.crt" run_lab cert status
  expect_rc 2 || return 1
  grep -qx '  servido: diferente' "${T}/out" || fail "servido diferente do cloud" || return 1
}

test_cert_cloud_status_unreachable() {
  cert_cloud_sandbox
  cp "${FAKE_CLOUD_PKI}/cloud.crt" "${FAKE_CLOUD_PKI}/cloud.key" "${FAKE_PKI}/"
  run_lab cert status
  expect_rc 0 || return 1
  grep -qx '  servido: inacessivel' "${T}/out" || fail "cloud sem resposta" || return 1
}

test_cert_cloud_status_not_issued() {
  cert_sandbox
  run_lab cert status
  expect_rc 0 || return 1
  grep -qx 'Horizon (cloud): nao emitido (./lab.sh cert cloud)' "${T}/out" || fail "sem nao emitido" || return 1
}

test_cert_cloud_trust_message() {
  cert_trust_sandbox
  run_lab cert trust
  expect_rc 0 || return 1
  grep -qF 'https://larcerto.com.br' "${T}/out" || fail "sem o site" || return 1
  grep -qF 'https://cloud.larcerto.com.br' "${T}/out" || fail "sem o Horizon" || return 1
}

# So o texto do ramo cert_cloud do papel ca (a execucao real e o C7, na nuvem).
test_cert_cloud_role_branch() {
  local f="${PROJECT_DIR}/ansible/roles/ca/tasks/main.yml" bloco
  grep -q 'cert_cloud | default(false) | bool' "${f}" || fail "ramo cert_cloud sem padrao desligado" || return 1
  bloco="$(sed -n '/Certificado do Horizon (cert_cloud=true/,/^- name: Dono dos arquivos da CA/p' "${f}")"
  grep -qF -- '--subject-alt-name="DNS:cloud.{{ domain }},DNS:horizon.{{ domain }}"' <<<"${bloco}" || fail "SAN do cloud" || return 1
  grep -qF 'build-server-full cloud nopass' <<<"${bloco}" || fail "sem build-server-full cloud" || return 1
  grep -qF 'openssl verify -CAfile pki/ca.crt pki/issued/cloud.crt' <<<"${bloco}" || fail "sem verify do cloud" || return 1
  grep -qF '["issued/cloud.crt", "private/cloud.key"]' <<<"${bloco}" || fail "sem fetch do cloud" || return 1
  if grep -qE 'ca\.key|ca\.crt"|cert_name' <<<"$(grep -v 'pki/ca.crt' <<<"${bloco}")"; then
    fail "ramo cloud mexe na CA ou no wildcard" || return 1
  fi
  grep -qF '"cloud.crt", "cloud.key"]' "${f}" || fail "ca_new nao apaga o cloud local" || return 1
}

# Renderiza o template do frontend com o Ansible do venv, como o kolla-ansible faz.
test_cloud_https_frontend_template() {
  local ansible="${HOME}/venvs/kolla/bin/ansible" tpl="${PROJECT_DIR}/kolla-config/config/haproxy/services.d/horizon-https.cfg"
  [[ -x "${ansible}" ]] || { fail "sem ${ansible}"; return 1; }
  mkdir -p "${T}/nc/haproxy"
  local render='msg={{ lookup("ansible.builtin.template", "'"${tpl}"'") }}'
  ANSIBLE_LOCALHOST_WARNING=false "${ansible}" localhost -c local -m ansible.builtin.debug -a "${render}" \
    -e node_config_directory="${T}/nc" -e kolla_internal_vip_address=192.168.1.250 >"${T}/out" 2>"${T}/err"
  if grep -qF 'frontend' "${T}/out"; then fail "frontend sem o .pem" || return 1; fi
  : >"${T}/nc/haproxy/haproxy.pem"
  ANSIBLE_LOCALHOST_WARNING=false "${ansible}" localhost -c local -m ansible.builtin.debug -a "${render}" \
    -e node_config_directory="${T}/nc" -e kolla_internal_vip_address=192.168.1.250 >"${T}/out" 2>"${T}/err"
  grep -qF 'bind 192.168.1.250:443 ssl crt /etc/haproxy/certificates/haproxy.pem' "${T}/out" || fail "bind 443" || return 1
  grep -qF 'default_backend horizon_back' "${T}/out" || fail "backend do Horizon" || return 1
  grep -qF 'X-Forwarded-Proto https' "${T}/out" || fail "X-Forwarded-Proto" || return 1
}

test_cloud_https_horizon_settings() {
  local f="${PROJECT_DIR}/kolla-config/config/horizon/_9999-custom-settings.py" g="${PROJECT_DIR}/kolla-config/globals.yml"
  grep -qxF "SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')" "${f}" || fail "sem SECURE_PROXY_SSL_HEADER" || return 1
  grep -qxF "DEFAULT_THEME = 'lux'" "${f}" || fail "perdeu o tema" || return 1
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${f}" || fail "settings nao e Python valido" || return 1
  if grep -qE '^kolla_enable_tls_(internal|external):' "${g}"; then fail "globals.yml ligou TLS do Kolla" || return 1; fi
}

test_cloud_https_cloud_check() {
  local f="${PROJECT_DIR}/tests/cloud-checks.sh" corpo
  corpo="$(sed -n '/^check_https_cloud()/,/^}/p' "${f}")"
  grep -qF -- '--cacert "${PKI}/ca.crt"' <<<"${corpo}" || fail "sem --cacert" || return 1
  grep -qF -- '--resolve "cloud.${DOMAIN}:443:192.168.1.250"' <<<"${corpo}" || fail "sem --resolve" || return 1
  grep -qF '/auth/login/' <<<"${corpo}" || fail "sem /auth/login/" || return 1
  if grep -E '^ALL=' "${f}" | grep -qw https_cloud; then fail "https_cloud na lista padrao" || return 1; fi
}

test_cloud_https_docs() {
  local d
  for d in docs/nuvem-larcerto.md docs/lab.sh.md README.md; do
    grep -qF 'cert cloud' "${PROJECT_DIR}/${d}" || fail "${d} sem cert cloud" || return 1
    grep -qF 'https://cloud.larcerto.com.br' "${PROJECT_DIR}/${d}" || fail "${d} sem https://cloud.larcerto.com.br" || return 1
  done
  setup_sandbox
  run_lab help
  grep -qF 'trust | cloud' "${T}/out" || fail "help sem cert cloud" || return 1
  grep -qF 'https://cloud.larcerto.com.br' "${T}/out" || fail "help sem o endereco" || return 1
}

ALL_STEP_NAMES=(prep prechecks deploy post-deploy prereqs start bootstrap terraform nuvem app dns-host checks cert-cloud deploy-https https-cloud)

all_sandbox() {
  install_sandbox
  unset FAKE_KOLLA_FAIL FAKE_KOLLA_FAIL_NTH
  export FAKE_PKI="${T}/project/ansible/files/pki" KOLLA_NODE_CONFIG="${T}/etc-kolla"
  mkdir -p "${KOLLA_NODE_CONFIG}/haproxy/services.d"
  cert_gera_pki "${FAKE_PKI}" 825
  cert_gera_cloud "${FAKE_PKI}" "${FAKE_PKI}"
  local real_install real_grep
  real_install="$(command -v install)"
  real_grep="$(command -v grep)"
  fake install 'echo "install $*" >>"$FAKE_LOG"; exec "'"${real_install}"'" "$@"'
  fake chown 'echo "chown $*" >>"$FAKE_LOG"'
  fake grep 'exec "'"${real_grep}"'" "$@"'
  cat >"${T}/venv/bin/kolla-ansible" <<EOF
#!/usr/bin/env bash
echo "kolla \$*" >>"\$FAKE_LOG"
echo "kolla-tmp \$(ls -A "\${TMPDIR}" | wc -l)" >>"\$FAKE_LOG"
if [[ "\$1" == "\${FAKE_KOLLA_FAIL:-}" ]]; then
  count="${T}/kolla-count-\$1"
  n=\$(( \$(cat "\${count}" 2>/dev/null || echo 0) + 1 ))
  echo "\${n}" >"\${count}"
  [[ "\${n}" -eq "\${FAKE_KOLLA_FAIL_NTH:-1}" ]] && exit 7
fi
exit 0
EOF
  chmod +x "${T}/venv/bin/kolla-ansible"
  cat >"${T}/project/tests/cloud-checks.sh" <<'EOF'
#!/usr/bin/env bash
echo "checks $*" >>"$FAKE_LOG"
if [[ $# -eq 0 && "${FAKE_FAIL:-}" == checks ]]; then exit "${FAKE_RC:-7}"; fi
if [[ "$1" == https_cloud && "${FAKE_FAIL:-}" == https-cloud ]]; then exit "${FAKE_RC:-7}"; fi
exit 0
EOF
  chmod +x "${T}/project/tests/cloud-checks.sh"
}

all_step_section() {
  awk -v step="$1" '
    /^==> \[[0-9]+\/15\] / { on = ($3 == step); next }
    on { print }
  ' "${T}/out"
}

test_all_runs_15_steps_in_order() {
  all_sandbox
  run_lab all
  expect_rc 0 || return 1
  local i=0 name want="" got
  for name in "${ALL_STEP_NAMES[@]}"; do
    i=$((i + 1))
    want+="==> [${i}/15] ${name}"$'\n'
  done
  got="$(grep -oE '^==> \[[0-9]+/15\] [a-z-]+' "${T}/out")"
  [[ "${got}" == "${want%$'\n'}" ]] || fail "ordem das etapas diferente: ${got}" || return 1
  local pem last_deploy https
  pem="$(grep -n "install -D -m 600 .*haproxy/haproxy.pem" "${T}/log" | head -1 | cut -d: -f1)"
  last_deploy="$(grep -n '^kolla deploy ' "${T}/log" | tail -1 | cut -d: -f1)"
  https="$(grep -n '^checks https_cloud$' "${T}/log" | cut -d: -f1)"
  [[ -n "${pem}" && -n "${last_deploy}" && -n "${https}" ]] || fail "falta .pem, deploy ou https_cloud no log" || return 1
  [[ "${pem}" -lt "${last_deploy}" ]] || fail ".pem depois do ultimo deploy" || return 1
  [[ "${last_deploy}" -lt "${https}" ]] || fail "https_cloud antes do ultimo deploy" || return 1
}

test_all_never_destroys_or_bootstraps() {
  all_sandbox
  run_lab all
  expect_rc 0 || return 1
  local got
  got="$(grep '^kolla ' "${T}/log" | awk '{ print $2 }' | paste -sd' ')"
  [[ "${got}" == "prechecks deploy post-deploy deploy" ]] || fail "acoes do Kolla: ${got}" || return 1
  if grep -qE '^kolla (destroy|bootstrap-servers)|^terraform destroy' "${T}/log"; then
    fail "chamou destroy ou bootstrap-servers" || return 1
  fi
}

test_all_deploy_steps_run_fixwired_extnet() {
  all_sandbox
  run_lab all
  expect_rc 0 || return 1
  local name
  for name in deploy post-deploy deploy-https; do
    all_step_section "${name}" | grep -q 'Padrao do lab: cabo' || fail "${name} sem fix-wired" || return 1
    all_step_section "${name}" | grep -q 'ext-net OK' || fail "${name} sem ext-net" || return 1
  done
  if all_step_section prechecks | grep -qE 'Padrao do lab: cabo|ext-net OK'; then
    fail "prechecks rodou fix-wired ou ext-net" || return 1
  fi
}

test_all_zorin_facts_each_kolla_step() {
  all_sandbox
  echo 'ID=zorin' >"${OS_RELEASE}"
  export FORCE_UBUNTU_FACTS=true
  run_lab all
  expect_rc 0 || return 1
  local n
  n="$(grep -c '^ansible .*-m setup' "${T}/log")"
  [[ "${n}" -eq 4 ]] || fail "setup chamado ${n} vezes" || return 1
  n="$(grep '^kolla ' "${T}/log" | grep -cE -- '-e @')"
  [[ "${n}" -eq 4 ]] || fail "${n} etapas Kolla com -e @facts" || return 1
  n="$(grep '^kolla ' "${T}/log" | grep -oE -- '-e @[^ ]+' | sort -u | wc -l)"
  [[ "${n}" -eq 4 ]] || fail "esperado 4 arquivos de facts, obtido ${n}" || return 1
  [[ "$(grep -c '^kolla-tmp 2$' "${T}/log")" -eq 4 ]] \
    || fail "temporarios de outra etapa durante o Kolla: $(grep '^kolla-tmp' "${T}/log" | paste -sd' ')" || return 1
  [[ -z "$(ls -A "${TMPDIR}")" ]] || fail "temporarios sobrando: $(ls -A "${TMPDIR}")" || return 1
}

test_all_prep_removes_host_ovs_before_kolla() {
  all_sandbox
  run_lab all
  expect_rc 0 || return 1
  local stop_ovs rm_ovs first_kolla
  stop_ovs="$(grep -n '^systemctl stop openvswitch-switch$' "${T}/log" | head -1 | cut -d: -f1)"
  rm_ovs="$(grep -n '^docker rm -f openvswitch_db openvswitch_vswitchd$' "${T}/log" | head -1 | cut -d: -f1)"
  first_kolla="$(grep -n '^kolla ' "${T}/log" | head -1 | cut -d: -f1)"
  [[ -n "${stop_ovs}" && -n "${rm_ovs}" && -n "${first_kolla}" ]] || fail "sem fix-ovs no log" || return 1
  [[ "${stop_ovs}" -lt "${first_kolla}" && "${rm_ovs}" -lt "${first_kolla}" ]] || fail "fix-ovs depois do Kolla" || return 1
}

test_all_https_waits_for_vip() {
  all_sandbox
  run_lab all
  expect_rc 0 || return 1
  local last_deploy vip https
  last_deploy="$(grep -n '^kolla deploy ' "${T}/log" | tail -1 | cut -d: -f1)"
  vip="$(grep -n '^curl .*http://192\.168\.1\.250:5000/$' "${T}/log" | tail -1 | cut -d: -f1)"
  https="$(grep -n '^checks https_cloud$' "${T}/log" | cut -d: -f1)"
  [[ -n "${last_deploy}" && -n "${vip}" && -n "${https}" ]] || fail "falta deploy, espera do VIP ou https_cloud" || return 1
  [[ "${last_deploy}" -lt "${vip}" && "${vip}" -lt "${https}" ]] || fail "https_cloud sem esperar o VIP" || return 1
  all_step_section https-cloud | grep -qx 'API respondendo em 192.168.1.250:5000.' || fail "etapa sem a espera do VIP" || return 1
  all_sandbox
  export FAKE_VIP_DOWN=1 VIP_WAIT=0
  run_lab all --from https-cloud
  expect_rc 1 || return 1
  grep -qx 'FALHOU na etapa 15/15 (https-cloud), codigo 1' "${T}/err" || fail "VIP fora: sem bloco de falha" || return 1
  if grep -q '^checks https_cloud$' "${T}/log"; then fail "VIP fora: rodou o https_cloud" || return 1; fi
}

test_install_prereqs_no_failure_block() {
  install_sandbox
  rm -f "${HOME}/.ssh/id_ed25519.pub"
  run_lab install-app
  expect_rc 1 || return 1
  if grep -qE '^FALHOU|^Para continuar' "${T}/err"; then fail "install-app: bloco nos prereqs" || return 1; fi
  install_sandbox
  rm -f "${T}/project/cloud/secrets/clouds.yaml"
  run_lab start-app
  expect_rc 1 || return 1
  if grep -qE '^FALHOU|^Para continuar' "${T}/err"; then fail "start-app: bloco nos prereqs" || return 1; fi
  install_sandbox
  rm -f "${T}/project/cloud/secrets/clouds.yaml"
  run_lab recreate-app --yes
  expect_rc 1 || return 1
  if grep -qE '^FALHOU|^Para continuar' "${T}/err"; then fail "recreate-app: bloco nos prereqs" || return 1; fi
}

test_all_success_output() {
  all_sandbox
  run_lab all
  expect_rc 0 || return 1
  grep -qx 'Pronto. Abra https://larcerto.com.br' "${T}/out" || fail "sem a URL da app" || return 1
  grep -qx 'Painel: https://cloud.larcerto.com.br' "${T}/out" || fail "sem a URL do painel" || return 1
}

all_break_step() {
  case "$1" in
    prep)
      fake ip 'echo "ip $*" >>"$FAKE_LOG"
case "$*" in
  "link show dummy0") exit 1 ;;
  "link add dummy0 type dummy") exit 7 ;;
esac
exit 0' ;;
    prechecks|deploy|post-deploy) export FAKE_KOLLA_FAIL="$1" ;;
    deploy-https) export FAKE_KOLLA_FAIL=deploy FAKE_KOLLA_FAIL_NTH=2 ;;
    prereqs) rm -f "${HOME}/.ssh/id_ed25519.pub" ;;
    cert-cloud) rm -f "${FAKE_PKI}/ca.key" ;;
    *) export FAKE_FAIL="$1" FAKE_RC=7 ;;
  esac
}

test_all_step_failure_stops() {
  local i=0 name want
  for name in "${ALL_STEP_NAMES[@]}"; do
    i=$((i + 1))
    all_sandbox
    all_break_step "${name}"
    run_lab all
    want=7
    case "${name}" in
      prereqs|cert-cloud) want=1 ;;
      start) want=123 ;;
    esac
    [[ "${RC}" -eq "${want}" ]] || fail "${name}: exit ${RC}, esperado ${want}" || return 1
    grep -qx "FALHOU na etapa ${i}/15 (${name}), codigo ${want}" "${T}/err" || fail "${name}: bloco de falha" || return 1
    grep -qE '^Dica: .+' "${T}/err" || fail "${name}: sem dica" || return 1
    grep -qx "Para continuar: ./lab.sh all --from ${name}" "${T}/err" || fail "${name}: linha de continuacao" || return 1
    [[ "$(grep -cE '^==> \[[0-9]+/15\] ' "${T}/out")" -eq "${i}" ]] || fail "${name}: etapa depois da falha rodou" || return 1
  done
}

test_all_from_runs_tail() {
  all_sandbox
  run_lab all --from nuvem
  expect_rc 0 || return 1
  local got
  got="$(grep -oE '^==> \[[0-9]+/15\] [a-z-]+' "${T}/out" | awk '{ print $2, $3 }' | paste -sd' ')"
  [[ "${got}" == "[5/15] prereqs [9/15] nuvem [10/15] app [11/15] dns-host [12/15] checks [13/15] cert-cloud [14/15] deploy-https [15/15] https-cloud" ]] \
    || fail "etapas: ${got}" || return 1
  if grep -qE '^bootstrap$|^terraform ' "${T}/log"; then fail "etapa anterior rodou" || return 1; fi
  [[ "$(grep -c '^kolla ' "${T}/log")" -eq 1 ]] || fail "so o deploy-https deveria chamar o Kolla" || return 1
}

test_all_from_unknown_exit_1() {
  all_sandbox
  run_lab all --from bogus
  expect_rc 1 || return 1
  grep -qxF "Etapa desconhecida: 'bogus'. Etapas validas: ${ALL_STEP_NAMES[*]}" "${T}/err" \
    || fail "sem a lista das 15 etapas" || return 1
  if grep -q '^==> ' "${T}/out"; then fail "alguma etapa rodou" || return 1; fi
  [[ ! -s "${T}/log" ]] || fail "chamou algum comando: $(cat "${T}/log")" || return 1
}

test_all_rejects_args() {
  local args
  for args in "foo" "--from" "--from nuvem extra"; do
    all_sandbox
    # shellcheck disable=SC2086
    run_lab all ${args}
    expect_rc 1 || return 1
    if [[ "${args}" == "--from" ]]; then
      grep -q '^Etapa desconhecida' "${T}/err" || fail "--from sem etapa: sem Etapa desconhecida" || return 1
    else
      grep -qxF 'Uso: ./lab.sh all [--from <etapa>]' "${T}/err" || fail "${args}: sem Uso" || return 1
    fi
    if grep -q '^==> ' "${T}/out"; then fail "${args}: alguma etapa rodou" || return 1; fi
    [[ ! -s "${T}/log" ]] || fail "${args}: chamou algum comando" || return 1
  done
}

test_kolla_single_action_each() {
  local pair cmd want got
  for pair in deploy:deploy bootstrap:bootstrap-servers prechecks:prechecks post-deploy:post-deploy stop-kolla:stop; do
    cmd="${pair%%:*}"
    want="${pair##*:}"
    : >"${T}/log"
    run_lab "${cmd}"
    expect_rc 0 || return 1
    got="$(grep '^kolla ' "${T}/log" | awk '{ print $2 }' | paste -sd' ')"
    [[ "${got}" == "${want}" ]] || fail "${cmd}: acoes ${got}, esperado ${want}" || return 1
  done
}

test_all_docs() {
  local d
  for d in README.md docs/lab.sh.md docs/kolla-ansible-quickstart.md; do
    grep -qF 'all --from' "${PROJECT_DIR}/${d}" || fail "${d} sem all --from" || return 1
    grep -iE 'm[aá]quina nova' "${PROJECT_DIR}/${d}" | grep -qF './lab.sh bootstrap' \
      || fail "${d} sem bootstrap para maquina nova" || return 1
  done
  run_lab help
  grep -qF 'all --from' "${T}/out" || grep -qF 'all [--from' "${T}/out" || fail "help sem all --from" || return 1
  grep -iE 'm[aá]quina nova' "${T}/out" | grep -qF './lab.sh bootstrap' \
    || fail "help sem bootstrap para maquina nova" || return 1
}

# ---------------------------------------------------------------- clear-all

CLEAR_STEPS_ALL=(start destroy-app dns-host ext-net kolla app-local files trust cabo)
CLEAR_GERADOS=(terraform/terraform.tfstate terraform/terraform.tfstate.backup ansible/inventory/hosts.ini
  cloud/secrets/clouds.yaml cloud/secrets/devops1.password kolla-config/clouds.yaml
  kolla-config/admin-openrc.sh kolla-config/public-openrc-system.sh ansible/files/pki/ca.key
  ansible/files/pki/cloud.crt ansible/files/pki/backup-20261101-000000/ca.key)
CLEAR_MANTIDOS=(kolla-config/passwords.yml kolla-config/globals.yml app/.env
  ansible/group_vars/all/secrets.yml terraform/.terraform/providers/x)

# clear_sandbox: o mundo antes de um clear-all completo: containers do Kolla e da app local,
# tfstate, todos os arquivos gerados e de configuracao, a CA num perfil do Firefox.
clear_sandbox() {
  install_sandbox
  local p
  export FAKE_APP_IDS="app1 app2"
  unset FAKE_DOCKER_RM_FAIL FAKE_KOLLA_RC FAKE_NO_BREX FAKE_IPV4 FAKE_IPTABLES_S_FAIL
  mkdir -p "${T}/project/ansible/files/pki/backup-20261101-000000" "${T}/project/terraform/.terraform/providers" \
    "${T}/project/app" "${HOME}/.mozilla/firefox/abc.default" "${HOME}/.pki/nssdb"
  for p in "${CLEAR_GERADOS[@]}"; do
    [[ -f "${T}/project/${p}" ]] || echo "gerado ${p}" >"${T}/project/${p}"
  done
  : >"${T}/project/ansible/files/pki/.gitkeep"
  echo 'keystone_admin_password: x' >"${T}/project/kolla-config/passwords.yml"
  echo 'DB_PASSWORD=local' >"${T}/project/app/.env"
  echo 'provider' >"${T}/project/terraform/.terraform/providers/x"
  : >"${HOME}/.mozilla/firefox/abc.default/cert9.db"
  echo 'CA' >"${HOME}/.mozilla/firefox/abc.default/larcerto-ca.pem"
  : >"${HOME}/.pki/nssdb/cert9.db"
  cert_fake_certutil
  # docker com filtros: kolla_version -> FAKE_CONTAINER_IDS, projeto larcerto -> FAKE_APP_IDS
  fake docker '
echo "docker $*" >>"$FAKE_LOG"
case "$1" in
  info) exit 0 ;;
  ps)
    case " $* " in
      *"label=com.docker.compose.project=larcerto"*) [[ -n "${FAKE_APP_IDS:-}" ]] && printf "%s\n" ${FAKE_APP_IDS} ;;
      *" -q "*|*" -aq "*) [[ -n "${FAKE_CONTAINER_IDS:-}" ]] && printf "%s\n" ${FAKE_CONTAINER_IDS} ;;
      *) [[ -n "${FAKE_DOCKER_NAMES:-}" ]] && printf "%s\n" ${FAKE_DOCKER_NAMES} ;;
    esac
    exit 0 ;;
  volume|image) [[ -n "${FAKE_DOCKER_RM_FAIL:-}" ]] && exit 1; exit 0 ;;
esac
exit 0'
}

# Linhas da saida da etapa <n> (do cabecalho dela ao proximo cabecalho de etapa).
clear_secao() {
  awk -v n="$1" '/^==> \[[0-9]+\/9\] /{ dentro = ($0 ~ "^==> \\[" n "/9\\] ") } dentro' "${T}/out"
}

clear_headers_ok() {
  local i=0 name want="" got
  for name in "${CLEAR_STEPS_ALL[@]}"; do
    i=$((i + 1))
    want+="==> [${i}/9] ${name}"$'\n'
  done
  # sem terminal, o primeiro cabecalho sai na linha da pergunta (o Enter nao e ecoado)
  got="$(grep -oE '(^|cancelar: )==> \[[0-9]/9\] [a-z-]*' "${T}/out" | sed 's/^cancelar: //')"
  [[ "${got}" == "${want%$'\n'}" ]] || fail "ordem das etapas diferente: ${got}"
}

test_clear_all_confirm_lists_and_asks() {
  clear_sandbox
  run_lab clear-all <<<"nao"
  local s
  for s in terraform.tfstate ansible/files/pki passwords.yml app/.env 'Digite yes para apagar tudo, ou qualquer outra coisa para cancelar'; do
    grep -qF -- "${s}" "${T}/out" || fail "a pergunta nao mostra ${s}" || return 1
  done
}

test_clear_all_wrong_word_cancels() {
  clear_sandbox
  local w
  for w in nao y YES sim apagar-tudo ""; do
    : >"${T}/log"
    run_lab clear-all <<<"${w}"
    expect_rc 1 || return 1
    grep -qE '(^|cancelar: )Cancelado\.$' "${T}/out" || fail "'${w}': sem Cancelado." || return 1
    grep -qxF 'Nada foi apagado.' "${T}/out" || fail "'${w}': sem Nada foi apagado." || return 1
    [[ ! -s "${T}/log" ]] || fail "'${w}': chamou algum comando" || return 1
  done
  : >"${T}/log"
  run_lab clear-all </dev/null
  expect_rc 1 || return 1
  grep -qE '(^|cancelar: )Cancelado\.$' "${T}/out" || fail "stdin fechado: sem Cancelado." || return 1
  [[ ! -s "${T}/log" ]] || fail "stdin fechado: chamou algum comando"
}

test_clear_all_rejects_args() {
  clear_sandbox
  local args
  for args in "foo" "--yes extra" "--from kolla"; do
    : >"${T}/log"
    # shellcheck disable=SC2086
    run_lab clear-all ${args}
    expect_rc 1 || return 1
    grep -qxF 'Uso: ./lab.sh clear-all [--yes]' "${T}/err" || fail "${args}: sem Uso" || return 1
    if grep -q '^==> ' "${T}/out"; then fail "${args}: alguma etapa rodou" || return 1; fi
    [[ ! -s "${T}/log" ]] || fail "${args}: chamou algum comando" || return 1
  done
}

test_clear_all_order_9_steps() {
  clear_sandbox
  run_lab clear-all <<<"yes"
  expect_rc 0 || return 1
  clear_headers_ok || return 1
  clear_sandbox
  run_lab clear-all --yes
  expect_rc 0 || return 1
  clear_headers_ok || return 1
  ! grep -q 'Digite yes' "${T}/out" || fail "--yes perguntou"
}

test_clear_all_success_output() {
  clear_sandbox
  run_lab clear-all --yes
  expect_rc 0 || return 1
  grep -qE '^Tudo apagado em [0-9]+min[0-9]{2}s$' "${T}/out" || fail "sem Tudo apagado em" || return 1
  grep -qxF 'Para subir de novo: ./lab.sh all' "${T}/out" || fail "sem Para subir de novo"
}

test_clear_all_never_recreates() {
  clear_sandbox
  run_lab clear-all --yes
  expect_rc 0 || return 1
  if grep -E '^terraform apply|^ansible-playbook|^kolla (deploy|post-deploy)|run\.sh' "${T}/log"; then
    fail "clear-all recriou algo" || return 1
  fi
}

test_clear_all_destroys_app_before_kolla() {
  clear_sandbox
  run_lab clear-all --yes
  expect_rc 0 || return 1
  clear_secao 1 | grep -qxF 'Containers Kolla iniciados.' || fail "start nao subiu os containers" || return 1
  local cfg="${T}/project/cloud/secrets/clouds.yaml" ini des kol
  ini="$(linha_log "terraform init cwd=terraform cloud=larcerto-devops1 cfg=${cfg}")"
  des="$(linha_log "terraform destroy -auto-approve cwd=terraform cloud=larcerto-devops1 cfg=${cfg}")"
  kol="$(linha_log_re '^kolla destroy ')"
  [[ -n "${ini}" && -n "${des}" && -n "${kol}" && "${ini}" -lt "${des}" && "${des}" -lt "${kol}" ]] \
    || fail "terraform destroy sem init/devops1 ou depois do kolla destroy (${ini}/${des}/${kol})"
}

test_clear_all_skips_without_kolla_or_state() {
  local mundo n
  for mundo in sem-kolla sem-tfstate; do
    clear_sandbox
    if [[ "${mundo}" == sem-kolla ]]; then
      export FAKE_CONTAINER_IDS=""
    else
      rm -f "${T}/project/terraform/terraform.tfstate"
    fi
    run_lab clear-all --yes
    expect_rc 0 || return 1
    for n in 1 2; do
      clear_secao "${n}" | grep -q '^pulado: ' || fail "${mundo}: etapa ${n} sem pulado:" || return 1
    done
    if grep -q '^terraform' "${T}/log"; then fail "${mundo}: chamou terraform" || return 1; fi
    if grep -qxF 'Containers Kolla iniciados.' "${T}/out"; then fail "${mundo}: rodou o start" || return 1; fi
  done
}

test_clear_all_dns_host_revert() {
  clear_sandbox
  run_lab clear-all --yes
  expect_rc 0 || return 1
  grep -qxF 'resolvectl revert br-ex' "${T}/log" || fail "sem resolvectl revert br-ex" || return 1
  clear_sandbox
  export FAKE_FAIL=dns-host
  run_lab clear-all --yes
  expect_rc 0 || return 1
  clear_secao 3 | grep -q '^pulado: ' || fail "resolvectl falhou e a etapa nao disse pulado:"
}

test_clear_all_ext_net_down() {
  clear_sandbox
  rm -f "${T}/project/terraform/terraform.tfstate"
  run_lab ext-net
  expect_rc 0 || return 1
  grep -q 'lab-ext-net' "${T}/rules" || fail "preparo: ext-net nao criou as regras" || return 1
  run_lab clear-all --yes
  expect_rc 0 || return 1
  if grep -q 'lab-ext-net' "${T}/rules"; then fail "sobrou regra lab-ext-net" || return 1; fi
  [[ ! -s "${T}/brex_addr" ]] || fail "sobrou 172.24.4.1/24 na br-ex" || return 1
  clear_sandbox
  rm -f "${T}/project/terraform/terraform.tfstate"
  export FAKE_NO_BREX=1
  run_lab clear-all --yes
  expect_rc 0 || return 1
  clear_secao 4 | grep -q '^pulado: ' || fail "sem br-ex e a etapa nao disse pulado:" || return 1
  [[ "$(grep -cxF 'ip link show br-ex' "${T}/log")" -le 1 ]] || fail "esperou a br-ex"
}

test_clear_all_kolla_destroy_args() {
  clear_sandbox
  run_lab clear-all --yes
  expect_rc 0 || return 1
  local p="${T}/project" want got
  want="kolla destroy -i ${p}/all-in-one --configdir ${p}/kolla-config --passwords ${p}/kolla-config/passwords.yml --yes-i-really-really-mean-it"
  got="$(grep '^kolla ' "${T}/log")"
  [[ "${got}" == "${want}" ]] || fail "linha do kolla: ${got}" || return 1
  grep -E '^sudo env .*kolla-ansible destroy ' "${T}/log" | grep -q . || fail "destroy sem sudo env" || return 1
  if grep -q -- '--include-images' "${T}/log"; then fail "apagou as imagens" || return 1; fi
}

test_no_kolla_destroy_outside_clear_all() {
  local args
  for args in deploy bootstrap prechecks post-deploy stop-kolla stop start all install-app start-app "recreate-app --yes"; do
    install_sandbox
    # shellcheck disable=SC2086
    run_lab ${args}
    if grep -q 'destroy -i' "${T}/log"; then fail "${args} chamou kolla-ansible destroy" || return 1; fi
  done
}

test_clear_all_removes_local_app() {
  clear_sandbox
  run_lab clear-all --yes
  expect_rc 0 || return 1
  grep -qxF 'docker ps -aq --filter label=com.docker.compose.project=larcerto' "${T}/log" || fail "nao listou o projeto larcerto" || return 1
  grep -qxF 'docker rm -f app1 app2' "${T}/log" || fail "nao removeu os containers da app" || return 1
  grep -qxF 'docker volume rm larcerto_db_data larcerto_uploads' "${T}/log" || fail "nao removeu os volumes" || return 1
  grep -qxF 'docker image rm larcerto-web larcerto-tests' "${T}/log" || fail "nao removeu as imagens" || return 1
  clear_sandbox
  export FAKE_DOCKER_RM_FAIL=1 FAKE_APP_IDS=""
  run_lab clear-all --yes
  expect_rc 0
}

test_clear_all_deletes_generated_files() {
  clear_sandbox
  run_lab clear-all --yes
  expect_rc 0 || return 1
  local p
  for p in "${CLEAR_GERADOS[@]}"; do
    [[ ! -e "${T}/project/${p}" ]] || fail "sobrou ${p}" || return 1
  done
  [[ ! -e "${T}/project/ansible/files/pki/backup-20261101-000000" ]] || fail "sobrou o backup da PKI" || return 1
  [[ -f "${T}/project/ansible/files/pki/.gitkeep" ]] || fail "apagou o .gitkeep"
}

test_clear_all_keeps_configuration() {
  clear_sandbox
  local antes depois
  antes="$(cd "${T}/project" && sha256sum "${CLEAR_MANTIDOS[@]}")"
  run_lab clear-all --yes
  expect_rc 0 || return 1
  depois="$(cd "${T}/project" && sha256sum "${CLEAR_MANTIDOS[@]}" 2>&1)"
  [[ "${antes}" == "${depois}" ]] || fail "configuracao mudou: ${depois}"
}

test_clear_all_untrusts_browser() {
  clear_sandbox
  run_lab clear-all --yes
  expect_rc 0 || return 1
  grep -qxF "${HOME}/.mozilla/firefox/abc.default: removido" "${T}/out" || fail "perfil do Firefox" || return 1
  grep -qxF "${HOME}/.pki/nssdb: nao estava" "${T}/out" || fail "~/.pki/nssdb" || return 1
  [[ ! -e "${HOME}/.mozilla/firefox/abc.default/larcerto-ca.pem" ]] || fail "a CA ficou no Firefox"
}

test_clear_all_trust_without_certutil() {
  clear_sandbox
  rm -f "${T}/bin/certutil"
  mkdir -p "${T}/semcert"
  local p
  for p in /usr/bin/* /bin/*; do
    [[ "$(basename "${p}")" == certutil ]] && continue
    ln -sfn "${p}" "${T}/semcert/$(basename "${p}")" 2>/dev/null
  done
  export PATH="${T}/bin:${T}/semcert"
  run_lab clear-all --yes
  expect_rc 0 || return 1
  clear_secao 8 | grep -qxF 'pulado: certutil ausente' || fail "sem pulado: certutil ausente"
}

test_clear_all_cabo_fix_wired() {
  clear_sandbox
  rm -f "${T}/project/terraform/terraform.tfstate"
  run_lab clear-all --yes
  expect_rc 0 || return 1
  clear_secao 9 | grep -qxF 'Cabo OK' || fail "cabo sem Cabo OK" || return 1
  clear_sandbox
  rm -f "${T}/project/terraform/terraform.tfstate"
  export FAKE_IPV4=0
  run_lab clear-all --yes
  expect_rc 1 || return 1
  grep -qxF 'FALHOU na etapa 9/9 (cabo), codigo 1' "${T}/err" || fail "sem o bloco de falha do cabo"
}

test_clear_all_step_failure_stops() {
  local caso n step rc k
  for caso in start:1:1 destroy-app:2:7 ext-net:4:1 kolla:5:5 cabo:9:1; do
    IFS=: read -r step n rc <<<"${caso}"
    clear_sandbox
    case "${step}" in
      start) export FAKE_VIP_DOWN=1 VIP_WAIT=0 ;;
      destroy-app) export FAKE_FAIL=destroy ;;
      ext-net) export FAKE_IPTABLES_S_FAIL=1 ;;
      kolla) export FAKE_KOLLA_RC=5 ;;
      cabo) rm -f "${T}/project/terraform/terraform.tfstate"; export FAKE_IPV4=0 ;;
    esac
    run_lab clear-all --yes
    expect_rc "${rc}" || return 1
    grep -qxF "FALHOU na etapa ${n}/9 (${step}), codigo ${rc}" "${T}/err" || fail "${step}: sem FALHOU" || return 1
    grep -qE '^Dica: .+' "${T}/err" || fail "${step}: sem Dica" || return 1
    grep -qxF 'Para continuar: ./lab.sh clear-all --yes' "${T}/err" || fail "${step}: sem Para continuar" || return 1
    for ((k = n + 1; k <= 9; k++)); do
      if grep -q "^==> \[${k}/9\]" "${T}/out"; then fail "${step}: rodou a etapa ${k} depois da falha" || return 1; fi
    done
    if grep -q '^Tudo apagado' "${T}/out"; then fail "${step}: disse Tudo apagado" || return 1; fi
  done
}

test_clear_all_kolla_hint() {
  clear_sandbox
  export FAKE_KOLLA_RC=5
  run_lab clear-all --yes
  expect_rc 5 || return 1
  grep '^Dica: ' "${T}/err" | grep -qF 'openstack server list --all-projects' || fail "Dica do kolla sem openstack server list"
}

test_clear_all_repeat_after_clear() {
  clear_sandbox
  run_lab clear-all --yes
  expect_rc 0 || return 1
  export FAKE_CONTAINER_IDS="" FAKE_APP_IDS=""
  : >"${T}/log"
  run_lab clear-all --yes
  expect_rc 0 || return 1
  clear_headers_ok || return 1
  if grep -q '^terraform' "${T}/log"; then fail "segunda rodada chamou terraform" || return 1; fi
  if grep -qxF 'Containers Kolla iniciados.' "${T}/out"; then fail "segunda rodada rodou o start" || return 1; fi
}

test_clear_all_docs() {
  local d s
  run_lab help
  for s in 'clear-all [--yes]' 'digitar yes' passwords.yml; do
    grep -qF -- "${s}" "${T}/out" || fail "help sem ${s}" || return 1
    for d in README.md docs/lab.sh.md; do
      grep -qF -- "${s}" "${PROJECT_DIR}/${d}" || fail "${d} sem ${s}" || return 1
    done
  done
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
  # o harness da app deixa um php -S no ar: derruba antes de apagar o sandbox
  if (setup_sandbox && "test_${name}"; rc=$?; [[ -f "${T}/server.pid" ]] && kill "$(cat "${T}/server.pid")" 2>/dev/null
      rm -rf "${T}"; exit "${rc}"); then
    echo "PASS ${name}"
  else
    echo "FAIL ${name}"
    failed=1
  fi
done
exit "${failed}"
