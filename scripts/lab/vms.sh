# vms: lista as VMs do projeto larcerto (status, IP privado, floating IP e a linha de ssh), so leitura.
# Carregado pelo lab.sh (SCRIPT_DIR = pasta project/), depois do install.sh: usa os_cli, CLOUDS_YAML,
# OPENSTACK_BIN e VENV_DIR de la. Le da API (nao do inventario) porque o floating IP muda num novo apply.
# shellcheck shell=bash

# Rede public: o IP da VM dentro dela e o floating; o outro e o da larcerto-net.
VMS_PUBLIC_CIDR="${EXT_NET_CIDR:-172.24.4.0/24}"

cmd_vms() {
  if [[ $# -gt 0 ]]; then
    echo "Uso: ./project/lab.sh vms" >&2
    return 1
  fi
  if [[ ! -f "${CLOUDS_YAML}" ]]; then
    echo "Falta: project/cloud/secrets/clouds.yaml (credencial do devops1) -> ./project/cloud/bootstrap.sh" >&2
    return 1
  fi
  if [[ ! -x "${OPENSTACK_BIN}" ]]; then
    echo "Falta: cliente openstack em ${OPENSTACK_BIN} -> ${VENV_DIR}/bin/pip install python-openstackclient" >&2
    return 1
  fi
  local json
  if ! json="$(os_cli server list -f json -c Name -c Status -c Networks 2>/dev/null)"; then
    echo "A API do OpenStack nao respondeu (lab desligado?) -> ./project/lab.sh start" >&2
    return 1
  fi
  python3 -I -c '
import ipaddress, json, sys

public = ipaddress.ip_network(sys.argv[1])
vms = sorted(json.load(sys.stdin), key=lambda v: v["Name"])
if not vms:
    print("Nenhuma VM no projeto larcerto -> cd project/terraform && terraform apply")
    sys.exit(0)

rows = []
for vm in vms:
    ips = [ip for net in (vm.get("Networks") or {}).values() for ip in net]
    floating = next((ip for ip in ips if ipaddress.ip_address(ip) in public), "-")
    private = next((ip for ip in ips if ip != floating), "-")
    rows.append((vm["Name"], vm["Status"], private, floating))

width = max(len(r[0]) for r in rows + [("VM",)])
fmt = "%-" + str(width) + "s  %-8s  %-14s  %s"
print(fmt % ("VM", "STATUS", "IP_PRIVADO", "FLOATING_IP"))
for row in rows:
    print(fmt % row)

ssh = [r for r in rows if r[1] == "ACTIVE" and r[3] != "-"]
if ssh:
    print()
    for name, _, _, floating in ssh:
        print(f"ssh -i ~/.ssh/id_ed25519 ubuntu@{floating}   # {name}")
' "${VMS_PUBLIC_CIDR}" <<<"${json}"
}
