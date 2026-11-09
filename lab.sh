#!/usr/bin/env bash
# Entrypoint único do lab AIO (dummy0, OVS host, testes, stop, fixes).
# Uso: ./project/lab.sh <comando> [opções]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Módulos: só definem funções e variáveis (nada roda ao carregar).
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"
# shellcheck source=scripts/lab/rede.sh
source "${SCRIPT_DIR}/scripts/lab/rede.sh"
# shellcheck source=scripts/lab/ovs.sh
source "${SCRIPT_DIR}/scripts/lab/ovs.sh"
# shellcheck source=scripts/lab/ciclo.sh
source "${SCRIPT_DIR}/scripts/lab/ciclo.sh"
# shellcheck source=scripts/kolla/kolla.sh
source "${SCRIPT_DIR}/scripts/kolla/kolla.sh"
# shellcheck source=scripts/lab/install.sh
source "${SCRIPT_DIR}/scripts/lab/install.sh"
# shellcheck source=scripts/lab/cert.sh
source "${SCRIPT_DIR}/scripts/lab/cert.sh"
# shellcheck source=scripts/lab/vms.sh
source "${SCRIPT_DIR}/scripts/lab/vms.sh"


usage() {
  cat <<'EOF'
Uso: ./project/lab.sh <comando> [opções]

Comandos:
  help           Mostra esta ajuda (-h, --help)
  prep           dummy0 + desativa OVS do host (antes do 1º deploy / após conflito OVS)
  dummy0         Cria/ativa interface dummy0 (neutron_external_interface)
  fix-ovs        Para OVS do host, limpa /run/openvswitch, remove containers OVS Kolla
  fix-wired      Tira network_interface de br-ex e reativa a cabo no NetworkManager
  test-ovs       Teste rápido (segundos) do openvswitch_db / vswitchd
  fix-horizon    Remove container horizon em conflito 409 (depois: lab.sh deploy)
  status         Estado rápido: dummy0, OVS, br-ex, Horizon, VIP
  stop           Para o lab e impede autostart no boot [--remove]
  start          Sobe o lab já deployado (dummy0 + kolla-* + ext-net + fix-wired)
  ext-net        IP 172.24.4.1/24 na br-ex + NAT: floating IPs alcançáveis do host [--down]
  dns-host       Split DNS do host: larcerto.com.br -> VM dns [<ip>|--down]
  all            Sobe o projeto inteiro, sem apagar nada [--from <etapa>]
                 (etapas: prep prechecks deploy post-deploy prereqs start bootstrap terraform nuvem
                  app dns-host checks cert-cloud deploy-https https-cloud)
                 Continuar de uma etapa: ./project/lab.sh all --from <etapa>
                 Maquina nova: rode antes ./project/lab.sh bootstrap
  install-app    Confere pre-requisitos e sobe nuvem + app em sequencia [--from <etapa>]
                 (etapas: prereqs start bootstrap terraform nuvem app dns-host checks)
  start-app      Religa uma instalacao existente (VMs SHUTOFF, dns-host, checks)
  recreate-app   Apaga e recria as VMs da app e roda os checks; mostra o tempo [--yes]
                 (etapas: prereqs start destroy terraform nuvem app dns-host checks)
  vms            VMs do projeto larcerto: status, IP privado, floating IP e linha de ssh (so leitura)
  cert           Certificado da LarCerto: status (padrão) | renew [--new-ca [--yes]] | trust | cloud
                 status: validade e se o web (e o Horizon) serve o mesmo certificado
                 renew: emite de novo na VM ca (mesma CA); --new-ca troca a CA com confirmação e cópia
                 trust: importa a CA nos bancos NSS do navegador (sem sudo)
                 cloud: certificado do Horizon (https://cloud.larcerto.com.br), emitido na VM ca e
                        servido pelo HAProxy do Kolla na 443 (root; depois, uma vez: deploy)
  deploy | bootstrap | prechecks | post-deploy | stop-kolla
                 Comandos Kolla (scripts/kolla/kolla.sh):
                 (deploy / post-deploy: depois corre fix-wired e ext-net automaticamente)

Exemplos:
  chmod +x project/lab.sh
  ./project/lab.sh prep
  ./project/lab.sh bootstrap && ./project/lab.sh prechecks && ./project/lab.sh deploy
  ./project/lab.sh post-deploy
  ./project/lab.sh test-ovs
  ./project/lab.sh fix-wired
  ./project/lab.sh status
  ./project/lab.sh stop
  ./project/lab.sh start
EOF
}

ACTION="${1:-help}"
shift || true

case "${ACTION}" in
  help|-h|--help) usage ;;
  prep) cmd_prep ;;
  dummy0) cmd_dummy0 ;;
  fix-ovs) cmd_fix_ovs ;;
  fix-wired) cmd_fix_wired ;;
  test-ovs) cmd_test_ovs ;;
  fix-horizon) cmd_fix_horizon ;;
  status) cmd_status ;;
  stop) cmd_stop "$@" ;;
  start) cmd_start ;;
  ext-net) cmd_ext_net "$@" ;;
  dns-host) cmd_dns_host "$@" ;;
  all) run_all "$@" ;;
  install-app) install_app "$@" ;;
  start-app) start_app "$@" ;;
  recreate-app) recreate_app "$@" ;;
  cert) cert_main "$@" ;;
  vms) cmd_vms "$@" ;;
  deploy|bootstrap|prechecks|post-deploy) cmd_kolla "${ACTION}" "$@" ;;
  stop-kolla) cmd_kolla stop "$@" ;;
  *)
    echo "Comando desconhecido: ${ACTION}" >&2
    usage >&2
    exit 1
    ;;
esac
