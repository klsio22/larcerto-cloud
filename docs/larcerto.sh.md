# `larcerto.sh`

Entrypoint único do lab AIO (dummy0, OVS host, testes, stop/start, fixes e deploy Kolla).

```bash
./larcerto.sh <comando> [opções]
```

Código: [`../larcerto.sh`](../larcerto.sh). O `larcerto.sh` só carrega os módulos de `scripts/` com `source`, imprime o `usage` e despacha o comando. Cada assunto fica num arquivo:

| Módulo | Origem | Conteúdo |
|--------|--------|----------|
| [`scripts/common.sh`](../scripts/common.sh) | compartilhado | `step`, `run_as_root`, `docker_cmd`, `read_globals` |
| [`scripts/lab/rede.sh`](../scripts/lab/rede.sh) | `larcerto.sh` | `dummy0` (e `dummy1`, a rede do host), `fix-wired`, `ext-net`, `dns-host` |
| [`scripts/lab/ovs.sh`](../scripts/lab/ovs.sh) | `larcerto.sh` | `fix-ovs`, `test-ovs` e leitura das portas da `br-ex` |
| [`scripts/lab/ciclo.sh`](../scripts/lab/ciclo.sh) | `larcerto.sh` | `prep`, `status`, `start`, `stop`, `fix-horizon` |
| [`scripts/lab/install.sh`](../scripts/lab/install.sh) | `larcerto.sh` | `all` (15 etapas, `--from`), `install-app` (8 etapas, `--from`), `start-app` (religa a instalação), `recreate-app` (apaga e recria a infra da app) |
| [`scripts/lab/cert.sh`](../scripts/lab/cert.sh) | `larcerto.sh` | `cert` (`status`, `renew`, `renew --new-ca`, `trust`, `cloud`) do certificado da LarCerto e do Horizon |
| [`scripts/lab/vms.sh`](../scripts/lab/vms.sh) | `larcerto.sh` | `vms`: lista as VMs do projeto `larcerto` (só leitura) |
| [`scripts/kolla/kolla.sh`](../scripts/kolla/kolla.sh) | wrapper Kolla removido | `bootstrap`, `prechecks`, `deploy`, `post-deploy`, `stop-kolla` |
| [`scripts/kolla/zorin_facts.py`](../scripts/kolla/zorin_facts.py) | wrapper Kolla removido | facts do Zorin para o Kolla |

Os arquivos de `scripts/` só definem funções e variáveis: nada roda ao carregá-los.

## Variáveis e paths

| Variável | Valor | Uso |
|----------|-------|-----|
| `SCRIPT_DIR` | raiz do repo | Base dos scripts |
| `GLOBALS_YML` | `kolla-config/globals.yml` | Lê `network_interface`, `neutron_external_interface` e `kolla_internal_vip_address` (definido em `scripts/common.sh`) |
| `DOCKER` | array (`docker` ou `sudo docker`) | Preenchido por `init_docker` |

## Helpers internos

### Em `scripts/common.sh` (compartilhados)

- `step <texto>` — imprime o cabeçalho de etapa `==> <texto>`.
- `read_globals <key> <default>` — lê linha ativa `key: value` em `globals.yml` (ignora comentários); imprime o default se ausente.
- `stop_host_libvirt` — se alguma unidade do libvirt do host (`libvirtd.socket`, `libvirtd`, `virtlogd.socket`, `virtlogd`) está ativa, roda `systemctl stop` nas quatro com `run_as_root` (root) e imprime `libvirt do host parado (conflita com o nova_libvirt)`. Só `stop`, nunca `disable`: o libvirt do host volta no próximo boot. Com `AUTO_STOP_HOST_LIBVIRT=false` não mexe e avisa `AVISO: libvirt do host ativo; as VMs podem nascer em ERROR`. Se o `stop` não pegar (sem root), avisa `AVISO: o libvirt do host continua ativo (o stop precisa de root)...` e o `start` não reinicia os containers. Usada pelo `start` e pelas etapas do Kolla. Para devolver o libvirt ao host: `sudo systemctl start libvirtd.socket virtlogd.socket` (enquanto ele estiver ativo, VMs novas do OpenStack nascem em `ERROR`; o próximo `larcerto.sh start` para de novo).

  Por quê: o `nova_libvirt` compartilha o `/run` do host. Com o `virtlogd` do host ativo (ele sobe no boot), é ele quem atende o libvirt do Kolla, não acha `/var/lib/nova/instances/<id>/console.log` (que só existe no volume do container) e as VMs nascem em `ERROR` ("Exceeded maximum number of retries").

### `run_as_root` (`scripts/common.sh`)

Executa um comando como root, nesta ordem:

1. Já é root (`EUID == 0`)
2. `sudo -n` (NOPASSWD)
3. Docker privilegiado + `nsenter -- <cmd>` no PID 1 (grupo `docker`)
4. `sudo` interativo (pede senha)

### `init_docker` / `docker_cmd` (`scripts/common.sh`)

- `init_docker` — define `DOCKER=(docker)` ou `DOCKER=(sudo docker)`; falha se nenhum tiver acesso.
- `docker_cmd` — chama `init_docker` e executa `"${DOCKER[@]}" "$@"`.

### `list_kolla_unit_files`

Lista unidades systemd `kolla-*.service` via `systemctl list-unit-files` (visível mesmo depois de disable/reboot). Usado por `stop` e `start`.

### `network_iface` / `external_iface` / `vip_address`

Leem `globals.yml` via `read_globals`:

- `network_iface` — `network_interface` (default `dummy1`).
- `is_virtual_iface` — interface sem placa por trás (sem `/sys/class/net/<if>/device`; `SYS_CLASS_NET` troca a pasta nos testes).
- `host_net_cidr` — IP do host na rede do VIP: `<3 primeiros octetos do VIP>.1/24` (`10.99.0.1/24`).
- `kolla_check_hostname` (`scripts/kolla/kolla.sh`) — antes do `prechecks` e do `deploy`, só leitura: o hostname (nome curto) tem de resolver (`getent ahostsv4`) só para o primeiro IPv4 do `network_interface`, como exige o precheck do rabbitmq. Senão: `Erro: o hostname ... resolve para ...` + `Rode ./larcerto.sh bootstrap` e sai 1, sem chamar o kolla-ansible. Sem IP na interface, não checa.
- `host_net_up` — com `network_interface` `dummy*`: cria a interface, põe `host_net_cidr` (sem duplicar) e sobe; placa física: nada. Chamado pelo `dummy0`, `prep` e `start`, e antes do kolla-ansible no `bootstrap`, `prechecks` e `deploy` (máquina nova sem `prep`).
- `uplink_iface` — placa da rota padrão (`ip route get 1.1.1.1`): saída do NAT das VMs.
- `external_iface` — `neutron_external_interface` (default `dummy0`).
- `vip_address` — `kolla_internal_vip_address` (default `10.99.0.250`).

### `ovs_db_running` / `br_ex_ports` / `mgmt_on_br_ex`

- `ovs_db_running` — true se o container `openvswitch_db` estiver Up.
- `br_ex_ports` — lista portas do bridge `br-ex` via `ovs-vsctl` no container.
- `mgmt_on_br_ex` — true se a NIC de gestão (`network_iface`) estiver em `br-ex`.
- `print_br_ex_ports` — imprime as portas de `br-ex` indentadas, ou `(vazio)`.

### `warn_or_fail_mgmt_on_br_ex`

Modo `warn` ou `fail`. Lista portas de `br-ex`; se a NIC de gestão estiver lá, avisa (e falha no modo `fail`). Sugere `./larcerto.sh fix-wired`.

### `usage`

Imprime help CLI (`help` / `-h` / `--help`).

### `cmd_kolla`

Chama `kolla_run <ação>` de [`scripts/kolla/kolla.sh`](../scripts/kolla/kolla.sh). Se o Kolla falhar, o `larcerto.sh` sai com o mesmo código. Se a ação for `deploy` ou `post-deploy` e o Kolla terminar com sucesso, corre `cmd_fix_wired` automaticamente (NIC de gestão fora do `br-ex`); se o `fix-wired` falhar, imprime `AVISO` no stderr e sai com 0, porque o deploy deu certo.

---

## Comandos públicos

| CLI | Função | O que faz |
|-----|--------|-----------|
| `venv` | `cmd_venv` (`scripts/kolla/kolla.sh`) | Cria o venv do Kolla em `VENV_PATH` com os comandos do quickstart (`python3 -m venv`, `pip install -U pip`, kolla-ansible `@master`, `python-openstackclient` com constraints `master`, `docker`, `dbus-python`, `kolla-ansible install-deps`) e gera `kolla-config/passwords.yml` com `kolla-genpwd` se faltar (modo `600`; existente não é tocado). Só refaz o que falta; a marca `${VENV_PATH}/.larcerto-venv` diz que terminou (`venv OK: ... (ja estava)`). Antes, confere `ensurepip` (`python3-venv`), `Python.h` (`python3-dev`), `git` e `gcc`: se falta, imprime `Falta no sistema:` e a linha do `sudo apt install` e sai 1, sem criar nada e sem rodar `sudo`. Python fora de 3.12/3.13: `AVISO:` e segue |
| `prep` | `cmd_prep` | `dummy0` + `fix-ovs`; imprime próximo fluxo |
| `dummy0` | `cmd_dummy0` | Cria/ativa a interface externa (`dummy0` ou valor de `globals.yml`) |
| `fix-ovs` | `cmd_fix_ovs` | Para OVS do host, limpa `/run/openvswitch`, remove containers OVS Kolla |
| `fix-wired` | `cmd_fix_wired` | Tira `network_interface` de `br-ex` e, se ela for placa física, reativa a conexão no NetworkManager; virtual (`dummy1`, padrão): `pulado:` |
| `test-ovs` | `cmd_test_ovs` | Healthcheck rápido OVS (host, containers, `ovs-vsctl`, alerta cabo em `br-ex`) |
| `fix-horizon` | `cmd_fix_horizon` | Remove container `horizon` (resolve 409 Conflict no recreate) |
| `status` | `cmd_status` | Estado: interfaces, OVS, Horizon, HTTP no VIP |
| `stop` | `cmd_stop` | Para `kolla-*`, desabilita autostart no boot e para containers |
| `start` | `cmd_start` | Sobe o lab já deployado: `dummy0` e `dummy1` + `kolla-*` + `ext-net` + `fix-wired` |
| `ext-net` | `cmd_ext_net` | IP `172.24.4.1/24` na `br-ex` + NAT/FORWARD pela placa da rota padrão (`ip route get 1.1.1.1`, cabo ou Wi-Fi): floating IPs alcançáveis do host e VMs com internet. Rodar de novo depois de trocar de rede tira as regras da placa antiga. Sem rota padrão: `Erro: sem rota padrao`, sai 1. `--down` desfaz |
| `dns-host` | `cmd_dns_host` | Split DNS do host: só `~larcerto.com.br` na `br-ex` vai para a VM `dns` (`--down` desfaz) |
| `install-app` | `install_app` (`scripts/lab/install.sh`) | Confere os pré-requisitos (instala o Terraform se faltar) e sobe nuvem + app em 8 etapas (`--from <etapa>` continua de uma etapa); para na que falhar e mostra como continuar |
| `start-app` | `start_app` (`scripts/lab/install.sh`) | Religa uma instalação existente: `start`, VMs `SHUTOFF`, `dns-host` e `checks`; sem `bootstrap`, Terraform ou Ansible |
| `recreate-app` | `recreate_app` (`scripts/lab/install.sh`) | `./larcerto.sh recreate-app [--yes]`: pede para digitar `larcerto` (o `--yes` pula), depois `prereqs` → `start` → `destroy` (`terraform destroy -auto-approve` como `devops1`) → `terraform` → `nuvem` → `app` → `dns-host` → `checks`; termina com `Recriado em <M>min<S>s` (do `destroy` ao `checks`). Falhou: mostra a etapa e `install-app --from <etapa>` (ou `recreate-app`, se foi o `destroy`). Usa root no `start` (libvirt, `dummy0`, `ext-net`) e no `dns-host` (`resolvectl`), pelo `run_as_root`: sem sudo NOPASSWD e sem grupo `docker`, o `sudo` pede a senha |
| `cert` | `cert_main` (`scripts/lab/cert.sh`) | Certificado da LarCerto. `status` (padrão): CN, SAN, validade, `openssl verify` e se o `web` serve o mesmo (exit 0; 1 se falta arquivo; 2 se a cadeia não confere, expirou ou o `web` serve outro). `renew`: `site.yml --limit ca,web -e cert_renew=true` (mesma CA). `renew --new-ca [--yes]`: pede `nova-ca`, copia `files/pki/` para `backup-<data>/` e roda com `ca_new=true`. `trust`: `certutil -A` em cada banco NSS do usuário (sem `sudo`; sai 1 se um banco falha). `cloud` (`./larcerto.sh cert cloud`): se `files/pki/cloud.crt` falta ou não confere com a CA, `site.yml --limit ca -e cert_cloud=true` (SAN `cloud` e `horizon`); depois grava `/etc/kolla/haproxy/haproxy.pem` (cert + CA + chave, root 600, pelo `run_as_root`), e, se o frontend 443 já existe, roda `docker restart haproxy`; senão pede o `deploy` que cria o frontend 443 de `https://cloud.larcerto.com.br`; o `status` ganha o bloco `Horizon (cloud)` |
| `vms` | `cmd_vms` (`scripts/lab/vms.sh`) | VMs do projeto `larcerto` pela API, como `devops1`: nome, status, IP privado, floating IP (o IP em `172.24.4.0/24`) e uma linha de `ssh` por VM `ACTIVE` com floating IP. Só `server list`. Sai 1 se falta `cloud/secrets/clouds.yaml`, o cliente `openstack` do venv ou a API não responde |
| `bootstrap` | `cmd_kolla` | → `kolla_run bootstrap` |
| `prechecks` | `cmd_kolla` | → `kolla_check_hostname` + `kolla_run prechecks` |
| `deploy` | `cmd_kolla` | → `kolla_check_hostname` + `kolla_run deploy` + `fix-wired` + `ext-net` |
| `post-deploy` | `cmd_kolla` | → `kolla_run post-deploy` + `fix-wired` + `ext-net` |
| `all` | `run_all` (`scripts/lab/install.sh`) | `./larcerto.sh all [--from <etapa>]`: sobe o projeto inteiro em 15 etapas, sem apagar nada: `prep` → `prechecks` → `deploy` → `post-deploy` → `prereqs` → `start` → `bootstrap` → `terraform` → `nuvem` → `app` → `dns-host` → `checks` → `cert-cloud` → `deploy-https` → `https-cloud`. Falhou: mostra a etapa e `all --from <etapa>`. Numa máquina nova, rode antes `./larcerto.sh venv` e `./larcerto.sh bootstrap`. Repetir com a nuvem no ar corta a rede das VMs até o `deploy` recriar o OVS |
| `clear-all` | `clear_all` (`scripts/lab/install.sh`) | `./larcerto.sh clear-all [--yes]`: **apaga** o projeto inteiro e não sobe nada de volta (não é um reinício; para subir de novo, `./larcerto.sh all`). Sem `--yes`, mostra o que sai e o que fica e pede para digitar yes (qualquer outra resposta cancela). 9 etapas: `start` (só com containers do Kolla e `terraform/terraform.tfstate`: a API precisa responder) → `destroy-app` (`terraform destroy -auto-approve` como `devops1`) → `dns-host` (`resolvectl revert br-ex`) → `ext-net` (`ext-net --down`, se a `br-ex` existe) → `kolla` (`kolla-ansible destroy --yes-i-really-really-mean-it`, sem `--include-images`: containers, volumes e `/etc/kolla/<serviço>`) → `app-local` (containers do projeto Compose `larcerto`, volumes `larcerto_db_data` e `larcerto_uploads`, imagens `larcerto-web` e `larcerto-tests`) → `files` (`terraform/terraform.tfstate` e `terraform/terraform.tfstate.backup`, `ansible/inventory/hosts.ini`, `cloud/secrets/clouds.yaml`, `cloud/secrets/devops1.password`, `kolla-config/clouds.yaml`, `kolla-config/*-openrc*.sh` e tudo em `ansible/files/pki/` menos o `.gitkeep`: a CA morre) → `trust` (`certutil -D` da `CA LarCerto` em cada banco NSS) → `cabo` (`fix-wired`). Ficam: `kolla-config/passwords.yml`, `kolla-config/globals.yml`, `app/.env`, `ansible/group_vars/all/secrets.yml`, a chave SSH, o venv, o Terraform e as imagens do Kolla. `start`, `destroy-app`, `dns-host`, `ext-net` e `trust` pulam (`pulado:`) o que já não existe, e as outras não falham quando o que apagam já sumiu; então, se uma etapa falhar, `./larcerto.sh clear-all --yes` continua. O `cleanup-host` do Kolla apaga **todos** os network namespaces e as interfaces `tap*`, `brq*` e `vxlan*` do host |
| `stop-kolla` | `cmd_kolla` | → `kolla_run stop` |
| `help` | `usage` | Ajuda |

### Detalhe por comando

#### `cmd_prep` (`prep`)

1. Chama `cmd_dummy0`
2. Chama `cmd_fix_ovs`
3. Indica o fluxo: bootstrap → prechecks → deploy → post-deploy

Usar antes do 1.º deploy ou após conflito com OVS do host.

#### `cmd_dummy0` (`dummy0`)

- Se a interface externa não existir: `ip link add … type dummy`
- Garante que está UP (`ip link set … up`)
- Usa `run_as_root` só quando necessário

#### `cmd_fix_ovs` (`fix-ovs`)

1. `systemctl stop/disable openvswitch-switch` no host
2. Limpa pidfiles/sockets em `/run/openvswitch`
3. `docker rm -f openvswitch_db openvswitch_vswitchd` (recriados no próximo deploy)

#### `cmd_fix_wired` (`fix-wired`)

1. Valida que `network_interface` ≠ `neutron_external_interface`
2. Se `openvswitch_db` estiver Up e a NIC de gestão estiver em `br-ex`: `ovs-vsctl del-port br-ex <nic>`
3. `network_interface` virtual (padrão `dummy1`): imprime `pulado: network_interface virtual (<if>)` e sai 0, sem `nmcli`
4. Placa física: ativa a ligação NetworkManager (`nmcli connection up` ou `nmcli device connect`)
5. Falha (exit 1) se a NIC física ficar sem IPv4, se as duas interfaces forem iguais ou se não houver `nmcli`

Também corre automaticamente no fim de `deploy` / `all` / `post-deploy` / `start`.

#### `cmd_test_ovs` (`test-ovs`)

Verifica:

- OVS do host **inactive**
- Containers `openvswitch_db` e `openvswitch_vswitchd` Up
- `ovs-vsctl --no-wait show` (mesmo check do Kolla)
- Conteúdo de `/run/openvswitch`
- NIC de gestão **não** em `br-ex` (modo fail)

Exit 1 se algum check falhar.

#### `cmd_fix_horizon` (`fix-horizon`)

`docker rm -f horizon` para desbloquear recreate com erro 409. Depois: `./larcerto.sh deploy`.

#### `cmd_status` (`status`)

Imprime:

- Interfaces lidas de `globals.yml`
- Estado de `dummy0` / cabo
- `openvswitch-switch` no host
- Containers OVS e Horizon
- Aviso se gestão estiver em `br-ex`
- HTTP no VIP Horizon (`http://<kolla_internal_vip_address>/auth/login/`, default `10.99.0.250`)

#### `cmd_stop` (`stop`)

Para o lab de forma que **não volte no boot**. Opções:

| Opção | Efeito |
|-------|--------|
| `--remove` | Após parar, remove todos os containers (`docker rm`); o próximo passo é `deploy` |
| `--disable-kolla-services` | Aceite por compatibilidade; já é o comportamento padrão |

Fluxo: `systemctl stop` + `disable` das unidades `kolla-*` → `docker stop` → `docker update --restart=no` (salvo `--remove`).

Reboot **sem** `stop` continua a subir o lab (unidades Kolla ainda enabled).

#### `cmd_ext_net` (`ext-net`)

Equivalente automatizado do que o professor refaz à mão no DevStack após reboot (M06/M07):

1. Espera a `br-ex` existir (até `EXT_NET_WAIT`, padrão 30 s)
2. `ip addr add 172.24.4.1/24 dev br-ex` (se ainda não tiver) e `ip link set br-ex up`
3. `net.ipv4.ip_forward=1` (se estiver 0)
4. Regras com comentário `lab-ext-net`: `MASQUERADE` de `172.24.4.0/24` saindo pela placa da rota padrão (`ip route get 1.1.1.1`: cabo ou Wi-Fi; nunca a `dummy1`), e `ACCEPT` de/para a `br-ex` na posição 1 da chain `DOCKER-USER` (se o Docker gerir o iptables) ou do `FORWARD`. Neste host o Docker roda com `"iptables": false` e é o **UFW** que deixa o `FORWARD` em `DROP`; depois de um `ufw reload`, se as regras sumirem rode `ext-net`; se ficarem atrás das do UFW rode `ext-net --down` e `ext-net` (o `-C` acha a regra existente e não a recoloca na posição 1)
5. Idempotente: cada regra só é inserida se `iptables -C` não a encontrar; antes, tira as regras `lab-ext-net` que citam outra placa (a rota padrão mudou, cabo ↔ Wi-Fi)
6. Sem rota padrão: `Erro: sem rota padrao`, sai 1, antes de mexer na `br-ex`

`ext-net --down` remove pelo comentário todas as regras `lab-ext-net` (mesmo se a interface mudou) e o IP. Não desfaz `ip_forward`, de que o Docker também depende. Nada disso persiste no reboot; o `start` reaplica. Uma falha em qualquer comando faz o `ext-net` retornar 1 e o `start`/`deploy` mostrar `AVISO`.

#### `cmd_dns_host` (`dns-host`)

`resolvectl dns br-ex <ip>` + `resolvectl domain br-ex ~larcerto.com.br`: só o domínio do lab passa a ser resolvido pela VM `dns`; o resto continua no DNS atual. Sem argumento, lê o IP da VM `dns` de `ansible/inventory/hosts.ini` (gerado pelo Terraform). `--down` faz `resolvectl revert br-ex`. Não persiste no reboot.

#### `cmd_start` (`start`)

Sobe um lab **já deployado**, sem `kolla-ansible deploy`:

1. Falha se não houver containers com label `kolla_version` (ex.: após `stop --remove`)
2. Recria/ativa `dummy0` (some no reboot)
3. `systemctl enable --now` nas unidades `kolla-*`
4. `stop_host_libvirt` (root): para o libvirt do host, que volta a cada boot; se o `nova_libvirt` já estava Up, reinicia `nova_libvirt` e depois `nova_compute`
5. `docker start` nos containers Kolla ainda parados
6. `cmd_ext_net` (falha vira AVISO)
7. `cmd_fix_wired` (cabo fora do `br-ex`)
8. `wait_vip`: espera o Keystone responder em `http://<VIP>:5000/` (até `VIP_WAIT`, padrão 90 s). Reativar o cabo tira o VIP por alguns segundos (o `keepalived` devolve depois); sem essa espera, o Terraform logo em seguida falha com `no route to host`. Sem resposta no prazo: `AVISO: a API em <VIP>:5000 nao respondeu...` e o `start` sai ≠ 0

---

## Kolla (`scripts/kolla/kolla.sh`)

Os comandos `bootstrap`, `prechecks`, `deploy`, `post-deploy` e `stop-kolla` rodam `kolla-ansible` com inventário, `kolla-config` e facts do Zorin. Variáveis de ambiente (padrões entre parênteses):

| Variável | Padrão | Uso |
|----------|--------|-----|
| `VENV_PATH` | `$HOME/venvs/kolla` | Venv com `kolla-ansible`, `ansible` e os módulos `docker` e `dbus` (criado por `venv`) |
| `VENV_PYTHON` | `python3` | Python usado pelo `venv` para criar o venv (ex.: `python3.12`) |
| `KOLLA_BIN` | `${VENV_PATH}/bin/kolla-ansible` | Executável do kolla-ansible |
| `INVENTORY` | `all-in-one` | Inventário Ansible |
| `CONFIG_DIR` | `kolla-config` | Pasta com `globals.yml` e demais configs |
| `PASSWORDS_FILE` | `${CONFIG_DIR}/passwords.yml` | Senhas (nunca copiar valores para docs) |
| `EXTRA_VARS` | vazio | Passado com `-e` ao kolla-ansible |
| `FORCE_UBUNTU_FACTS` | `true` | Em Zorin OS, gera facts completos e ajusta distro/família |
| `USE_TEST_IMAGES` | `true` | Adiciona `--use-test-images` no `prechecks` |
| `AUTO_STOP_HOST_LIBVIRT` | `true` | Para o libvirt do host (`stop_host_libvirt`) antes de cada etapa do Kolla e no `start` (conflita com o `nova_libvirt`) |
| `OS_RELEASE` | `/etc/os-release` | Arquivo lido para detectar Zorin |

Ordem das etapas: `bootstrap` = `bootstrap-servers`; os demais rodam a própria ação. Os arquivos temporários de facts são removidos ao sair do `larcerto.sh`, mesmo se o kolla-ansible falhar.

## Testes

`bash tests/test-scripts.sh [teste ...]` testa `larcerto.sh` e os módulos de `scripts/` com comandos falsos no `PATH` (nada toca o host; não rodar como root).

## Exemplos

```bash
chmod +x larcerto.sh
./larcerto.sh prep
./larcerto.sh bootstrap && ./larcerto.sh prechecks && ./larcerto.sh deploy
./larcerto.sh post-deploy
./larcerto.sh test-ovs
./larcerto.sh fix-wired
./larcerto.sh status
./larcerto.sh stop
./larcerto.sh start
```
