<?php
declare(strict_types=1);

const RAIZ = __DIR__ . '/..';

spl_autoload_register(static function (string $classe): void {
    $prefixo = 'LarCerto\\';
    if (str_starts_with($classe, $prefixo)) {
        $arquivo = __DIR__ . '/' . str_replace('\\', '/', substr($classe, strlen($prefixo))) . '.php';
        if (is_file($arquivo)) {
            require $arquivo;
        }
    }
});

require __DIR__ . '/Core/helpers.php';

session_start(['cookie_httponly' => true, 'cookie_samesite' => 'Lax']);
