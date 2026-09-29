# `run-kolla.sh`

Wrapper para executar `kolla-ansible` com os caminhos deste projeto. Normalmente chamado via [`lab.sh`](lab.sh.md) (`bootstrap`, `deploy`, etc.); também pode ser invocado diretamente.

```bash
./project/run-kolla.sh {all|bootstrap|prechecks|deploy|post-deploy|stop}
```

Código: [`../run-kolla.sh`](../run-kolla.sh).

## Paths e variáveis de ambiente

| Variável | Default | Uso |
|----------|---------|-----|
| `VENV_PATH` | `$HOME/venvs/kolla` | Virtualenv com `kolla-ansible` |
| `KOLLA_BIN` | `${VENV_PATH}/bin/kolla-ansible` | Binário Kolla |
| `INVENTORY` | `project/all-in-one` | Inventário Ansible AIO |
| `CONFIG_DIR` | `project/kolla-config` | `--configdir` |
| `PASSWORDS_FILE` | `kolla-config/passwords.yml` | `--passwords` |
| `EXTRA_VARS` | (vazio) | Extra vars Ansible (`-e`) |
| `FORCE_UBUNTU_FACTS` | `true` | Em Zorin OS, normaliza facts para Ubuntu/Noble |
| `USE_TEST_IMAGES` | `true` | Em `prechecks`, passa `--use-test-images` |
| `AUTO_STOP_HOST_LIBVIRT` | `true` | Para libvirtd/virtlogd do host antes do step |

Também resolve `ORIGINAL_USER` / `ORIGINAL_HOME` (respeita `SUDO_USER`) para manter `HOME` e collections Ansible corretos quando corre como root.

Pré-condições: `KOLLA_BIN` executável, inventory, `CONFIG_DIR` e `PASSWORDS_FILE` existentes — senão exit 1.

## Funções

### `run_as_root`

Mesma estratégia que em `lab.sh`: root → sudo NOPASSWD → Docker+nsenter → sudo interativo.

### `run_step <step>`

Executa um passo `kolla-ansible`:

1. **Libvirt do host** — se `AUTO_STOP_HOST_LIBVIRT=true` e houver socket/serviço ativo, para `libvirtd` / `virtlogd` (evita conflito com Nova/libvirt em container).
2. **Deps Python no venv** — garante `docker` e `dbus-python` via pip se o import falhar.
3. **Facts Zorin → Ubuntu** — se `/etc/os-release` for Zorin e `FORCE_UBUNTU_FACTS=true`, gera facts Ansible normalizados (`distribution=Ubuntu`, `noble`, etc.) e passa `-e @<facts_file>`.
4. **Comando Kolla** — `kolla-ansible <step> -i … --configdir … --passwords …`, com root via `run_as_root` e env (`PATH` do venv, `HOME`, collections).
5. Limpa o ficheiro temporário de facts.

## Ações CLI

| Argumento | Step(s) Kolla |
|-----------|----------------|
| `bootstrap` | `bootstrap-servers` |
| `prechecks` | `prechecks` (+ `--use-test-images` se `USE_TEST_IMAGES=true`) |
| `deploy` | `deploy` |
| `post-deploy` | `post-deploy` (gera openrc / `clouds.yaml` em `kolla-config/`) |
| `stop` | `stop` |
| `all` | `bootstrap-servers` → `prechecks` → `deploy` |

Qualquer outro argumento imprime uso e exit 1.

## Relação com `lab.sh`

| Via `lab.sh` | Chama |
|--------------|------|
| `lab.sh bootstrap` | `run-kolla.sh bootstrap` |
| `lab.sh prechecks` | `run-kolla.sh prechecks` |
| `lab.sh deploy` | `run-kolla.sh deploy` + `fix-wired` |
| `lab.sh post-deploy` | `run-kolla.sh post-deploy` + `fix-wired` |
| `lab.sh all` | `run-kolla.sh all` + `fix-wired` |
| `lab.sh stop-kolla` | `run-kolla.sh stop` |

Nota: `lab.sh stop` **não** chama este script — para containers/serviços localmente. Para o stop oficial do Kolla, usar `lab.sh stop-kolla`.

## Exemplos

```bash
source ~/venvs/kolla/bin/activate
./project/run-kolla.sh bootstrap
./project/run-kolla.sh prechecks
./project/run-kolla.sh deploy
./project/run-kolla.sh post-deploy

# Atalho equivalente (sem fix-wired automático):
./project/run-kolla.sh all
```

Preferir `./project/lab.sh …` no dia a dia (inclui `fix-wired` após deploy).
