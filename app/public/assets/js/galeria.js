(function () {
  'use strict';

  const slider = document.querySelector('[data-galeria]');
  if (!slider || typeof Swiper === 'undefined') {
    return;
  }
  const opcoes = {
    keyboard: { enabled: true },
    a11y: { prevSlideMessage: 'Foto anterior', nextSlideMessage: 'Próxima foto', slideLabelMessage: 'Foto {{index}} de {{slidesLength}}' },
  };
  const proximo = slider.querySelector('.swiper-button-next');
  if (proximo) {
    opcoes.navigation = { nextEl: proximo, prevEl: slider.querySelector('.swiper-button-prev') };
    opcoes.pagination = { el: slider.querySelector('.swiper-pagination'), type: 'fraction' };
  }
  new Swiper(slider, opcoes);
})();
