<?php
// Shared by novo.php and editar.php; $id is null when creating.
use LarCerto\Models\Imovel;

$erro = fn (string $campo): string => isset($erros[$campo]) ? 'campo-erro' : '';
?>
<form class="grid gap-5 rounded-xl border border-line bg-white p-6 shadow-sm" method="post"
      action="<?= e($id === null ? '/imoveis' : '/imoveis/' . $id) ?>" enctype="multipart/form-data">
  <input type="hidden" name="csrf" value="<?= e($csrf) ?>">

  <?php if ($erros): ?>
    <div class="rounded-lg border border-red-700/30 bg-red-50 px-4 py-3 font-semibold text-red-800" role="alert">Corrija os campos destacados antes de salvar.</div>
  <?php endif ?>

  <label class="rotulo <?= e($erro('titulo')) ?>">
    Título
    <input class="campo" name="titulo" required maxlength="120" value="<?= e($dados['titulo']) ?>" placeholder="Ex.: Kitnet Centro · perto UTFPR">
    <?php if (isset($erros['titulo'])): ?><small class="erro-msg"><?= e($erros['titulo']) ?></small><?php endif ?>
  </label>

  <div class="grid gap-5 sm:grid-cols-2">
    <label class="rotulo <?= e($erro('tipo')) ?>">
      Tipo
      <select class="campo" name="tipo" required>
        <?php foreach (Imovel::TIPOS as $valor => $rotulo): ?>
          <option value="<?= e($valor) ?>" <?= e($dados['tipo'] === $valor ? 'selected' : '') ?>><?= e($rotulo) ?></option>
        <?php endforeach ?>
      </select>
      <?php if (isset($erros['tipo'])): ?><small class="erro-msg"><?= e($erros['tipo']) ?></small><?php endif ?>
    </label>

    <label class="rotulo <?= e($erro('preco')) ?>">
      Aluguel (R$/mês)
      <input class="campo" type="number" name="preco" required min="0.01" step="0.01" value="<?= e($dados['preco']) ?>">
      <?php if (isset($erros['preco'])): ?><small class="erro-msg"><?= e($erros['preco']) ?></small><?php endif ?>
    </label>

    <label class="rotulo <?= e($erro('bairro')) ?>">
      Bairro (Guarapuava)
      <input class="campo" name="bairro" required maxlength="60" list="bairros" value="<?= e($dados['bairro']) ?>">
      <datalist id="bairros">
        <?php foreach (Imovel::BAIRROS as $bairro): ?><option value="<?= e($bairro) ?>"></option><?php endforeach ?>
      </datalist>
      <?php if (isset($erros['bairro'])): ?><small class="erro-msg"><?= e($erros['bairro']) ?></small><?php endif ?>
    </label>

    <label class="rotulo <?= e($erro('campus')) ?>">
      Campus mais próximo
      <select class="campo" name="campus" required>
        <?php foreach (Imovel::CAMPI as $valor => $rotulo): ?>
          <option value="<?= e($valor) ?>" <?= e($dados['campus'] === $valor ? 'selected' : '') ?>><?= e($rotulo) ?></option>
        <?php endforeach ?>
      </select>
      <?php if (isset($erros['campus'])): ?><small class="erro-msg"><?= e($erros['campus']) ?></small><?php endif ?>
    </label>

    <label class="rotulo <?= e($erro('anunciante_nome')) ?>">
      Nome do anunciante
      <input class="campo" name="anunciante_nome" required maxlength="80" value="<?= e($dados['anunciante_nome']) ?>">
      <?php if (isset($erros['anunciante_nome'])): ?><small class="erro-msg"><?= e($erros['anunciante_nome']) ?></small><?php endif ?>
    </label>

    <label class="rotulo <?= e($erro('anunciante_tipo')) ?>">
      Anunciante é
      <select class="campo" name="anunciante_tipo" required>
        <?php foreach (Imovel::ANUNCIANTES as $valor => $rotulo): ?>
          <option value="<?= e($valor) ?>" <?= e($dados['anunciante_tipo'] === $valor ? 'selected' : '') ?>><?= e($rotulo) ?></option>
        <?php endforeach ?>
      </select>
      <?php if (isset($erros['anunciante_tipo'])): ?><small class="erro-msg"><?= e($erros['anunciante_tipo']) ?></small><?php endif ?>
    </label>
  </div>

  <label class="flex items-center gap-2 font-semibold">
    <input class="size-4 accent-brand" type="checkbox" name="verificado" value="1" <?= e($dados['verificado'] ? 'checked' : '') ?>>
    Imóvel verificado pela equipe LarCerto (exibe o selo)
  </label>

  <fieldset class="grid gap-3 rounded-lg border border-line p-4 <?= e($erro('fotos')) ?>">
    <legend class="px-1 font-semibold">Fotos</legend>
    <p class="text-sm text-muted">
      Até <?= e($maxFotos) ?> fotos por imóvel (JPEG, PNG ou WebP, até 20 MB cada). Fotos grandes são reduzidas
      antes do envio. Escolha quantas vezes quiser: as fotos se somam na lista. Marque a <strong>capa</strong>: ela aparece no card da listagem e abre a galeria do anúncio.
    </p>

    <div id="previa-fotos" class="grid grid-cols-2 gap-3 sm:grid-cols-4" aria-live="polite">
      <?php
      $capa = array_values(array_filter($fotos, fn (array $foto): bool => $foto['capa']));
      $galeria = array_values(array_filter($fotos, fn (array $foto): bool => !$foto['capa']));
      ?>
      <?php if (!$fotos): ?>
        <p class="col-span-full text-sm text-muted">Nenhuma foto ainda</p>
      <?php endif ?>
      <?php if ($capa): ?>
        <p class="col-span-full font-semibold">Capa</p>
        <?php foreach ($capa as $foto): ?>
          <figure class="col-span-full overflow-hidden rounded-lg border border-line" data-papel="capa">
            <img class="aspect-[4/3] w-full object-cover" src="<?= e($foto['url']) ?>" alt="Capa do anúncio">
            <figcaption class="grid gap-1 p-2 text-sm">
              <label class="sr-only"><input class="sr-only" type="radio" name="capa" value="<?= e('h:' . $foto['nome']) ?>" checked> <span data-texto-capa>Capa do anúncio</span></label>
              <label class="flex items-center gap-1.5 text-red-700"><input class="accent-red-700" type="checkbox" name="remover[]" value="<?= e($foto['nome']) ?>"> <span data-texto-remover>Remover</span></label>
              <small class="hidden text-muted" data-aviso-remover>Será removida ao salvar</small>
            </figcaption>
          </figure>
        <?php endforeach ?>
      <?php endif ?>
      <?php if ($galeria): ?>
        <p class="col-span-full font-semibold">Galeria do anúncio (<?= e(count($galeria)) ?>)</p>
        <?php foreach ($galeria as $foto): ?>
          <figure class="overflow-hidden rounded-lg border border-line" data-papel="galeria">
            <img class="aspect-[4/3] w-full object-cover" src="<?= e($foto['url']) ?>" alt="Foto do imóvel">
            <figcaption class="grid gap-1 p-2 text-sm">
              <label class="flex items-center gap-1.5" data-rotulo-capa><input class="accent-brand" type="radio" name="capa" value="<?= e('h:' . $foto['nome']) ?>"> <span data-texto-capa>Usar como capa</span></label>
              <label class="flex items-center gap-1.5 text-red-700"><input class="accent-red-700" type="checkbox" name="remover[]" value="<?= e($foto['nome']) ?>"> <span data-texto-remover>Remover</span></label>
              <small class="hidden text-muted" data-aviso-remover>Será removida ao salvar</small>
            </figcaption>
          </figure>
        <?php endforeach ?>
      <?php endif ?>
    </div>

    <input class="campo file:mr-3 file:rounded-md file:border-0 file:bg-brand/10 file:px-3 file:py-1.5 file:font-semibold file:text-brand"
           type="file" name="fotos[]" multiple accept="image/jpeg,image/png,image/webp" data-fotos="previa-fotos" data-cabem="<?= e($cabem) ?>" data-max="<?= e($maxFotos) ?>">

    <?php if (isset($erros['fotos'])): ?><small class="erro-msg"><?= e($erros['fotos']) ?></small><?php endif ?>
  </fieldset>

  <button class="btn btn-accent w-full" type="submit"><?= e($id === null ? 'Salvar anúncio' : 'Salvar alterações') ?></button>
</form>
