<?php
declare(strict_types=1);

namespace LarCerto\Core;

final class Csrf
{
    public static function token(): string
    {
        return $_SESSION['csrf'] ??= bin2hex(random_bytes(32));
    }

    public static function valido(mixed $token): bool
    {
        return is_string($token) && hash_equals(self::token(), $token);
    }
}
