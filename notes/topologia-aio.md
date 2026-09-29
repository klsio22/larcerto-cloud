# Topologia AIO — host Kolla + 2 VMs (REQ09)

Mapa aula → passo do lab. Deploy **manual** pelo aluno (não pelo agente).

## Desenho

```
Host (Zorin)
├─ enp9s0 ………… gerenciamento + internet (IP do host; VIP 192.168.1.250)
├─ dummy0 ……… neutron_external_interface (não toca no cabo)
└─ Kolla AIO (containers)
     ├─ Horizon / APIs (via HAProxy no VIP)
     └─ Projeto OpenStack
          ├─ VM web  (Apache/PHP CRUD)     ← REQ14
          └─ VM DB   (MariaDB)             ← REQ15
```

Portas: ver [`../ports.md`](../ports.md).

## Por que enp9s0 + dummy0

| Variável Kolla | Valor | Efeito |
|----------------|-------|--------|
| `network_interface` | `enp9s0` | APIs/VIP na LAN; cabo e internet do host **continuam** |
| `neutron_external_interface` | `dummy0` | Neutron não assume a NIC física |
| `kolla_internal_vip_address` | `192.168.1.250` | Endpoint Horizon/APIs (confirmar IP livre na LAN) |

Colocar o cabo em `neutron_external_interface` (ou no `br-ex` do OVS) derruba a rede. Este lab usa só `dummy0` na externa. O fluxo normal (`lab.sh deploy` / `all` / `post-deploy`) corre `fix-wired` no fim; se a cabo ainda ficar sem IPv4, corre `./project/lab.sh fix-wired` de novo.

## Aula → passo

| Módulo | Foco | Passo neste lab |
|--------|------|-----------------|
| 06 | Implantar nuvem privada | Preparar host, `dummy0`, `run-kolla` (bootstrap → deploy) |
| 07 | Projeto e instâncias via Horizon | REQ13–REQ15: projeto + VMs web/DB |
| 08 | CLI OpenStack | Alternativa ao Horizon para imagens/flavors/instâncias |
| 09–10 | Terraform / Ansible | Substitutivo REQ25 (depois da nuvem estável) |

Transcrições: [`../../transcricoes/`](../../transcricoes/).

## Checklist pré-deploy (aluno)

1. Venv Kolla ativo (`~/venvs/kolla`) e `kolla-ansible install-deps` já feito.
2. Conferir VIP livre: `ping -c1 192.168.1.250` (não deve responder se estiver livre).
3. Prep (dummy0 + OVS do host): `./project/lab.sh prep`
4. Revisar [`../kolla-config/globals.yml`](../kolla-config/globals.yml): `enp9s0`, `dummy0`, VIP.
5. Subir na ordem:
   - `./project/lab.sh bootstrap`
   - `./project/lab.sh prechecks`
   - `./project/lab.sh deploy`
   - `./project/lab.sh post-deploy`
6. Abrir Horizon: `http://192.168.1.250`
7. Instalar CLI (se ainda não tiver): `pip install python-openstackclient` no venv.

Estado / parar: `./project/lab.sh status` · `./project/lab.sh stop`

## Pós-nuvem (ainda pendente no Trabalho 1)

- REQ01–08: app CRUD PHP + domínio/logo
- REQ10–11: DNS + CA (topologia ideal)
- REQ13–16: projeto + 2 VMs + app HTTP/HTTPS
- REQ17–24: vídeo e envio Moodle
