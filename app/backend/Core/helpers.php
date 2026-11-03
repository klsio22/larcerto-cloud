<?php
declare(strict_types=1);
// Global on purpose, so templates can call e() and preco() directly.

// Every value printed in a view goes through e() (XSS).
function e(mixed $valor): string
{
    return htmlspecialchars((string) $valor, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function preco(string|float $valor): string
{
    return 'R$ ' . number_format((float) $valor, 2, ',', '.');
}
