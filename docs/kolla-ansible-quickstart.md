# Kolla-Ansible Quick Start (Projeto)

Guia prático para instalar OpenStack com `kolla-ansible` em ambiente de estudo, seguindo a estrutura da documentação oficial.

> Escopo: ambiente de avaliacao/lab em **no unico** (`all-in-one`), nao producao.

## 1) Visao geral

`kolla-ansible` faz deploy dos servicos do OpenStack em containers Docker, automatizados via Ansible.  
Para este projeto, isso ajuda a montar uma nuvem privada reproduzivel para os requisitos do trabalho.

## 2) Requisitos minimos

- Host Linux suportado (Ubuntu recomendado para estudo)
- 8 GB RAM (recomendado 12+ GB para folga)
- 40 GB disco (recomendado 80+ GB)
- 2 interfaces de rede (ou ajuste para seu lab local)
- Acesso `sudo`
- Virtualizacao habilitada (se for criar VMs no compute local)

## 3) Dependencias do sistema (Ubuntu/Debian)

```bash
sudo apt update
sudo apt install -y git python3-dev python3-venv libffi-dev gcc libssl-dev libdbus-glib-1-dev
```

## 4) Criar e ativar ambiente virtual Python

```bash
python3 -m venv ~/venvs/kolla
source ~/venvs/kolla/bin/activate
pip install -U pip
```

> Sempre rode comandos de `kolla-ansible` com o venv ativo.

## 5) Instalar Kolla-Ansible

```bash
pip install git+https://opendev.org/openstack/kolla-ansible@master
```

Criar estrutura de configuracao:

```bash
sudo mkdir -p /etc/kolla
sudo chown "$USER:$USER" /etc/kolla
cp -r ~/venvs/kolla/share/kolla-ansible/etc_examples/kolla/* /etc/kolla
cp ~/venvs/kolla/share/kolla-ansible/ansible/inventory/all-in-one .
```

Instalar colecoes Ansible Galaxy exigidas:

```bash
kolla-ansible install-deps
```

## 6) Configuracao inicial

### 6.1) Gerar senhas

```bash
kolla-genpwd
```

Isso preenche `/etc/kolla/passwords.yml`.

### 6.2) Ajustar `/etc/kolla/globals.yml`

Campos essenciais para um lab `all-in-one`:

```yaml
kolla_base_distro: "ubuntu"
network_interface: "eth0"
neutron_external_interface: "eth1"
kolla_internal_vip_address: "10.1.0.250"
```

Notas importantes:

- `network_interface`: interface de gerenciamento.
- `neutron_external_interface`: interface externa do Neutron; idealmente ativa e **sem IP**.
- `kolla_internal_vip_address`: IP livre na rede de gerenciamento.

## 7) Deploy do OpenStack

Execute na ordem:

```bash
kolla-ansible bootstrap-servers -i ./all-in-one
kolla-ansible prechecks -i ./all-in-one
kolla-ansible deploy -i ./all-in-one
```

Se os `prechecks` falharem, corrija primeiro rede/interface/VIP e execute novamente.

### 7.1) Comandos equivalentes neste repositorio

Este projeto ja inclui inventario (`project/all-in-one`) e config (`project/kolla-config/`).
Para usar exatamente essa estrutura:

```bash
./project/lab.sh all
```

Esse comando sobe o projeto inteiro (OpenStack, nuvem, app e HTTPS do Horizon) e continua de uma etapa com `./project/lab.sh all --from <etapa>`. Numa máquina nova, rode antes `./project/lab.sh bootstrap`.

Só o OpenStack, em etapas:

```bash
./project/lab.sh bootstrap
./project/lab.sh prechecks
./project/lab.sh deploy
```

## 8) Pos-deploy e uso inicial

Gerar arquivo de credenciais (`clouds.yaml`):

```bash
kolla-ansible post-deploy
```

No repositorio:

```bash
./project/lab.sh post-deploy
```

Instalar cliente OpenStack:

```bash
pip install python-openstackclient -c https://releases.openstack.org/constraints/upper/master
```

Disponibilizar `clouds.yaml`:

```bash
mkdir -p ~/.config/openstack
cp /etc/kolla/clouds.yaml ~/.config/openstack/clouds.yaml
```

Teste rapido:

```bash
openstack --os-cloud kolla-admin token issue
```

## 9) Script de demo (opcional)

O `init-runonce` cria recursos de exemplo (rede, imagem etc.) e pode conflitar com customizacoes do seu ambiente.

```bash
~/venvs/kolla/share/kolla-ansible/init-runonce
```

Use apenas se voce quiser um bootstrap de demonstracao.

## 10) Problemas comuns

- **Interface externa com IP**: remove acesso externo das instancias em varios cenarios.
- **VIP em uso**: causa falha no `prechecks`/`deploy`.
- **Memoria insuficiente**: containers sobem e caem repetidamente.
- **Mistura de venv e sistema**: comando instalado fora do venv gera erros de dependencia.
- **VMs sem IP (DHCP do Neutron nao sobe)**: ver abaixo.

### VMs sem IP: AppArmor bloqueando o dnsmasq do Neutron

Sintomas:

- o Ansible para em `Esperar SSH` com `No route to host` nos floating IPs;
- o console da VM (`openstack console log show <vm>`) mostra a `ens3` so com `fe80::` e o cloud-init termina com `DataSourceNone` (sem IP, sem metadata, sem chave SSH);
- o log do agente (`docker exec neutron_dhcp_agent tail /var/log/kolla/neutron/neutron-dhcp-agent.log`) repete `Failed to start DHCP process ... Timed out after 60 seconds`;
- o conteiner `neutron_dhcp_agent_dnsmasq_qdhcp-<id>` sai com codigo 3 (erro de arquivo).

Causa: o pacote `apparmor-profiles` instala `/etc/apparmor.d/usr.sbin.dnsmasq`. O perfil vale para
qualquer `/usr/sbin/dnsmasq`, inclusive dentro do conteiner privilegiado do Kolla, e so libera os
caminhos do dnsmasq do sistema; o dnsmasq do Neutron nao consegue ler `/etc/neutron/dnsmasq.conf`.
O kernel pode nao registrar o bloqueio no log. E o mesmo caso do `usr.sbin.libvirtd`, que ja fica
em `/etc/apparmor.d/disable/`.

Correcao (muda o host; o dnsmasq do libvirt e do Multipass deixam de usar esse perfil):

```bash
sudo ln -s /etc/apparmor.d/usr.sbin.dnsmasq /etc/apparmor.d/disable/
sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.dnsmasq
docker restart neutron_dhcp_agent
openstack server reboot --hard <vm>    # como devops1, para cada VM; o cloud-init roda de novo
```

Rollback (reativa o perfil):

```bash
sudo rm /etc/apparmor.d/disable/usr.sbin.dnsmasq && sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.dnsmasq
```

## 11) Proximos passos para o projeto

Depois do OpenStack no ar, seguir para os requisitos do trabalho:

1. Criar projeto/tenant.
2. Criar redes, roteador e regras de seguranca.
3. Subir VM web e VM banco.
4. Configurar DNS/certificados (quando aplicavel aos REQs).
5. Implantar aplicacao CRUD e demonstrar no video.

## Referencia oficial

- Quick Start for development (inclui deploy e "Using OpenStack"):
  <https://docs.openstack.org/kolla-ansible/latest/user/quickstart-development.html#using-openstack>
