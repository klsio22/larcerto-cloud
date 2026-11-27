# LarCerto Cloud — nuvem privada OpenStack (TSI36C-EAD)

Trabalho 1 de Computação em Nuvem (UTFPR, TSI36C): nuvem privada OpenStack com Kolla-Ansible, Terraform e Ansible hospedando o CRUD LarCerto em PHP.

## Trabalho 1 — LarCerto

Passo a passo da nuvem do trabalho (rede externa, projeto, VMs, DNS, CA, HTTPS): [`docs/nuvem-larcerto.md`](docs/nuvem-larcerto.md). O CRUD (PHP 8.4 + MariaDB 12.3, MVC, CSS e JavaScript próprios, fotos dos imóveis) roda também sem a nuvem, num Docker Compose local (`bash app/run.sh setup`; o mesmo script serve na VM `web`): [`app/README.md`](app/README.md).

### Endereços (nuvem e app no ar)

| O quê | Endereço | Login |
|-------|----------|-------|
| App LarCerto | https://larcerto.com.br (http redireciona para https) | — |
| Painel OpenStack (Horizon) | https://cloud.larcerto.com.br | `devops1` (projeto `larcerto`); senha em `cloud/secrets/devops1.password` |
| Horizon como admin | https://cloud.larcerto.com.br | `admin`; senha `keystone_admin_password` em `kolla-config/passwords.yml` |

Os nomes resolvem pela VM `dns` (`./larcerto.sh dns-host`, feito pelo `all` e pelo `start-app`) e o cadeado
depende da CA LarCerto no navegador (`./larcerto.sh cert trust`). O IP do VIP, `http://192.168.1.250`, só
serve antes disso: logo depois do `deploy`, quando ainda não existem as VMs `dns` e `ca`.

Senhas, CLI do OpenStack (admin e `devops1`), estado do lab e SSH nas VMs:
[Comandos úteis](docs/nuvem-larcerto.md#comandos-úteis).

## Fontes

1. **Videoaulas 06–10** da disciplina (Computação em Nuvem); o mapa aula → passo está em [`docs/topologia-aio.md`](docs/topologia-aio.md)
2. **Enunciado** — [`docs/enunciado-trabalho-1.md`](docs/enunciado-trabalho-1.md) (REQ01–REQ24; substitutivo + REQ25)
3. **OpenStack com containers** — [`docs/kolla-ansible-quickstart.md`](docs/kolla-ansible-quickstart.md)
4. **Portas dos containers** — [`docs/ports.md`](docs/ports.md)
5. **Topologia AIO** — [`docs/topologia-aio.md`](docs/topologia-aio.md)

Não inventar passos além das aulas e do enunciado. Se faltar transcrição, avisar.

## Estrutura e para que serve cada ficheiro

```
larcerto-cloud/
  README.md
  larcerto.sh
  all-in-one                 # inventário Ansible (usado pelo scripts/kolla/kolla.sh)
  scripts/                   # módulos do lab: common.sh, lab/ (rede, ovs, ciclo, install, cert, vms), kolla/ (kolla.sh, zorin_facts.py)
  tests/                     # test-scripts.sh (sem tocar no host), app-checks.sh (Compose local) e cloud-checks.sh (nuvem montada)
  cloud/bootstrap.sh         # admin: rede public, flavor, imagem, projeto larcerto, devops1
  terraform/                 # infra do projeto larcerto (4 VMs, redes, SGs, floating IPs)
  ansible/                   # configuração das VMs: dns, ca, db, web
  app/                       # CRUD LarCerto em MVC: backend/, frontend/, public/, sql/ + compose.yml (ambiente local)
  docs/                      # toda a documentação de apoio
    README.md                # índice
    enunciado-trabalho-1.md
    nuvem-larcerto.md        # passo a passo do Trabalho 1
    topologia-aio.md         # topologia (REQ09) e mapa aula → passo
    kolla-ansible-quickstart.md
    ports.md
    larcerto.sh.md · kolla-config-scripts.md · horizon-theme-lux.md
  kolla-config/
    globals.yml
    passwords.yml            # fora do git: kolla-genpwd (ver abaixo)
    clouds.yaml              # gerado no post-deploy
    admin-openrc.sh          # gerado no post-deploy
    admin-openrc-system.sh   # gerado no post-deploy
    public-openrc.sh         # gerado no post-deploy
    public-openrc-system.sh  # gerado no post-deploy
```

| Ficheiro | Para que serve |
|----------|----------------|
| [`README.md`](README.md) | Guia do lab: como subir a nuvem, rede AIO, troubleshooting |
| [`docs/`](docs/README.md) | Documentação dos scripts: funções de `larcerto.sh` e dos módulos de `scripts/`, openrc/`clouds.yaml` |
| [`larcerto.sh`](larcerto.sh) | Entrypoint único (lista completa: `./larcerto.sh help`): `venv`, `all`, `prep`, `bootstrap`/`prechecks`/`deploy`/`post-deploy`, `status`, `stop`, `start`, `ext-net`, `dns-host`, `install-app`, `start-app`, `recreate-app`, `clear-all`, `vms`, `cert`, `dummy0`, `fix-ovs`, `fix-wired`, `fix-horizon`, `test-ovs` |
| [`scripts/`](scripts/) | Módulos do lab, carregados pelo `larcerto.sh`. Os comandos Kolla estão em `scripts/kolla/kolla.sh` (inventário + `kolla-config`); tenta root via Docker se não houver sudo NOPASSWD |
| [`all-in-one`](all-in-one) | Inventário Ansible AIO: todos os papéis (control, network, compute…) em `localhost` |
| [`docs/enunciado-trabalho-1.md`](docs/enunciado-trabalho-1.md) | Requisitos do Trabalho 1 (REQ01–REQ24 + substitutivo REQ25) |
| [`docs/kolla-ansible-quickstart.md`](docs/kolla-ansible-quickstart.md) | Notas/referência do quickstart Kolla (contexto OpenStack em containers) |
| [`docs/nuvem-larcerto.md`](docs/nuvem-larcerto.md) | Passo a passo do Trabalho 1: do lab ligado até `https://larcerto.com.br` |
| [`docs/ports.md`](docs/ports.md) | Mapa de portas VIP, containers Kolla e da app do trabalho |
| [`docs/topologia-aio.md`](docs/topologia-aio.md) | Topologia do lab (host, Kolla, projeto `larcerto` e as 4 VMs; REQ09) e mapa aula → passo |
| [`kolla-config/globals.yml`](kolla-config/globals.yml) | Config Kolla: distro, interfaces, VIP, serviços enable/disable |
| `kolla-config/passwords.yml` | Senhas dos serviços (incl. `keystone_admin_password` para Horizon) |
| `kolla-config/clouds.yaml` | Credenciais da CLI OpenStack (`OS_CLOUD=kolla-admin`); gerado no `post-deploy` |
| `kolla-config/admin-openrc.sh` | `source` para exportar env vars do admin (API pública); gerado no `post-deploy` |
| `kolla-config/admin-openrc-system.sh` | Igual, com *system scope* (admin de sistema) |
| `kolla-config/public-openrc.sh` | OpenRC com endpoint público |
| `kolla-config/public-openrc-system.sh` | OpenRC público + system scope |

`passwords.yml`, `*-openrc.sh` e `clouds.yaml` contêm **senhas** e ficam fora do git (`.gitignore`). Numa máquina nova, gere o
`passwords.yml` antes do `bootstrap` (o `./larcerto.sh venv` já gera se faltar); os openrc e o `clouds.yaml`
saem do `./larcerto.sh post-deploy`. À mão:

```bash
cp ~/venvs/kolla/share/kolla-ansible/etc_examples/kolla/passwords.yml kolla-config/
~/venvs/kolla/bin/kolla-genpwd -p kolla-config/passwords.yml
```

## Rede deste lab (não fica sem internet)

| Variável | Valor | Papel |
|----------|-------|--------|
| `network_interface` | `enp9s0` | Cabo Ethernet — gerenciamento/VIP; IP do host permanece |
| `neutron_external_interface` | `dummy0` | Externa do Neutron (falsa; não toma o cabo) |
| `kolla_internal_vip_address` | `192.168.1.250` | Horizon/APIs (confirmar IP livre na LAN) |

Detalhes: [`docs/topologia-aio.md`](docs/topologia-aio.md).

## Requisitos

Para o `./larcerto.sh install-app` (ou o passo a passo de [`docs/nuvem-larcerto.md`](docs/nuvem-larcerto.md)):

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
- **Cliente `openstack`** no venv: já vem do `./larcerto.sh venv` (à mão: `~/venvs/kolla/bin/pip install python-openstackclient`).
- **Chave SSH**: `~/.ssh/id_ed25519.pub` (`ssh-keygen -t ed25519`, se não existir).
- **Senha do banco**: `ansible/group_vars/all/secrets.yml`, copiado de `secrets.yml.example` com a
  senha trocada (fora do git). Se a app local já foi criada (`app/.env` com `DB_PASSWORD`), o
  `install-app` cria o `secrets.yml` com a mesma senha; um `secrets.yml` já editado não é mexido.
- **Kolla deployado**: `./larcerto.sh deploy` uma vez, antes da primeira instalação.
- **`certutil`** (opcional, só para `./larcerto.sh cert trust` confiar na CA no navegador sem abrir
  as configurações): `sudo apt install libnss3-tools`. Detalhes em
  [`docs/nuvem-larcerto.md`](docs/nuvem-larcerto.md#confiar-na-ca-no-navegador-sem-abrir-as-configurações).

Para os testes de navegador do `tests/test-scripts.sh` (CSS, galeria, slider): Python com Playwright em
`.venv/` na raiz do repo (fora do git):

```bash
python3 -m venv .venv && .venv/bin/pip install playwright && .venv/bin/playwright install chromium
```

Outro Python já com Playwright: `PW_PYTHON=/caminho/bin/python bash tests/test-scripts.sh`.

## Como rodar (manual — aluno)

Na raiz do repo (`larcerto-cloud`).

### 0) Permissão

```bash
chmod +x larcerto.sh
```

`chmod` só evita “Permission denied” ao executar o ficheiro. Pedidos de **senha** vinham do **sudo**. O `larcerto.sh` tenta root via **Docker** (grupo `docker`) quando não há sudo NOPASSWD — bootstrap/deploy/post-deploy não devem pedir senha se o Docker funcionar.

### 1) Venv

Uma vez por máquina: os pacotes do sistema (pedem `sudo`, por isso ficam com você) e o venv do Kolla.

```bash
sudo apt install python3-venv python3-dev git gcc libffi-dev libssl-dev libdbus-glib-1-dev
./larcerto.sh venv
```

O `venv` faz o passo "Install dependencies" do
[quickstart oficial](https://docs.openstack.org/kolla-ansible/latest/user/quickstart.html), com os mesmos
comandos: `python3 -m venv ~/venvs/kolla`, `pip install -U pip`,
`pip install git+https://opendev.org/openstack/kolla-ansible@master`, o cliente `openstack`
(`python-openstackclient`, constraints `master`), os módulos `docker` e `dbus-python` e
`kolla-ansible install-deps`. Se `kolla-config/passwords.yml` não existe, ele o gera com `kolla-genpwd`
(um `passwords.yml` existente nunca é tocado). Rodar de novo não reinstala nada (`venv OK: ... (ja estava)`);
se parou no meio, ele retoma do que falta. Faltando pacote do sistema, ele só mostra a linha do `apt` e sai.

- Outro caminho: `VENV_PATH=/outro/venv ./larcerto.sh venv` (e o mesmo `VENV_PATH` nos outros comandos).
- Outro Python: `VENV_PYTHON=python3.12 ./larcerto.sh venv`. O Kolla suporta o Python padrão dos sistemas
  da [support matrix](https://docs.openstack.org/kolla-ansible/latest/user/support-matrix.html)
  (3.12 e 3.13); com outra versão o `venv` avisa e segue.
- Refazer do zero: `rm -rf ~/venvs/kolla && ./larcerto.sh venv`.

O `larcerto.sh` não precisa do venv ativo. Para usar `openstack` ou `kolla-ansible` à mão no terminal:

```bash
source ~/venvs/kolla/bin/activate
```

### 2) Prep + deploy

```bash
ping -c1 192.168.1.250          # sem resposta = VIP livre
./larcerto.sh prep           # dummy0 + OVS do host fora do caminho
./larcerto.sh bootstrap
./larcerto.sh prechecks
./larcerto.sh deploy         # demora; no fim aplica fix-wired (cabo fora do br-ex)
./larcerto.sh post-deploy    # tambem garante fix-wired
```

Atalho para subir o projeto inteiro de uma vez (OpenStack, nuvem, app e HTTPS do Horizon), sem apagar nada. Se uma etapa falhar, ele mostra como continuar com `./larcerto.sh all --from <etapa>`:

```bash
./larcerto.sh all
```

Numa máquina nova, rode antes `./larcerto.sh venv` e `./larcerto.sh bootstrap`. Repetir o `all` com a nuvem no ar corta a rede das VMs até o `deploy` recriar o OVS.

**Depois do `all`: confiar no certificado.** Para o HTTPS de `https://larcerto.com.br` e
`https://cloud.larcerto.com.br` funcionar no navegador (cadeado, sem aviso), recomenda-se rodar:

```bash
./larcerto.sh cert trust   # importa a CA LarCerto no Firefox, Brave e Chromium, sem sudo
```

e depois **fechar e abrir o navegador de novo** (ele só lê CAs novas ao reiniciar). O `all` cria a
CA LarCerto, mas não a instala no navegador. Por isso o `cert trust` é necessário na primeira vez e
sempre que o projeto subir do zero, porque aí a CA é nova. Rodar de novo com a CA já instalada é
seguro: ele responde `ja estava`. Sem esse passo, o Firefox mostra *Warning: Security Risk* e, por
causa do HSTS da app, nem oferece a opção de continuar. Para ver a CA e os certificados servidos:
`./larcerto.sh cert`.

### 3) Testar

1. Browser: **https://larcerto.com.br** (app) e **https://cloud.larcerto.com.br** (Horizon); logins na seção [Endereços](#endereços-nuvem-e-app-no-ar). Só com o Kolla no ar (sem as VMs `dns` e `ca`): `http://192.168.1.250`
2. Estado rápido: `./larcerto.sh status` (Kolla); VMs da nuvem: `./larcerto.sh vms`; apagar e recriar a infra da app (REQ25): `./larcerto.sh recreate-app`
3. OVS só: `./larcerto.sh test-ovs`
4. Portas: [`docs/ports.md`](docs/ports.md)

### 4) Parar e voltar a subir

`stop` desabilita as unidades systemd `kolla-*` e o restart automático do Docker: os containers **não voltam no boot**. Reboot **sem** `stop` continua a subir o lab (padrão Kolla).

```bash
./larcerto.sh stop
# ou: ./larcerto.sh stop --remove   # apaga containers; depois precisa de deploy

# Depois do reboot (ou para voltar a trabalhar, sem redeploy):
./larcerto.sh start
```

### 5) Apagar tudo (sem subir de volta)

`./larcerto.sh clear-all [--yes]` **só apaga**: as VMs da app, o OpenStack (containers e volumes do Kolla), a app local
(containers, volumes e imagens), o `terraform.tfstate`, o inventário, as credenciais geradas, a CA
com todos os certificados e a CA nos navegadores. Não é um reinício: nada sobe de volta.

```bash
./larcerto.sh clear-all          # mostra o que sai e o que fica e pede para digitar yes (outra resposta cancela)
./larcerto.sh clear-all --yes    # sem a pergunta

# Para subir de novo, do zero (CA nova: depois, ./larcerto.sh cert trust):
./larcerto.sh all
```

Ficam `kolla-config/passwords.yml`, `kolla-config/globals.yml`, `app/.env`,
`ansible/group_vars/all/secrets.yml`, a chave SSH e as imagens do Kolla (o próximo `deploy` não
baixa tudo de novo). Se uma etapa falhar, `./larcerto.sh clear-all --yes` continua: `start`, `destroy-app`, `dns-host`,
`ext-net` e `trust` pulam (`pulado:`) o que já foi apagado, e as outras não falham quando o que
apagam já não existe. Atenção: o `kolla-ansible destroy` apaga **todos** os network namespaces e as
interfaces `tap*`, `brq*` e `vxlan*` do host, não só as do Kolla.

## O que o lab muda no seu PC (e como desfazer)

Para **usar** o projeto, você não configura nada no PC à mão: os comandos do `larcerto.sh` fazem e refazem
estas mudanças sozinhos. A tabela serve para quem quer entender o que acontece, mudar o lab ou
devolver o PC ao estado de antes.

| Mudança | Quem faz | Depois do reboot | Desfazer à mão |
|---------|----------|------------------|----------------|
| Interface `dummy0` (rede externa falsa do Neutron, para não tomar o cabo) | `prep`, `start` | some; o `start` e o `all` recriam | `sudo ip link delete dummy0` |
| `openvswitch-switch` do Ubuntu parado e desabilitado (brigaria com o OVS do Kolla) | `prep` (`fix-ovs`) | continua desabilitado | `sudo systemctl enable --now openvswitch-switch` |
| libvirt do Ubuntu parado (brigaria com o `nova_libvirt`; as VMs nasceriam em `ERROR`) | `start`, `deploy`, `all`, `recreate-app` | volta sozinho; o `larcerto.sh` para de novo | nada: ele já volta no reboot |
| VIP `192.168.1.250` no cabo, containers e volumes do Kolla, unidades `kolla-*`, `/etc/kolla/<serviço>` | `deploy` | voltam (padrão do Kolla), salvo depois de `stop` | `./larcerto.sh clear-all` |
| IP `172.24.4.1/24` na `br-ex`, regras `lab-ext-net` no iptables, `net.ipv4.ip_forward=1` | `ext-net` (no fim do `deploy` e do `start`) | IP e regras somem; o `start` refaz | `./larcerto.sh ext-net --down` (o `ip_forward` fica: o Docker usa) |
| DNS do host: `*.larcerto.com.br` vai para a VM `dns` (`resolvectl` na `br-ex`) | `dns-host` | some | `./larcerto.sh dns-host --down` |
| CA LarCerto nos navegadores (Firefox, Brave, Chromium) | `cert trust` | fica | `./larcerto.sh clear-all`, ou remova a "CA LarCerto" nas configurações do navegador |
| Docker (repositório oficial), bloco `# BEGIN ANSIBLE GENERATED HOSTS` no `/etc/hosts`, firewall do sistema desativado, perfil AppArmor do `libvirtd` desativado, `/etc/systemd/system/kolla.target` | `bootstrap` (`kolla-ansible bootstrap-servers`) | fica | ver abaixo |
| Perfil AppArmor do `dnsmasq` desativado (só se você aplicou a correção) | à mão | fica | rollback em [docs/kolla-ansible-quickstart.md](docs/kolla-ansible-quickstart.md#vms-sem-ip-apparmor-bloqueando-o-dnsmasq-do-neutron) |
| Imagens do Kolla (~11 GB), venv `~/venvs/kolla`, Terraform em `~/.local/bin`, imagem do Ubuntu em `~/.cache/larcerto` | `deploy`, passo 1, `install-app`, `bootstrap` da nuvem | ficam | ver abaixo |

Devolver o PC ao normal, nesta ordem (só o que você quiser; nada disso é preciso para usar o lab):

```bash
./larcerto.sh clear-all --yes                     # VMs, OpenStack, app local, CA e arquivos gerados

sudo ip link delete dummy0
sudo systemctl enable --now openvswitch-switch   # só se você usa o OVS do Ubuntu para outra coisa
sudo rm -f /etc/systemd/system/kolla.target && sudo systemctl daemon-reload
sudo rm -rf /etc/kolla

# Imagens do Kolla, venv, Terraform e cache da imagem do Ubuntu
docker image rm $(docker images --filter label=kolla_version -q)
rm -rf ~/venvs/kolla ~/.cache/larcerto ~/.local/bin/terraform

# Do bootstrap: confira antes de mexer, porque podem servir a outras coisas no seu PC
sudo nano /etc/hosts                          # apague o bloco BEGIN/END ANSIBLE GENERATED HOSTS
sudo rm /etc/apparmor.d/disable/usr.sbin.libvirtd && sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.libvirtd
sudo ufw enable                               # se você usava o firewall do Ubuntu
# Docker: só remova se não usa para mais nada (sudo apt remove docker-ce docker-ce-cli containerd.io)
```

## Troubleshooting (via larcerto.sh)

| Sintoma | Comando |
|---------|---------|
| `openvswitch_db` / `pidfile check failed` | `./larcerto.sh fix-ovs` → `./larcerto.sh deploy` |
| Confirmar OVS sem redeploy longo | `./larcerto.sh test-ovs` |
| Cabo sem IP / “getting IP configuration” | Já corre no fim de `deploy`/`all`/`post-deploy`; se voltar: `./larcerto.sh fix-wired` |
| Deploy falha em horizon `409 Conflict` (nome já em uso) | `./larcerto.sh fix-horizon` → `./larcerto.sh deploy` |
| Horizon já abre no browser | Ignora o 409; usa o login |
| Navegador não confia no HTTPS da LarCerto (Firefox: *Warning: Security Risk* / HSTS em `larcerto.com.br`), ou o certificado venceu / o `web` serve outro | `./larcerto.sh cert` (ver); `./larcerto.sh cert trust` (confiar na CA); `./larcerto.sh cert renew` (emitir de novo) |
| Horizon só em HTTP; quero `https://cloud.larcerto.com.br` | `./larcerto.sh cert cloud` e, uma vez, `./larcerto.sh deploy` ([guia](docs/nuvem-larcerto.md#https-do-horizon-httpscloudlarcertocombr)) |
| VMs sem IP, Ansible com `No route to host` no `Esperar SSH` | AppArmor do `dnsmasq`: correção e rollback em [docs/kolla-ansible-quickstart.md](docs/kolla-ansible-quickstart.md#vms-sem-ip-apparmor-bloqueando-o-dnsmasq-do-neutron) |

Ajuda: `./larcerto.sh help`

## Uso de IA

Este projeto teve apoio de um assistente de IA (Claude, da Anthropic) na escrita de scripts,
configurações, testes e documentação. A execução e a validação no meu ambiente (OpenStack,
VMs, DNS, CA e app) e a apresentação em vídeo foram feitas por mim.
