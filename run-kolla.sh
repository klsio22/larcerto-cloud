#!/usr/bin/env bash
set -euo pipefail

# Wrapper para executar kolla-ansible com os caminhos deste projeto.
# Uso:
#   ./project/run-kolla.sh all
#   ./project/run-kolla.sh bootstrap
#   ./project/run-kolla.sh prechecks
#   ./project/run-kolla.sh deploy
#   ./project/run-kolla.sh post-deploy
#   ./project/run-kolla.sh stop

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ORIGINAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ORIGINAL_HOME="$(getent passwd "${ORIGINAL_USER}" | cut -d: -f6)"
ORIGINAL_HOME="${ORIGINAL_HOME:-$HOME}"

VENV_PATH="${VENV_PATH:-$HOME/venvs/kolla}"
KOLLA_BIN="${KOLLA_BIN:-${VENV_PATH}/bin/kolla-ansible}"

INVENTORY="${INVENTORY:-${SCRIPT_DIR}/all-in-one}"
CONFIG_DIR="${CONFIG_DIR:-${SCRIPT_DIR}/kolla-config}"
PASSWORDS_FILE="${PASSWORDS_FILE:-${CONFIG_DIR}/passwords.yml}"
EXTRA_VARS="${EXTRA_VARS:-}"
FORCE_UBUNTU_FACTS="${FORCE_UBUNTU_FACTS:-true}"
USE_TEST_IMAGES="${USE_TEST_IMAGES:-true}"
AUTO_STOP_HOST_LIBVIRT="${AUTO_STOP_HOST_LIBVIRT:-true}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"

ACTION="${1:-all}"

check_prereqs() {
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
    exit 1
  fi
}

# Temporarios dos facts do Zorin; removidos em qualquer saida (inclusive falha do Kolla).
FACTS_DIR=""
FACTS_FILE=""
cleanup() {
  if [[ -n "${FACTS_DIR}" ]]; then rm -rf "${FACTS_DIR}"; fi
  if [[ -n "${FACTS_FILE}" ]]; then rm -f "${FACTS_FILE}"; fi
}
trap cleanup EXIT

# Libvirt do host conflita com o nova_libvirt em container.
stop_host_libvirt() {
  if [[ "${AUTO_STOP_HOST_LIBVIRT}" != "true" ]]; then
    return 0
  fi
  if test -S /var/run/libvirt/libvirt-sock \
    || [[ "$(systemctl is-active libvirtd 2>/dev/null || true)" == "active" ]] \
    || [[ "$(systemctl is-active libvirtd.socket 2>/dev/null || true)" == "active" ]]; then
    run_as_root systemctl stop libvirtd.socket libvirtd virtlogd.socket virtlogd >/dev/null 2>&1 || true
  fi
}

# ensure_py_module <modulo> <pacote pip>: instala no venv se o import falhar.
ensure_py_module() {
  local module="$1"
  local package="$2"
  if ! "${VENV_PATH}/bin/python3" -c "import ${module}" >/dev/null 2>&1; then
    "${VENV_PATH}/bin/pip" install "${package}" >/dev/null
  fi
}

# Zorin OS reporta facts fora do esperado pelo Kolla.
# Geramos facts completos uma vez e apenas ajustamos os campos de distro/familia.
build_zorin_facts() {
  if [[ "${FORCE_UBUNTU_FACTS}" != "true" ]] || ! grep -qi '^ID=zorin' "${OS_RELEASE}" 2>/dev/null; then
    return 0
  fi
  FACTS_DIR="$(mktemp -d)"
  FACTS_FILE="$(mktemp)"
  "${VENV_PATH}/bin/ansible" localhost -c local -m setup --tree "${FACTS_DIR}" >/dev/null
  python3 "${SCRIPT_DIR}/lib/zorin_facts.py" "${FACTS_DIR}/localhost" "${FACTS_FILE}"
}

run_step() {
  local kolla_step="$1"
  echo
  step "Executando: ${kolla_step}"

  stop_host_libvirt

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

check_prereqs

case "${ACTION}" in
  bootstrap) steps=(bootstrap-servers) ;;
  prechecks|deploy|post-deploy|stop) steps=("${ACTION}") ;;
  all) steps=(bootstrap-servers prechecks deploy) ;;
  *)
    echo "Uso: $0 {all|bootstrap|prechecks|deploy|post-deploy|stop}" >&2
    exit 1
    ;;
esac

ensure_py_module docker docker
ensure_py_module dbus dbus-python
build_zorin_facts

for s in "${steps[@]}"; do
  run_step "${s}"
done
