<?php
declare(strict_types=1);

namespace LarCerto\Core;

abstract class Controller
{
    protected function render(string $view, array $dados = [], int $status = 200): void
    {
        http_response_code($status);
        View::render($view, $dados);
    }

    protected function redirecionar(string $url, ?string $aviso = null): never
    {
        if ($aviso !== null) {
            Flash::definir($aviso);
        }
        header('Location: ' . $url, true, 303);
        exit;
    }

    protected function exigirCsrf(): void
    {
        if (!Csrf::valido($_POST['csrf'] ?? null)) {
            $this->render('erros/403', ['titulo' => 'Formulário expirado'], 403);
            exit;
        }
    }

    public function naoEncontrado(): void
    {
        $this->render('erros/404', ['titulo' => 'Página não encontrada'], 404);
    }

    public function metodoNaoPermitido(): void
    {
        $this->render('erros/405', ['titulo' => 'Ação não permitida'], 405);
    }
}
