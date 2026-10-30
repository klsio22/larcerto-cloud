# Documentação dos scripts do lab

Referência dos scripts shell do lab OpenStack AIO. O guia operacional (como subir a nuvem) está em [`../README.md`](../README.md).

## Índice

| Script / ficheiro | Papel | Doc |
|-------------------|-------|-----|
| [`../lab.sh`](../lab.sh) | Entrypoint único: prep, deploy, fixes, status, stop, start | [`lab.sh.md`](lab.sh.md) |
| [`../run-kolla.sh`](../run-kolla.sh) | Wrapper do `kolla-ansible` (inventário + `kolla-config`) | [`run-kolla.sh.md`](run-kolla.sh.md) |
| [`../kolla-config/*-openrc*.sh`](../kolla-config/) | Credenciais CLI OpenStack (`source`) | [`kolla-config-scripts.md`](kolla-config-scripts.md) |
| [`../kolla-config/clouds.yaml`](../kolla-config/clouds.yaml) | Clouds para `OS_CLOUD=…` | [`kolla-config-scripts.md`](kolla-config-scripts.md) |
| Tema Horizon Lux | Cores/layout custom (herda default) | [`horizon-theme-lux.md`](horizon-theme-lux.md) |

## Fluxo

```mermaid
flowchart LR
  labSh["lab.sh"] --> helpers["helpers internos"]
  labSh --> cmds["comandos prep/fix/status/stop/start"]
  labSh --> kollaFwd["deploy/bootstrap/..."]
  kollaFwd --> runKolla["run-kolla.sh"]
  runKolla --> kollaCfg["kolla-config/"]
  runKolla --> openrc["*-openrc.sh / clouds.yaml"]
```

1. O aluno usa **`lab.sh`** (prep, bootstrap, deploy, status, fixes).
2. Comandos Kolla (`bootstrap`, `prechecks`, `deploy`, `post-deploy`, `all`, `stop-kolla`) são encaminhados para **`run-kolla.sh`**.
3. O Kolla lê **`kolla-config/`** (`globals.yml`, `passwords.yml`).
4. Após **`post-deploy`**, o Ansible gera `*-openrc.sh` e `clouds.yaml` para a CLI OpenStack.

**Sem senhas nestes docs.** Valores reais estão em `passwords.yml` / openrc / `clouds.yaml` — não partilhar.
