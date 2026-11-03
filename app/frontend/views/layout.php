<?php
// Logo and name on every page (REQ02).
$nav = fn (string $item): string => $ativo === $item ? 'text-brand border-brand' : 'text-muted border-transparent hover:text-ink';
?>
<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><?= e($titulo) ?> · LarCerto</title>
  <link rel="icon" href="/assets/logo.svg" type="image/svg+xml">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,600;9..144,700&family=Source+Sans+3:wght@400;600;700&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="/assets/app.css">
</head>
<body class="flex min-h-screen flex-col bg-paper font-sans text-ink antialiased">
  <div class="bg-brand-deep text-sm text-white/85">
    <div class="shell flex justify-between py-1.5">
      <span>Imóveis verificados para estudantes · Guarapuava-PR</span>
      <span class="hidden sm:inline">larcerto.com.br</span>
    </div>
  </div>

  <header class="border-b border-line bg-white">
    <div class="shell flex items-center gap-6 py-3">
      <a class="flex items-center gap-2.5" href="/">
        <img src="/assets/logo.svg" alt="Logotipo LarCerto" width="36" height="36">
        <span class="font-display text-2xl font-bold tracking-tight">Lar<span>Certo</span></span>
      </a>
      <nav class="hidden gap-5 sm:flex" aria-label="Principal">
        <a class="border-b-2 py-1 font-semibold <?= e($nav('imoveis')) ?>" href="/">Imóveis</a>
        <a class="border-b-2 py-1 font-semibold <?= e($nav('anunciar')) ?>" href="/imoveis/novo">Anunciar</a>
      </nav>
      <a class="btn btn-primary ml-auto" href="/imoveis/novo">+ Anunciar</a>
    </div>
  </header>

  <main class="flex-1 pb-16">
    <?php if ($aviso !== null): ?>
      <div class="shell pt-6">
        <p class="rounded-lg border border-brand/25 bg-brand/10 px-4 py-3 font-semibold text-brand-deep" role="status"><?= e($aviso) ?></p>
      </div>
    <?php endif ?>
    <?php require $__view; ?>
  </main>

  <footer class="bg-brand-deep text-white/80">
    <div class="shell grid gap-6 py-10 sm:grid-cols-3">
      <div>
        <h4 class="font-display text-lg font-semibold text-white">LarCerto</h4>
        <p class="mt-1 text-sm">Aluguel com selo Verificado perto da UTFPR e da Unicentro.</p>
      </div>
      <div>
        <h4 class="font-semibold text-white">Imóveis</h4>
        <a class="mt-1 block text-sm hover:text-white" href="/">Buscar imóveis</a>
      </div>
      <div>
        <h4 class="font-semibold text-white">Anunciantes</h4>
        <a class="mt-1 block text-sm hover:text-white" href="/imoveis/novo">Anunciar imóvel</a>
      </div>
      <p class="border-t border-white/15 pt-4 text-xs sm:col-span-3">LarCerto · Computação em Nuvem (TSI36C) · UTFPR</p>
    </div>
  </footer>
  <script src="/assets/js/fotos.js" defer></script>
</body>
</html>
