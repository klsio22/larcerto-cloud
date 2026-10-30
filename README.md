# Projeto OpenStack — Computação em Nuvem (TSI36C-EAD)

Labs e entrega do **Trabalho 1** (nuvem privada + app web CRUD).

## Fontes

1. **Videoaulas 06–10** — [`transcricoes/`](../transcricoes/) · links em [`videos/README.md`](../videos/README.md)
2. **Enunciado** — [`enunciado-trabalho-1.md`](enunciado-trabalho-1.md) (REQ01–REQ24; substitutivo + REQ25)
3. **OpenStack com containers** — [`kolla-ansible-quickstart.md`](kolla-ansible-quickstart.md)
4. **Portas dos containers** — [`ports.md`](ports.md)
5. **Topologia AIO** — [`notes/topologia-aio.md`](notes/topologia-aio.md)

Não inventar passos além das aulas e do enunciado. Se faltar transcrição, avisar.

## Estrutura e para que serve cada ficheiro

```
project/
  README.md
  lab.sh
  run-kolla.sh
  all-in-one
  enunciado-trabalho-1.md
  kolla-ansible-quickstart.md
  ports.md
  docs/                      # referência detalhada dos scripts
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
| [`docs/`](docs/README.md) | Documentação dos scripts: funções de `lab.sh`, `run-kolla.sh`, openrc/`clouds.yaml` |
| [`lab.sh`](lab.sh) | Entrypoint único: `prep`, `bootstrap`/`deploy`/`post-deploy`, `status`, `stop`, `start`, `fix-ovs`, `fix-wired`, `fix-horizon`, `test-ovs` |
| [`run-kolla.sh`](run-kolla.sh) | Wrapper do `kolla-ansible` (inventário + `kolla-config`); chamado pelo `lab.sh`. Tenta root via Docker se não houver sudo NOPASSWD |
| [`all-in-one`](all-in-one) | Inventário Ansible AIO: todos os papéis (control, network, compute…) em `localhost` |
| [`enunciado-trabalho-1.md`](enunciado-trabalho-1.md) | Requisitos do Trabalho 1 (REQ01–REQ24 + substitutivo REQ25) |
| [`kolla-ansible-quickstart.md`](kolla-ansible-quickstart.md) | Notas/referência do quickstart Kolla (contexto OpenStack em containers) |
| [`ports.md`](ports.md) | Mapa de portas VIP, containers Kolla e da app do trabalho |
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

## Como rodar (manual — aluno)

Na raiz do repo (`DevOps3`).

### 0) Permissão

```bash
chmod +x project/lab.sh project/run-kolla.sh
```

`chmod` só evita “Permission denied” ao executar o ficheiro. Pedidos de **senha** vinham do **sudo**. O `lab.sh` e o `run-kolla.sh` tentam root via **Docker** (grupo `docker`) quando não há sudo NOPASSWD — bootstrap/deploy/post-deploy não devem pedir senha se o Docker funcionar.

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

Atalho (bootstrap + prechecks + deploy + fix-wired no fim):

```bash
./project/lab.sh all
```

### 3) Testar

1. Browser: **http://192.168.1.250** (Horizon) — user `admin`, senha em `kolla-config/passwords.yml` (`keystone_admin_password`)
2. Estado rápido: `./project/lab.sh status`
3. OVS só: `./project/lab.sh test-ovs`
4. Portas: [`ports.md`](ports.md)

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

Ajuda: `./project/lab.sh help`
