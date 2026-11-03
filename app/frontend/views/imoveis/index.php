<?php
use LarCerto\Models\Imovel;

$total = count($imoveis);
?>
<section class="bg-gradient-to-b from-brand-deep to-brand pb-10 pt-12 text-white">
  <div class="shell">
    <h1 class="font-display text-3xl font-bold sm:text-4xl">Aluguel verificado perto do seu campus</h1>
    <p class="mt-2 max-w-2xl text-white/85">Kitnets, apartamentos e repúblicas em Guarapuava para quem estuda na UTFPR ou na Unicentro.</p>

    <form class="mt-6 grid gap-3 rounded-xl bg-white p-4 text-ink shadow-lg sm:grid-cols-5 sm:items-end" method="get" action="/">
      <label class="rotulo">
        Aluguel até (R$)
        <input class="campo" type="number" name="max" min="0" step="10" value="<?= e($filtros['max']) ?>" placeholder="Ex.: 800">
      </label>
      <label class="rotulo">
        Bairro
        <select class="campo" name="bairro">
          <option value="">Todos</option>
          <?php foreach ($bairros as $bairro): ?>
            <option value="<?= e($bairro) ?>" <?= e($filtros['bairro'] === $bairro ? 'selected' : '') ?>><?= e($bairro) ?></option>
          <?php endforeach ?>
        </select>
      </label>
      <label class="rotulo">
        Campus
        <select class="campo" name="campus">
          <option value="">Todos</option>
          <?php foreach (Imovel::CAMPI as $valor => $rotulo): ?>
            <option value="<?= e($valor) ?>" <?= e($filtros['campus'] === $valor ? 'selected' : '') ?>><?= e($rotulo) ?></option>
          <?php endforeach ?>
        </select>
      </label>
      <label class="rotulo">
        Tipo
        <select class="campo" name="tipo">
          <option value="">Todos</option>
          <?php foreach (Imovel::TIPOS as $valor => $rotulo): ?>
            <option value="<?= e($valor) ?>" <?= e($filtros['tipo'] === $valor ? 'selected' : '') ?>><?= e($rotulo) ?></option>
          <?php endforeach ?>
        </select>
      </label>
      <button class="btn btn-accent" type="submit">Buscar</button>
    </form>
  </div>
</section>

<section class="shell pt-8">
  <div class="mb-4 flex items-baseline justify-between font-display text-2xl font-semibold">
    <h2 class="resumo"><?= e($total . ($total === 1 ? ' imóvel' : ' imóveis')) ?></h2>
    <?php if ($filtrando): ?><a class="font-sans text-base text-brand hover:underline" href="/">Limpar filtros</a><?php endif ?>
  </div>

  <?php if ($total === 0): ?>
    <p class="rounded-xl border border-dashed border-line bg-white p-8 text-center text-muted">
      Nenhum imóvel com esses filtros. <a class="font-semibold text-brand hover:underline" href="/imoveis/novo">Anunciar um imóvel</a>.
    </p>
  <?php else: ?>
    <div class="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
      <?php foreach ($imoveis as $i): ?>
        <a class="group flex flex-col overflow-hidden rounded-xl border border-line bg-white transition hover:-translate-y-1 hover:shadow-xl" href="/imoveis/<?= e($i['id']) ?>"
           data-preco="<?= e($i['preco']) ?>" data-tipo="<?= e($i['tipo']) ?>" data-campus="<?= e($i['campus']) ?>" data-bairro="<?= e($i['bairro']) ?>">
          <div class="relative aspect-[4/3] overflow-hidden">
            <?php if ($i['foto'] !== null): ?>
              <img class="h-full w-full object-cover transition group-hover:scale-105" src="<?= e($i['foto']) ?>" alt="<?= e('Foto de ' . $i['titulo']) ?>" loading="lazy">
            <?php else: ?>
              <div class="thumb h-full w-full <?= e(Imovel::thumbClass($i['tipo'])) ?>"></div>
            <?php endif ?>
            <?php if ($i['verificado']): ?><span class="selo absolute left-3 top-3">Verificado</span><?php endif ?>
          </div>
          <div class="flex flex-1 flex-col gap-1 p-4">
            <h3 class="font-display text-lg font-semibold leading-snug"><?= e($i['titulo']) ?></h3>
            <p class="text-sm text-muted"><?= e(Imovel::TIPOS[$i['tipo']] . ' · ' . $i['bairro'] . ' · ' . Imovel::CAMPI[$i['campus']]) ?></p>
            <p class="text-sm text-muted"><?= e(Imovel::anuncianteTexto($i)) ?></p>
            <p class="mt-auto pt-2 text-xl font-bold text-brand-deep"><?= e(preco($i['preco'])) ?><span class="text-sm font-normal text-muted">/mês</span></p>
          </div>
        </a>
      <?php endforeach ?>
    </div>
  <?php endif ?>
</section>
