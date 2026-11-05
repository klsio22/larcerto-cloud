<?php
use LarCerto\Models\Imovel;

$texto = Imovel::anuncianteTexto($imovel);
$total = 1 + count($galeria);
?>
<div class="shell imovel">
  <div class="imovel-principal">
    <div class="imovel-midia">
      <?php if ($capa === null && !$galeria): ?>
        <div class="thumb imovel-desenho <?= e(Imovel::thumbClass($imovel['tipo'])) ?>"></div>
      <?php else: ?>
        <section class="slider imovel-slider" data-slider tabindex="0" aria-roledescription="carrossel" aria-label="<?= e('Fotos de ' . $imovel['titulo']) ?>">
          <ul class="slider-trilho">
            <?php if ($capa !== null): ?>
              <li class="slider-slide" aria-label="<?= e('Foto 1 de ' . $total) ?>"><img class="preencher" src="<?= e($capa) ?>" alt="<?= e('Foto principal de ' . $imovel['titulo']) ?>"></li>
            <?php else: ?>
              <li class="slider-slide" aria-label="<?= e('Foto 1 de ' . $total) ?>"><div class="thumb preencher <?= e(Imovel::thumbClass($imovel['tipo'])) ?>"></div></li>
            <?php endif ?>
            <?php foreach ($galeria as $n => $url): ?>
              <li class="slider-slide" aria-label="<?= e('Foto ' . ($n + 2) . ' de ' . $total) ?>"><img class="preencher" src="<?= e($url) ?>" alt="<?= e('Foto ' . ($n + 2) . ' de ' . $imovel['titulo']) ?>" loading="lazy"></li>
            <?php endforeach ?>
          </ul>
          <?php if ($galeria): ?>
            <button class="slider-anterior" type="button" aria-label="Foto anterior"><svg viewBox="0 0 11 20" width="11" height="20" aria-hidden="true"><path d="M9.6 1 1.4 10l8.2 9" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
            <button class="slider-proxima" type="button" aria-label="Próxima foto"><svg viewBox="0 0 11 20" width="11" height="20" aria-hidden="true"><path d="M1.4 1 9.6 10l-8.2 9" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
            <div class="slider-contador" aria-live="polite"><?= e('1 / ' . $total) ?></div>
          <?php endif ?>
        </section>
        <script src="/assets/js/slider.js" defer></script>
      <?php endif ?>
      <?php if ($imovel['verificado']): ?><span class="selo selo-canto">Verificado</span><?php endif ?>
    </div>

    <h1 class="imovel-titulo"><?= e($imovel['titulo']) ?></h1>
    <p class="imovel-local"><?= e(Imovel::TIPOS[$imovel['tipo']] . ' · ' . $imovel['bairro'] . ', Guarapuava-PR') ?></p>

    <?php if ($imovel['verificado']): ?>
      <p class="imovel-verificado">Selo <strong>Verificado</strong>: anúncio conferido pela equipe LarCerto.</p>
    <?php endif ?>

    <dl class="ficha">
      <dt>Tipo</dt><dd><?= e(Imovel::TIPOS[$imovel['tipo']]) ?></dd>
      <dt>Bairro</dt><dd><?= e($imovel['bairro']) ?></dd>
      <dt>Campus</dt><dd><?= e(Imovel::CAMPI[$imovel['campus']]) ?></dd>
      <dt>Anunciante</dt><dd><?= e($texto) ?></dd>
    </dl>
  </div>

  <aside class="lateral">
    <p class="lateral-anunciante"><?= e($texto) ?></p>
    <p class="lateral-preco"><?= e(preco($imovel['preco'])) ?><span class="por-mes">/mês</span></p>
    <div class="lateral-acoes">
      <a class="btn btn-secondary" href="/imoveis/<?= e($imovel['id']) ?>/editar">Editar anúncio</a>
      <form method="post" action="/imoveis/<?= e($imovel['id']) ?>/excluir" onsubmit="return confirm('Excluir este anúncio e as fotos dele?');">
        <input type="hidden" name="csrf" value="<?= e($csrf) ?>">
        <button class="btn btn-danger btn-bloco" type="submit">Excluir anúncio</button>
      </form>
      <a class="btn btn-secondary" href="/">← Voltar à lista</a>
    </div>
  </aside>
</div>
