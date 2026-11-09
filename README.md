# Projeto OpenStack — Computação em Nuvem (TSI36C-EAD)

Labs e entrega do **Trabalho 1** (nuvem privada + app web CRUD).

## Trabalho 1 — LarCerto

Passo a passo da nuvem do trabalho (rede externa, projeto, VMs, DNS, CA, HTTPS): [`docs/nuvem-larcerto.md`](docs/nuvem-larcerto.md). O CRUD (PHP 8.4 + MariaDB 12.3, MVC, CSS e JavaScript próprios, fotos dos imóveis) roda também sem a nuvem, num Docker Compose local (`bash app/run.sh setup`; o mesmo script serve na VM `web`): [`app/README.md`](app/README.md).

## Fontes

1. **Videoaulas 06–10** da disciplina (Computação em Nuvem); o mapa aula → passo está em [`notes/topologia-aio.md`](notes/topologia-aio.md)
2. **Enunciado** — [`docs/enunciado-trabalho-1.md`](docs/enunciado-trabalho-1.md) (REQ01–REQ24; substitutivo + REQ25)
3. **OpenStack com containers** — [`docs/kolla-ansible-quickstart.md`](docs/kolla-ansible-quickstart.md)
4. **Portas dos containers** — [`docs/ports.md`](docs/ports.md)
5. **Topologia AIO** — [`notes/topologia-aio.md`](notes/topologia-aio.md)

Não inventar passos além das aulas e do enunciado. Se faltar transcrição, avisar.

## Estrutura e para que serve cada ficheiro

```
project/
  README.md
  lab.sh
  all-in-one                 # inventário Ansible (usado pelo scripts/kolla/kolla.sh)
  scripts/                   # módulos do lab: common.sh, lab/ (rede, ovs, ciclo), kolla/ (kolla.sh, zorin_facts.py)
  tests/                     # test-scripts.sh (sem tocar no host), app-checks.sh (Compose local) e cloud-checks.sh (nuvem montada)
  cloud/bootstrap.sh         # admin: rede public, flavor, imagem, projeto larcerto, devops1
  terraform/                 # infra do projeto larcerto (4 VMs, redes, SGs, floating IPs)
  ansible/                   # configuração das VMs: dns, ca, db, web
  app/                       # CRUD LarCerto em MVC: backend/, frontend/, public/, sql/ + compose.yml (ambiente local)
  docs/                      # toda a documentação de apoio
    enunciado-trabalho-1.md
    kolla-ansible-quickstart.md
    ports.md
    lab.sh.md · kolla-config-scripts.md · horizon-theme-lux.md
  notes/
    topologia-aio.md
  kolla-config/
    globals.yml
    passwords.yml
    clouds.yaml              # gerado no post-deploy
    admin-openrc.sh          # gerado no post-deploy
    admin-openrc-system.sh   # gerado no post-deploy
    public-openrc.sh         # gerado no post-deploy
    public-openrc-system.sh  # gerado no post-deploy
```

| Ficheiro | Para que serve |
|----------|----------------|
| [`README.md`](README.md) | Guia do lab: como subir a nuvem, rede AIO, troubleshooting |
| [`docs/`](docs/README.md) | Documentação dos scripts: funções de `lab.sh` e dos módulos de `scripts/`, openrc/`clouds.yaml` |
| [`lab.sh`](lab.sh) | Entrypoint único: `prep`, `bootstrap`/`deploy`/`post-deploy`, `status`, `stop`, `start`, `fix-ovs`, `fix-wired`, `fix-horizon`, `test-ovs`, `install-app`, `start-app`, `recreate-app` |
| [`scripts/`](scripts/) | Módulos do lab, carregados pelo `lab.sh`. Os comandos Kolla estão em `scripts/kolla/kolla.sh` (inventário + `kolla-config`); tenta root via Docker se não houver sudo NOPASSWD |
| [`all-in-one`](all-in-one) | Inventário Ansible AIO: todos os papéis (control, network, compute…) em `localhost` |
| [`docs/enunciado-trabalho-1.md`](docs/enunciado-trabalho-1.md) | Requisitos do Trabalho 1 (REQ01–REQ24 + substitutivo REQ25) |
| [`docs/kolla-ansible-quickstart.md`](docs/kolla-ansible-quickstart.md) | Notas/referência do quickstart Kolla (contexto OpenStack em containers) |
| [`docs/ports.md`](docs/ports.md) | Mapa de portas VIP, containers Kolla e da app do trabalho |
| [`notes/topologia-aio.md`](notes/topologia-aio.md) | Topologia do lab (`enp9s0` + `dummy0` + VIP) e mapa aula → passo |
| [`kolla-config/globals.yml`](kolla-config/globals.yml) | Config Kolla: distro, interfaces, VIP, serviços enable/disable |
| [`kolla-config/passwords.yml`](kolla-config/passwords.yml) | Senhas dos serviços (incl. `keystone_admin_password` para Horizon) |
| [`kolla-config/clouds.yaml`](kolla-config/clouds.yaml) | Credenciais da CLI OpenStack (`OS_CLOUD=kolla-admin`); gerado no `post-deploy` |
| [`kolla-config/admin-openrc.sh`](kolla-config/admin-openrc.sh) | `source` para exportar env vars do admin (API pública); gerado no `post-deploy` |
| [`kolla-config/admin-openrc-system.sh`](kolla-config/admin-openrc-system.sh) | Igual, com *system scope* (admin de sistema) |
| [`kolla-config/public-openrc.sh`](kolla-config/public-openrc.sh) | OpenRC com endpoint público |
| [`kolla-config/public-openrc-system.sh`](kolla-config/public-openrc-system.sh) | OpenRC público + system scope |

Ficheiros `*-openrc.sh` e `clouds.yaml` contêm **senhas** — não partilhar; preferir não os commitar em repositórios públicos.

## Rede deste lab (não fica sem internet)

| Variável | Valor | Papel |
|----------|-------|--------|
| `network_interface` | `enp9s0` | Cabo Ethernet — gerenciamento/VIP; IP do host permanece |
| `neutron_external_interface` | `dummy0` | Externa do Neutron (falsa; não toma o cabo) |
| `kolla_internal_vip_address` | `192.168.1.250` | Horizon/APIs (confirmar IP livre na LAN) |

Detalhes: [`notes/topologia-aio.md`](notes/topologia-aio.md).

## Requisitos

Para o `./project/lab.sh install-app` (ou o passo a passo de [`docs/nuvem-larcerto.md`](docs/nuvem-larcerto.md)):

- **Terraform `>= 1.5`**: binário em `~/.local/bin/terraform`. Se faltar, o `install-app` instala a versão
  atual (download de `releases.hashicorp.com`, SHA-256 conferido, sem `sudo`). À mão, troque `1.9.8` pela
  versão desejada:

  ```bash
  V=1.9.8
  mkdir -p ~/.local/bin && cd "$(mktemp -d)" && \
    curl -fsSLO "https://releases.hashicorp.com/terraform/${V}/terraform_${V}_linux_amd64.zip" && \
    curl -fsSLO "https://releases.hashicorp.com/terraform/${V}/terraform_${V}_SHA256SUMS" && \
    sha256sum -c --ignore-missing terraform_${V}_SHA256SUMS && \
    python3 -m zipfile -e "terraform_${V}_linux_amd64.zip" . && \
    install -m 0755 terraform ~/.local/bin/terraform && ~/.local/bin/terraform version
  ```
- **Cliente `openstack`** no venv: `~/venvs/kolla/bin/pip install python-openstackclient`.
- **Chave SSH**: `~/.ssh/id_ed25519.pub` (`ssh-keygen -t ed25519`, se não existir).
- **Senha do banco**: `project/ansible/group_vars/all/secrets.yml`, copiado de `secrets.yml.example` com a
  senha trocada (fora do git). Se a app local já foi criada (`project/app/.env` com `DB_PASSWORD`), o
  `install-app` cria o `secrets.yml` com a mesma senha; um `secrets.yml` já editado não é mexido.
- **Kolla deployado**: `./project/lab.sh deploy` uma vez, antes da primeira instalação.
- **`certutil`** (opcional, só para `./project/lab.sh cert trust` confiar na CA no navegador sem abrir
  as configurações): `sudo apt install libnss3-tools`. Detalhes em
  [`docs/nuvem-larcerto.md`](docs/nuvem-larcerto.md#confiar-na-ca-no-navegador-sem-abrir-as-configurações).

## Como rodar (manual — aluno)

Na raiz do repo (`DevOps3`).

### 0) Permissão

```bash
chmod +x project/lab.sh
```

`chmod` só evita “Permission denied” ao executar o ficheiro. Pedidos de **senha** vinham do **sudo**. O `lab.sh` tenta root via **Docker** (grupo `docker`) quando não há sudo NOPASSWD — bootstrap/deploy/post-deploy não devem pedir senha se o Docker funcionar.

### 1) Venv

```bash
source ~/venvs/kolla/bin/activate
```

Se ainda não existir:

```bash
python3 -m venv ~/venvs/kolla
source ~/venvs/kolla/bin/activate
pip install -U pip
pip install git+https://opendev.org/openstack/kolla-ansible@master
kolla-ansible install-deps
```

### 2) Prep + deploy

```bash
ping -c1 192.168.1.250          # sem resposta = VIP livre
./project/lab.sh prep           # dummy0 + OVS do host fora do caminho
./project/lab.sh bootstrap
./project/lab.sh prechecks
./project/lab.sh deploy         # demora; no fim aplica fix-wired (cabo fora do br-ex)
./project/lab.sh post-deploy    # tambem garante fix-wired
```

Atalho para subir o projeto inteiro de uma vez (OpenStack, nuvem, app e HTTPS do Horizon), sem apagar nada. Se uma etapa falhar, ele mostra como continuar com `./project/lab.sh all --from <etapa>`:

```bash
./project/lab.sh all
```

Numa máquina nova, rode antes `./project/lab.sh bootstrap`. Repetir o `all` com a nuvem no ar corta a rede das VMs até o `deploy` recriar o OVS.

### 3) Testar

1. Browser: **http://192.168.1.250** (Horizon) — user `admin`, senha em `kolla-config/passwords.yml` (`keystone_admin_password`)
2. Estado rápido: `./project/lab.sh status` (Kolla); VMs da nuvem: `./project/lab.sh vms`; apagar e recriar a infra da app (REQ25): `./project/lab.sh recreate-app`
3. OVS só: `./project/lab.sh test-ovs`
4. Portas: [`docs/ports.md`](docs/ports.md)

### 4) Parar e voltar a subir

`stop` desabilita as unidades systemd `kolla-*` e o restart automático do Docker: os containers **não voltam no boot**. Reboot **sem** `stop` continua a subir o lab (padrão Kolla).

```bash
./project/lab.sh stop
# ou: ./project/lab.sh stop --remove   # apaga containers; depois precisa de deploy

# Depois do reboot (ou para voltar a trabalhar, sem redeploy):
./project/lab.sh start
```

## Troubleshooting (via lab.sh)

| Sintoma | Comando |
|---------|---------|
| `openvswitch_db` / `pidfile check failed` | `./project/lab.sh fix-ovs` → `./project/lab.sh deploy` |
| Confirmar OVS sem redeploy longo | `./project/lab.sh test-ovs` |
| Cabo sem IP / “getting IP configuration” | Já corre no fim de `deploy`/`all`/`post-deploy`; se voltar: `./project/lab.sh fix-wired` |
| Deploy falha em horizon `409 Conflict` (nome já em uso) | `./project/lab.sh fix-horizon` → `./project/lab.sh deploy` |
| Horizon já abre no browser | Ignora o 409; usa o login |
| Navegador não confia no HTTPS da LarCerto, ou o certificado venceu / o `web` serve outro | `./project/lab.sh cert` (ver); `./project/lab.sh cert trust` (confiar na CA); `./project/lab.sh cert renew` (emitir de novo) |
| Horizon só em HTTP; quero `https://cloud.larcerto.com.br` | `./project/lab.sh cert cloud` e, uma vez, `./project/lab.sh deploy` ([guia](docs/nuvem-larcerto.md#https-do-horizon-httpscloudlarcertocombr)) |
| VMs sem IP, Ansible com `No route to host` no `Esperar SSH` | AppArmor do `dnsmasq`: correção e rollback em [docs/kolla-ansible-quickstart.md](docs/kolla-ansible-quickstart.md#vms-sem-ip-apparmor-bloqueando-o-dnsmasq-do-neutron) |

Ajuda: `./project/lab.sh help`
