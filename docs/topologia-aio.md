# Topologia AIO — host Kolla + 4 VMs (REQ09)

Mapa aula → passo do lab. Deploy **manual** pelo aluno (não pelo agente). O desenho de rede
completo (router, redes e floating IPs) está em [`../docs/nuvem-larcerto.md`](nuvem-larcerto.md#topologia-req09-completa).

## Desenho

```
Host (Zorin) — cliente: Firefox/Brave e terminal (SSH)
├─ cabo ou Wi-Fi … só internet do host e saída (NAT) das VMs; o lab não mexe nelas
├─ dummy1 ……… network_interface: rede só do host 10.99.0.1/24, VIP 10.99.0.250
├─ dummy0 ……… neutron_external_interface (não toca placa real)
├─ br-ex ………… 172.24.4.1/24 + NAT pela rota padrão (larcerto.sh ext-net): host alcança os floating IPs
└─ Kolla AIO (containers)
     ├─ Horizon / APIs (HAProxy no VIP; https://cloud.larcerto.com.br) ← REQ12
     └─ Projeto OpenStack larcerto, usuário devops1                  ← REQ13
          rede public 172.24.4.0/24 → larcerto-router → larcerto-net 10.11.12.0/24
          ├─ VM dns  10.11.12.10 (bind9, *.larcerto.com.br)   ← REQ10
          ├─ VM ca   10.11.12.11 (CA easy-rsa)                ← REQ11
          ├─ VM db   10.11.12.12 (MariaDB)                    ← REQ15
          └─ VM web  10.11.12.13 (Apache/PHP CRUD)            ← REQ14, REQ16
     cada VM com floating IP da public (pool .100–.199); db só aceita a 3306 da larcerto-net
```

No REQ09 isto é a topologia **completa** (uma VM por serviço). A "ideal" do enunciado põe DNS e
CA num servidor separado, fora do OpenStack; aqui eles ficam como VMs do projeto.

Portas: ver [`ports.md`](ports.md).

## Por que dummy1 + dummy0 (modo isolado)

| Variável Kolla | Valor | Efeito |
|----------------|-------|--------|
| `network_interface` | `dummy1` | APIs/VIP numa rede só do host; cabo e Wi-Fi **não são tocados** |
| `neutron_external_interface` | `dummy0` | Neutron não assume a NIC física |
| `kolla_internal_vip_address` | `10.99.0.250` | Endpoint Horizon/APIs; o host fica com `10.99.0.1/24` na `dummy1` |

Antes (até 26/11/2026) o VIP ficava no cabo (`enp9s0`, `192.168.1.250`): outra máquina tinha de trocar a
placa e o IP, e um notebook só com Wi-Fi teria o VIP anunciado na rede sem fio. Agora nenhuma placa real
recebe IP do lab; as VMs saem para a internet pelo NAT do `ext-net`, pela placa da rota padrão (cabo ou
Wi-Fi). Colocar uma placa real em `neutron_external_interface` (ou no `br-ex` do OVS) continua derrubando a
rede: a externa é sempre a `dummy0`. O `fix-wired` só age se `network_interface` for uma placa física.

## Aula → passo

| Módulo | Foco | Passo neste lab |
|--------|------|-----------------|
| 06 | Implantar nuvem privada | Preparar host, `dummy0`, `larcerto.sh` Kolla (bootstrap → deploy) |
| 07 | Projeto e instâncias via Horizon | REQ13–REQ15: projeto `larcerto` (`cloud/bootstrap.sh`) e VMs (Terraform); Horizon para mostrar no vídeo |
| 08 | CLI OpenStack | Alternativa ao Horizon para imagens/flavors/instâncias |
| 09–10 | Terraform / Ansible | `terraform/` cria as 4 VMs, `ansible/` configura dns → ca → db → web (REQ25, usado também no Trabalho 1) |

## Checklist pré-deploy (aluno)

1. Venv Kolla pronto (`./larcerto.sh venv`: cria `~/venvs/kolla` e roda `kolla-ansible install-deps`).
2. Conferir a faixa do VIP livre no host: `ip route | grep '10\.99\.0\.'` vazio antes do primeiro `prep` (VPN ou rede da faculdade na mesma faixa colidiria; depois do `prep` aparece a `dummy1`).
3. Revisar [`../kolla-config/globals.yml`](../kolla-config/globals.yml): `dummy1`, `dummy0`, VIP.
4. Máquina nova: `./larcerto.sh bootstrap` (uma vez).
5. Subir tudo: `./larcerto.sh all` (prep → Kolla → projeto → Terraform → Ansible → HTTPS do Horizon;
   continuar de uma etapa com `--from <etapa>`). O passo `prereqs` avisa se falta o cliente
   `openstack` no venv.
6. Abrir: `https://larcerto.com.br` (app) e `https://cloud.larcerto.com.br` (Horizon), com a CA
   importada (`./larcerto.sh cert trust`).

Estado / parar / subir: `./larcerto.sh status` · `./larcerto.sh vms` · `./larcerto.sh stop` · `./larcerto.sh start-app`

## Pós-nuvem

- REQ01–08: app CRUD PHP + domínio/logo (`app/`)
- REQ10–11: DNS + CA nas VMs `dns` e `ca` (`ansible/`)
- REQ13–16: projeto + 4 VMs (`terraform/`) + app HTTP/HTTPS (`ansible/`)
- REQ17–24: vídeo e envio no Moodle (aluno)
