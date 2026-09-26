#!/usr/bin/env bash
set -euo pipefail

# Cria a interface dummy0 para uso no neutron_external_interface em lab AIO.
# Uso:
#   ./project/setup-dummy0.sh

if ! command -v ip >/dev/null 2>&1; then
  echo "Erro: comando 'ip' nao encontrado." >&2
  exit 1
fi

if ip link show dummy0 >/dev/null 2>&1; then
  echo "dummy0 ja existe."
else
  if [[ "${EUID}" -eq 0 ]]; then
    ip link add dummy0 type dummy
  else
    sudo ip link add dummy0 type dummy
  fi
  echo "dummy0 criada."
fi

if [[ "${EUID}" -eq 0 ]]; then
  ip link set dummy0 up
else
  sudo ip link set dummy0 up
fi

echo "dummy0 esta ativa."
