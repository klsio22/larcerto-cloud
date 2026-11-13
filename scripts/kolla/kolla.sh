# Comandos Kolla (bootstrap, prechecks, deploy, post-deploy, stop-kolla) via kolla-ansible.
# Carregado pelo lab.sh; so define funcoes e variaveis. Sem o antigo wrapper na raiz.
# shellcheck shell=bash

INVENTORY="${INVENTORY:-${SCRIPT_DIR}/all-in-one}"
CONFIG_DIR="${CONFIG_DIR:-${SCRIPT_DIR}/kolla-config}"
PASSWORDS_FILE="${PASSWORDS_FILE:-${CONFIG_DIR}/passwords.yml}"
EXTRA_VARS="${EXTRA_VARS:-}"
FORCE_UBUNTU_FACTS="${FORCE_UBUNTU_FACTS:-true}"
USE_TEST_IMAGES="${USE_TEST_IMAGES:-true}"
AUTO_STOP_HOST_LIBVIRT="${AUTO_STOP_HOST_LIBVIRT:-true}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
VENV_PATH="${VENV_PATH:-$HOME/venvs/kolla}"
KOLLA_BIN="${KOLLA_BIN:-${VENV_PATH}/bin/kolla-ansible}"

# Temporarios dos facts do Zorin; removidos em qualquer saida (inclusive falha do Kolla).
FACTS_DIR=""
FACTS_FILE=""
kolla_cleanup() {
  if [[ -n "${FACTS_DIR}" ]]; then rm -rf "${FACTS_DIR}"; fi
  if [[ -n "${FACTS_FILE}" ]]; then rm -f "${FACTS_FILE}"; fi
}

kolla_check_prereqs() {
  if [[ ! -x "${KOLLA_BIN}" ]]; then
    echo "Erro: kolla-ansible nao encontrado em: ${KOLLA_BIN}" >&2
    echo "Defina VENV_PATH ou KOLLA_BIN corretamente e tente novamente." >&2
    exit 1
  fi
  if [[ ! -f "${INVENTORY}" ]]; then
    echo "Erro: inventory nao encontrado em: ${INVENTORY}" >&2
    exit 1
  fi
  if [[ ! -d "${CONFIG_DIR}" ]]; then
    echo "Erro: configdir nao encontrado em: ${CONFIG_DIR}" >&2
    exit 1
  fi
  if [[ ! -f "${PASSWORDS_FILE}" ]]; then
    echo "Erro: arquivo de senhas nao encontrado em: ${PASSWORDS_FILE}" >&2
    echo "Gere com: cp ${VENV_PATH}/share/kolla-ansible/etc_examples/kolla/passwords.yml ${PASSWORDS_FILE} && ${VENV_PATH}/bin/kolla-genpwd -p ${PASSWORDS_FILE}" >&2
    exit 1
  fi
}

# ensure_py_module <modulo> <pacote pip>: instala no venv se o import falhar.
kolla_ensure_py_module() {
  local module="$1"
  local package="$2"
  if ! "${VENV_PATH}/bin/python3" -c "import ${module}" >/dev/null 2>&1; then
    "${VENV_PATH}/bin/pip" install "${package}" >/dev/null
  fi
}

# Zorin OS reporta facts fora do esperado pelo Kolla.
# Geramos facts completos uma vez e apenas ajustamos os campos de distro/familia.
kolla_build_zorin_facts() {
  if [[ "${FORCE_UBUNTU_FACTS}" != "true" ]] || ! grep -qi '^ID=zorin' "${OS_RELEASE}" 2>/dev/null; then
    return 0
  fi
  FACTS_DIR="$(mktemp -d)"
  FACTS_FILE="$(mktemp)"
  "${VENV_PATH}/bin/ansible" localhost -c local -m setup --tree "${FACTS_DIR}" >/dev/null
  python3 "${SCRIPT_DIR}/scripts/kolla/zorin_facts.py" "${FACTS_DIR}/localhost" "${FACTS_FILE}"
}

kolla_run_step() {
  local kolla_step="$1"
  echo
  step "Executando: ${kolla_step}"

  stop_host_libvirt || true

  local -a cmd=(
    "${KOLLA_BIN}" "${kolla_step}"
    -i "${INVENTORY}"
    --configdir "${CONFIG_DIR}"
    --passwords "${PASSWORDS_FILE}"
  )
  if [[ "${USE_TEST_IMAGES}" == "true" && "${kolla_step}" == "prechecks" ]]; then
    cmd+=(--use-test-images)
  fi
  if [[ -n "${EXTRA_VARS}" ]]; then
    cmd+=(-e "${EXTRA_VARS}")
  fi
  if [[ -n "${FACTS_FILE}" ]]; then
    cmd+=(-e "@${FACTS_FILE}")
  fi

  # Kolla precisa de root (become). Sem sudo NOPASSWD, usa Docker+nsenter.
  run_as_root env \
    "PATH=${VENV_PATH}/bin:${PATH}" \
    "HOME=${ORIGINAL_HOME}" \
    "USER=root" \
    "LOGNAME=root" \
    "SUDO_USER=${ORIGINAL_USER}" \
    "ANSIBLE_COLLECTIONS_PATH=${ORIGINAL_HOME}/.ansible/collections:/usr/share/ansible/collections" \
    "${cmd[@]}"
}

# kolla_run <acao>: roda as etapas Kolla da acao (sem o fix-wired/ext-net, que e do cmd_kolla).
kolla_run() {
  local action="$1"
  local steps=()

  ORIGINAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
  ORIGINAL_HOME="$(getent passwd "${ORIGINAL_USER}" | cut -d: -f6)"
  ORIGINAL_HOME="${ORIGINAL_HOME:-$HOME}"

  case "${action}" in
    bootstrap) steps=(bootstrap-servers) ;;
    prechecks|deploy|post-deploy|stop) steps=("${action}") ;;
    *)
      echo "Uso: ./lab.sh {bootstrap|prechecks|deploy|post-deploy|stop-kolla}" >&2
      exit 1
      ;;
  esac

  kolla_check_prereqs
  trap kolla_cleanup EXIT
  kolla_ensure_py_module docker docker
  kolla_ensure_py_module dbus dbus-python
  kolla_build_zorin_facts

  local s
  for s in "${steps[@]}"; do
    kolla_run_step "${s}"
  done
}

cmd_kolla() {
  local action="$1"
  # Com set -e, uma falha em kolla_run encerra o lab.sh com o mesmo codigo do kolla-ansible.
  kolla_run "${action}"
  # Padrao do lab AIO: apos subir a nuvem, NIC de gestao fora do br-ex.
  case "${action}" in
    deploy|post-deploy)
      echo
      step "Padrao do lab: cabo (network_interface) fora do br-ex"
      if ! cmd_fix_wired; then
        echo "AVISO: fix-wired nao confirmou IPv4 (cabo desligado?). Deploy Kolla terminou OK." >&2
      fi
      if ! cmd_ext_net; then
        echo "AVISO: ext-net falhou. Deploy Kolla terminou OK; tente: ./lab.sh ext-net" >&2
      fi
      ;;
  esac
}
