<?php
declare(strict_types=1);

namespace LarCerto\Core;

final class View
{
    public static function render(string $view, array $dados): void
    {
        $dados += ['titulo' => 'LarCerto', 'ativo' => '', 'aviso' => Flash::pegar(), 'csrf' => Csrf::token()];
        (static function (string $__view, string $__layout, array $__dados): void {
            extract($__dados, EXTR_SKIP);
            require $__layout;
        })(self::arquivo($view), self::arquivo('layout'), $dados);
    }

    private static function arquivo(string $nome): string
    {
        return RAIZ . '/frontend/views/' . $nome . '.php';
    }
}
