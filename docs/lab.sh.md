# `lab.sh`

Entrypoint único do lab AIO (dummy0, OVS host, testes, stop/start, fixes e deploy Kolla).

```bash
./project/lab.sh <comando> [opções]
```

Código: [`../lab.sh`](../lab.sh). Helpers compartilhados com o `run-kolla.sh` ficam em [`../lib/common.sh`](../lib/common.sh), carregado com `source`.

## Variáveis e paths

| Variável | Valor | Uso |
|----------|-------|-----|
| `SCRIPT_DIR` | pasta `project/` | Base dos scripts |
| `GLOBALS_YML` | `kolla-config/globals.yml` | Lê `network_interface`, `neutron_external_interface` e `kolla_internal_vip_address` (definido em `lib/common.sh`) |
| `DOCKER` | array (`docker` ou `sudo docker`) | Preenchido por `init_docker` |

## Helpers internos

### Em `lib/common.sh` (compartilhados)

- `step <texto>` — imprime o cabeçalho de etapa `==> <texto>`.
- `read_globals <key> <default>` — lê linha ativa `key: value` em `globals.yml` (ignora comentários); imprime o default se ausente.

### `run_as_root` (`lib/common.sh`)

Executa um comando como root, nesta ordem:

1. Já é root (`EUID == 0`)
2. `sudo -n` (NOPASSWD)
3. Docker privilegiado + `nsenter -- <cmd>` no PID 1 (grupo `docker`)
4. `sudo` interativo (pede senha)

### `init_docker` / `docker_cmd` (`lib/common.sh`)

- `init_docker` — define `DOCKER=(docker)` ou `DOCKER=(sudo docker)`; falha se nenhum tiver acesso.
- `docker_cmd` — chama `init_docker` e executa `"${DOCKER[@]}" "$@"`.

### `list_kolla_unit_files`

Lista unidades systemd `kolla-*.service` via `systemctl list-unit-files` (visível mesmo depois de disable/reboot). Usado por `stop` e `start`.

### `network_iface` / `external_iface` / `vip_address`

Leem `globals.yml` via `read_globals`:

- `network_iface` — `network_interface` (default `enp9s0`).
- `external_iface` — `neutron_external_interface` (default `dummy0`).
- `vip_address` — `kolla_internal_vip_address` (default `192.168.1.250`).

### `ovs_db_running` / `br_ex_ports` / `mgmt_on_br_ex`

- `ovs_db_running` — true se o container `openvswitch_db` estiver Up.
- `br_ex_ports` — lista portas do bridge `br-ex` via `ovs-vsctl` no container.
- `mgmt_on_br_ex` — true se a NIC de gestão (`network_iface`) estiver em `br-ex`.
- `print_br_ex_ports` — imprime as portas de `br-ex` indentadas, ou `(vazio)`.

### `warn_or_fail_mgmt_on_br_ex`

Modo `warn` ou `fail`. Lista portas de `br-ex`; se a NIC de gestão estiver lá, avisa (e falha no modo `fail`). Sugere `./project/lab.sh fix-wired`.

### `usage`

Imprime help CLI (`help` / `-h` / `--help`).

### `cmd_kolla`

Encaminha a ação para [`run-kolla.sh`](run-kolla.sh.md). Se o Kolla falhar, o `lab.sh` sai com o mesmo código. Se a ação for `deploy`, `all` ou `post-deploy` e o Kolla terminar com sucesso, corre `cmd_fix_wired` automaticamente (NIC de gestão fora do `br-ex`); se o `fix-wired` falhar, imprime `AVISO` no stderr e sai com 0, porque o deploy deu certo.

---

## Comandos públicos

| CLI | Função | O que faz |
|-----|--------|-----------|
| `prep` | `cmd_prep` | `dummy0` + `fix-ovs`; imprime próximo fluxo |
| `dummy0` | `cmd_dummy0` | Cria/ativa a interface externa (`dummy0` ou valor de `globals.yml`) |
| `fix-ovs` | `cmd_fix_ovs` | Para OVS do host, limpa `/run/openvswitch`, remove containers OVS Kolla |
| `fix-wired` | `cmd_fix_wired` | Tira `network_interface` de `br-ex` e reativa o cabo no NetworkManager |
| `test-ovs` | `cmd_test_ovs` | Healthcheck rápido OVS (host, containers, `ovs-vsctl`, alerta cabo em `br-ex`) |
| `fix-horizon` | `cmd_fix_horizon` | Remove container `horizon` (resolve 409 Conflict no recreate) |
| `status` | `cmd_status` | Estado: interfaces, OVS, Horizon, HTTP no VIP |
| `stop` | `cmd_stop` | Para `kolla-*`, desabilita autostart no boot e para containers |
| `start` | `cmd_start` | Sobe o lab já deployado: `dummy0` + `kolla-*` + `fix-wired` |
| `bootstrap` | `cmd_kolla` | → `run-kolla.sh bootstrap` |
| `prechecks` | `cmd_kolla` | → `run-kolla.sh prechecks` |
| `deploy` | `cmd_kolla` | → `run-kolla.sh deploy` + `fix-wired` |
| `post-deploy` | `cmd_kolla` | → `run-kolla.sh post-deploy` + `fix-wired` |
| `all` | `cmd_kolla` | → `run-kolla.sh all` + `fix-wired` |
| `stop-kolla` | `cmd_kolla` | → `run-kolla.sh stop` |
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
3. Ativa a ligação NetworkManager (`nmcli connection up` ou `nmcli device connect`)
4. Falha (exit 1) se a NIC ficar sem IPv4, se as duas interfaces forem iguais ou se não houver `nmcli`

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

`docker rm -f horizon` para desbloquear recreate com erro 409. Depois: `./project/lab.sh deploy`.

#### `cmd_status` (`status`)

Imprime:

- Interfaces lidas de `globals.yml`
- Estado de `dummy0` / cabo
- `openvswitch-switch` no host
- Containers OVS e Horizon
- Aviso se gestão estiver em `br-ex`
- HTTP no VIP Horizon (`http://<kolla_internal_vip_address>/auth/login/`, default `192.168.1.250`)

#### `cmd_stop` (`stop`)

Para o lab de forma que **não volte no boot**. Opções:

| Opção | Efeito |
|-------|--------|
| `--remove` | Após parar, remove todos os containers (`docker rm`); o próximo passo é `deploy` |
| `--disable-kolla-services` | Aceite por compatibilidade; já é o comportamento padrão |

Fluxo: `systemctl stop` + `disable` das unidades `kolla-*` → `docker stop` → `docker update --restart=no` (salvo `--remove`).

Reboot **sem** `stop` continua a subir o lab (unidades Kolla ainda enabled).

#### `cmd_start` (`start`)

Sobe um lab **já deployado**, sem `kolla-ansible deploy`:

1. Falha se não houver containers com label `kolla_version` (ex.: após `stop --remove`)
2. Recria/ativa `dummy0` (some no reboot)
3. `systemctl enable --now` nas unidades `kolla-*`
4. `docker start` nos containers Kolla ainda parados
5. `cmd_fix_wired` (cabo fora do `br-ex`)

---

## Testes

`bash project/tests/test-scripts.sh [teste ...]` testa `lab.sh` e `run-kolla.sh` com comandos falsos no `PATH` (nada toca o host; não rodar como root).

## Exemplos

```bash
chmod +x project/lab.sh
./project/lab.sh prep
./project/lab.sh bootstrap && ./project/lab.sh prechecks && ./project/lab.sh deploy
./project/lab.sh post-deploy
./project/lab.sh test-ovs
./project/lab.sh fix-wired
./project/lab.sh status
./project/lab.sh stop
./project/lab.sh start
```
