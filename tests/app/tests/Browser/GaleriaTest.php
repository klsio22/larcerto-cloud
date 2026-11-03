<?php
declare(strict_types=1);

test('slider navega por 3 fotos com botao e teclado', function () {
    $titulo = 'E2E Slider ' . bin2hex(random_bytes(3));
    $page = preencher(visit(url('/imoveis/novo')), $titulo)
        ->attach('fotos[]', foto('casa.jpg'))
        ->attach('fotos[]', foto('sala.jpg'))
        ->attach('fotos[]', foto('quarto.jpg'));
    figuras($page, 3);
    $page->press('Salvar anúncio')
        ->assertSee('Anúncio criado.')
        ->assertCount('.swiper-slide', 3)
        ->assertScript("document.querySelector('[data-galeria]').getBoundingClientRect().width"
            . " <= document.querySelector('[data-galeria]').closest('.min-w-0').getBoundingClientRect().width + 1"
            . " && document.documentElement.scrollWidth <= window.innerWidth")
        ->assertSeeIn('.swiper-pagination', '1 / 3')
        ->assertAttributeContains('.swiper-button-prev', 'class', 'swiper-button-disabled')
        ->click('.swiper-button-next')
        ->assertSeeIn('.swiper-pagination', '2 / 3')
        ->keys('[data-galeria]', 'ArrowRight')
        ->assertSeeIn('.swiper-pagination', '3 / 3')
        ->assertAttributeContains('.swiper-button-next', 'class', 'swiper-button-disabled')
        ->assertScript("document.querySelector('[data-galeria]').swiper.allowTouchMove === true"
            . " && document.querySelector('[data-galeria]').swiper.params.simulateTouch === true")
        ->assertNoJavaScriptErrors()
        ->assertNoBrokenImages();

    $id = (int) basename((string) parse_url($page->url(), PHP_URL_PATH));
    visit(url('/'))->assertAttributeContains("a[href='/imoveis/{$id}'] img", 'src', '_thumb.webp');

    excluir($page);
});

test('uma foto aparece sem controles', function () {
    $titulo = 'E2E Uma ' . bin2hex(random_bytes(3));
    $page = preencher(visit(url('/imoveis/novo')), $titulo)->attach('fotos[]', foto('casa.jpg'));
    figuras($page, 1);
    $page->press('Salvar anúncio')
        ->assertSee('Anúncio criado.')
        ->assertVisible('img[alt="Foto principal de ' . $titulo . '"]')
        ->assertNotPresent('.swiper-button-next')
        ->assertNotPresent('.swiper-button-prev')
        ->assertNotPresent('.swiper-pagination');

    excluir($page);
});

test('formulario acumula tres fotos e salva todas', function () {
    $page = preencher(visit(url('/imoveis/novo')), 'E2E Acumula ' . bin2hex(random_bytes(3)))
        ->attach('fotos[]', foto('casa.jpg'));
    figuras($page, 1);
    $page->attach('fotos[]', foto('sala.jpg'));
    figuras($page, 2);
    $page->attach('fotos[]', foto('quarto.jpg'));
    figuras($page, 3);
    $page->assertScript("JSON.stringify([...document.querySelectorAll('#previa-fotos figure img')].map((i) => i.alt))",
            '["Prévia de casa.jpg","Prévia de sala.jpg","Prévia de quarto.jpg"]')
        ->assertScript("JSON.stringify([...document.querySelectorAll('#previa-fotos input[name=capa]')].map((r) => r.value))",
            '["n:0","n:1","n:2"]')
        ->assertCount('#previa-fotos figure button', 3)
        ->press('Salvar anúncio')
        ->assertSee('Anúncio criado.')
        ->assertCount('.swiper-slide', 3);

    excluir($page);
});

test('formulario acumula, remove a do meio e escolhe a capa', function () {
    $page = preencher(visit(url('/imoveis/novo')), 'E2E Capa ' . bin2hex(random_bytes(3)))
        ->attach('fotos[]', foto('casa.jpg'));
    figuras($page, 1);
    $page->attach('fotos[]', foto('sala.jpg'));
    figuras($page, 2);
    $page->attach('fotos[]', foto('quarto.jpg'));
    figuras($page, 3);
    $page->click('#previa-fotos figure:nth-of-type(2) button');
    figuras($page, 2);
    $page->assertScript("JSON.stringify([...document.querySelectorAll('#previa-fotos figure img')].map((i) => i.alt))",
            '["Prévia de casa.jpg","Prévia de quarto.jpg"]')
        ->assertScript("JSON.stringify([...document.querySelectorAll('#previa-fotos input[name=capa]')].map((r) => r.value))",
            '["n:0","n:1"]')
        ->radio('capa', 'n:1')
        ->press('Salvar anúncio')
        ->assertSee('Anúncio criado.')
        ->assertCount('.swiper-slide', 2);

    $largura = $page->script("new Promise((r) => { const i = document.querySelector('.swiper-slide img');"
        . " i.complete && i.naturalWidth ? r(i.naturalWidth) : i.addEventListener('load', () => r(i.naturalWidth)); })");
    expect($largura)->toBe(1024);

    excluir($page);
});

test('capa pendente volta para a primeira ao remover a marcada', function () {
    $page = visit(url('/imoveis/novo'))->attach('fotos[]', foto('casa.jpg'));
    figuras($page, 1);
    $page->attach('fotos[]', foto('sala.jpg'));
    figuras($page, 2);
    $page->assertRadioSelected('capa', 'n:0')
        ->radio('capa', 'n:1')
        ->assertRadioSelected('capa', 'n:1')
        // remove a marcada (a capa): ela fica no meio da lista e o seletor a acha pelo rádio marcado
        ->click('#previa-fotos figure:has(input[name=capa]:checked) button');
    figuras($page, 1);
    $page->assertRadioSelected('capa', 'n:0');
});

test('limite recusa a selecao inteira e mantem a lista', function () {
    $page = visit(url('/imoveis/novo'));
    selecionar($page, 9, 'nove');
    figuras($page, 9);
    selecionar($page, 2, 'mais');
    $page->assertSee('Escolha até 1 foto(s)');
    figuras($page, 9);
});

test('arquivo repetido nao entra duas vezes', function () {
    $page = visit(url('/imoveis/novo'));
    selecionar($page, 1, 'repetido');
    figuras($page, 1);
    selecionar($page, 1, 'repetido');
    figuras($page, 1);
    $page->assertScript("document.querySelectorAll('#previa-fotos figure').length === 1");
});

test('tamanho aparece em KB e em MB', function () {
    $page = visit(url('/imoveis/novo'))->attach('fotos[]', foto('casa.jpg'));
    figuras($page, 1);
    $page->assertSeeIn('#previa-fotos figure:nth-of-type(1)', '13 KB');
    selecionar($page, 1, 'grande', 1468006);
    figuras($page, 2);
    $page->assertSeeIn('#previa-fotos figure:nth-of-type(2)', '1.4 MB');
});

test('preparando fotos desabilita o envio ate terminar', function () {
    $page = visit(url('/imoveis/novo'));
    $page->script("(() => { const original = window.createImageBitmap;"
        . " window.createImageBitmap = (...a) => new Promise((r) => { window.soltar = () => r(original(...a)); }); })()");
    $page->attach('fotos[]', foto('casa.jpg'))
        ->assertButtonDisabled('Preparando fotos…');
    $page->script('window.soltar()');
    figuras($page, 1);
    $page->assertButtonEnabled('Salvar anúncio');
});
