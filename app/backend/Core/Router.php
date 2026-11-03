<?php
declare(strict_types=1);

namespace LarCerto\Core;

use LarCerto\Controllers\ImoveisController;

final class Router
{
    public function __construct(private array $rotas)
    {
    }

    public function despachar(string $metodo, string $uri): void
    {
        $caminho = rawurldecode((string) parse_url($uri, PHP_URL_PATH));
        $controller = new ImoveisController();
        $permitidos = [];

        foreach ($this->rotas as [$metodoRota, $padrao, $acao]) {
            $regex = '#^' . str_replace('\{id\}', '([1-9][0-9]{0,9})', preg_quote($padrao, '#')) . '$#D';
            if (preg_match($regex, $caminho, $partes) !== 1) {
                continue;
            }
            if ($metodoRota !== $metodo) {
                $permitidos[] = $metodoRota;
                continue;
            }
            isset($partes[1]) ? $controller->$acao((int) $partes[1]) : $controller->$acao();
            return;
        }

        if ($permitidos) {
            header('Allow: ' . implode(', ', array_unique($permitidos)));
            $controller->metodoNaoPermitido();
            return;
        }
        $controller->naoEncontrado();
    }
}
