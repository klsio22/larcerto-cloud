# Comandos Kolla (venv, bootstrap, prechecks, deploy, post-deploy, stop-kolla) via kolla-ansible.
# Carregado pelo larcerto.sh; so define funcoes e variaveis. Sem o antigo wrapper na raiz.
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
    echo "Crie o venv com ./larcerto.sh venv (ou defina VENV_PATH ou KOLLA_BIN)." >&2
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
    echo "Gere com: ./larcerto.sh venv (ou: cp ${VENV_PATH}/share/kolla-ansible/etc_examples/kolla/passwords.yml ${PASSWORDS_FILE} && ${VENV_PATH}/bin/kolla-genpwd -p ${PASSWORDS_FILE})" >&2
    exit 1
  fi
}

# ---- venv: o passo "Install dependencies" do quickstart do Kolla, num comando.
VENV_PYTHON="${VENV_PYTHON:-python3}"
KOLLA_ANSIBLE_SRC="${KOLLA_ANSIBLE_SRC:-git+https://opendev.org/openstack/kolla-ansible@master}"
OPENSTACK_CONSTRAINTS="${OPENSTACK_CONSTRAINTS:-https://releases.openstack.org/constraints/upper/master}"
VENV_APT_PKGS="python3-venv python3-dev git gcc libffi-dev libssl-dev libdbus-glib-1-dev"

# Pacotes do sistema que o venv precisa. So confere: o apt (sudo) fica com o aluno.
venv_check_system() {
  local -a falta=()
  if ! command -v "${VENV_PYTHON}" >/dev/null 2>&1; then
    falta+=("${VENV_PYTHON}")
  else
    "${VENV_PYTHON}" -c 'import ensurepip' >/dev/null 2>&1 || falta+=("python3-venv (sem ensurepip)")
    "${VENV_PYTHON}" -c 'import os, sys, sysconfig; sys.exit(not os.path.exists(os.path.join(sysconfig.get_paths()["include"], "Python.h")))' \
      >/dev/null 2>&1 || falta+=("python3-dev (sem Python.h)")
  fi
  command -v git >/dev/null 2>&1 || falta+=(git)
  command -v gcc >/dev/null 2>&1 || falta+=(gcc)
  [[ ${#falta[@]} -eq 0 ]] && return 0
  echo "Falta no sistema: ${falta[*]}" >&2
  echo "Instale (uma vez) e rode de novo: sudo apt install ${VENV_APT_PKGS}" >&2
  return 1
}

# O Kolla suporta o Python padrao dos sistemas da support matrix (Ubuntu 24.04 e Rocky 10: 3.12; Debian 13: 3.13).
venv_python_warning() {
  local v
  v="$("${VENV_PYTHON}" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  case "${v}" in
    3.12|3.13) ;;
    *) echo "AVISO: Python ${v} fora da support matrix do Kolla (3.12/3.13); se a instalacao falhar, use VENV_PYTHON=python3.12" >&2 ;;
  esac
}

# passwords.yml so quando falta: regenerar trocaria as senhas de um Kolla ja implantado.
venv_passwords() {
  [[ -f "${PASSWORDS_FILE}" ]] && return 0
  local example="${VENV_PATH}/share/kolla-ansible/etc_examples/kolla/passwords.yml"
  local tmp="${PASSWORDS_FILE}.tmp"
  if [[ ! -f "${example}" ]]; then
    echo "Erro: falta ${example} (kolla-ansible do venv incompleto: rm -rf ${VENV_PATH} e rode de novo)" >&2
    return 1
  fi
  cp "${example}" "${tmp}"
  chmod 600 "${tmp}"
  "${VENV_PATH}/bin/kolla-genpwd" -p "${tmp}" >/dev/null
  mv "${tmp}" "${PASSWORDS_FILE}"
  echo "Gerado: ${PASSWORDS_FILE} (senhas do Kolla, fora do git)"
}

# ./larcerto.sh venv: cria o venv do Kolla; refaz so o que falta (a marca diz que terminou).
cmd_venv() {
  if [[ $# -gt 0 ]]; then
    echo "Uso: ./larcerto.sh venv   (caminho: VENV_PATH=${VENV_PATH}; Python: VENV_PYTHON=${VENV_PYTHON})" >&2
    exit 1
  fi
  local bin="${VENV_PATH}/bin"
  local mark="${VENV_PATH}/.larcerto-venv"
  if [[ -f "${mark}" && -x "${bin}/kolla-ansible" && -x "${bin}/openstack" ]]; then
    venv_passwords
    echo "venv OK: ${VENV_PATH} (ja estava)"
    return 0
  fi

  venv_check_system || exit 1
  # sem pip = criacao parou no meio: o venv do python3 completa a pasta existente
  if [[ ! -x "${bin}/pip" ]]; then
    venv_python_warning
    step "Criando o venv em ${VENV_PATH}"
    "${VENV_PYTHON}" -m venv "${VENV_PATH}"
  fi
  step "pip, kolla-ansible e cliente openstack"
  "${bin}/pip" install -U pip
  [[ -x "${bin}/kolla-ansible" ]] || "${bin}/pip" install "${KOLLA_ANSIBLE_SRC}"
  [[ -x "${bin}/openstack" ]] || "${bin}/pip" install python-openstackclient -c "${OPENSTACK_CONSTRAINTS}"
  kolla_ensure_py_module docker docker
  kolla_ensure_py_module dbus dbus-python
  step "Colecoes do Ansible (kolla-ansible install-deps)"
  # install-deps chama ansible-galaxy pelo PATH: sem o venv ativado, so o bin do venv o tem
  PATH="${bin}:${PATH}" "${bin}/kolla-ansible" install-deps
  : >"${mark}"
  venv_passwords
  echo "venv OK: ${VENV_PATH}"
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
  if [[ "${kolla_step}" == destroy ]]; then
    cmd+=(--yes-i-really-really-mean-it)
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
    prechecks|deploy|post-deploy|stop|destroy) steps=("${action}") ;;
    *)
      echo "Uso: ./larcerto.sh {bootstrap|prechecks|deploy|post-deploy|stop-kolla}" >&2
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

# O Kolla (precheck do rabbitmq) exige que o hostname resolva so para o IP do network_interface.
# No Ubuntu, o /etc/hosts vem com "127.0.1.1 <hostname>": quem troca isso e o bootstrap
# (role etc_hosts do Kolla). So leitura: para antes do Ansible, com o comando que resolve.
kolla_check_hostname() {
  local ifc ip host got
  ifc="$(network_iface)"
  ip="$(ip -4 -o addr show "${ifc}" 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')"
  # sem IP na interface: o proprio Kolla reclama dela com mensagem melhor
  [[ -n "${ip}" ]] || return 0
  host="$(hostname)"
  host="${host%%.*}"
  got="$({ getent ahostsv4 "${host}" || true; } | awk '{ print $1 }' | sort -u | paste -sd ' ' -)"
  [[ "${got}" == "${ip}" ]] && return 0
  echo "Erro: o hostname '${host}' resolve para '${got:-nada}', mas o Kolla exige so o IP da ${ifc} (${ip})." >&2
  echo "Rode ./larcerto.sh bootstrap: ele grava ${ip} no /etc/hosts e tira a linha 127.0.1.1 do hostname." >&2
  return 1
}

cmd_kolla() {
  local action="$1"
  # network_interface dummy* (modo isolado): o bootstrap grava o IP dela no /etc/hosts e o
  # prechecks/deploy poem o VIP nela, entao ela precisa existir antes (maquina nova sem prep).
  case "${action}" in
    bootstrap|prechecks|deploy) host_net_up ;;
  esac
  case "${action}" in
    prechecks|deploy) kolla_check_hostname || exit 1 ;;
  esac
  # Com set -e, uma falha em kolla_run encerra o larcerto.sh com o mesmo codigo do kolla-ansible.
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
        echo "AVISO: ext-net falhou. Deploy Kolla terminou OK; tente: ./larcerto.sh ext-net" >&2
      fi
      ;;
  esac
}
