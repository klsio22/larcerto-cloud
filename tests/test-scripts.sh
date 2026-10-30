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
  fake sudo '
echo "sudo $*" >>"$FAKE_LOG"
[[ "$1" == "-n" ]] && exit 0
[[ "$1" == "env" ]] && exec "$@"
exit 0'
  fake systemctl '
echo "systemctl $*" >>"$FAKE_LOG"
[[ "$1" == "is-active" ]] && { echo inactive; exit 3; }
exit 0'
  fake ip '
echo "ip $*" >>"$FAKE_LOG"
case "$*" in
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
