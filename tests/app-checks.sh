#!/usr/bin/env bash
# Provas do ambiente local da app (Docker Compose em project/app, independente da nuvem).
# Cria containers, volumes e imagem no host: so roda a mao, pelo aluno.
# Atencao: apaga os dados do Compose local (schema mexe na tabela e
# persistencia faz down -v, que leva banco e fotos).
# Uso: bash project/tests/app-checks.sh [check ...]   (sem argumento: todos, na ordem)
# Desfazer: docker compose -f project/app/compose.yml down -v --rmi local
#           (+ docker image rm mariadb:12.3 php:8.4-apache php:8.4-cli para as imagens baixadas)
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${PROJECT_DIR}/app"
COMPOSE=(docker compose -f "${APP_DIR}/compose.yml")
BASE="http://127.0.0.1:8088"
T="$(mktemp -d)"
JAR="${T}/jar"
BODY="${T}/body"
trap 'rm -rf "${T}"' EXIT

[[ -f "${APP_DIR}/.env" ]] || { echo "Sem ${APP_DIR}/.env: cp project/app/.env.example project/app/.env" >&2; exit 2; }
DB_PASSWORD="$(sed -n 's/^DB_PASSWORD=//p' "${APP_DIR}/.env")"

# ---------------------------------------------------------------- apoio

sql() {
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD="${DB_PASSWORD}" db \
    mariadb -ularcerto --batch --skip-column-names -e "$1" larcerto
}

count() { sql 'SELECT COUNT(*) FROM imoveis'; }

page() { curl -fsS -b "${JAR}" -c "${JAR}" "${BASE}$1"; }

csrf_from() {
  grep -oP -m1 'name="csrf" value="\K[0-9a-f]+' <<<"$(page "$1")"
}

# post <caminho> <campos curl...>: imprime o codigo HTTP; corpo em $BODY
post() {
  local caminho="$1"
  shift
  curl -sS -o "${BODY}" -w '%{http_code}' -b "${JAR}" -c "${JAR}" "$@" "${BASE}${caminho}"
}

code_of() { curl -sS -o "${BODY}" -w '%{http_code}' "${BASE}$1"; }

campos() {
  # campos <titulo> [preco] [tipo]: imovel valido, com preco/tipo trocaveis
  printf '%s\n' --form-string "titulo=$1" --form-string "preco=${2:-750}" \
    --form-string "tipo=${3:-kitnet}" --form-string "bairro=Centro" \
    --form-string "campus=UTFPR" --form-string "anunciante_nome=Teste" \
    --form-string "anunciante_tipo=locador" --form-string "verificado=1"
}

# criar <titulo> [args curl...]: anuncia e imprime o id do novo imovel
criar() {
  local titulo="$1" token url args
  shift
  token="$(csrf_from /imoveis/novo)"
  mapfile -t args < <(campos "${titulo}")
  url="$(curl -sS -o /dev/null -w '%{redirect_url}' -b "${JAR}" -c "${JAR}" \
    --form-string "csrf=${token}" "${args[@]}" "$@" "${BASE}/imoveis")"
  grep -oP '/imoveis/\K[0-9]+$' <<<"${url}"
}

# jpeg <arquivo> <largura> <altura>: JPEG gerado pela GD do container web
jpeg() {
  "${COMPOSE[@]}" exec -T web php -r '
    [, $l, $a] = $argv; $i = imagecreatetruecolor((int) $l, (int) $a);
    for ($y = 0; $y < $a; $y += 8) { imagefilledrectangle($i, 0, $y, $l, $y + 7, imagecolorallocate($i, (int) (255 * $y / $a), 120, 200)); }
    imagejpeg($i, "php://stdout", 92);' "$2" "$3" >"$1"
}

up_wait() {
  docker build --network host -q -t larcerto-web "${APP_DIR}" >/dev/null 2>&1 &&
    "${COMPOSE[@]}" up -d --no-build --wait >/dev/null 2>&1
}

# ---------------------------------------------------------------- checks (CRUD)

check_lint84() {
  docker run --rm --network none -v "${APP_DIR}:/app:ro" php:8.4-cli \
    sh -c 'find /app -name "*.php" -print0 | xargs -0 -n1 php -l >/dev/null'
}

check_up() {
  up_wait || return 1
  local ps
  ps="$("${COMPOSE[@]}" ps --format '{{.Service}} {{.State}} {{.Health}}')"
  grep -qE '^web running' <<<"${ps}" && grep -qE '^db running healthy' <<<"${ps}"
}

check_home() {
  local html
  html="$(page /)" || return 1
  grep -q 'LarCerto' <<<"${html}" && grep -q '/assets/logo.svg' <<<"${html}" \
    && grep -q 'class="resumo">22 imóveis' <<<"${html}"
}

check_db_port() {
  local n
  n="$(docker run --rm --network host -e MYSQL_PWD="${DB_PASSWORD}" mariadb:12.3 \
    mariadb -h127.0.0.1 -P3307 -ularcerto --batch --skip-column-names \
    -e 'SELECT COUNT(*) FROM imoveis' larcerto)" || return 1
  [[ "${n}" == "22" ]]
}

check_filtros() {
  local html pares campi
  html="$(page '/?max=700&tipo=kitnet')" || return 1
  pares="$(grep -oP 'data-preco="\K[^"]+(?=" data-tipo="kitnet")' <<<"${html}")"
  [[ -n "${pares}" ]] || return 1
  # Nenhum card fora do filtro: todos kitnet e todos ate 700.
  [[ "$(grep -c 'data-tipo=' <<<"${html}")" -eq "$(wc -l <<<"${pares}")" ]] || return 1
  awk '$1 > 700 { bad = 1 } END { exit bad }' <<<"${pares}" || return 1
  html="$(page '/?bairro=Centro')" || return 1
  [[ "$(grep -oP 'data-bairro="\K[^"]+' <<<"${html}" | sort -u)" == "Centro" ]] || return 1
  html="$(page '/?campus=UTFPR')" || return 1
  campi="$(grep -oP 'data-campus="\K[^"]+' <<<"${html}" | sort -u)"
  grep -qx 'UTFPR' <<<"${campi}" && grep -qx 'Qualquer campus' <<<"${campi}" \
    && ! grep -qx 'Unicentro' <<<"${campi}"
}

check_validacao() {
  local antes token args code caso
  antes="$(count)" || return 1
  for caso in "0 kitnet" "750 castelo"; do
    token="$(csrf_from /imoveis/novo)"
    # shellcheck disable=SC2086
    mapfile -t args < <(campos "Invalido" ${caso})
    code="$(post /imoveis --form-string "csrf=${token}" "${args[@]}")"
    [[ "${code}" == "422" ]] && grep -q 'Corrija os campos' "${BODY}" || return 1
  done
  [[ "$(count)" == "${antes}" ]]
}

check_csrf() {
  local antes
  antes="$(count)" || return 1
  [[ "$(code_of /imoveis/1/excluir)" == "405" ]] || return 1
  [[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/imoveis/1/excluir")" == "403" ]] || return 1
  [[ "$(count)" == "${antes}" ]]
}

check_crud() {
  local titulo="Teste CRUD $$" id token args
  id="$(criar "${titulo}")"
  [[ -n "${id}" ]] && grep -q "${titulo}" <<<"$(page /)" || return 1
  token="$(csrf_from "/imoveis/${id}/editar")"
  mapfile -t args < <(campos "${titulo} editado")
  [[ "$(post "/imoveis/${id}" --form-string "csrf=${token}" "${args[@]}")" == "303" ]] || return 1
  grep -q "${titulo} editado" <<<"$(page /)" || return 1
  token="$(csrf_from "/imoveis/${id}")"
  [[ "$(post "/imoveis/${id}/excluir" --form-string "csrf=${token}")" == "303" ]] || return 1
  ! grep -q "${titulo}" <<<"$(page /)" && [[ "$(code_of "/imoveis/${id}")" == "404" ]]
}

check_persistencia() {
  # imovel e foto no volume larcerto_uploads
  local titulo="Persistencia $$" id foto
  jpeg "${T}/p.jpg" 1200 900 || return 1
  id="$(criar "${titulo}" -F "fotos[]=@${T}/p.jpg")"
  [[ -n "${id}" ]] || return 1
  foto="$(grep -oP -m1 "src=\"\K/uploads/${id}/[0-9a-f]{32}\.webp" <<<"$(page "/imoveis/${id}")")"
  [[ -n "${foto}" && "$(code_of "${foto}")" == "200" ]] || return 1
  "${COMPOSE[@]}" down >/dev/null 2>&1 && up_wait || return 1
  grep -q "${titulo}" <<<"$(page /)" && [[ "$(code_of "${foto}")" == "200" ]] || return 1
  "${COMPOSE[@]}" down -v >/dev/null 2>&1 || return 1
  ! docker volume inspect larcerto_uploads >/dev/null 2>&1 || return 1
  up_wait && [[ "$(count)" == "22" ]]
}

# ---------------------------------------------------------------- checks (MVC e fotos)

check_php_ext() {
  local mods ini
  mods="$("${COMPOSE[@]}" exec -T web php -m)" || return 1
  grep -qx gd <<<"${mods}" && grep -qx exif <<<"${mods}" || return 1
  [[ "$("${COMPOSE[@]}" exec -T web php -r 'echo gd_info()["WebP Support"] && gd_info()["JPEG Support"] ? "ok" : "nao";')" == ok ]] || return 1
  ini="$("${COMPOSE[@]}" exec -T web php -r 'foreach (["upload_max_filesize", "post_max_size", "max_file_uploads", "memory_limit"] as $k) { echo ini_get($k), " "; }')"
  [[ "${ini}" == "20M 64M 11 256M " ]]
}

check_schema() {
  # banco da versao anterior (9 campos) simulado tirando a capa; o schema devolve a coluna sem perder linhas
  local antes colunas
  antes="$(count)" || return 1
  sql 'ALTER TABLE imoveis DROP COLUMN IF EXISTS capa' || return 1
  colunas="SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'larcerto' AND table_name = 'imoveis'"
  [[ "$(sql "${colunas}")" == "9" ]] || return 1
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD="${DB_PASSWORD}" db mariadb -ularcerto larcerto <"${APP_DIR}/sql/01-schema.sql" || return 1
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD="${DB_PASSWORD}" db mariadb -ularcerto larcerto <"${APP_DIR}/sql/01-schema.sql" || return 1
  [[ "$(sql "${colunas}")" == "10" && "$(count)" == "${antes}" ]] || return 1
  [[ "$(sql "SELECT column_type FROM information_schema.columns WHERE table_schema = 'larcerto' AND table_name = 'imoveis' AND column_name = 'capa'")" == "char(32)" ]]
}

check_fotos_gd() {
  # GD real (container web): orientacao, tamanho, miniatura, sem EXIF/GPS, recusas.
  "${COMPOSE[@]}" exec -T web php <<'PHP'
<?php
require '/var/www/larcerto/backend/Services/ValidadorImagem.php';
require '/var/www/larcerto/backend/Services/ProcessadorImagem.php';
use LarCerto\Services\ProcessadorImagem;
use LarCerto\Services\ValidadorImagem;

$d = sys_get_temp_dir() . '/fotos-' . getmypid();
mkdir($d);
$falhou = function (string $msg) { fwrite(STDERR, "FALHOU: $msg\n"); exit(1); };
$arquivo = fn (string $f) => ['tmp_name' => $f, 'size' => filesize($f), 'error' => UPLOAD_ERR_OK, 'name' => basename($f)];
// Chunks de um WebP (RIFF): nenhum EXIF/XMP pode sobrar.
$chunks = function (string $f): array {
    $b = file_get_contents($f); $out = []; $p = 12;
    while ($p + 8 <= strlen($b)) { $out[] = substr($b, $p, 4); $p += 8 + unpack('V', substr($b, $p + 4, 4))[1]; $p += $p % 2; }
    return $out;
};

// 1) JPEG 4000x3000 (12 MP): metade esquerda vermelha, direita azul, com detalhe; EXIF Orientation=6 + GPS.
$i = imagecreatetruecolor(4000, 3000);
imagefilledrectangle($i, 0, 0, 1999, 2999, imagecolorallocate($i, 220, 30, 30));
imagefilledrectangle($i, 2000, 0, 3999, 2999, imagecolorallocate($i, 30, 30, 220));
// detalhe so na faixa x 400..3600, longe dos pontos de amostra da orientacao (x ~ 83 e ~ 3917)
for ($k = 0; $k < 3000; $k++) {
    imagefilledellipse($i, 400 + ($k * 97) % 3200, ($k * 61) % 3000, 30, 30, imagecolorallocate($i, ($k * 7) % 256, ($k * 13) % 256, ($k * 29) % 256));
}
ob_start(); imagejpeg($i, null, 92); $jpg = ob_get_clean();
$ifd0 = pack('v', 2) . pack('vvVvv', 0x0112, 3, 1, 6, 0) . pack('vvVV', 0x8825, 4, 1, 38) . pack('V', 0);
$gps = pack('v', 1) . pack('vvV', 0x0001, 2, 2) . "S\0\0\0" . pack('V', 0);
$tiff = "II*\0" . pack('V', 8) . $ifd0 . $gps;
$app1 = "\xFF\xE1" . pack('n', strlen("Exif\0\0" . $tiff) + 2) . "Exif\0\0" . $tiff;
file_put_contents("$d/celular.jpg", substr($jpg, 0, 2) . $app1 . substr($jpg, 2));
$exif = exif_read_data("$d/celular.jpg");
if (($exif['Orientation'] ?? 0) !== 6 || !isset($exif['GPSLatitudeRef'])) { $falhou('fixture sem Orientation=6/GPS'); }
if (($e = (new ValidadorImagem())->erro($arquivo("$d/celular.jpg"))) !== null) { $falhou("validador recusou JPEG valido: $e"); }
(new ProcessadorImagem())->processar("$d/celular.jpg", "$d/saida");
[$l, $a, $t] = getimagesize("$d/saida.webp");
if ([$l, $a, $t] !== [1440, 1920, IMAGETYPE_WEBP]) { $falhou("saida {$l}x{$a} tipo $t (esperado 1440x1920 WebP, em pe)"); }
if (filesize("$d/saida.webp") > 1024 * 1024) { $falhou('saida passa de 1 MB: ' . filesize("$d/saida.webp")); }
$w = imagecreatefromwebp("$d/saida.webp");
$topo = imagecolorat($w, 720, 40); $base = imagecolorat($w, 720, 1880);
if (!((($topo >> 16) & 255) > 150 && ($topo & 255) < 100 && ($base & 255) > 150 && (($base >> 16) & 255) < 100)) {
    $falhou('orientacao errada: o lado esquerdo (vermelho) devia ficar em cima');
}
if (array_intersect($chunks("$d/saida.webp"), ['EXIF', 'XMP ']) || array_intersect($chunks("$d/saida_thumb.webp"), ['EXIF', 'XMP '])) {
    $falhou('WebP com metadados');
}
if (str_contains(file_get_contents("$d/saida.webp"), "Exif\0\0")) { $falhou('EXIF no arquivo gravado'); }
if (array_slice(getimagesize("$d/saida_thumb.webp"), 0, 3) !== [640, 480, IMAGETYPE_WEBP]) { $falhou('miniatura nao e 640x480 WebP'); }
if (glob("$d/saida*.jpg")) { $falhou('original guardado'); }

// 1b) ~40 MP (7296x5472 = 39,9 MP) com Orientation=6: cabe no memory_limit (reduz antes de girar) e sai em pe
unset($i, $w);   // libera a foto de 12 MP antes da de 40 MP (memory_limit 256M)
$g = imagecreatetruecolor(7296, 5472);
imagefilledrectangle($g, 0, 0, 3647, 5471, imagecolorallocate($g, 220, 30, 30));
imagefilledrectangle($g, 3648, 0, 7295, 5471, imagecolorallocate($g, 30, 30, 220));
ob_start(); imagejpeg($g, null, 85); $jpg40 = ob_get_clean(); unset($g);
file_put_contents("$d/40mp.jpg", substr($jpg40, 0, 2) . $app1 . substr($jpg40, 2)); unset($jpg40);
if (($e = (new ValidadorImagem())->erro($arquivo("$d/40mp.jpg"))) !== null) { $falhou("validador recusou 40 MP: $e"); }
(new ProcessadorImagem())->processar("$d/40mp.jpg", "$d/40mp");
if (array_slice(getimagesize("$d/40mp.webp"), 0, 2) !== [1440, 1920]) { $falhou('40 MP nao saiu 1440x1920 em pe'); }
$w = imagecreatefromwebp("$d/40mp.webp");
if (((imagecolorat($w, 720, 40) >> 16) & 255) < 150) { $falhou('40 MP com orientacao errada'); }

// 2) PNG 800x600 nao e ampliado
$p = imagecreatetruecolor(800, 600); imagepng($p, "$d/pequena.png");
(new ProcessadorImagem())->processar("$d/pequena.png", "$d/pequena");
if (array_slice(getimagesize("$d/pequena.webp"), 0, 2) !== [800, 600]) { $falhou('PNG pequeno foi redimensionado'); }

// 3) recusas: PHP com nome de foto e PNG de 50 MP (so cabecalho)
file_put_contents("$d/foto.jpg", '<?php echo "pwned";');
if (!str_contains((string) (new ValidadorImagem())->erro($arquivo("$d/foto.jpg")), 'não é uma foto')) { $falhou('aceitou PHP renomeado'); }
$chunk = fn ($t, $x) => pack('N', strlen($x)) . $t . $x . pack('N', crc32($t . $x));
file_put_contents("$d/50mp.png", "\x89PNG\r\n\x1a\n" . $chunk('IHDR', pack('NNCCCCC', 8000, 6250, 8, 2, 0, 0, 0)) . $chunk('IDAT', gzcompress('x')) . $chunk('IEND', ''));
if (!str_contains((string) (new ValidadorImagem())->erro($arquivo("$d/50mp.png")), '40 megapixels')) { $falhou('aceitou 50 MP'); }

array_map('unlink', glob("$d/*")); rmdir($d);
PHP
}

check_fotos_http() {
  local id token args capa code
  jpeg "${T}/a.jpg" 1600 1200 && jpeg "${T}/b.jpg" 1000 750 || return 1
  id="$(criar "Fotos HTTP $$" -F "fotos[]=@${T}/a.jpg" -F "fotos[]=@${T}/b.jpg")"
  [[ -n "${id}" ]] || return 1
  capa="$(grep -oP -m1 "src=\"\K/uploads/${id}/[0-9a-f]{32}_thumb\.webp" <<<"$(page /)")"
  [[ -n "${capa}" ]] || return 1
  [[ "$(curl -sS -o /dev/null -w '%{http_code} %{content_type}' "${BASE}${capa}")" == "200 image/webp" ]] || return 1
  # 21 MB: 422; 4 x 17 MB (68 MB > post_max_size): 413 com mensagem
  truncate -s 21M "${T}/21mb.jpg" && truncate -s 17M "${T}/17mb.jpg"
  token="$(csrf_from /imoveis/novo)"
  mapfile -t args < <(campos "Grande")
  code="$(post /imoveis --form-string "csrf=${token}" "${args[@]}" -F "fotos[]=@${T}/21mb.jpg")"
  [[ "${code}" == "422" ]] && grep -q 'passa de 20 MB' "${BODY}" || return 1
  code="$(post /imoveis --form-string "csrf=${token}" "${args[@]}" -F "fotos[]=@${T}/17mb.jpg" \
    -F "fotos[]=@${T}/17mb.jpg" -F "fotos[]=@${T}/17mb.jpg" -F "fotos[]=@${T}/17mb.jpg")"
  [[ "${code}" == "413" ]] && grep -q 'Envie menos fotos por vez' "${BODY}" || return 1
  # .php dentro da pasta de fotos nao executa nem e servido
  "${COMPOSE[@]}" exec -T web sh -c "echo '<?php echo \"PHP-EXECUTOU\";' > /var/www/larcerto/storage/uploads/${id}/teste.php" || return 1
  code="$(code_of "/uploads/${id}/teste.php")"
  "${COMPOSE[@]}" exec -T web rm -f "/var/www/larcerto/storage/uploads/${id}/teste.php"
  [[ "${code}" == "403" || "${code}" == "404" ]] && ! grep -q 'PHP-EXECUTOU' "${BODY}"
}

ALL=(lint84 up home db_port filtros validacao csrf crud php_ext schema fotos_gd fotos_http persistencia)
selected=("$@")
[[ "${#selected[@]}" -eq 0 ]] && selected=("${ALL[@]}")

failed=0
for name in "${selected[@]}"; do
  if ! declare -F "check_${name}" >/dev/null; then
    echo "Check desconhecido: ${name}" >&2
    exit 2
  fi
  if "check_${name}"; then echo "PASS ${name}"; else echo "FAIL ${name}"; failed=1; fi
done
exit "${failed}"
