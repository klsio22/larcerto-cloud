# Portas — Kolla AIO (core) + app CRUD

Mapa das portas esperadas neste lab. Fonte: defaults do Kolla-Ansible
(`group_vars/all` no venv) alinhados a [`kolla-config/globals.yml`](../kolla-config/globals.yml).

- VIP / Horizon: `http://10.99.0.250` (porta 80 via HAProxy) e `https://cloud.larcerto.com.br` (443, `./larcerto.sh cert cloud`)
- `network_interface`: `dummy1` (rede só do host `10.99.0.0/24`; nenhuma placa real; o VIP fica nela)
- `neutron_external_interface`: `dummy0` (não usa placa real)
- As portas abaixo escutam no VIP `10.99.0.250`: alcançáveis do host e das VMs, não da LAN

Após o primeiro `deploy`, confira com `docker ps` e `ss -tlnp` e ajuste este arquivo se algo divergir.

---

## Expostas no VIP / host (uso no lab)

| Serviço | Porta | Protocolo | Container típico | Uso |
|---------|------:|-----------|------------------|-----|
| Horizon | 80 | TCP | `horizon` (via `haproxy`) | Dashboard |
| Horizon HTTPS | 443 | TCP | `haproxy` | `cloud.larcerto.com.br`: frontend custom `horizon-https.cfg` (só o Horizon; as APIs seguem em HTTP) |
| Keystone | 5000 | TCP | `keystone` / `haproxy` | Autenticação |
| Glance | 9292 | TCP | `glance_api` | Imagens |
| Nova API | 8774 | TCP | `nova_api` | Compute |
| Nova metadata | 8775 | TCP | `nova_metadata` | Metadata das VMs |
| Placement | 8780 | TCP | `placement_api` | Scheduling |
| Neutron | 9696 | TCP | `neutron_server` | Redes |
| Heat API | 8004 | TCP | `heat_api` | Orquestração |
| Heat CFN | 8000 | TCP | `heat_api_cfn` | CloudFormation API |
| noVNC | 6080 | TCP | `nova_novncproxy` | Console da VM |
| HAProxy stats | 1984 | TCP | `haproxy` | Stats (lab) |

Com HAProxy ativo, o cliente fala com o VIP; os backends escutam essas portas nos containers.

---

## Internas (containers / overlay)

Em geral **não** precisam ser abertas no browser do host.

| Serviço | Porta | Protocolo | Container típico |
|---------|------:|-----------|------------------|
| MariaDB / ProxySQL (DB) | 3306 | TCP | `mariadb`, `proxysql` |
| ProxySQL admin | 6032 | TCP | `proxysql` |
| RabbitMQ AMQP | 5672 | TCP | `rabbitmq` |
| RabbitMQ management | 15672 | TCP | `rabbitmq` |
| RabbitMQ cluster | 25672 | TCP | `rabbitmq` |
| RabbitMQ epmd | 4369 | TCP | `rabbitmq` |
| Memcached | 11211 | TCP | `memcached` |
| OVSDB | 6640 | TCP | `openvswitch_*` |
| Fluentd syslog | 5140 | UDP/TCP | `fluentd` |
| Horizon (atrás do HAProxy) | 8080 | TCP | `horizon` |
| HAProxy monitor | 61313 | TCP | `haproxy` |
| HAProxy SSH | 2985 | TCP | `haproxy` |
| Keepalived | — | VRRP | `keepalived` (mantém o VIP; não é porta de app) |

Serviços desabilitados neste lab (Cinder, Octavia, Designate, etc.) **não** entram nesta lista.

---

## App CRUD nas VMs (não são containers Kolla)

Após criar as instâncias no OpenStack (REQ14–REQ16):

| Serviço | Porta | Onde |
|---------|------:|------|
| HTTP | 80 | VM web |
| HTTPS | 443 | VM web |
| MariaDB (app) | 3306 | VM db, só a partir da `larcerto-net` (a VM web) |
| SSH | 22 | VMs (administração) |
| DNS | 53 | VM dns (bind9, REQ10) |

## App local (Docker Compose, sem a nuvem)

`docker compose -f app/compose.yml up -d` publica só em `127.0.0.1`
([`../app/README.md`](../app/README.md)). As portas fogem das do Kolla no host (8080 Horizon, 3306 MariaDB).

| Serviço | Porta no host | Container |
|---------|--------------:|-----------|
| App (Apache + PHP 8.4) | `127.0.0.1:8088` | `larcerto-web-1:80` (publicada pelo `db`: o `web` usa a rede dele) |
| MariaDB 12.3 (DBeaver) | `127.0.0.1:3307` | `larcerto-db-1:3306` |

---

## Conferência rápida (manual, após deploy)

```bash
# Containers Kolla
docker ps --format 'table {{.Names}}\t{{.Ports}}'

# Portas em escuta no host
ss -tlnp | head -80
```
