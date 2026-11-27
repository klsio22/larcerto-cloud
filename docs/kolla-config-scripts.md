# Scripts e credenciais em `kolla-config/`

Pasta: [`../kolla-config/`](../kolla-config/).

Os ficheiros `*-openrc.sh` e `clouds.yaml` são **gerados pelo Kolla** no `post-deploy` (marcados `# Ansible managed`). Não editar à mão — regenerar com:

```bash
./larcerto.sh post-deploy
```

**Contêm senhas.** Não partilhar; preferir não commitar em repositórios públicos.

## OpenRC (`source`)

Cada script limpa variáveis `OS_*` antigas e exporta as novas para a CLI OpenStack (`openstack`, `nova`, etc.).

| Ficheiro | Scope | Interface | Uso típico |
|----------|-------|-----------|------------|
| `admin-openrc.sh` | Project `admin` | internal (`OS_INTERFACE` / `OS_ENDPOINT_TYPE`) | Admin no projeto; API interna |
| `admin-openrc-system.sh` | System (`OS_SYSTEM_SCOPE=all`) | internal | Operações de sistema (admin de plataforma) |
| `public-openrc.sh` | Project `admin` | pública (sem `OS_INTERFACE` internal) | Admin via endpoint público |
| `public-openrc-system.sh` | System | pública | System scope via endpoint público |

Variáveis comuns (nomes, não valores):

- `OS_AUTH_URL` — Keystone (VIP do lab, porta 5000)
- `OS_USERNAME` / `OS_PASSWORD` — admin (senha alinhada a `keystone_admin_password` em `passwords.yml`)
- `OS_IDENTITY_API_VERSION=3`, `OS_REGION_NAME`, `OS_AUTH_PLUGIN=password`

### Como usar

```bash
source kolla-config/admin-openrc.sh
openstack token issue
```

## `clouds.yaml`

Ficheiro: `../kolla-config/clouds.yaml`.

Define clouds nomeadas para a CLI moderna (`OS_CLOUD`):

| Cloud | Equivalente aproximado |
|-------|------------------------|
| `kolla-admin` | admin, project scope |
| `kolla-admin-system` | admin, system scope |
| `kolla-admin-internal` | admin + `interface: internal` |
| `kolla-admin-system-internal` | system scope + internal |

```bash
export OS_CLOUD=kolla-admin
# ou: OS_CLOUD=kolla-admin-internal
openstack server list
```

A CLI procura `clouds.yaml` em `~/.config/openstack/` ou via `OS_CLIENT_CONFIG_FILE`. Para usar o ficheiro do projeto:

```bash
export OS_CLIENT_CONFIG_FILE="$(pwd)/kolla-config/clouds.yaml"
export OS_CLOUD=kolla-admin
```

## Config (não são scripts)

| Ficheiro | Papel |
|----------|-------|
| [`globals.yml`](../kolla-config/globals.yml) | Distro, interfaces, VIP, enable/disable de serviços |
| `passwords.yml` | Senhas dos serviços (incl. Horizon / Keystone admin) |

Detalhes de rede e deploy: [`../README.md`](../README.md) e [`topologia-aio.md`](topologia-aio.md).
