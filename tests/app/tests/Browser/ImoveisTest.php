<?php
declare(strict_types=1);

test('listagem mostra logo, nome e imoveis', function () {
    visit(url('/'))
        ->assertVisible('img[alt="Logotipo LarCerto"]')
        ->assertSee('LarCerto')
        ->assertScript("document.querySelectorAll('a[data-tipo]').length > 0")
        ->assertNoJavaScriptErrors();
});

test('filtro por tipo mostra so o tipo escolhido', function () {
    visit(url('/'))
        ->select('tipo', 'republica')
        ->press('Buscar')
        ->assertQueryStringHas('tipo', 'republica')
        ->assertScript("[...document.querySelectorAll('a[data-tipo]')].length > 0"
            . " && [...document.querySelectorAll('a[data-tipo]')].every(a => a.dataset.tipo === 'republica')");
});

test('validacao recusa titulo so com espacos', function () {
    $antes = totalImoveis();

    visit(url('/imoveis/novo'))
        ->fill('titulo', '   ')
        ->fill('preco', '650')
        ->fill('bairro', 'Centro')
        ->fill('anunciante_nome', 'E2E Teste')
        ->press('Salvar anúncio')
        ->assertSee('Corrija os campos destacados')
        ->assertSee('Informe o título');

    expect(totalImoveis())->toBe($antes);
});

test('ciclo anuncia com foto, edita e exclui', function () {
    $antes = totalImoveis();
    $titulo = 'E2E Casa ' . bin2hex(random_bytes(3));
    $novo = $titulo . ' editada';

    $page = visit(url('/imoveis/novo'))
        ->fill('titulo', $titulo)
        ->select('tipo', 'casa')
        ->fill('preco', '1200')
        ->fill('bairro', 'Centro')
        ->select('campus', 'UTFPR')
        ->fill('anunciante_nome', 'E2E Teste')
        ->attach('fotos[]', __DIR__ . '/../fixtures/casa.jpg')
        ->press('Salvar anúncio')
        ->assertSee('Anúncio criado.')
        ->assertSee($titulo)
        ->assertVisible('img[alt="Foto principal de ' . $titulo . '"]')
        ->assertNoBrokenImages();

    $page->click('Editar anúncio')
        ->fill('titulo', $novo)
        ->press('Salvar alterações')
        ->assertSee('Anúncio atualizado.')
        ->assertSee($novo);

    // Playwright dismisses confirm() dialogs by default, which would cancel the delete.
    $page->script('window.confirm = () => true');
    $page->press('Excluir anúncio')
        ->assertSee('Anúncio excluído.')
        ->assertPathIs('/')
        ->assertDontSee($novo);

    expect(totalImoveis())->toBe($antes);
});

test('404 da app para imovel inexistente', function () {
    visit(url('/imoveis/999999'))
        ->assertSee('Página não encontrada')
        ->assertVisible('img[alt="Logotipo LarCerto"]');
});
