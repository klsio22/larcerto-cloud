#!/usr/bin/env bash
set -euo pipefail

# Para todos os containers Docker em execucao.
# Uso:
#   ./project/stop-containers.sh
#   ./project/stop-containers.sh --remove
#   ./project/stop-containers.sh --disable-kolla-services

REMOVE_AFTER_STOP=false
DISABLE_KOLLA_SERVICES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove)
      REMOVE_AFTER_STOP=true
      shift
      ;;
    --disable-kolla-services)
      DISABLE_KOLLA_SERVICES=true
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Uso: stop-containers.sh [--remove] [--disable-kolla-services]

Opcoes:
  --remove                  Remove os containers apos parar.
  --disable-kolla-services  Desabilita servicos kolla-* no systemd.
EOF
      exit 0
      ;;
    *)
      echo "Opcao invalida: $1" >&2
      echo "Use --help para ver o uso." >&2
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "Erro: docker nao encontrado no PATH." >&2
  exit 1
fi

if docker info >/dev/null 2>&1; then
  DOCKER_CMD=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
  DOCKER_CMD=(sudo docker)
else
  echo "Erro: sem permissao para acessar o Docker." >&2
  echo "Rode com sudo ou adicione seu usuario ao grupo docker." >&2
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  mapfile -t kolla_services < <(systemctl list-units --type=service --all 'kolla-*' --no-legend 2>/dev/null | awk '{print $1}')
else
  kolla_services=()
fi

if [[ "${#kolla_services[@]}" -gt 0 ]]; then
  echo "Parando servicos kolla-* no systemd para evitar restart em loop..."
  if systemctl stop "${kolla_services[@]}" >/dev/null 2>&1; then
    echo "Servicos kolla-* parados."
  elif command -v sudo >/dev/null 2>&1; then
    sudo systemctl stop "${kolla_services[@]}"
    echo "Servicos kolla-* parados."
  else
    echo "Aviso: nao consegui parar servicos kolla-* (sem permissao)." >&2
  fi

  if [[ "${DISABLE_KOLLA_SERVICES}" == "true" ]]; then
    echo "Desabilitando servicos kolla-*..."
    if systemctl disable "${kolla_services[@]}" >/dev/null 2>&1; then
      echo "Servicos kolla-* desabilitados."
    elif command -v sudo >/dev/null 2>&1; then
      sudo systemctl disable "${kolla_services[@]}"
      echo "Servicos kolla-* desabilitados."
    else
      echo "Aviso: nao consegui desabilitar servicos kolla-* (sem permissao)." >&2
    fi
  fi
fi

running_ids="$("${DOCKER_CMD[@]}" ps -q)"
if [[ -z "${running_ids}" ]]; then
  echo "Nenhum container em execucao."
else
  echo "Parando containers em execucao..."
  # xargs -r evita executar docker stop sem IDs.
  "${DOCKER_CMD[@]}" ps -q | xargs -r "${DOCKER_CMD[@]}" stop
  echo "Containers parados."
fi

if [[ "${REMOVE_AFTER_STOP}" == "true" ]]; then
  all_ids="$("${DOCKER_CMD[@]}" ps -aq)"
  if [[ -z "${all_ids}" ]]; then
    echo "Nenhum container para remover."
  else
    echo "Removendo containers..."
    "${DOCKER_CMD[@]}" ps -aq | xargs -r "${DOCKER_CMD[@]}" rm
    echo "Containers removidos."
  fi
fi
