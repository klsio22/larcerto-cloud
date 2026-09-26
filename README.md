# Projeto OpenStack — Computação em Nuvem (TSI36C-EAD)

Labs e entrega do **Trabalho 1** (nuvem privada + app web CRUD).

## Fontes

1. **Videoaulas 06–10** — [`transcricoes/`](../transcricoes/) · links em [`videos/README.md`](../videos/README.md)
2. **Enunciado** — [`enunciado-trabalho-1.md`](enunciado-trabalho-1.md) (REQ01–REQ24; substitutivo + REQ25)
3. **OpenStack com containers** — [`kolla-ansible-quickstart.md`](kolla-ansible-quickstart.md)

Não inventar passos além das aulas e do enunciado. Se faltar transcrição, avisar.

## Estrutura

```
project/
  README.md
  enunciado-trabalho-1.md
  notes/          # aula → passo do lab
  # (futuro) configs OpenStack, Terraform, Ansible, app CRUD
```

## Fluxo

1. Assistir / transcrever módulos relevantes
2. Anotar em `notes/`
3. Implementar topologia e app conforme REQs
4. Gravar vídeo de demonstração (5–7 min)

## Como rodar o Kolla no projeto (conforme docs oficiais)

Baseado no quickstart de desenvolvimento do Kolla-Ansible, a ordem de execucao e:
`bootstrap-servers` -> `prechecks` -> `deploy` -> `post-deploy`.

No repositorio, essa sequencia ja esta encapsulada em `run-kolla.sh` usando:
- inventario: `project/all-in-one`
- configuracao: `project/kolla-config/`

### 1) Preparar ambiente Python

```bash
python3 -m venv ~/venvs/kolla
source ~/venvs/kolla/bin/activate
pip install -U pip
pip install git+https://opendev.org/openstack/kolla-ansible@master
kolla-ansible install-deps
```

### 2) Revisar configuracao local

Antes do deploy, ajuste em `project/kolla-config/globals.yml`:
- `network_interface`
- `neutron_external_interface`
- `kolla_internal_vip_address`

### 3) Executar deploy

```bash
./project/run-kolla.sh all
```

Ou em etapas:

```bash
./project/run-kolla.sh bootstrap
./project/run-kolla.sh prechecks
./project/run-kolla.sh deploy
```

### 4) Pos-deploy e uso do OpenStack

```bash
./project/run-kolla.sh post-deploy
pip install python-openstackclient -c https://releases.openstack.org/constraints/upper/master
```

Depois, use o `clouds.yaml` gerado no pos-deploy para autenticar o cliente OpenStack.
