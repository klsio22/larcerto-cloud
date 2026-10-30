# App LarCerto — CRUD de imóveis (S5, **pendente**)

> **Status:** ainda não implementado, por decisão do aluno. Enquanto `public/index.php` não
> existir, o Ansible publica na VM `web` uma página provisória com o logo e o teste de conexão
> com o banco ([`../ansible/roles/web/templates/placeholder.php.j2`](../ansible/roles/web/templates/placeholder.php.j2)).
> Quando a app for criada aqui em `public/`, o mesmo `ansible-playbook site.yml` passa a
> publicá-la, sem outra mudança.

Especificação aprovada no plano ([`../../.specs/trabalho-1/plano.md`](../../.specs/trabalho-1/plano.md), fatia S5, critérios 20–28).

## Onde roda

| Peça | Onde |
|------|------|
| Código PHP | `project/app/public/` → copiado para `/var/www/larcerto/public/` na VM `web` |
| Conexão com o banco | `/var/www/larcerto/config.php` (gerado pelo Ansible; `require __DIR__ . '/../config.php'`) |
| Banco | MariaDB na VM `db` (`db.larcerto.com.br`, 10.11.12.12), banco `larcerto`, usuário `larcerto` |
| URL | `https://larcerto.com.br` (HTTP redireciona para HTTPS) |

## Requisitos do enunciado

- REQ04: só CRUD, sem módulos extras · REQ05: **uma tabela**, 3–10 campos
- REQ06: PHP · REQ07: sem framework (só com consulta ao professor) · REQ08: MariaDB
- REQ02: logo em todas as páginas (`assets/logo.svg`; trocar pelo logo do MVP se houver)

## Tabela `imoveis` (9 campos)

```sql
CREATE TABLE imoveis (
  id              INT AUTO_INCREMENT PRIMARY KEY,
  titulo          VARCHAR(120) NOT NULL,
  tipo            ENUM('kitnet','apartamento','casa','quarto','republica') NOT NULL,
  preco           DECIMAL(8,2) NOT NULL,
  bairro          VARCHAR(60)  NOT NULL,
  campus          ENUM('UTFPR','Unicentro Santa Cruz','Unicentro Cedeteg') NOT NULL,
  verificado      BOOLEAN NOT NULL DEFAULT 0,
  anunciante_nome VARCHAR(80)  NOT NULL,
  anunciante_tipo ENUM('locador','imobiliaria') NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Do MVP (`store.js`) saem `cep`, `meta` e `thumbClass` (a imagem do card vem do `tipo`).
Seed: os ~22 anúncios do MVP. **Falta o caminho do outro projeto** (`activities/04-mvp/demo/`).

## Telas

| Tela | Função |
|------|--------|
| `index.php` | listagem com filtros `preco` máx., `bairro`, `campus`, `tipo` |
| `imovel.php?id=` | detalhe, selo "Verificado" |
| `anunciar.php` | criar |
| `editar.php?id=` | editar |
| `excluir.php` | excluir (POST + token CSRF) |

Regras: PDO com prepared statements, `htmlspecialchars` em toda saída, validação de
`titulo` não vazio, `preco` > 0 e enums válidos.

## Fora de escopo (ferem REQ04/REQ05)

Tabelas `usuarios` e `interesses`, papéis e login, painel de verificação, upload de fotos,
seguro-fiança.

## Decisões em aberto (aluno)

- Filtros contam como "R" do CRUD ou como módulo extra? Consultar o professor.
- Caminho do MVP para reaproveitar seed, CSS e logo.
