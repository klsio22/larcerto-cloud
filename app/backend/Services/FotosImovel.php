<?php
declare(strict_types=1);

namespace LarCerto\Services;

// Photos are files in storage/uploads/<id>/ (no extra table): <32 hex>.webp + _thumb.webp.
// Names start with the upload time, so alphabetical order is upload order.
// New photos are processed in a temp dir and moved in only after the database write.
final class FotosImovel
{
    public const MAX_FOTOS = 10;
    private const NOME = '/^[0-9a-f]{32}$/';

    private string $raiz;

    public function __construct(
        private ValidadorImagem $validador = new ValidadorImagem(),
        private ProcessadorImagem $processador = new ProcessadorImagem(),
    ) {
        $this->raiz = RAIZ . '/storage/uploads';
    }

    public static function recebidas(array $campo): array
    {
        $lista = [];
        foreach ((array) ($campo['error'] ?? []) as $i => $erro) {
            if ((int) $erro === UPLOAD_ERR_NO_FILE) {
                continue;
            }
            $lista[] = [
                'tmp_name' => (string) ($campo['tmp_name'][$i] ?? ''),
                'size'     => (int) ($campo['size'][$i] ?? 0),
                'error'    => (int) $erro,
                'name'     => (string) ($campo['name'][$i] ?? 'foto'),
            ];
        }
        return $lista;
    }

    public function erro(array $recebidas, int $jaNoImovel): ?string
    {
        if ($jaNoImovel + count($recebidas) > self::MAX_FOTOS) {
            return 'Cada imóvel pode ter até ' . self::MAX_FOTOS . ' fotos.';
        }
        foreach ($recebidas as $arquivo) {
            if (($erro = $this->validador->erro($arquivo)) !== null) {
                return $erro;
            }
        }
        return null;
    }

    public function preparar(array $recebidas): array
    {
        if (!$recebidas) {
            return [null, []];
        }
        $temp = $this->raiz . '/.tmp-' . bin2hex(random_bytes(8));
        if (!is_dir($temp) && !mkdir($temp, 0750, true)) {
            throw new \RuntimeException('Não foi possível gravar as fotos.');
        }
        // Also cleans up after a fatal error; a no-op once confirmar() has moved the files.
        register_shutdown_function(fn () => $this->descartar($temp));
        $nomes = [];
        $inicio = (int) (microtime(true) * 1_000_000);
        try {
            foreach ($recebidas as $i => $arquivo) {
                $nome = sprintf('%014x', $inicio + $i) . bin2hex(random_bytes(9));
                $this->processador->processar($arquivo['tmp_name'], $temp . '/' . $nome);
                $nomes[] = $nome;
            }
        } catch (\Throwable $falha) {
            $this->descartar($temp);
            throw $falha;
        }
        return [$temp, $nomes];
    }

    public function confirmar(?string $temp, int $id): void
    {
        if ($temp === null) {
            return;
        }
        $pasta = $this->pasta($id);
        if (!is_dir($pasta) && !mkdir($pasta, 0750, true)) {
            throw new \RuntimeException('Não foi possível gravar as fotos.');
        }
        foreach (glob($temp . '/*.webp') ?: [] as $arquivo) {
            if (!rename($arquivo, $pasta . '/' . basename($arquivo))) {
                throw new \RuntimeException('Não foi possível gravar as fotos.');
            }
        }
        rmdir($temp);
    }

    public function descartar(?string $temp): void
    {
        if ($temp !== null && is_dir($temp)) {
            array_map('unlink', glob($temp . '/*') ?: []);
            rmdir($temp);
        }
    }

    public function listar(int $id): array
    {
        $nomes = [];
        foreach (glob($this->pasta($id) . '/*.webp') ?: [] as $arquivo) {
            $nome = basename($arquivo, '.webp');
            if (preg_match(self::NOME, $nome) === 1) {
                $nomes[] = $nome;
            }
        }
        sort($nomes);
        return $nomes;
    }

    public function remover(int $id, array $nomes): void
    {
        foreach ($nomes as $nome) {
            if (preg_match(self::NOME, $nome) === 1) {
                foreach ([$nome . '.webp', $nome . '_thumb.webp'] as $arquivo) {
                    if (is_file($this->pasta($id) . '/' . $arquivo)) {
                        unlink($this->pasta($id) . '/' . $arquivo);
                    }
                }
            }
        }
    }

    public function removerTudo(int $id): void
    {
        $pasta = $this->pasta($id);
        if (is_dir($pasta)) {
            array_map('unlink', glob($pasta . '/*') ?: []);
            rmdir($pasta);
        }
    }

    public function existe(int $id, ?string $nome): bool
    {
        return $nome !== null && preg_match(self::NOME, $nome) === 1 && is_file($this->pasta($id) . '/' . $nome . '_thumb.webp');
    }

    public static function url(int $id, string $nome, bool $mini = false): string
    {
        return '/uploads/' . $id . '/' . $nome . ($mini ? '_thumb' : '') . '.webp';
    }

    // $pedida comes from the "capa" radio: "h:<name>" (existing photo) or "n:<i>" (i-th new photo).
    // Falls back to the current cover, then to the first photo.
    public static function capa(array $todas, array $novas, mixed $pedida, ?string $atual): ?string
    {
        $pedida = is_string($pedida) ? $pedida : '';
        $escolhida = match (true) {
            str_starts_with($pedida, 'h:') => substr($pedida, 2),
            str_starts_with($pedida, 'n:') && ctype_digit(substr($pedida, 2)) => $novas[(int) substr($pedida, 2)] ?? null,
            default => null,
        };
        foreach ([$escolhida, $atual] as $candidata) {
            if ($candidata !== null && in_array($candidata, $todas, true)) {
                return $candidata;
            }
        }
        return $todas[0] ?? null;
    }

    private function pasta(int $id): string
    {
        return $this->raiz . '/' . $id;
    }
}
