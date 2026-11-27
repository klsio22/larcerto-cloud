# Documentação dos scripts do lab

Referência dos scripts shell do lab OpenStack AIO. O guia operacional (como subir a nuvem) está em [`../README.md`](../README.md).

## Índice

| Script / ficheiro | Papel | Doc |
|-------------------|-------|-----|
| [`../larcerto.sh`](../larcerto.sh) | Entrypoint único: sobe tudo (`all`), Kolla, app na nuvem, certificados, VMs, fixes, `clear-all` (`./larcerto.sh help`) | [`larcerto.sh.md`](larcerto.sh.md) |
| [`../scripts/`](../scripts/) | Módulos carregados pelo `larcerto.sh` (`common.sh`, `lab/`, `kolla/`) | [`larcerto.sh.md`](larcerto.sh.md) |
| Passo a passo do Trabalho 1 | Do lab ligado até `https://larcerto.com.br` | [`nuvem-larcerto.md`](nuvem-larcerto.md) |
| Topologia (REQ09) | Host, Kolla, projeto `larcerto`, 4 VMs; mapa aula → passo | [`topologia-aio.md`](topologia-aio.md) |
| [`../kolla-config/*-openrc*.sh`](../kolla-config/) | Credenciais CLI OpenStack (`source`) | [`kolla-config-scripts.md`](kolla-config-scripts.md) |
| `../kolla-config/clouds.yaml` | Clouds para `OS_CLOUD=…` | [`kolla-config-scripts.md`](kolla-config-scripts.md) |
| Enunciado Trabalho 1 | REQ01–REQ24 + substitutivo REQ25, com o texto original do Moodle | [`enunciado-trabalho-1.md`](enunciado-trabalho-1.md) |
| Quickstart Kolla | Referência do Kolla-Ansible em containers | [`kolla-ansible-quickstart.md`](kolla-ansible-quickstart.md) |
| Portas | VIP, containers Kolla e app do trabalho | [`ports.md`](ports.md) |
| Tema Horizon Lux | Cores/layout custom (herda default) | [`horizon-theme-lux.md`](horizon-theme-lux.md) |

## Fluxo

```mermaid
flowchart LR
  labSh["larcerto.sh"] --> common["scripts/common.sh"]
  labSh --> lab["scripts/lab/ (rede, ovs, ciclo, install, cert, vms)"]
  labSh --> kolla["scripts/kolla/kolla.sh"]
  kolla --> kollaCfg["kolla-config/"]
  kolla --> openrc["*-openrc.sh / clouds.yaml"]
```

1. O aluno usa **`larcerto.sh`** (`all` sobe tudo; `status`, `vms`, `cert`, fixes).
2. Comandos Kolla (`bootstrap`, `prechecks`, `deploy`, `post-deploy`, `stop-kolla`) são executados por **`scripts/kolla/kolla.sh`**, sempre pelo `larcerto.sh`.
3. O Kolla lê **`kolla-config/`** (`globals.yml`, `passwords.yml`).
4. Após **`post-deploy`**, o Ansible gera `*-openrc.sh` e `clouds.yaml` para a CLI OpenStack.

**Sem senhas nestes docs.** Valores reais estão em `passwords.yml` / openrc / `clouds.yaml` — não partilhar.
