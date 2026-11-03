<?php
declare(strict_types=1);

pest()->browser()->timeout(10000);

// The plugin only serves relative paths for Laravel apps, so every visit gets an absolute URL.
function url(string $path = '/'): string
{
    return rtrim(getenv('APP_URL') ?: 'http://127.0.0.1:8088', '/') . $path;
}

function totalImoveis(): int
{
    return (int) visit(url('/'))->text('.resumo');
}

function foto(string $nome): string
{
    return __DIR__ . '/fixtures/' . $nome;
}

function preencher(mixed $page, string $titulo): mixed
{
    return $page->fill('titulo', $titulo)
        ->fill('preco', '900')
        ->fill('bairro', 'Centro')
        ->fill('anunciante_nome', 'E2E Teste');
}

function excluir(mixed $page): void
{
    $page->script('window.confirm = () => true');
    $page->press('Excluir anúncio')->assertSee('Anúncio excluído.');
}

// Adds generated files to the photo field the way a user selection does (one change event).
function selecionar(mixed $page, int $quantos, string $prefixo, int $bytes = 0): void
{
    $page->script(<<<JS
        (async () => {
            const input = document.querySelector('input[name="fotos[]"]');
            const dt = new DataTransfer();
            for (let i = 0; i < {$quantos}; i++) {
                let blob;
                if ({$bytes} > 0) {
                    blob = new Blob([new Uint8Array({$bytes})], { type: 'image/jpeg' });
                } else {
                    const c = document.createElement('canvas');
                    c.width = 20 + i; c.height = 15;
                    c.getContext('2d').fillRect(0, 0, i + 1, 5);
                    blob = await new Promise((r) => c.toBlob(r, 'image/png'));
                }
                dt.items.add(new File([blob], '{$prefixo}' + i + ({$bytes} > 0 ? '.jpg' : '.png'), { type: blob.type, lastModified: 1000 + i }));
            }
            input.files = dt.files;
            input.dispatchEvent(new Event('change'));
        })()
        JS);
}

function figuras(mixed $page, int $esperadas): void
{
    expect($page->script(<<<JS
        new Promise((r) => {
            const fim = Date.now() + 8000;
            const t = setInterval(() => {
                const n = document.querySelectorAll('#previa-fotos figure').length;
                if (n === {$esperadas} || Date.now() > fim) { clearInterval(t); r(n); }
            }, 50);
        })
        JS))->toBe($esperadas);
}

// JS expression for the first photo of the form that is not the cover (the gallery's first photo).
function galeriaJs(): string
{
    return "[...document.querySelectorAll('#previa-fotos figure')].find((f) => !f.querySelector('input[name=capa]').checked)";
}

// Creates a listing with one photo per name (fixtures in order), the first one as cover; returns its id.
function anuncioComFotos(array $nomes): int
{
    $page = preencher(visit(url('/imoveis/novo')), 'E2E Form ' . bin2hex(random_bytes(3)));
    foreach ($nomes as $i => $nome) {
        $page->attach('fotos[]', foto($nome . '.jpg'));
        figuras($page, $i + 1);
    }
    $page->press('Salvar anúncio')->assertSee('Anúncio criado.');

    return (int) basename((string) parse_url($page->url(), PHP_URL_PATH));
}
