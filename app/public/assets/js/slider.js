// Small carousel for [data-slider]: arrows, "n / total" counter, arrow keys and mouse/touch drag.
(function () {
  'use strict';

  const LIMIAR = 50;

  function iniciar(raiz) {
    const trilho = raiz.querySelector('.slider-trilho');
    const slides = Array.from(trilho.children);
    const anterior = raiz.querySelector('.slider-anterior');
    const proxima = raiz.querySelector('.slider-proxima');
    const contador = raiz.querySelector('.slider-contador');
    let atual = 0;
    let inicio = null;
    let deslocamento = 0;

    function mover(extra) {
      trilho.style.transform = `translateX(calc(${-100 * atual}% + ${extra}px))`;
    }

    function ir(indice) {
      atual = Math.max(0, Math.min(slides.length - 1, indice));
      mover(0);
      slides.forEach((slide, i) => slide.setAttribute('aria-hidden', String(i !== atual)));
      if (contador) {
        contador.textContent = `${atual + 1} / ${slides.length}`;
      }
      if (anterior) {
        anterior.disabled = atual === 0;
      }
      if (proxima) {
        proxima.disabled = atual === slides.length - 1;
      }
    }

    function soltar(evento) {
      if (inicio === null) {
        return;
      }
      inicio = null;
      trilho.style.transition = '';
      const cancelado = evento.type === 'pointercancel';
      const passo = cancelado ? 0 : deslocamento < -LIMIAR ? 1 : deslocamento > LIMIAR ? -1 : 0;
      deslocamento = 0;
      ir(atual + passo);
    }

    raiz.scrollLeft = 0;
    trilho.scrollLeft = 0;
    raiz.classList.add('slider-pronto');

    if (anterior) {
      anterior.addEventListener('click', () => ir(atual - 1));
    }
    if (proxima) {
      proxima.addEventListener('click', () => ir(atual + 1));
    }

    raiz.addEventListener('keydown', (evento) => {
      if (evento.key === 'ArrowLeft' || evento.key === 'ArrowRight') {
        evento.preventDefault();
        ir(atual + (evento.key === 'ArrowRight' ? 1 : -1));
      }
    });

    trilho.addEventListener('pointerdown', (evento) => {
      if (slides.length < 2 || (evento.pointerType === 'mouse' && evento.button !== 0)) {
        return;
      }
      inicio = evento.clientX;
      deslocamento = 0;
      trilho.setPointerCapture(evento.pointerId);
      trilho.style.transition = 'none';
    });

    trilho.addEventListener('pointermove', (evento) => {
      if (inicio === null) {
        return;
      }
      deslocamento = evento.clientX - inicio;
      mover(deslocamento);
    });

    trilho.addEventListener('pointerup', soltar);
    trilho.addEventListener('pointercancel', soltar);

    ir(0);
    return { ir, atual: () => atual, total: slides.length };
  }

  window.LarCertoSlider = { iniciar };
  document.querySelectorAll('[data-slider]').forEach((raiz) => {
    raiz.larCertoSlider = iniciar(raiz);
  });
})();
