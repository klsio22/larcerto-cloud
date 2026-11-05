<?php
use LarCerto\Models\Imovel;

$total = count($imoveis);
?>
<section class="hero">
  <div class="shell">
    <h1 class="hero-titulo">Aluguel verificado perto do seu campus</h1>
    <p class="hero-texto">Kitnets, apartamentos e repúblicas em Guarapuava para quem estuda na UTFPR ou na Unicentro.</p>

    <form class="busca" method="get" action="/">
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

<section class="shell lista">
  <div class="lista-topo">
    <h2 class="resumo"><?= e($total . ($total === 1 ? ' imóvel' : ' imóveis')) ?></h2>
    <?php if ($filtrando): ?><a class="link" href="/">Limpar filtros</a><?php endif ?>
  </div>

  <?php if ($total === 0): ?>
    <p class="vazio">
      Nenhum imóvel com esses filtros. <a class="link" href="/imoveis/novo">Anunciar um imóvel</a>.
    </p>
  <?php else: ?>
    <div class="cards">
      <?php foreach ($imoveis as $i): ?>
        <a class="card" href="/imoveis/<?= e($i['id']) ?>"
           data-preco="<?= e($i['preco']) ?>" data-tipo="<?= e($i['tipo']) ?>" data-campus="<?= e($i['campus']) ?>" data-bairro="<?= e($i['bairro']) ?>">
          <div class="card-foto">
            <?php if ($i['foto'] !== null): ?>
              <img class="preencher card-img" src="<?= e($i['foto']) ?>" alt="<?= e('Foto de ' . $i['titulo']) ?>" loading="lazy">
            <?php else: ?>
              <div class="thumb preencher <?= e(Imovel::thumbClass($i['tipo'])) ?>"></div>
            <?php endif ?>
            <?php if ($i['verificado']): ?><span class="selo selo-canto">Verificado</span><?php endif ?>
          </div>
          <div class="card-corpo">
            <h3 class="card-titulo"><?= e($i['titulo']) ?></h3>
            <p class="card-info"><?= e(Imovel::TIPOS[$i['tipo']] . ' · ' . $i['bairro'] . ' · ' . Imovel::CAMPI[$i['campus']]) ?></p>
            <p class="card-info"><?= e(Imovel::anuncianteTexto($i)) ?></p>
            <p class="card-preco"><?= e(preco($i['preco'])) ?><span class="por-mes">/mês</span></p>
          </div>
        </a>
      <?php endforeach ?>
    </div>
  <?php endif ?>
</section>
