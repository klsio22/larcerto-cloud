<?php
declare(strict_types=1);

namespace LarCerto\Controllers;

use LarCerto\Core\Controller;
use LarCerto\Models\Imovel;
use LarCerto\Services\FotosImovel;

final class ImoveisController extends Controller
{
    private const POST_GRANDE = 'Envie menos fotos por vez: o envio passou de 64 MB. Salve e adicione o resto pela edição.';

    private FotosImovel $fotos;

    public function __construct()
    {
        $this->fotos = new FotosImovel();
    }

    public function index(): void
    {
        $filtros = [
            'max'    => trim((string) ($_GET['max'] ?? '')),
            'bairro' => trim((string) ($_GET['bairro'] ?? '')),
            'campus' => (string) ($_GET['campus'] ?? ''),
            'tipo'   => (string) ($_GET['tipo'] ?? ''),
        ];
        $imoveis = array_map(fn (array $i): array => $i + ['foto' => $this->capaUrl($i)], Imovel::listar($filtros));
        $this->render('imoveis/index', [
            'titulo'    => 'Imóveis verificados',
            'ativo'     => 'imoveis',
            'imoveis'   => $imoveis,
            'filtros'   => $filtros,
            'bairros'   => Imovel::bairros(),
            'filtrando' => is_numeric($filtros['max']) || $filtros['bairro'] !== ''
                || isset(Imovel::CAMPI[$filtros['campus']]) || isset(Imovel::TIPOS[$filtros['tipo']]),
        ]);
    }

    public function mostrar(int $id): void
    {
        $imovel = Imovel::buscar($id);
        if ($imovel === null) {
            $this->naoEncontrado();
            return;
        }
        $nomes = $this->fotos->listar($id);
        $capa = in_array($imovel['capa'], $nomes, true) ? $imovel['capa'] : null;
        $url = fn (string $n): string => FotosImovel::url($id, $n);
        $this->render('imoveis/mostrar', [
            'titulo'  => $imovel['titulo'],
            'ativo'   => 'imoveis',
            'imovel'  => $imovel,
            'capa'    => $capa === null ? null : $url($capa),
            'galeria' => array_map($url, array_values(array_diff($nomes, [$capa]))),
        ]);
    }

    public function novo(): void
    {
        $this->formulario(Imovel::VAZIO, [], null);
    }

    public function criar(): void
    {
        if ($this->postGrandeDemais()) {
            $this->formulario(Imovel::VAZIO, ['fotos' => self::POST_GRANDE], null, 413);
            return;
        }
        $this->exigirCsrf();
        [$dados, $erros] = Imovel::validar($_POST);
        $recebidas = FotosImovel::recebidas($_FILES['fotos'] ?? []);
        if (($erro = $this->fotos->erro($recebidas, 0)) !== null) {
            $erros['fotos'] = $erro;
        }
        if ($erros) {
            $this->formulario($dados + Imovel::VAZIO, $erros, null, 422);
            return;
        }

        try {
            [$temp, $novas] = $this->fotos->preparar($recebidas);
        } catch (\RuntimeException $falha) {
            $this->formulario($dados + Imovel::VAZIO, ['fotos' => $falha->getMessage()], null, 422);
            return;
        }
        $id = Imovel::criar($dados, FotosImovel::capa($novas, $novas, $_POST['capa'] ?? null, null));
        $this->fotos->confirmar($temp, $id);
        $this->redirecionar('/imoveis/' . $id, 'Anúncio criado.');
    }

    public function editar(int $id): void
    {
        $imovel = Imovel::buscar($id);
        if ($imovel === null) {
            $this->naoEncontrado();
            return;
        }
        $this->formulario($imovel, [], $id);
    }

    public function atualizar(int $id): void
    {
        $imovel = Imovel::buscar($id);
        if ($imovel === null) {
            $this->naoEncontrado();
            return;
        }
        if ($this->postGrandeDemais()) {
            $this->formulario($imovel, ['fotos' => self::POST_GRANDE], $id, 413);
            return;
        }
        $this->exigirCsrf();
        [$dados, $erros] = Imovel::validar($_POST);
        $existentes = $this->fotos->listar($id);
        $remover = array_values(array_intersect($existentes, array_filter((array) ($_POST['remover'] ?? []), 'is_string')));
        $ficam = array_values(array_diff($existentes, $remover));
        $recebidas = FotosImovel::recebidas($_FILES['fotos'] ?? []);
        if (($erro = $this->fotos->erro($recebidas, count($ficam))) !== null) {
            $erros['fotos'] = $erro;
        }
        if ($erros) {
            $this->formulario(['id' => $id, 'capa' => $imovel['capa']] + $dados, $erros, $id, 422);
            return;
        }

        try {
            [$temp, $novas] = $this->fotos->preparar($recebidas);
        } catch (\RuntimeException $falha) {
            $this->formulario(['id' => $id, 'capa' => $imovel['capa']] + $dados, ['fotos' => $falha->getMessage()], $id, 422);
            return;
        }
        $capa = FotosImovel::capa(array_merge($ficam, $novas), $novas, $_POST['capa'] ?? null, $imovel['capa']);
        Imovel::atualizar($id, $dados, $capa);
        $this->fotos->remover($id, $remover);
        $this->fotos->confirmar($temp, $id);
        $this->redirecionar('/imoveis/' . $id, 'Anúncio atualizado.');
    }

    public function excluir(int $id): void
    {
        $this->exigirCsrf();
        if (!Imovel::excluir($id)) {
            $this->naoEncontrado();
            return;
        }
        $this->fotos->removerTudo($id);
        $this->redirecionar('/', 'Anúncio excluído.');
    }

    private function formulario(array $dados, array $erros, ?int $id, int $status = 200): void
    {
        $fotos = [];
        if ($id !== null) {
            foreach ($this->fotos->listar($id) as $nome) {
                $fotos[] = ['nome' => $nome, 'url' => FotosImovel::url($id, $nome, true), 'capa' => $nome === $dados['capa']];
            }
        }
        $this->render('imoveis/' . ($id === null ? 'novo' : 'editar'), [
            'titulo'   => $id === null ? 'Anunciar imóvel' : 'Editar anúncio',
            'ativo'    => $id === null ? 'anunciar' : 'imoveis',
            'id'       => $id,
            'dados'    => $dados,
            'erros'    => $erros,
            'fotos'    => $fotos,
            'maxFotos' => FotosImovel::MAX_FOTOS,
            'cabem'    => FotosImovel::MAX_FOTOS - count($fotos),
        ], $status);
    }

    private function capaUrl(array $imovel): ?string
    {
        $id = (int) $imovel['id'];
        return $this->fotos->existe($id, $imovel['capa']) ? FotosImovel::url($id, $imovel['capa'], true) : null;
    }

    // Above post_max_size PHP drops $_POST and $_FILES entirely, CSRF token included.
    private function postGrandeDemais(): bool
    {
        $limite = (string) ini_get('post_max_size');
        $bytes = (int) $limite * match (strtoupper(substr($limite, -1))) {
            'G' => 1024 ** 3,
            'M' => 1024 ** 2,
            'K' => 1024,
            default => 1,
        };
        return $bytes > 0 && (int) ($_SERVER['CONTENT_LENGTH'] ?? 0) > $bytes;
    }
}
