<?php
declare(strict_types=1);

namespace LarCerto\Services;

// Checks a photo without decoding it, before GD spends memory on it.
final class ValidadorImagem
{
    public const MAX_BYTES = 20 * 1024 * 1024;   // = upload_max_filesize in php/larcerto.ini
    public const MAX_PIXELS = 40_000_000;
    public const TIPOS = ['image/jpeg' => IMAGETYPE_JPEG, 'image/png' => IMAGETYPE_PNG, 'image/webp' => IMAGETYPE_WEBP];

    public function erro(array $arquivo): ?string
    {
        $nome = basename($arquivo['name']);
        return match (true) {
            in_array($arquivo['error'], [UPLOAD_ERR_INI_SIZE, UPLOAD_ERR_FORM_SIZE], true),
            $arquivo['size'] > self::MAX_BYTES   => "\"{$nome}\" passa de 20 MB.",
            $arquivo['error'] !== UPLOAD_ERR_OK  => "\"{$nome}\" não chegou inteira. Envie de novo.",
            !$this->tipoOk($arquivo['tmp_name']) => "\"{$nome}\" não é uma foto JPEG, PNG ou WebP.",
            $this->pixels($arquivo['tmp_name']) > self::MAX_PIXELS => "\"{$nome}\" passa de 40 megapixels.",
            default => null,
        };
    }

    private function tipoOk(string $tmp): bool
    {
        $mime = (new \finfo(FILEINFO_MIME_TYPE))->file($tmp);
        $info = @getimagesize($tmp);
        return isset(self::TIPOS[$mime]) && $info !== false && $info[2] === self::TIPOS[$mime]
            && $info[0] > 0 && $info[1] > 0;
    }

    private function pixels(string $tmp): int
    {
        $info = getimagesize($tmp);
        return $info[0] * $info[1];
    }
}
