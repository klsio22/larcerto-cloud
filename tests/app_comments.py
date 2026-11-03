#!/usr/bin/env python3
"""Comentarios do codigo da app (poucos, em ingles, so com o porque).

Uso:
  python3 project/tests/app_comments.py list   # arquivo:linha: comentario (uma linha fisica por saida)
  python3 project/tests/app_comments.py hash   # sha256 de cada arquivo sem comentarios nem linhas em branco
  python3 project/tests/app_comments.py pt     # comentarios com cara de portugues (sai 1 se houver)
APP_DIR troca a pasta da app (fora de um repositorio git, le todos os arquivos dela).

PHP: comentarios pelo token_get_all do php do host. Outros arquivos: pela sintaxe de comentario
de cada tipo (#, ;, --, //, /* */).
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

APP = Path(os.environ.get("APP_DIR") or Path(__file__).resolve().parent.parent / "app")
PT_WORDS = set("de da das dos que nao para com sem uma um os ao na nos pelo pela ou entao quando isso fica vai sao tem mas esta este essa esse ainda depois cada mesmo todo toda ja deve pode campo foto fotos formulario valida".split())
SKIP = {"public/assets/app.css", "README.md"}
VENDOR = "public/assets/vendor/"  # third-party files keep their own licence header

PHP_SPLIT = r"""
$out = [];
foreach (token_get_all(file_get_contents($argv[1])) as $t) {
    $c = is_array($t) && in_array($t[0], [T_COMMENT, T_DOC_COMMENT], true);
    $out[] = [$c, is_array($t) ? $t[1] : $t];
}
echo json_encode($out);
"""


def files():
    git = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", "."], cwd=APP, capture_output=True, text=True)
    names = git.stdout.split() if git.returncode == 0 else [str(p.relative_to(APP)) for p in APP.rglob("*")]
    for rel in sorted(names):
        p = APP / rel
        if rel in SKIP or rel.startswith(VENDOR) or not p.is_file() or p.suffix in {".svg", ".md"}:
            continue
        yield rel, p


def comment_rule(rel):
    name = Path(rel).name
    if rel.endswith(".ini"):
        return r"^[ \t]*;.*$"
    if rel.endswith(".sql"):
        return r"^[ \t]*--.*$|[ \t]+--[ \t].*$"
    if rel.endswith((".sh", ".conf", ".yml")) or name in {"Dockerfile", ".env.example"}:
        return r"^[ \t]*#(?!!).*$|[ \t]+#[ \t].*$"
    if rel.endswith(".js"):
        return r"/\*[\s\S]*?\*/|(?:^|[ \t])//.*$"
    if rel.endswith(".css"):
        return r"/\*[\s\S]*?\*/"
    return None


def split(rel, p):
    """Lista de (e_comentario, texto) que remonta o arquivo inteiro."""
    if rel.endswith(".php"):
        out = subprocess.run(["php", "-r", PHP_SPLIT, str(p)], capture_output=True, text=True, check=True)
        return [tuple(x) for x in json.loads(out.stdout)]
    rule = comment_rule(rel)
    if rule is None:
        sys.exit(f"tipo de arquivo sem regra de comentario: {rel}")
    src = p.read_text()
    parts, pos = [], 0
    for m in re.finditer(rule, src, re.M):
        parts += [(False, src[pos:m.start()]), (True, m.group(0))]
        pos = m.end()
    return parts + [(False, src[pos:])]


def comments():
    for rel, p in files():
        line = 1
        for is_c, text in split(rel, p):
            if is_c:
                for i, l in enumerate(text.rstrip("\n").split("\n")):
                    yield rel, line + i, l.strip()
            line += text.count("\n")


def code(rel, p):
    src = "".join(t for c, t in split(rel, p) if not c)
    src = re.sub(r"<\?php\s*\?>", "", src)  # bloco <?php // ... ?> que so tinha comentario
    return "\n".join(l.rstrip() for l in src.split("\n") if l.strip()) + "\n"


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "list":
        for rel, n, text in comments():
            print(f"{rel}:{n}: {text}")
    elif cmd == "hash":
        for rel, p in files():
            print(hashlib.sha256(code(rel, p).encode()).hexdigest(), rel)
    elif cmd == "pt":
        bad = [(rel, n, t) for rel, n, t in comments()
               if re.search(r"[áàâãéêíóôõúçÁÀÂÃÉÊÍÓÔÕÚÇ]", t) or PT_WORDS & set(re.findall(r"[a-z]+", t.lower()))]
        for rel, n, text in bad:
            print(f"{rel}:{n}: {text}")
        sys.exit(1 if bad else 0)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
