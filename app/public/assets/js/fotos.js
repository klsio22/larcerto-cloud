// Downscales large photos before upload. Without JS the server receives and resizes the original.
(function () {
  'use strict';

  const LADO_MAX = 1920;
  const LIMITE_BYTES = 2 * 1024 * 1024;
  const QUALIDADE = 0.85;

  function blob(canvas, tipo) {
    return new Promise((resolve) => canvas.toBlob(resolve, tipo, QUALIDADE));
  }

  async function reduzir(arquivo) {
    let imagem;
    try {
      imagem = await createImageBitmap(arquivo, { imageOrientation: 'from-image' });
    } catch (falha) {
      return arquivo; // the server rejects it with a message
    }
    const maior = Math.max(imagem.width, imagem.height);
    if (maior <= LADO_MAX && arquivo.size <= LIMITE_BYTES) {
      imagem.close();
      return arquivo;
    }
    const fator = Math.min(1, LADO_MAX / maior);
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(imagem.width * fator);
    canvas.height = Math.round(imagem.height * fator);
    canvas.getContext('2d').drawImage(imagem, 0, 0, canvas.width, canvas.height);
    imagem.close();

    // JPEG where the browser cannot encode WebP; the server re-encodes to WebP anyway.
    let saida = await blob(canvas, 'image/webp');
    if (!saida || saida.type !== 'image/webp') {
      saida = await blob(canvas, 'image/jpeg');
    }
    if (!saida || saida.size >= arquivo.size) {
      return arquivo;
    }
    const extensao = saida.type === 'image/webp' ? '.webp' : '.jpg';
    return new File([saida], arquivo.name.replace(/\.[^.]+$/, '') + extensao, { type: saida.type });
  }

  function tamanho(bytes) {
    return bytes < 1024 * 1024
      ? Math.max(1, Math.round(bytes / 1024)) + ' KB'
      : (bytes / 1024 / 1024).toFixed(1) + ' MB';
  }

  function mesmo(a, b) {
    return a.name === b.name && a.size === b.size && a.lastModified === b.lastModified;
  }

  function titulo(texto) {
    const p = document.createElement('p');
    p.className = 'col-span-full font-semibold';
    p.textContent = texto;
    return p;
  }

  function criarFigura(arquivo) {
    const figura = document.createElement('figure');
    figura.className = 'overflow-hidden rounded-lg border border-line';

    const img = document.createElement('img');
    img.className = 'aspect-[4/3] w-full object-cover';
    img.alt = 'Prévia de ' + arquivo.name;
    img.src = URL.createObjectURL(arquivo);
    img.onload = () => URL.revokeObjectURL(img.src);

    const legenda = document.createElement('figcaption');
    legenda.className = 'grid gap-1 p-2 text-sm';
    const linha = document.createElement('div');
    linha.className = 'flex items-center justify-between gap-2';
    const rotulo = document.createElement('label');
    rotulo.className = 'flex items-center gap-1.5';
    const radio = document.createElement('input');
    radio.type = 'radio';
    radio.name = 'capa';
    radio.className = 'accent-brand';
    const texto = document.createElement('span');
    texto.setAttribute('data-texto-capa', '');
    rotulo.append(radio, texto);
    const peso = document.createElement('span');
    peso.className = 'text-muted';
    peso.textContent = tamanho(arquivo.size);
    linha.append(rotulo, peso);
    const remover = document.createElement('button');
    remover.type = 'button';
    remover.className = 'justify-self-start font-semibold text-red-700 hover:underline';
    remover.setAttribute('data-remover-nova', '');
    remover.textContent = 'Remover';
    legenda.append(linha, remover);

    figura.append(img, legenda);
    return figura;
  }

  document.querySelectorAll('input[type="file"][data-fotos]').forEach((input) => {
    const destino = document.getElementById(input.dataset.fotos);
    const form = input.form;
    const botao = form.querySelector('button[type="submit"]');
    const max = Number(input.dataset.max);
    const pendentes = [];
    let aviso = '';

    const figuras = () => Array.from(destino.querySelectorAll(':scope > figure'));
    const radioDe = (figura) => figura.querySelector('input[name="capa"]');
    const removeDe = (figura) => figura.querySelector('input[name="remover[]"]');
    const marcada = (figura) => removeDe(figura) !== null && removeDe(figura).checked;

    function vagas() {
      return Number(input.dataset.cabem) + form.querySelectorAll('input[name="remover[]"]:checked').length - pendentes.length;
    }

    function atualizarRemocao(figura) {
      const marca = marcada(figura);
      figura.classList.toggle('opacity-50', marca);
      figura.querySelector('[data-texto-remover]').textContent = marca ? 'Desfazer' : 'Remover';
      figura.querySelector('[data-aviso-remover]').classList.toggle('hidden', !marca);
    }

    function papel(figura, capa) {
      figura.classList.toggle('col-span-full', capa);
      figura.dataset.papel = capa ? 'capa' : 'galeria';
      const radio = radioDe(figura);
      const rotulo = radio.closest('label');
      radio.classList.toggle('sr-only', capa);
      rotulo.classList.toggle('sr-only', capa);
      rotulo.querySelector('[data-texto-capa]').textContent = capa ? 'Capa do anúncio' : 'Usar como capa';
    }

    function sincronizar() {
      const lista = new DataTransfer();
      pendentes.forEach((pendente, i) => {
        lista.items.add(pendente.arquivo);
        radioDe(pendente.figura).value = 'n:' + i;
      });
      input.files = lista.files;
    }

    // Puts the cover first, the rest after it, and keeps a checked radio on the cover.
    function posicionar() {
      const todas = figuras();
      let capa = todas.find((figura) => radioDe(figura).checked && !marcada(figura));
      if (!capa) {
        capa = todas.find((figura) => !marcada(figura)) || null;
        if (capa) {
          radioDe(capa).checked = true;
        }
      }
      const galeria = todas.filter((figura) => figura !== capa);
      todas.forEach((figura) => papel(figura, figura === capa));
      sincronizar();

      const nodos = [];
      if (aviso) {
        const p = document.createElement('p');
        p.className = 'col-span-full text-sm text-red-700';
        p.textContent = aviso;
        nodos.push(p);
      }
      if (capa) {
        nodos.push(titulo('Capa'), capa);
      }
      if (galeria.length) {
        nodos.push(titulo('Galeria do anúncio (' + galeria.length + ')'), ...galeria);
      }
      if (!todas.length) {
        const vazio = document.createElement('p');
        vazio.className = 'col-span-full text-sm text-muted';
        vazio.textContent = 'Nenhuma foto ainda';
        nodos.push(vazio);
      }
      destino.replaceChildren(...nodos);
    }

    destino.addEventListener('change', (evento) => {
      const alvo = evento.target;
      if (alvo.name === 'remover[]') {
        atualizarRemocao(alvo.closest('figure'));
      }
      if (alvo.name === 'capa' || alvo.name === 'remover[]') {
        posicionar();
      }
    });

    destino.addEventListener('click', (evento) => {
      const remover = evento.target.closest('[data-remover-nova]');
      if (!remover) {
        return;
      }
      const figura = remover.closest('figure');
      const i = pendentes.findIndex((pendente) => pendente.figura === figura);
      if (i >= 0) {
        pendentes.splice(i, 1);
      }
      figura.remove();
      aviso = '';
      posicionar();
    });

    input.addEventListener('change', async () => {
      const escolhidos = Array.from(input.files);
      const novos = escolhidos.filter((f, i) => !pendentes.some((p) => mesmo(p.original, f))
        && escolhidos.findIndex((g) => mesmo(g, f)) === i);
      const cabem = vagas();
      if (novos.length > cabem) {
        aviso = cabem > 0
          ? `Escolha até ${cabem} foto(s): cada imóvel pode ter até ${max}. Marque "Remover" em alguma para liberar vaga.`
          : `Não cabe mais foto: cada imóvel pode ter até ${max}. Remova alguma para liberar vaga.`;
        posicionar();
        return;
      }
      aviso = '';
      const textoBotao = botao.textContent;
      botao.disabled = true;
      input.disabled = true;
      botao.textContent = 'Preparando fotos…';
      try {
        for (const original of novos) {
          const arquivo = await reduzir(original);
          const figura = criarFigura(arquivo);
          pendentes.push({ original, arquivo, figura });
          destino.append(figura);
        }
      } finally {
        posicionar();
        input.disabled = false;
        botao.disabled = false;
        botao.textContent = textoBotao;
      }
    });
  });
})();
