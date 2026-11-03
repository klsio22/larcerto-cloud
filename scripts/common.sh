# Helpers compartilhados pelos modulos de scripts/ (carregados pelo lab.sh).
# Carregar com: source "${SCRIPT_DIR}/scripts/common.sh" (SCRIPT_DIR = pasta project/).
# shellcheck shell=bash

GLOBALS_YML="${SCRIPT_DIR}/kolla-config/globals.yml"

# Cabeçalho de etapa: "==> <texto>".
step() {
  echo "==> $*"
}

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
  echo "Precisa de root: configure sudo NOPASSWD, entre no grupo docker, ou digite a senha." >&2
  sudo "$@"
}

DOCKER=()
init_docker() {
  if [[ "${#DOCKER[@]}" -gt 0 ]]; then
    return 0
  fi
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    echo "Erro: sem permissao para acessar o Docker." >&2
    exit 1
  fi
}

docker_cmd() {
  init_docker
  "${DOCKER[@]}" "$@"
}

# Lê "key: value" ativo (não comentado) de globals.yml; imprime <default> se ausente.
read_globals() {
  local key="$1"
  local default="$2"
  local val=""
  if [[ -f "${GLOBALS_YML}" ]]; then
    val="$(grep -E "^${key}:" "${GLOBALS_YML}" 2>/dev/null | head -1 \
      | sed -E 's/^[^:]+:[[:space:]]*"?([^"#]+)"?.*/\1/' \
      | tr -d '[:space:]')"
  fi
  printf '%s\n' "${val:-${default}}"
}
