<?php
declare(strict_types=1);

namespace LarCerto\Models;

use LarCerto\Core\Database;

final class Imovel
{
    public const TIPOS = [
        'kitnet'      => 'Kitnet / studio',
        'apartamento' => 'Apartamento',
        'casa'        => 'Casa',
        'quarto'      => 'Quarto',
        'republica'   => 'República / compartilhado',
    ];

    public const CAMPI = [
        'UTFPR'           => 'UTFPR — Guarapuava',
        'Unicentro'       => 'Unicentro — Guarapuava',
        'Qualquer campus' => 'Qualquer campus',
    ];

    public const ANUNCIANTES = [
        'locador'     => 'Proprietário',
        'imobiliaria' => 'Imobiliária',
    ];

    // Suggestions only: the form accepts any neighbourhood.
    public const BAIRROS = [
        'Alto Cascavel', 'Alto da XV', 'Batel', 'Bonsucesso', 'Boqueirão', 'Cascavel', 'Centro',
        'Conradinho', 'Dos Estados', 'Industrial', 'Industrial Xarquinho', 'Jardim das Américas',
        'Morro Alto', 'Núcleo Habitacional 2000', 'Primavera', 'Santa Cruz', 'Santana',
        'São Cristóvão', 'Trianon', 'Vila Bela', 'Vila Carli', 'Vila Jordão',
    ];

    public const PRECO_MAX = 999999.99; // DECIMAL(8,2)

    public const VAZIO = [
        'titulo' => '', 'tipo' => 'kitnet', 'preco' => '', 'bairro' => '', 'campus' => 'UTFPR',
        'verificado' => 0, 'anunciante_nome' => '', 'anunciante_tipo' => 'locador', 'capa' => null,
    ];

    public static function thumbClass(string $tipo): string
    {
        return match ($tipo) {
            'apartamento'    => 't3',
            'republica'      => 't4',
            'casa', 'quarto' => 't2',
            default          => '',
        };
    }

    public static function anuncianteTexto(array $imovel): string
    {
        return (self::ANUNCIANTES[$imovel['anunciante_tipo']] ?? 'Anunciante') . ' · ' . $imovel['anunciante_nome'];
    }

    public static function validar(array $in): array
    {
        $dados = [
            'titulo'          => trim((string) ($in['titulo'] ?? '')),
            'tipo'            => (string) ($in['tipo'] ?? ''),
            'preco'           => str_replace(',', '.', trim((string) ($in['preco'] ?? ''))),
            'bairro'          => trim((string) ($in['bairro'] ?? '')),
            'campus'          => (string) ($in['campus'] ?? ''),
            'verificado'      => empty($in['verificado']) ? 0 : 1,
            'anunciante_nome' => trim((string) ($in['anunciante_nome'] ?? '')),
            'anunciante_tipo' => (string) ($in['anunciante_tipo'] ?? ''),
        ];
        $erros = [];

        if (!self::tamanhoOk($dados['titulo'], 120)) {
            $erros['titulo'] = 'Informe o título (até 120 caracteres).';
        }
        if (!isset(self::TIPOS[$dados['tipo']])) {
            $erros['tipo'] = 'Escolha um tipo da lista.';
        }
        // Round like DECIMAL(8,2), otherwise 0.001 would be stored as 0.00.
        $preco = is_numeric($dados['preco']) ? round((float) $dados['preco'], 2) : 0.0;
        if ($preco <= 0 || $preco > self::PRECO_MAX) {
            $erros['preco'] = 'Informe um aluguel maior que zero.';
        } else {
            $dados['preco'] = number_format($preco, 2, '.', '');
        }
        if (!self::tamanhoOk($dados['bairro'], 60)) {
            $erros['bairro'] = 'Informe o bairro (até 60 caracteres).';
        }
        if (!isset(self::CAMPI[$dados['campus']])) {
            $erros['campus'] = 'Escolha um campus da lista.';
        }
        if (!self::tamanhoOk($dados['anunciante_nome'], 80)) {
            $erros['anunciante_nome'] = 'Informe o nome do anunciante (até 80 caracteres).';
        }
        if (!isset(self::ANUNCIANTES[$dados['anunciante_tipo']])) {
            $erros['anunciante_tipo'] = 'Escolha proprietário ou imobiliária.';
        }

        return [$dados, $erros];
    }

    // 1..$max UTF-8 characters without mbstring, which the VM does not install.
    private static function tamanhoOk(string $texto, int $max): bool
    {
        return preg_match('/^.{1,' . $max . '}$/us', $texto) === 1;
    }

    public static function listar(array $filtros): array
    {
        $where = [];
        $params = [];
        if (is_numeric($filtros['max'])) {
            $where[] = 'preco <= ?';
            $params[] = $filtros['max'];
        }
        if ($filtros['bairro'] !== '') {
            $where[] = 'bairro = ?';
            $params[] = $filtros['bairro'];
        }
        // Listings open to any campus match every campus filter.
        if (isset(self::CAMPI[$filtros['campus']]) && $filtros['campus'] !== 'Qualquer campus') {
            $where[] = "(campus = ? OR campus = 'Qualquer campus')";
            $params[] = $filtros['campus'];
        }
        if (isset(self::TIPOS[$filtros['tipo']])) {
            $where[] = 'tipo = ?';
            $params[] = $filtros['tipo'];
        }

        $sql = 'SELECT * FROM imoveis' . ($where ? ' WHERE ' . implode(' AND ', $where) : '') . ' ORDER BY id DESC';
        $stmt = Database::pdo()->prepare($sql);
        $stmt->execute($params);
        return $stmt->fetchAll();
    }

    public static function bairros(): array
    {
        return Database::pdo()->query('SELECT DISTINCT bairro FROM imoveis ORDER BY bairro')->fetchAll(\PDO::FETCH_COLUMN);
    }

    public static function buscar(int $id): ?array
    {
        $stmt = Database::pdo()->prepare('SELECT * FROM imoveis WHERE id = ?');
        $stmt->execute([$id]);
        return $stmt->fetch() ?: null;
    }

    public static function criar(array $dados, ?string $capa): int
    {
        $stmt = Database::pdo()->prepare(
            'INSERT INTO imoveis (titulo, tipo, preco, bairro, campus, verificado, anunciante_nome, anunciante_tipo, capa)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
        );
        $stmt->execute([
            $dados['titulo'], $dados['tipo'], $dados['preco'], $dados['bairro'], $dados['campus'],
            $dados['verificado'], $dados['anunciante_nome'], $dados['anunciante_tipo'], $capa,
        ]);
        return (int) Database::pdo()->lastInsertId();
    }

    public static function atualizar(int $id, array $dados, ?string $capa): void
    {
        $stmt = Database::pdo()->prepare(
            'UPDATE imoveis SET titulo = ?, tipo = ?, preco = ?, bairro = ?, campus = ?, verificado = ?,
             anunciante_nome = ?, anunciante_tipo = ?, capa = ? WHERE id = ?'
        );
        $stmt->execute([
            $dados['titulo'], $dados['tipo'], $dados['preco'], $dados['bairro'], $dados['campus'],
            $dados['verificado'], $dados['anunciante_nome'], $dados['anunciante_tipo'], $capa, $id,
        ]);
    }

    public static function excluir(int $id): bool
    {
        $stmt = Database::pdo()->prepare('DELETE FROM imoveis WHERE id = ?');
        $stmt->execute([$id]);
        return $stmt->rowCount() > 0;
    }
}
