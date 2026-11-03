#!/usr/bin/env bash
# Builds public/assets/app.css with the standalone Tailwind CLI (no Node needed).
# Downloads the pinned release only if missing and verifies it before running it.
# Usage: bash project/app/bin/build-css.sh
set -euo pipefail

TAILWIND_VERSION=4.3.3
ASSET=tailwindcss-linux-x64
SHA256=dc61b3ac6b8c9ca874c0cc4c57b2409791a64c5540404ca5f5367360babc313a
URL="https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}"

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "${BIN_DIR}")"
BIN="${BIN_DIR}/tailwindcss"

die() {
  echo "build-css.sh: $*" >&2
  exit 1
}

sha_ok() { [[ "$(sha256sum "$1" | cut -d' ' -f1)" == "${SHA256}" ]]; }

[[ "$(uname -sm)" == "Linux x86_64" ]] || die "este script baixa o binario Linux x64 (${ASSET})"

if [[ ! -e "${BIN}" ]]; then
  tmp="$(mktemp "${BIN_DIR}/.tailwindcss.XXXXXX")"
  trap 'rm -f "${tmp}" "${tmp}.sums"' EXIT
  echo "Baixando Tailwind CSS v${TAILWIND_VERSION} (${ASSET})..."
  curl -fsSL "${URL}/${ASSET}" -o "${tmp}" || die "download do binario falhou"
  curl -fsSL "${URL}/sha256sums.txt" -o "${tmp}.sums" || die "download do sha256sums.txt falhou"
  # Both the release sha256sums.txt and the pinned hash must match.
  grep -qxE "${SHA256} +(\./)?${ASSET}" "${tmp}.sums" || die "sha256sums.txt da release nao traz ${SHA256} para ${ASSET}"
  sha_ok "${tmp}" || die "SHA-256 do binario baixado nao confere; nada foi executado"
  chmod +x "${tmp}"
  mv "${tmp}" "${BIN}"
fi

sha_ok "${BIN}" || die "SHA-256 de ${BIN} nao confere com a v${TAILWIND_VERSION}; apague o arquivo e rode de novo"

cd "${APP_DIR}"
"${BIN}" --input frontend/css/app.css --output public/assets/app.css --minify
