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
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ORIGINAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ORIGINAL_HOME="$(getent passwd "${ORIGINAL_USER}" | cut -d: -f6)"
ORIGINAL_HOME="${ORIGINAL_HOME:-$HOME}"

# Root sem senha: NOPASSWD, senao Docker+nsenter (grupo docker), senao sudo interativo.
run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    sudo "$@"
    return $?
  fi
  if docker info >/dev/null 2>&1; then
    docker run --rm --privileged --pid=host alpine:3.20 \
      nsenter -t 1 -m -u -i -n -- "$@"
    return $?
  fi
  echo "Precisa de root: sudo NOPASSWD, grupo docker, ou digite a senha." >&2
  sudo "$@"
}

VENV_PATH="${VENV_PATH:-$HOME/venvs/kolla}"
KOLLA_BIN="${KOLLA_BIN:-${VENV_PATH}/bin/kolla-ansible}"

INVENTORY="${INVENTORY:-${SCRIPT_DIR}/all-in-one}"
CONFIG_DIR="${CONFIG_DIR:-${SCRIPT_DIR}/kolla-config}"
PASSWORDS_FILE="${PASSWORDS_FILE:-${CONFIG_DIR}/passwords.yml}"
EXTRA_VARS="${EXTRA_VARS:-}"
FORCE_UBUNTU_FACTS="${FORCE_UBUNTU_FACTS:-true}"
USE_TEST_IMAGES="${USE_TEST_IMAGES:-true}"
AUTO_STOP_HOST_LIBVIRT="${AUTO_STOP_HOST_LIBVIRT:-true}"

ACTION="${1:-all}"

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

run_step() {
  local step="$1"
  echo
  echo "==> Executando: ${step}"

  local libvirt_sock_exists_before libvirtd_active_before libvirtd_socket_active_before virtlogd_active_before
  set +e
  test -S /var/run/libvirt/libvirt-sock
  libvirt_sock_exists_before=$?
  libvirtd_active_before="$(systemctl is-active libvirtd 2>/dev/null || true)"
  libvirtd_socket_active_before="$(systemctl is-active libvirtd.socket 2>/dev/null || true)"
  virtlogd_active_before="$(systemctl is-active virtlogd 2>/dev/null || true)"
  set -e

  if [[ "${AUTO_STOP_HOST_LIBVIRT}" == "true" ]]; then
    if [[ "${libvirt_sock_exists_before}" -eq 0 || "${libvirtd_active_before}" == "active" || "${libvirtd_socket_active_before}" == "active" ]]; then
      run_as_root systemctl stop libvirtd.socket libvirtd virtlogd.socket virtlogd >/dev/null 2>&1 || true
    fi
  fi

  local docker_import_rc docker_import_out
  set +e
  docker_import_out="$("${VENV_PATH}/bin/python3" -c 'import docker; print(docker.__version__)' 2>&1)"
  docker_import_rc=$?
  set -e
  if [[ "${docker_import_rc}" -ne 0 ]]; then
    "${VENV_PATH}/bin/pip" install docker >/dev/null
    set +e
    docker_import_out="$("${VENV_PATH}/bin/python3" -c 'import docker; print(docker.__version__)' 2>&1)"
    docker_import_rc=$?
    set -e
  fi

  local dbus_import_rc dbus_import_out
  set +e
  dbus_import_out="$("${VENV_PATH}/bin/python3" -c 'import dbus; print("ok")' 2>&1)"
  dbus_import_rc=$?
  set -e
  if [[ "${dbus_import_rc}" -ne 0 ]]; then
    "${VENV_PATH}/bin/pip" install dbus-python >/dev/null
    set +e
    dbus_import_out="$("${VENV_PATH}/bin/python3" -c 'import dbus; print("ok")' 2>&1)"
    dbus_import_rc=$?
    set -e
  fi

  # Zorin OS reporta facts fora do esperado pelo Kolla.
  # Geramos facts completos e apenas ajustamos os campos de distro/familia.
  local facts_file=""
  local effective_extra_vars="${EXTRA_VARS}"
  if [[ "${FORCE_UBUNTU_FACTS}" == "true" ]] && grep -qi '^ID=zorin' /etc/os-release 2>/dev/null; then
    local facts_dir
    facts_dir="$(mktemp -d)"
    facts_file="$(mktemp)"
    "${VENV_PATH}/bin/ansible" localhost -c local -m setup --tree "${facts_dir}" >/dev/null
    python3 - "${facts_dir}/localhost" "${facts_file}" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)

facts = data.get("ansible_facts", {})
# Normalize setup facts: ansible-core returns many keys prefixed with
# "ansible_", while Kolla roles/filters read unprefixed keys from
# ansible_facts (e.g. interfaces, service_mgr, python, <iface>).
for key, value in list(facts.items()):
    if key.startswith("ansible_"):
        short_key = key[len("ansible_"):]
        facts.setdefault(short_key, value)
# Kolla roles may access ansible_facts.hostname directly.
# Some distros expose only ansible_hostname in collected facts.
if "hostname" not in facts and "ansible_hostname" in facts:
    facts["hostname"] = facts["ansible_hostname"]
# Kolla roles may also access ansible_facts.python.version.* directly.
# Some environments expose only ansible_python in collected facts.
if "python" not in facts and "ansible_python" in facts:
    facts["python"] = facts["ansible_python"]
# Kolla prechecks expects ansible_facts.service_mgr.
if "service_mgr" not in facts:
    if "ansible_service_mgr" in facts:
        facts["service_mgr"] = facts["ansible_service_mgr"]
    elif "proc_cmdline" in facts and "init=" in str(facts["proc_cmdline"]):
        # Best-effort fallback for systems where setup omits service manager fact.
        facts["service_mgr"] = "systemd"
facts["os_family"] = "Debian"
facts["distribution"] = "Ubuntu"
facts["distribution_release"] = "noble"
facts["distribution_major_version"] = "24"

with open(dst, "w", encoding="utf-8") as f:
    json.dump({"ansible_facts": facts}, f)
PY
    rm -rf "${facts_dir}"
    if [[ -n "${effective_extra_vars}" ]]; then
      effective_extra_vars="${effective_extra_vars} -e @${facts_file}"
    else
      effective_extra_vars="-e @${facts_file}"
    fi
  fi

  local -a cmd=(
    "${KOLLA_BIN}" "${step}"
    -i "${INVENTORY}"
    --configdir "${CONFIG_DIR}"
    --passwords "${PASSWORDS_FILE}"
  )
  if [[ "${USE_TEST_IMAGES}" == "true" && "${step}" == "prechecks" ]]; then
    cmd+=(--use-test-images)
  fi

  if [[ -n "${EXTRA_VARS}" ]]; then
    cmd+=(-e "${EXTRA_VARS}")
  fi
  if [[ -n "${facts_file}" ]]; then
    cmd+=(-e "@${facts_file}")
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

  if [[ -n "${facts_file}" && -f "${facts_file}" ]]; then
    rm -f "${facts_file}"
  fi
}

case "${ACTION}" in
  bootstrap)
    run_step "bootstrap-servers"
    ;;
  prechecks)
    run_step "prechecks"
    ;;
  deploy)
    run_step "deploy"
    ;;
  post-deploy)
    run_step "post-deploy"
    ;;
  stop)
    run_step "stop"
    ;;
  all)
    run_step "bootstrap-servers"
    run_step "prechecks"
    run_step "deploy"
    ;;
  *)
    echo "Uso: $0 {all|bootstrap|prechecks|deploy|post-deploy|stop}" >&2
    exit 1
    ;;
esac
