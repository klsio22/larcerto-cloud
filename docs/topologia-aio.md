# Topologia AIO — host Kolla + 4 VMs (REQ09)

Mapa aula → passo do lab. Deploy **manual** pelo aluno (não pelo agente). O desenho de rede
completo (router, redes e floating IPs) está em [`../docs/nuvem-larcerto.md`](nuvem-larcerto.md#topologia-req09-completa).

## Desenho

```
Host (Zorin) — cliente: Firefox/Brave e terminal (SSH)
├─ enp9s0 ………… gerenciamento + internet (IP do host; VIP 192.168.1.250)
├─ dummy0 ……… neutron_external_interface (não toca no cabo)
├─ br-ex ………… 172.24.4.1/24 + NAT (larcerto.sh ext-net): host alcança os floating IPs
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

## Por que enp9s0 + dummy0

| Variável Kolla | Valor | Efeito |
|----------------|-------|--------|
| `network_interface` | `enp9s0` | APIs/VIP na LAN; cabo e internet do host **continuam** |
| `neutron_external_interface` | `dummy0` | Neutron não assume a NIC física |
| `kolla_internal_vip_address` | `192.168.1.250` | Endpoint Horizon/APIs (confirmar IP livre na LAN) |

Colocar o cabo em `neutron_external_interface` (ou no `br-ex` do OVS) derruba a rede. Este lab usa só `dummy0` na externa. O fluxo normal (`larcerto.sh deploy` / `all` / `post-deploy`) corre `fix-wired` no fim; se a cabo ainda ficar sem IPv4, corre `./larcerto.sh fix-wired` de novo.

## Aula → passo

| Módulo | Foco | Passo neste lab |
|--------|------|-----------------|
| 06 | Implantar nuvem privada | Preparar host, `dummy0`, `larcerto.sh` Kolla (bootstrap → deploy) |
| 07 | Projeto e instâncias via Horizon | REQ13–REQ15: projeto `larcerto` (`cloud/bootstrap.sh`) e VMs (Terraform); Horizon para mostrar no vídeo |
| 08 | CLI OpenStack | Alternativa ao Horizon para imagens/flavors/instâncias |
| 09–10 | Terraform / Ansible | `terraform/` cria as 4 VMs, `ansible/` configura dns → ca → db → web (REQ25, usado também no Trabalho 1) |

## Checklist pré-deploy (aluno)

1. Venv Kolla pronto (`./larcerto.sh venv`: cria `~/venvs/kolla` e roda `kolla-ansible install-deps`).
2. Conferir VIP livre: `ping -c1 192.168.1.250` (não deve responder se estiver livre).
3. Revisar [`../kolla-config/globals.yml`](../kolla-config/globals.yml): `enp9s0`, `dummy0`, VIP.
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
