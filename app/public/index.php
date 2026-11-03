<?php
declare(strict_types=1);

require __DIR__ . '/../backend/bootstrap.php';

(new LarCerto\Core\Router(require __DIR__ . '/../backend/routes.php'))
    ->despachar($_SERVER['REQUEST_METHOD'], $_SERVER['REQUEST_URI']);
