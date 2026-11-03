<?php
declare(strict_types=1);

return [
    ['GET',  '/',                     'index'],
    ['GET',  '/imoveis/novo',         'novo'],
    ['POST', '/imoveis',              'criar'],
    ['GET',  '/imoveis/{id}',         'mostrar'],
    ['GET',  '/imoveis/{id}/editar',  'editar'],
    ['POST', '/imoveis/{id}',         'atualizar'],
    ['POST', '/imoveis/{id}/excluir', 'excluir'],
];
