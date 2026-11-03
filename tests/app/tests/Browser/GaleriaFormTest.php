<?php
declare(strict_types=1);

test('troca a capa sem recarregar', function () {
    $id = anuncioComFotos(['casa', 'sala']);
    $page = visit(url("/imoveis/{$id}/editar"));
    $page->script('window.semRecarga = 1');
    $antes = $page->script("document.querySelector('#previa-fotos input[name=capa]:checked').value");
    $page->script("document.querySelector('#previa-fotos input[name=capa]:not(:checked)').click()");

    expect($page->script("document.querySelector('#previa-fotos > figure input[name=capa]').value"))->not->toBe($antes);
    expect($page->script("document.querySelector('#previa-fotos > figure input[name=capa]').checked"))->toBeTrue();
    expect($page->script('window.semRecarga'))->toBe(1);
    $page->assertSee('Galeria do anúncio (1)')->assertSee('Usar como capa');

    excluir(visit(url("/imoveis/{$id}")));
});

test('salva a capa escolhida', function () {
    $id = anuncioComFotos(['casa', 'sala']);
    $page = visit(url("/imoveis/{$id}/editar"));
    $outra = $page->script("document.querySelector('#previa-fotos input[name=capa]:not(:checked)').value");
    $page->script("document.querySelector('#previa-fotos input[name=capa]:not(:checked)').click()");
    $page->press('Salvar alterações')->assertSee('Anúncio atualizado.');

    expect($page->script("document.querySelector('[data-galeria] .swiper-slide img').getAttribute('src')"))
        ->toContain('/uploads/' . $id . '/' . substr($outra, 2) . '.webp');

    excluir($page);
});

test('remover foto salva marca e desfaz', function () {
    $id = anuncioComFotos(['casa', 'sala']);
    $page = visit(url("/imoveis/{$id}/editar"));
    $page->script(galeriaJs() . ".querySelector('input[name=\"remover[]\"]').click()");

    $page->assertSee('Será removida ao salvar')
        ->assertScript(galeriaJs() . ".classList.contains('opacity-50')", true)
        ->assertScript(galeriaJs() . ".querySelector('[data-texto-remover]').textContent", 'Desfazer');

    $page->script(galeriaJs() . ".querySelector('input[name=\"remover[]\"]').click()");

    $page->assertDontSee('Será removida ao salvar')
        ->assertScript(galeriaJs() . ".classList.contains('opacity-50')", false)
        ->assertScript(galeriaJs() . ".querySelector('[data-texto-remover]').textContent", 'Remover');

    excluir(visit(url("/imoveis/{$id}")));
});

test('remover a capa promove a primeira da galeria', function () {
    $id = anuncioComFotos(['casa', 'sala', 'quarto']);
    $page = visit(url("/imoveis/{$id}/editar"));
    // a primeira da galeria, na ordem em que aparece antes de qualquer clique
    $promovida = $page->script("document.querySelectorAll('#previa-fotos > figure')[1].querySelector('input[name=capa]').value");
    $removida = $page->script("document.querySelector('#previa-fotos > figure input[name=\"remover[]\"]').value");
    $page->script("document.querySelector('#previa-fotos > figure input[name=\"remover[]\"]').click()");

    $page->assertScript("document.querySelector('#previa-fotos > figure input[name=capa]').value", $promovida)
        ->assertScript("document.querySelector('#previa-fotos > figure input[name=capa]').checked", true)
        ->assertScript("document.querySelector('#previa-fotos > figure input[name=\"remover[]\"]').checked", false)
        ->assertScript("document.querySelectorAll('#previa-fotos input[name=capa]:checked').length", 1);

    $page->press('Salvar alterações')->assertSee('Anúncio atualizado.')->assertCount('.swiper-slide', 2);
    expect($page->script('document.documentElement.outerHTML.includes(' . json_encode($removida) . ')'))->toBeFalse();

    excluir($page);
});

test('salvar remove foto marcada', function () {
    $id = anuncioComFotos(['casa', 'sala']);
    $page = visit(url("/imoveis/{$id}/editar"));
    $removida = $page->script(galeriaJs() . ".querySelector('input[name=\"remover[]\"]').value");
    $page->script(galeriaJs() . ".querySelector('input[name=\"remover[]\"]').click()");
    $page->press('Salvar alterações')->assertSee('Anúncio atualizado.')->assertCount('.swiper-slide', 1);
    expect($page->script('document.documentElement.outerHTML.includes(' . json_encode($removida) . ')'))->toBeFalse();

    excluir($page);
});

test('foto nova entra no fim da galeria', function () {
    $id = anuncioComFotos(['casa', 'sala', 'quarto']);
    $page = visit(url("/imoveis/{$id}/editar"));
    $salvas = $page->script("JSON.stringify([...document.querySelectorAll('#previa-fotos figure[data-papel=galeria] input[name=capa]')].map((r) => r.value))");
    selecionar($page, 1, 'nova');
    figuras($page, 4);

    $page->assertScript("JSON.stringify([...document.querySelectorAll('#previa-fotos figure[data-papel=galeria] input[name=capa]')].slice(0, 2).map((r) => r.value))", $salvas)
        ->assertScript("(() => { const f = document.querySelectorAll('#previa-fotos figure');"
            . " const u = f[f.length - 1];"
            . " return u.dataset.papel === 'galeria' && u.querySelector('img').alt === 'Prévia de nova0.png'"
            . " && u.querySelector('input[name=capa]').checked === false"
            . " && u.textContent.includes('Usar como capa') && u.textContent.includes('Remover'); })()", true)
        ->assertSee('Galeria do anúncio (3)');

    excluir(visit(url("/imoveis/{$id}")));
});

test('sem capa, a primeira foto nova vai para a capa', function () {
    $page = visit(url('/imoveis/novo'));
    $page->attach('fotos[]', foto('casa.jpg'));
    figuras($page, 1);

    $page->assertScript("[...document.querySelectorAll('#previa-fotos > p')].map((p) => p.textContent).includes('Capa')", true)
        ->assertScript("[...document.querySelectorAll('#previa-fotos > p')].some((p) => p.textContent.startsWith('Galeria do anúncio'))", false)
        ->assertScript("document.querySelector('#previa-fotos > figure').dataset.papel", 'capa');

    $page->attach('fotos[]', foto('sala.jpg'));
    figuras($page, 2);

    $page->assertSee('Galeria do anúncio (1)')
        ->assertScript("document.querySelector('#previa-fotos > figure').dataset.papel", 'capa')
        ->assertScript("document.querySelector('#previa-fotos > figure img').alt", 'Prévia de casa.jpg');
});
