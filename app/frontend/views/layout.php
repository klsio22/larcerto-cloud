<?php
// Logo and name on every page (REQ02).
$nav = fn (string $item): string => $ativo === $item ? 'menu-link ativo' : 'menu-link';
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
<body>
  <div class="faixa">
    <div class="shell faixa-in">
      <span>Imóveis verificados para estudantes · Guarapuava-PR</span>
      <span class="faixa-dominio">larcerto.com.br</span>
    </div>
  </div>

  <header class="cabecalho">
    <div class="shell cabecalho-in">
      <a class="marca" href="/">
        <img src="/assets/logo.svg" alt="Logotipo LarCerto" width="36" height="36">
        <span class="marca-nome">Lar<span>Certo</span></span>
      </a>
      <nav class="menu" aria-label="Principal">
        <a class="<?= e($nav('imoveis')) ?>" href="/">Imóveis</a>
        <a class="<?= e($nav('anunciar')) ?>" href="/imoveis/novo">Anunciar</a>
      </nav>
      <a class="btn btn-primary cabecalho-acao" href="/imoveis/novo">+ Anunciar</a>
    </div>
  </header>

  <main class="conteudo">
    <?php if ($aviso !== null): ?>
      <div class="shell aviso-area">
        <p class="aviso" role="status"><?= e($aviso) ?></p>
      </div>
    <?php endif ?>
    <?php require $__view; ?>
  </main>

  <footer class="rodape">
    <div class="shell rodape-grade">
      <div>
        <h4 class="rodape-titulo rodape-marca">LarCerto</h4>
        <p class="rodape-texto">Aluguel com selo Verificado perto da UTFPR e da Unicentro.</p>
      </div>
      <div>
        <h4 class="rodape-titulo">Imóveis</h4>
        <a class="rodape-link" href="/">Buscar imóveis</a>
      </div>
      <div>
        <h4 class="rodape-titulo">Anunciantes</h4>
        <a class="rodape-link" href="/imoveis/novo">Anunciar imóvel</a>
      </div>
      <p class="rodape-fim">LarCerto · Computação em Nuvem (TSI36C) · UTFPR</p>
    </div>
  </footer>
  <script src="/assets/js/fotos.js" defer></script>
</body>
</html>
