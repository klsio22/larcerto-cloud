<?php
use LarCerto\Models\Imovel;

$texto = Imovel::anuncianteTexto($imovel);
?>
<div class="shell grid gap-8 pt-8 lg:grid-cols-[1fr_320px]">
  <div class="min-w-0">
    <div class="relative overflow-hidden rounded-xl">
      <?php if ($capa === null && !$galeria): ?>
        <div class="thumb aspect-[4/3] w-full <?= e(Imovel::thumbClass($imovel['tipo'])) ?>"></div>
      <?php else: ?>
        <div class="swiper galeria-slider aspect-[4/3] w-full bg-white" data-galeria>
          <ul class="galeria swiper-wrapper">
            <?php if ($capa !== null): ?>
              <li class="swiper-slide"><img class="h-full w-full object-cover" src="<?= e($capa) ?>" alt="<?= e('Foto principal de ' . $imovel['titulo']) ?>"></li>
            <?php else: ?>
              <li class="swiper-slide"><div class="thumb h-full w-full <?= e(Imovel::thumbClass($imovel['tipo'])) ?>"></div></li>
            <?php endif ?>
            <?php foreach ($galeria as $n => $url): ?>
              <li class="swiper-slide"><img class="h-full w-full object-cover" src="<?= e($url) ?>" alt="<?= e('Foto ' . ($n + 2) . ' de ' . $imovel['titulo']) ?>" loading="lazy"></li>
            <?php endforeach ?>
          </ul>
          <?php if ($galeria): ?>
            <button class="swiper-button-prev" type="button" aria-label="Foto anterior"></button>
            <button class="swiper-button-next" type="button" aria-label="Próxima foto"></button>
            <div class="swiper-pagination"></div>
          <?php endif ?>
        </div>
        <link rel="stylesheet" href="/assets/vendor/swiper/swiper-bundle.min.css">
        <script src="/assets/vendor/swiper/swiper-bundle.min.js" defer></script>
        <script src="/assets/js/galeria.js" defer></script>
      <?php endif ?>
      <?php if ($imovel['verificado']): ?><span class="selo absolute left-3 top-3 z-10">Verificado</span><?php endif ?>
    </div>

    <h1 class="mt-6 font-display text-3xl font-bold"><?= e($imovel['titulo']) ?></h1>
    <p class="mt-1 text-muted"><?= e(Imovel::TIPOS[$imovel['tipo']] . ' · ' . $imovel['bairro'] . ', Guarapuava-PR') ?></p>

    <?php if ($imovel['verificado']): ?>
      <p class="mt-4 rounded-lg border-l-4 border-brand bg-brand/10 px-4 py-3">Selo <strong>Verificado</strong>: anúncio conferido pela equipe LarCerto.</p>
    <?php endif ?>

    <dl class="mt-6 grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 rounded-xl border border-line bg-white p-5">
      <dt class="font-semibold">Tipo</dt><dd><?= e(Imovel::TIPOS[$imovel['tipo']]) ?></dd>
      <dt class="font-semibold">Bairro</dt><dd><?= e($imovel['bairro']) ?></dd>
      <dt class="font-semibold">Campus</dt><dd><?= e(Imovel::CAMPI[$imovel['campus']]) ?></dd>
      <dt class="font-semibold">Anunciante</dt><dd><?= e($texto) ?></dd>
    </dl>
  </div>

  <aside class="h-fit rounded-xl border border-line bg-white p-5 lg:sticky lg:top-6">
    <p class="text-sm text-muted"><?= e($texto) ?></p>
    <p class="mt-1 text-3xl font-bold text-brand-deep"><?= e(preco($imovel['preco'])) ?><span class="text-base font-normal text-muted">/mês</span></p>
    <div class="mt-5 grid gap-2">
      <a class="btn btn-secondary" href="/imoveis/<?= e($imovel['id']) ?>/editar">Editar anúncio</a>
      <form method="post" action="/imoveis/<?= e($imovel['id']) ?>/excluir" onsubmit="return confirm('Excluir este anúncio e as fotos dele?');">
        <input type="hidden" name="csrf" value="<?= e($csrf) ?>">
        <button class="btn btn-danger w-full" type="submit">Excluir anúncio</button>
      </form>
      <a class="btn btn-secondary" href="/">← Voltar à lista</a>
    </div>
  </aside>
</div>
