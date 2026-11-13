# App LarCerto — CRUD de imóveis

CRUD de imóveis para alugar da LarCerto em PHP 8.4 + MariaDB 12.3, sem framework. Usa MVC próprio
(back-end em `backend/`, telas em `frontend/`), CSS escrito à mão, slider próprio em JavaScript e várias
fotos por imóvel. Roda **independente da nuvem** num Docker Compose local (o "ambiente de desenvolvimento") e depois é
implantado na nuvem privada (que faz o papel do provedor) pelo Ansible, com o mesmo código e o
mesmo SQL.

Este README cobre o CRUD (Compose local e papéis Ansible `web`/`db`), o MVC com CSS e fotos, e o
`run.sh` (local e na VM). HTTPS e VMs: [`../docs/nuvem-larcerto.md`](../docs/nuvem-larcerto.md).

## Rodar local (sem a nuvem)

```bash
./run.sh setup        # dentro de app/ (ou: bash app/run.sh setup)
```

Esse comando faz tudo de uma vez:
- cria o `.env` com uma senha aleatória, se ele faltar (só vale no local);
- faz o build e sobe o banco e a app, esperando o banco ficar saudável;
- popula o banco com os 22 anúncios, se a tabela estiver vazia;
- mostra os endereços.

Rodar de novo não duplica nada.

| O quê | Onde |
|-------|------|
| App | `http://127.0.0.1:8088` |
| Banco (DBeaver) | `127.0.0.1:3307`, banco `larcerto`, usuário `larcerto`, senha do `.env` |

### Comandos do `run.sh`

O mesmo script serve no local e na VM `web` da nuvem. Ele descobre sozinho onde está: com o
`compose.yml` ao lado, usa o Docker Compose; sem ele, usa o Apache e o banco que o Ansible
instalou. `LARCERTO_MODE=local|server` força o modo.

| Comando | Local (Docker Compose) | Servidor (VM `web`) |
|---------|------------------------|---------------------|
| `setup` | `.env` → build e subida → semente se vazio → endereços | schema → semente se vazio → Apache ativo → endereço |
| `up [args]` | `docker build --network host` + `up -d --no-build --wait`; args só no local | `systemctl start apache2` |
| `down [args]` | para (mantém banco e fotos) | `systemctl stop apache2` |
| `restart` | `down` + `up` (não use `restart db` sozinho, ver abaixo) | `systemctl restart apache2` |
| `ps` | containers | Apache e resposta do banco na VM `db` |
| `logs [args]` | `logs -f web` mostra também os erros do PHP | `larcerto-error.log` do Apache, com os erros do PHP (`logs -f` acompanha) |
| `db:populate` | semente só com a tabela vazia | igual |
| `db:reset [--yes]` | apaga banco e fotos (`down -v`) e volta à semente; pede confirmação | `DROP TABLE` + schema + semente + apaga as fotos; pede confirmação |
| `db:console` | cliente `mariadb` no banco `larcerto` | cliente `mariadb` na VM `db` |
| `check [checks]` | `tests/app-checks.sh` | só no local |
| `phpstan [args]` | PHPStan nível 6 em `backend/` e `public/` (ver Testes) | só no local |
| `test:browser [args]` | sobe a app e roda os testes no navegador (Pest + Playwright) | só no local |
| `test` | `phpstan` e depois `test:browser` | só no local |
| `composer [args]` | Composer do projeto de testes (`tests/app/`) | só no local |
| `help` | lista os comandos | igual |

Na VM `web`, o Ansible copia o script e o `sql/` para `/var/www/larcerto/` e instala o
`mariadb-client` e o `php8.4-cli`. Ali o uso é com `sudo`, porque o `config.php` com a senha é `root:www-data 0640`:

```bash
ssh ubuntu@<ip da VM web>
sudo /var/www/larcerto/run.sh setup
sudo /var/www/larcerto/run.sh ps
```

A senha nunca vai para a linha de comando: no local, o cliente usa a senha do próprio container;
na VM, ela é lida do `config.php` e passada por `MYSQL_PWD`.

Sem o `run.sh`: `docker build --network host -t larcerto-web app` e depois
`docker compose -f app/compose.yml up -d --no-build --wait` (com o `.env` criado a partir do
`.env.example`). O `up --build` do Compose v5 passa pelo bake, que recusa o `build.network: host`
sem `--allow=network.host` (opção que o `compose up` não tem). Para apagar tudo e as imagens, use
`docker compose -f app/compose.yml down -v --rmi local` e depois
`docker image rm mariadb:12.3 php:8.4-apache php:8.4-cli larcerto-tests`.

As portas 8080 e 3306 do host já são do Kolla (Horizon e MariaDB do OpenStack), por isso a app usa
8088 e 3307. Só `127.0.0.1` é publicado.

O Docker deste host roda sem bridge padrão, sem `ip-forward` e sem iptables, e o UFW bloqueia o
FORWARD. Por isso:
- o `web` usa a rede do `db` (`network_mode: service:db`): os dois se falam por `127.0.0.1` e as
  duas portas ficam publicadas no `db`. Para reiniciar, use `up -d` ou `down` + `up`; não use
  `restart db` sozinho, senão o `web` fica preso na rede antiga do `db`;
- o build usa a rede do host (`build.network: host`) só para baixar as bibliotecas da GD.

O código em `public/`, `backend/` e `frontend/views/` é montado no container: editou, recarregou o
navegador. O SQL de `sql/` roda sozinho só na primeira subida do volume. Para voltar à semente, use
`./run.sh db:reset`.

Provas do ambiente local: `bash tests/app-checks.sh` (sobe o Compose e apaga os dados locais;
o que cada prova confere está nos comentários do script).

## CSS e JavaScript (sem framework)

- `public/assets/app.css` é CSS puro, escrito à mão e servido como está: não há build nem binário para
  baixar. As cores e fontes do LarCerto ficam como variáveis em `:root` (`--brand`, `--accent`...).
- As views usam classes por componente (`.card`, `.campo`, `.btn-primary`, `.slider-proxima`...);
  toda classe usada nas views e nos scripts tem regra no `app.css`. Pontos de quebra: 640 px e 1024 px.
- `public/assets/js/fotos.js` (prévia e redução das fotos no formulário) e
  `public/assets/js/slider.js` (slider da página do imóvel) são JavaScript próprio, sem dependência.

## Testes (PHPStan e navegador)

```bash
./run.sh test           # PHPStan e depois os testes no navegador; use antes de commitar
./run.sh phpstan        # só a análise estática
./run.sh test:browser   # só o navegador; aceita args do Pest, ex.: --filter=ciclo
```

As ferramentas ficam em [`../tests/app/`](../tests/app/), fora da app, para a app publicada continuar
sem `composer.json` nem `vendor/` (REQ07). Rodam na imagem `larcerto-tests` (PHP 8.4, Composer, Node e
o Chromium do Playwright, ~1,9 GB), gerada no primeiro uso; nada é instalado no host. Na primeira vez,
o `run.sh` também instala o `vendor/` e o `node_modules/` de `tests/app/` (fora do git).

- **PHPStan 2** (`tests/app/phpstan.neon`): nível 6 sobre `backend/` e `public/`, sem rede.
- **Pest 5 + `pest-plugin-browser`** (`tests/app/tests/Browser/`): o Chromium headless abre
  `http://127.0.0.1:8088` (ou `APP_URL`) e percorre listagem, filtro, validação, o ciclo
  anunciar com foto → editar → excluir e a página 404. Os testes só criam e apagam imóveis `E2E ...`,
  sem tocar na semente. Em falha, o screenshot fica em `tests/app/tests/Browser/Screenshots/`.

## Estrutura

```
app/
├── backend/           PHP sem HTML
│   ├── bootstrap.php     autoload (spl_autoload_register, namespace LarCerto\), sessão
│   ├── routes.php        as 7 rotas
│   ├── Core/             Router, Controller, View, Database (PDO), Csrf, Flash, helpers (e, preco)
│   ├── Controllers/      ImoveisController
│   ├── Models/           Imovel (validação e todo o SQL)
│   └── Services/         FotosImovel (pasta, capa), ValidadorImagem, ProcessadorImagem (GD)
├── frontend/          telas sem SQL
│   └── views/            layout.php, imoveis/ (index, mostrar, novo, editar, _form), erros/
├── public/            DocumentRoot: index.php (front controller) + assets/ (app.css, logo, js/fotos.js, js/slider.js)
├── apache/larcerto.conf   front controller e /uploads sem PHP (Compose e VM)
├── php/larcerto.ini       limites das fotos (Compose e VM)
├── sql/               01-schema.sql, 02-seed.sql (22 anúncios do MVP)
├── run.sh             setup, db:populate, db:reset... (local e VM web)
├── compose.yml, Dockerfile, .env.example, dev/config.php
└── (storage/uploads/  fotos: volume larcerto_uploads no Compose, disco da VM na nuvem)
```

Base: estrutura do [`SI-DABE/problem-track`](https://github.com/SI-DABE/problem-track) (front
controller → Router → Controller → Model → View), sem Composer, ActiveRecord, login nem nginx.

## Rotas

| Rota | Ação | Resposta |
|------|------|----------|
| `GET /` | listagem com filtros `max` (preço), `bairro`, `campus`, `tipo` | 200 |
| `GET /imoveis/novo` | formulário de anunciar | 200 |
| `POST /imoveis` | criar (com fotos) | 303 → `/imoveis/{id}`; 422 inválido; 413 envio grande demais; 403 sem token |
| `GET /imoveis/{id}` | detalhe com a capa e a galeria | 200; 404 |
| `GET /imoveis/{id}/editar` | formulário de editar (fotos, capa, remover) | 200; 404 |
| `POST /imoveis/{id}` | atualizar | 303; 422; 413; 403; 404 |
| `POST /imoveis/{id}/excluir` | excluir (apaga as fotos) | 303; 403; 404; `GET` dá 405 |

Toda URL que não é arquivo de `public/` cai no `public/index.php` (`FallbackResource`). Uma rota
desconhecida, um `{id}` que não é inteiro positivo ou um imóvel que não existe dá 404 com o logo.

## Fotos

- **Limites:** até **10 fotos** por imóvel, JPEG, PNG ou WebP, até **20 MB** e **40 MP** cada. O envio inteiro
  vai até 64 MB. Um envio com mais fotos do que cabem é recusado com mensagem (`max_file_uploads = 11`
  deixa a app ver a 11ª foto), e o formulário já avisa antes de enviar.
- **No navegador** (`public/assets/js/fotos.js`): foto com mais de 1920 px ou mais de 2 MB é reduzida
  antes do envio. Cada "Choose Files" **soma** fotos a uma lista (o mesmo arquivo não entra duas vezes;
  uma seleção que passe das vagas é recusada inteira, com aviso). O formulário mostra a **Capa** em
  destaque (o que aparece no card) e, abaixo, a **Galeria do anúncio** com "Usar como capa" e **Remover**
  em cada foto; trocar a capa move a foto na hora. Sem capa marcada, a primeira vira capa. O envio
  continua no "Salvar".
- **No servidor:** o `ValidadorImagem` confere o tipo pelo conteúdo, o tamanho e os megapixels, antes de
  decodificar a imagem. Depois o `ProcessadorImagem` (GD) faz quatro coisas:
  - aplica a orientação do EXIF;
  - reduz a foto para no máximo 1920 px;
  - gera a miniatura 640×480;
  - grava as duas em WebP (qualidade 82 e 75).

  O original e o EXIF (inclusive o GPS) não são guardados.
- **Onde ficam:** em `storage/uploads/<id>/<32 hex>.webp` + `<32 hex>_thumb.webp`, em ordem de envio. A
  tabela continua única: a coluna `capa` guarda o nome da principal. Se a capa for removida, a
  próxima vira capa. Sem foto, o card mostra o desenho do tipo.
- **Na página do imóvel** (`frontend/views/imoveis/mostrar.php` + `public/assets/js/slider.js`): todas as
  fotos num slider no lugar da foto grande, a capa primeiro. Com 2 ou mais fotos há setas, contador
  `1 / N`, teclado (←/→ com o foco no slider) e arraste com mouse ou dedo (mais de 50 px), sem voltar do
  último ao primeiro. Sem JavaScript as fotos ficam lado a lado com rolagem horizontal. A capa continua
  sendo a miniatura do card da listagem. O `slider.js` só é carregado na página de um imóvel com foto.
- **`slider.js`** é uma lib própria (menos de 100 linhas, sem dependência): procura os `[data-slider]` da
  página e expõe só `window.LarCertoSlider.iniciar(el)`. A marcação é `section.slider[data-slider]` >
  `ul.slider-trilho` > `li.slider-slide`, mais `button.slider-anterior`, `button.slider-proxima` e
  `.slider-contador`; o estilo fica no `app.css`.
- **Como são servidas:** pelo `Alias /uploads/` do Apache, sem PHP. Só os `.webp` com esse nome
  respondem; o resto da pasta dá 403.

## Na nuvem

`ansible-playbook site.yml` (em `ansible/`) faz o mesmo nas VMs:

| Peça | Local (Compose) | Nuvem (Ansible) |
|------|-----------------|-----------------|
| PHP | imagem `php:8.4-apache` + `pdo_mysql`, `gd`, `exif` | `php8.4`, `libapache2-mod-php8.4`, `php8.4-mysql`, `php8.4-gd` do PPA `ondrej/php` na VM `web` (chave do keyserver, fingerprint conferido) |
| MariaDB | imagem `mariadb:12.3` | `mariadb-server` 12.3 de `deb.mariadb.org` na VM `db` |
| Código | `public/`, `backend/`, `frontend/views/` montados em `/var/www/larcerto/` | copiados para `/var/www/larcerto/` |
| Apache e PHP | `apache/larcerto.conf` e `php/larcerto.ini` copiados no build | os mesmos arquivos em `conf-available/` e `99-larcerto.ini` |
| Fotos | volume `larcerto_uploads` | `/var/www/larcerto/storage/uploads` (`www-data`, 0750); recriar a VM apaga |
| Conexão | `dev/config.php` (lê o `.env`) | `config.php` gerado pelo Ansible (`secrets.yml`) |
| Tabela e semente | `sql/` em `/docker-entrypoint-initdb.d` | papel `db`: schema a cada apply, semente só com a tabela vazia |
| URL | `http://127.0.0.1:8088` | `https://larcerto.com.br` (HTTP redireciona para HTTPS) |

## Requisitos do enunciado

- REQ04: só CRUD, sem módulos extras · REQ05: **uma tabela**, 10 campos
- REQ06: PHP · REQ07: sem framework (nem de PHP, nem de CSS, nem de JavaScript)
- REQ08: MariaDB
- REQ02: logo e nome LarCerto em todas as páginas (`frontend/views/layout.php`)

## Tabela `imoveis` (10 campos)

```sql
CREATE TABLE imoveis (
  id              INT AUTO_INCREMENT PRIMARY KEY,
  titulo          VARCHAR(120) NOT NULL,
  tipo            ENUM('kitnet','apartamento','casa','quarto','republica') NOT NULL,
  preco           DECIMAL(8,2) NOT NULL,
  bairro          VARCHAR(60)  NOT NULL,
  campus          ENUM('UTFPR','Unicentro','Qualquer campus') NOT NULL,
  verificado      BOOLEAN NOT NULL DEFAULT 0,
  anunciante_nome VARCHAR(80)  NOT NULL,
  anunciante_tipo ENUM('locador','imobiliaria') NOT NULL,
  capa            CHAR(32) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Um banco de uma versão anterior da app (sem fotos) ganha a coluna `capa` pelo
`ALTER TABLE ... ADD COLUMN IF NOT EXISTS` do `01-schema.sql`, sem perder linhas.

Semente: os 22 anúncios do MVP da LarCerto (protótipo em HTML/CSS/JS com `localStorage`), sem `cep`,
`meta` e `thumbClass`, todos verificados como no MVP e sem fotos.

## Fora de escopo (ferem REQ04/REQ05)

Tabelas `usuarios`, `interesses` e `imovel_fotos`, papéis e login, painel de verificação, legenda
por foto, seguro-fiança.

## Decisões em aberto (aluno)

- Filtros contam como "R" do CRUD ou como módulo extra? Consultar o professor. Se forem vetados,
  saem de `Imovel::listar()` e do formulário de `frontend/views/imoveis/index.php`.
- Fotos em pasta + coluna `capa` (REQ05): confirmar com o professor.
