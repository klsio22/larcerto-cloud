<?php
declare(strict_types=1);

namespace LarCerto\Core;

final class Flash
{
    public static function definir(string $aviso): void
    {
        $_SESSION['aviso'] = $aviso;
    }

    public static function pegar(): ?string
    {
        $aviso = $_SESSION['aviso'] ?? null;
        unset($_SESSION['aviso']);
        return $aviso;
    }
}
