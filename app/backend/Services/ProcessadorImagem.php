<?php
declare(strict_types=1);

namespace LarCerto\Services;

// Re-encoding drops all EXIF (GPS included) and anything hidden in the original file.
final class ProcessadorImagem
{
    public const LADO_MAX = 1920;
    public const MINI_L = 640;
    public const MINI_A = 480;
    public const QUALIDADE = 82;
    public const QUALIDADE_MINI = 75;

    public function processar(string $tmp, string $destino): void
    {
        $tipo = getimagesize($tmp)[2];
        $img = match ($tipo) {
            IMAGETYPE_JPEG => imagecreatefromjpeg($tmp),
            IMAGETYPE_PNG  => imagecreatefrompng($tmp),
            IMAGETYPE_WEBP => imagecreatefromwebp($tmp),
            default        => false,
        };
        if (!$img instanceof \GdImage) {
            throw new \RuntimeException('Não foi possível ler a foto.');
        }
        // Downscale before rotating and free the original: a 40 MP photo takes ~160 MB in GD,
        // and rotating it would need a second copy (over the 256M memory_limit).
        [$l, $a] = [imagesx($img), imagesy($img)];
        $fator = min(1, self::LADO_MAX / max($l, $a));   // never upscale
        $grande = $this->copiar($img, 0, 0, $l, $a, (int) round($l * $fator), (int) round($a * $fator));
        unset($img);
        if ($tipo === IMAGETYPE_JPEG) {
            $grande = $this->orientar($grande, $tmp);
        }
        [$l, $a] = [imagesx($grande), imagesy($grande)];

        // Thumbnail: largest centered 4:3 crop, then 640x480.
        $escala = min($l / self::MINI_L, $a / self::MINI_A);
        [$rl, $ra] = [(int) floor(self::MINI_L * $escala), (int) floor(self::MINI_A * $escala)];
        $mini = $this->copiar($grande, intdiv($l - $rl, 2), intdiv($a - $ra, 2), $rl, $ra, self::MINI_L, self::MINI_A);

        if (!imagewebp($grande, $destino . '.webp', self::QUALIDADE)
            || !imagewebp($mini, $destino . '_thumb.webp', self::QUALIDADE_MINI)) {
            throw new \RuntimeException('Não foi possível gravar a foto.');
        }
    }

    // Phones store photos sideways and set the EXIF orientation, which GD ignores.
    private function orientar(\GdImage $img, string $tmp): \GdImage
    {
        $orientacao = (int) ((@exif_read_data($tmp) ?: [])['Orientation'] ?? 1);
        // imagerotate is counter-clockwise: 270 = 90 degrees clockwise.
        $angulo = match ($orientacao) {
            3       => 180,
            5, 6    => 270,
            7, 8    => 90,
            default => 0,
        };
        if ($angulo !== 0) {
            $img = imagerotate($img, $angulo, 0);
        }
        // 2 and 4 only flip; 5 and 7 rotate, then flip.
        if (in_array($orientacao, [2, 4, 5, 7], true)) {
            imageflip($img, $orientacao === 4 ? IMG_FLIP_VERTICAL : IMG_FLIP_HORIZONTAL);
        }
        return $img;
    }

    private function copiar(\GdImage $img, int $x, int $y, int $l, int $a, int $novoL, int $novoA): \GdImage
    {
        $nova = imagecreatetruecolor($novoL, $novoA);
        imagealphablending($nova, false);
        imagesavealpha($nova, true);   // keep PNG/WebP transparency
        imagecopyresampled($nova, $img, 0, 0, $x, $y, $novoL, $novoA, $l, $a);
        return $nova;
    }
}
