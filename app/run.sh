#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
MODE="${LARCERTO_MODE:-$([[ -f "${DIR}/compose.yml" ]] && echo local || echo server)}"
LOCAL_URL="http://127.0.0.1:8088"
IMAGE="larcerto-web"
QA="${DIR}/../tests/app"
QA_IMAGE="larcerto-tests"
SERVER_URL="${LARCERTO_URL:-https://larcerto.com.br}"
APACHE_LOG_DIR="${APACHE_LOG_DIR:-/var/log/apache2}"
APP_LOG="${APACHE_LOG_DIR}/larcerto-error.log"
DB_HOST="" DB_NAME="" DB_USER="" DB_PASS=""

usage() {
  cat <<EOF
Uso: ./run.sh <comando> [args]        (modo atual: ${MODE})

  setup              sobe tudo e popula o banco se estiver vazio
  up [args]          sobe a app (args só no local)
  down [args]        para a app; banco e fotos ficam (args só no local)
  restart            para e sobe de novo
  ps                 mostra o que está rodando
  logs [args]        logs da app (ex.: logs -f)
  db:populate        aplica a semente (22 imóveis) só se a tabela estiver vazia
  db:reset [--yes]   apaga banco e fotos e volta à semente (pede confirmação)
  db:console         abre o cliente mariadb no banco larcerto
  css                gera public/assets/app.css (só no local)
  check [checks]     roda tests/app-checks.sh (só no local)
  phpstan [args]     análise estática (PHPStan nível 6) de backend/ e public/ (só no local)
  test:browser [args] testes no navegador (Pest + Playwright); sobe a app se preciso (só no local)
  test               phpstan e depois test:browser (só no local)
  composer [args]    composer do projeto de testes em tests/app (só no local)
  help               esta ajuda

Local: Docker Compose (compose.yml ao lado do script).
Servidor (VM web): sudo /var/www/larcerto/run.sh <comando>
LARCERTO_MODE=local|server força o modo.
EOF
}

die() { echo "run.sh: $*" >&2; exit 1; }

is_local() { [[ "${MODE}" == local ]]; }

only_local() {
  is_local || { echo "run.sh: '$1' só funciona no local." >&2; exit 2; }
}

compose() { docker compose -f "${DIR}/compose.yml" "$@"; }

ensure_env() {
  [[ -f "${DIR}/.env" ]] && return 0
  (umask 077 && printf 'DB_PASSWORD=%s\n' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" >"${DIR}/.env")
  echo "Criado ${DIR}/.env com uma senha aleatória (só vale no local)."
}

local_up() {
  ensure_env
  docker build --network host -t "${IMAGE}" "${DIR}"
  compose up -d --no-build --wait "$@"
  sql <"${DIR}/sql/01-schema.sql"
}

load_config() {
  [[ -n "${DB_HOST:-}" ]] && return 0
  [[ -r "${DIR}/config.php" ]] || die "não consigo ler ${DIR}/config.php: rode com sudo."
  local out
  out="$(php -r '$c = require $argv[1];
    preg_match("/host=([^;]+)/", $c["dsn"], $h);
    preg_match("/dbname=([^;]+)/", $c["dsn"], $d);
    echo $h[1], "\n", $d[1], "\n", $c["user"], "\n", $c["password"];' "${DIR}/config.php")"
  { read -r DB_HOST; read -r DB_NAME; read -r DB_USER; IFS= read -r DB_PASS || true; } <<<"${out}"
  [[ -n "${DB_HOST}" && -n "${DB_NAME}" && -n "${DB_USER}" ]] || die "config.php sem host, banco ou usuário."
}

sql() {
  if is_local; then
    compose exec -T db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb --default-character-set=utf8mb4 -u"$MARIADB_USER" "$MARIADB_DATABASE" "$@"' sh "$@"
  else
    load_config
    MYSQL_PWD="${DB_PASS}" mariadb --default-character-set=utf8mb4 -h "${DB_HOST}" -u "${DB_USER}" "${DB_NAME}" "$@"
  fi
}

qa() {
  local net="$1"
  shift
  docker run --rm --network "${net}" --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e APP_URL="${APP_URL:-${LOCAL_URL}}" -v "${DIR}/backend:/project/app/backend:ro" -v "${DIR}/public:/project/app/public:ro" \
    -v "${QA}:/project/tests/app" \
    -w /project/tests/app "${QA_IMAGE}" "$@"
}

qa_ready() {
  [[ -f "${QA}/Dockerfile" ]] || die "projeto de testes não encontrado em ${QA}."
  local hash
  hash="$(sha256sum "${QA}/Dockerfile" | cut -d' ' -f1)"
  [[ "$(docker image inspect -f '{{index .Config.Labels "larcerto.dockerfile"}}' "${QA_IMAGE}" 2>/dev/null)" == "${hash}" ]] \
    || docker build -q --network host --label "larcerto.dockerfile=${hash}" -t "${QA_IMAGE}" "${QA}" >/dev/null
  [[ -x "${QA}/vendor/bin/pest" && -d "${QA}/node_modules/playwright" ]] \
    || qa host sh -c 'composer install --no-interaction --no-progress && npm ci --no-audit --no-fund'
}

cmd_phpstan() {
  qa_ready
  qa none vendor/bin/phpstan analyse --memory-limit=1G --no-progress "$@"
}

cmd_browser() {
  local_up
  qa_ready
  qa host vendor/bin/pest "$@"
}

count() { sql -N -B -e 'SELECT COUNT(*) FROM imoveis' | tr -d '[:space:]'; }

cmd_populate() {
  local n
  n="$(count)"
  if [[ "${n}" == 0 ]]; then
    sql <"${DIR}/sql/02-seed.sql"
    echo "Banco populado: $(count) imóveis."
  else
    echo "A tabela imoveis já tem ${n} imóveis: semente não aplicada."
  fi
}

cmd_setup() {
  if is_local; then
    local_up
    cmd_populate
    echo "App: ${LOCAL_URL}"
    echo "Banco (DBeaver): 127.0.0.1:3307, banco e usuário larcerto, senha no .env"
  else
    load_config
    sql <"${DIR}/sql/01-schema.sql"
    cmd_populate
    systemctl is-active --quiet apache2 || systemctl start apache2
    echo "App: ${SERVER_URL}"
  fi
}

cmd_reset() {
  if [[ "${1:-}" != --yes ]]; then
    local resposta=""
    read -r -p "Apagar o banco e as fotos e voltar à semente? [s/N] " resposta || true
    [[ "${resposta}" == s ]] || { echo "Nada foi apagado."; return 0; }
  fi
  if is_local; then
    compose down -v
    local_up
    local n
    n="$(count)"
    [[ "${n}" == 0 ]] && sql <"${DIR}/sql/02-seed.sql"
  else
    load_config
    sql -e 'DROP TABLE IF EXISTS imoveis'
    sql <"${DIR}/sql/01-schema.sql"
    sql <"${DIR}/sql/02-seed.sql"
    [[ -d "${DIR}/storage/uploads" ]] && find "${DIR}/storage/uploads" -mindepth 1 -delete
  fi
  local total
  total="$(count)"
  echo "Banco voltou à semente: ${total} imóveis; fotos apagadas."
}

cmd_console() {
  if is_local; then
    compose exec db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE"'
  else
    load_config
    MYSQL_PWD="${DB_PASS}" exec mariadb --default-character-set=utf8mb4 -h "${DB_HOST}" -u "${DB_USER}" "${DB_NAME}"
  fi
}

cmd_ps() {
  if is_local; then
    compose ps "$@"
  else
    load_config
    echo "apache2: $(systemctl is-active apache2 || true)"
    if sql -N -B -e 'SELECT 1' >/dev/null; then
      echo "banco: ok (${DB_HOST})"
    else
      die "banco: sem resposta de ${DB_HOST}"
    fi
  fi
}

cmd_logs() {
  if is_local; then
    compose logs "$@"
  elif (($#)); then
    tail "$@" "${APP_LOG}"
  else
    tail -n 100 "${APP_LOG}"
  fi
}

[[ "${MODE}" == local || "${MODE}" == server ]] || die "LARCERTO_MODE deve ser local ou server."
case "${1:-}" in
  setup | ps | db:*) is_local || load_config ;;
esac

cmd="${1:-help}"
shift || true
case "${cmd}" in
  setup) cmd_setup ;;
  up) if is_local; then local_up "$@"; else systemctl start apache2; fi ;;
  down) if is_local; then compose down "$@"; else systemctl stop apache2; fi ;;
  restart) if is_local; then compose down && local_up; else systemctl restart apache2; fi ;;
  ps) cmd_ps "$@" ;;
  logs) cmd_logs "$@" ;;
  db:populate) cmd_populate ;;
  db:reset) cmd_reset "$@" ;;
  db:console) cmd_console ;;
  css) only_local css && bash "${DIR}/bin/build-css.sh" ;;
  phpstan)
    only_local phpstan
    cmd_phpstan "$@"
    ;;
  test:browser)
    only_local test:browser
    cmd_browser "$@"
    ;;
  test)
    only_local test
    cmd_phpstan
    cmd_browser
    ;;
  composer)
    only_local composer
    qa_ready
    qa host composer "$@"
    ;;
  check)
    only_local check
    [[ -f "${DIR}/../tests/app-checks.sh" ]] || die "tests/app-checks.sh não encontrado."
    bash "${DIR}/../tests/app-checks.sh" "$@"
    ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
