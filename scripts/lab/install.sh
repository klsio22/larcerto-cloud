# install-app, start-app e recreate-app: sobem a nuvem e a app numa sequencia de etapas, com retorno em caso de erro.
# Carregado pelo larcerto.sh (SCRIPT_DIR = raiz do repo). Cada etapa roda numa subshell, para o
# exit dela nao derrubar o larcerto.sh e o codigo volta para quem chamou.
# shellcheck shell=bash

INSTALL_STEPS=(prereqs start bootstrap terraform nuvem app dns-host checks)
START_APP_STEPS=(prereqs start vms dns-host checks)
RECREATE_STEPS=(prereqs start destroy terraform nuvem app dns-host checks)
ALL_STEPS=(prep prechecks deploy post-deploy prereqs start bootstrap terraform nuvem app dns-host checks cert-cloud deploy-https https-cloud)
CLEAR_STEPS=(start destroy-app dns-host ext-net kolla app-local files trust cabo)

CLOUDS_YAML="${SCRIPT_DIR}/cloud/secrets/clouds.yaml"
HOSTS_INI="${SCRIPT_DIR}/ansible/inventory/hosts.ini"
TFSTATE="${SCRIPT_DIR}/terraform/terraform.tfstate"
SECRETS_YML="${SCRIPT_DIR}/ansible/group_vars/all/secrets.yml"
VENV_DIR="${VENV_PATH:-$HOME/venvs/kolla}"
OPENSTACK_BIN="${VENV_DIR}/bin/openstack"
ANSIBLE_PLAYBOOK_BIN="${VENV_DIR}/bin/ansible-playbook"
LOCAL_BIN="${HOME}/.local/bin"
SSH_PUB="${HOME}/.ssh/id_ed25519.pub"
TF_CHECKPOINT_URL="https://checkpoint-api.hashicorp.com/v1/check/terraform"
START_APP_WAIT="${START_APP_WAIT:-120}"
DOMAIN_URL="https://larcerto.com.br"
CA_CERT="ansible/files/pki/ca.crt"

# Falta de pre-requisito: uma linha por item, com o comando que resolve.
falta() {
  echo "Falta: $1 -> $2" >&2
  FALTAM=$((FALTAM + 1))
}

# Terraform: o do PATH, ou o instalado em ~/.local/bin (o PATH pode nao ter ~/.local/bin).
terraform_bin() {
  command -v terraform 2>/dev/null || printf '%s\n' "${LOCAL_BIN}/terraform"
}

# Cliente openstack do venv, com a nuvem do devops1 (start-app e etapas da nuvem).
os_cli() {
  OS_CLIENT_CONFIG_FILE="${CLOUDS_YAML}" OS_CLOUD=larcerto-devops1 "${OPENSTACK_BIN}" "$@"
}

# Baixa, confere o SHA-256 e so entao grava ~/.local/bin/terraform.
install_terraform() {
  local version="${TERRAFORM_VERSION:-}" zip base dir
  if [[ -z "${version}" ]]; then
    version="$(curl -fsSL "${TF_CHECKPOINT_URL}" 2>/dev/null \
      | grep -oE '"current_version":"[^"]+"' | cut -d'"' -f4)"
  fi
  if [[ -z "${version}" ]]; then
    echo "Terraform: nao consegui descobrir a versao (defina TERRAFORM_VERSION)" >&2
    return 1
  fi
  echo "Terraform nao encontrado: instalando ${version} em ~/.local/bin"
  zip="terraform_${version}_linux_amd64.zip"
  base="https://releases.hashicorp.com/terraform/${version}"
  dir="$(mktemp -d)"
  if ! curl -fsSL -o "${dir}/${zip}" "${base}/${zip}" \
    || ! curl -fsSL -o "${dir}/SHA256SUMS" "${base}/terraform_${version}_SHA256SUMS"; then
    rm -rf "${dir}"
    echo "Download do Terraform falhou: nada foi gravado em ~/.local/bin" >&2
    return 1
  fi
  if ! (cd "${dir}" && grep -F "${zip}" SHA256SUMS | sha256sum -c --status -); then
    rm -rf "${dir}"
    echo "SHA-256 do Terraform nao confere: nada foi gravado em ~/.local/bin" >&2
    return 1
  fi
  if ! python3 -I -m zipfile -e "${dir}/${zip}" "${dir}" \
    || ! mkdir -p "${LOCAL_BIN}" \
    || ! install -m 0755 "${dir}/terraform" "${LOCAL_BIN}/terraform"; then
    rm -rf "${dir}"
    echo "Nao consegui extrair o Terraform em ~/.local/bin" >&2
    return 1
  fi
  rm -rf "${dir}"
  "${LOCAL_BIN}/terraform" version | head -1
}

# App local ja criada: reaproveita o DB_PASSWORD de app/.env no secrets.yml.
# Nunca imprime a senha.
secrets_from_app_env() {
  local env_file="${SCRIPT_DIR}/app/.env" val
  [[ -f "${env_file}" ]] || return 1
  val="$(grep -E '^DB_PASSWORD=' "${env_file}" | tail -1)"
  val="${val#DB_PASSWORD=}"
  val="${val%$'\r'}"
  if [[ "${val}" == \"*\" || "${val}" == \'*\' ]]; then
    val="${val:1:${#val}-2}"
  fi
  [[ -n "${val}" ]] || return 1
  # O role db poe a senha entre aspas simples no SQL (roles/db/tasks/main.yml).
  if [[ "${val}" == *"'"* ]]; then
    echo "DB_PASSWORD de app/.env tem aspas simples, que o role db nao aceita: preencha o secrets.yml a mao" >&2
    return 1
  fi
  (umask 077 && printf -- "---\n# Gerado pelo larcerto.sh install-app a partir de app/.env (DB_PASSWORD).\ndb_password: '%s'\n" \
    "${val}" >"${SECRETS_YML}") || return 1
  chmod 600 "${SECRETS_YML}"
  echo "secrets.yml criado a partir de app/.env (mesma senha do banco da app local)"
}

# Pre-requisitos do install-app ou do start-app.
step_prereqs() {
  FALTAM=0
  if [[ "${MODE}" == install || "${MODE}" == recreate ]]; then
    if ! command -v terraform >/dev/null 2>&1; then
      if [[ ! -x "${LOCAL_BIN}/terraform" ]] && ! install_terraform; then
        falta "Terraform (>= 1.5)" "instale a mao: ver README.md, secao Requisitos"
      fi
      # Confere o PATH de novo: depois da instalacao o binario pode estar em ~/.local/bin, que ja esta no PATH.
      if [[ -x "${LOCAL_BIN}/terraform" ]] && ! command -v terraform >/dev/null 2>&1; then
        echo "AVISO: ${LOCAL_BIN} nao esta no PATH: usando ${LOCAL_BIN}/terraform nesta execucao; acrescente ao PATH"
      fi
    fi
  fi
  if [[ ! -x "${OPENSTACK_BIN}" ]]; then
    falta "cliente openstack em ${OPENSTACK_BIN}" "${VENV_DIR}/bin/pip install python-openstackclient"
  fi
  if [[ ( "${MODE}" == install || "${MODE}" == recreate ) && ! -f "${SSH_PUB}" ]]; then
    falta "chave SSH ${SSH_PUB}" "ssh-keygen -t ed25519"
  fi
  if [[ "${MODE}" == install || "${MODE}" == recreate ]]; then
    if [[ ! -f "${SECRETS_YML}" ]] || grep -q 'troque-esta-senha' "${SECRETS_YML}"; then
      secrets_from_app_env || falta "senha do banco em ansible/group_vars/all/secrets.yml" \
        "cp ansible/group_vars/all/secrets.yml.example ansible/group_vars/all/secrets.yml (e troque a senha), ou crie a app local antes (./app/run.sh setup)"
    fi
  fi
  if [[ "${MODE}" == recreate && ! -f "${CLOUDS_YAML}" ]]; then
    falta "cloud/secrets/clouds.yaml do devops1 (o projeto ainda nao foi criado)" "./larcerto.sh install-app"
  fi
  if [[ "${MODE}" == start && ( ! -f "${CLOUDS_YAML}" || ! -f "${HOSTS_INI}" ) ]]; then
    echo "Nao encontrei uma instalacao anterior (falta cloud/secrets/clouds.yaml ou ansible/inventory/hosts.ini)." >&2
    echo "Rode antes: ./larcerto.sh install-app" >&2
    return 1
  fi
  if ! (docker_cmd ps -aq --filter label=kolla_version 2>/dev/null | grep -q .); then
    falta "containers do Kolla (o deploy ainda nao rodou)" "./larcerto.sh deploy"
  fi
  if [[ "${FALTAM}" -gt 0 ]]; then
    echo "Pre-requisitos faltando: ${FALTAM}. Corrija e rode de novo." >&2
    return 1
  fi
}

step_start() {
  cmd_start
}

step_bootstrap() {
  bash "${SCRIPT_DIR}/cloud/bootstrap.sh"
}

step_destroy() {
  cd "${SCRIPT_DIR}/terraform" || return 1
  export OS_CLIENT_CONFIG_FILE="${CLOUDS_YAML}" OS_CLOUD=larcerto-devops1
  "$(terraform_bin)" init
  "$(terraform_bin)" destroy -auto-approve
}

step_terraform() {
  cd "${SCRIPT_DIR}/terraform" || return 1
  export OS_CLIENT_CONFIG_FILE="${CLOUDS_YAML}" OS_CLOUD=larcerto-devops1
  "$(terraform_bin)" init
  "$(terraform_bin)" apply -auto-approve
}

step_nuvem() {
  cd "${SCRIPT_DIR}/ansible" || return 1
  "${ANSIBLE_PLAYBOOK_BIN}" site.yml --limit dns,ca
}

step_app() {
  cd "${SCRIPT_DIR}/ansible" || return 1
  "${ANSIBLE_PLAYBOOK_BIN}" site.yml --limit db,web
}

step_dns_host() {
  cmd_dns_host
}

step_checks() {
  bash "${SCRIPT_DIR}/tests/cloud-checks.sh"
}

step_prep() {
  cmd_prep
}

step_prechecks() {
  cmd_kolla prechecks
}

step_deploy() {
  cmd_kolla deploy
}

step_post_deploy() {
  cmd_kolla post-deploy
}

step_cert_cloud() {
  cert_main cloud
}

step_deploy_https() {
  cmd_kolla deploy
}

step_https_cloud() {
  wait_vip
  bash "${SCRIPT_DIR}/tests/cloud-checks.sh" https_cloud
}

# Religa so as VMs SHUTOFF e espera as 4 ACTIVE.
step_vms() {
  local vms=(dns ca db web) vm status pending
  for vm in "${vms[@]}"; do
    status="$(os_cli server show -f value -c status "${vm}" 2>/dev/null || true)"
    if [[ -z "${status}" ]]; then
      echo "VM ${vm}: status ausente (a VM nao existe ou o openstack nao conseguiu ler o status)" >&2
      return 1
    fi
    if [[ "${status}" == SHUTOFF ]]; then
      echo "Ligando ${vm} (estava SHUTOFF)"
      os_cli server start "${vm}" >/dev/null || return 1
    fi
  done
  SECONDS=0
  while true; do
    pending=""
    for vm in "${vms[@]}"; do
      status="$(os_cli server show -f value -c status "${vm}" 2>/dev/null || true)"
      [[ "${status}" == ACTIVE ]] || pending="${pending} ${vm}:${status:-ausente}"
    done
    [[ -z "${pending}" ]] && return 0
    [[ "${SECONDS}" -ge "${START_APP_WAIT}" ]] && break
    sleep 2
  done
  echo "VM nao ficou ACTIVE em ${START_APP_WAIT}s:${pending}" >&2
  return 1
}

# Dica por etapa, mostrada no bloco de falha. Uma linha por item:
#   D <texto>          o que houve (linha "Dica:")
#   V <cmd>|<motivo>   para investigar (bloco "Para ver:")
#   A <cmd>|<motivo>   rodar antes de continuar (bloco "Para continuar:", antes do comando de retomar)
step_hint() {
  case "$1" in
    prep) echo "D veja o erro acima"
      echo "V ./larcerto.sh status|mostra a dummy0 e o OVS" ;;
    prechecks) echo "D veja qual checagem do Kolla falhou acima"
      echo "A ./larcerto.sh bootstrap|so numa maquina nova (prepara o host e o /etc/hosts)" ;;
    deploy) echo "D veja a tarefa do Kolla que falhou acima"
      echo "V ./larcerto.sh status|estado dos containers" ;;
    post-deploy) echo "D veja o erro do kolla-ansible post-deploy acima; ele gera o clouds.yaml do admin" ;;
    prereqs) echo "D corrija o que esta nas linhas Falta acima" ;;
    cert-cloud) echo "D veja o erro do cert cloud acima"
      echo "V ./larcerto.sh cert|estado dos certificados" ;;
    deploy-https) echo "D veja a tarefa do Kolla que falhou acima"
      echo "V ./larcerto.sh status|estado do haproxy e do Horizon" ;;
    https-cloud) echo "D o Horizon nao respondeu em https://cloud.larcerto.com.br"
      echo "V ./larcerto.sh cert|compara o certificado servido" ;;
    start) echo "D veja a saida do start acima; se a API nao respondeu no VIP, espere uns segundos e continue"
      echo "V ./larcerto.sh status|estado do Kolla" ;;
    bootstrap) echo "D veja o erro do bootstrap acima; ele pula o que ja existe, entao repetir e seguro"
      echo "V ./larcerto.sh status|estado do Kolla" ;;
    destroy) echo "D veja o erro do terraform destroy acima; repetir e seguro: ele so apaga o que ainda existe" ;;
    terraform) echo "D veja o erro do terraform acima; repetir o apply e seguro: ele so cria o que falta"
      echo "V ./larcerto.sh vms|VM em ERROR? mostra o status de cada uma"
      echo "A ./larcerto.sh start|so depois de um reboot (o libvirt do host faz as VMs nascerem em ERROR)" ;;
    nuvem) echo "D veja o erro do ansible acima para as VMs dns e ca; o playbook pode ser rodado de novo" ;;
    app) echo "D veja o erro do ansible acima para as VMs db e web; o playbook pode ser rodado de novo" ;;
    dns-host) echo "D o dns-host precisa do ip da VM dns no inventario (ansible/inventory/hosts.ini)" ;;
    checks) echo "D uma checagem da nuvem falhou (a saida do cloud-checks.sh mostra qual); a nuvem subiu mas nao esta provada" ;;
    vms) echo "D uma VM falta ou nao ligou"
      echo "A ./larcerto.sh install-app --from terraform|cria o que falta (o apply so cria o que nao existe)" ;;
  esac
}

# fail_cmd <cmd>|<motivo>: uma linha de comando do bloco de falha, com o motivo alinhado.
fail_cmd() {
  local cmd="${1%%|*}" why=""
  [[ "$1" == *"|"* ]] && why="${1#*|}"
  if [[ -n "${why}" ]]; then
    printf '  %-38s # %s\n' "${cmd}" "${why}"
  else
    printf '  %s\n' "${cmd}"
  fi
}

# fail_block <n> <total> <etapa> <codigo> <funcao de dica> <comando de retomar>
fail_block() {
  local n="$1" total="$2" step="$3" rc="$4" hint="$5" cont="$6" line dica="" e
  local -a ver=() antes=()
  while IFS= read -r line; do
    case "${line}" in
      "D "*) dica="${line#D }" ;;
      "V "*) ver+=("${line#V }") ;;
      "A "*) antes+=("${line#A }") ;;
    esac
  done < <("${hint}" "${step}")
  {
    echo
    echo "FALHOU na etapa ${n}/${total} (${step}), codigo ${rc}"
    echo "Dica: ${dica:-veja o erro acima}"
    if [[ "${#ver[@]}" -gt 0 ]]; then
      echo "Para ver:"
      for e in "${ver[@]}"; do fail_cmd "${e}"; done
    fi
    echo "Para continuar:"
    for e in "${antes[@]}"; do fail_cmd "${e}"; done
    fail_cmd "${cont}"
  } >&2
}

# Roda a lista de etapas. Argumentos: modo (install|start), etapa inicial (--from), etapas...
run_steps() {
  local mode="$1" from="$2"
  shift 2
  local steps=("$@") total="${#steps[@]}" n=0 started=0 step rc
  local cont prefix=step_ hint=step_hint
  if [[ "${mode}" == clear ]]; then
    prefix=clear_
    hint=clear_hint
  fi
  for step in "${steps[@]}"; do
    n=$((n + 1))
    [[ "${step}" == "${from}" ]] && started=1
    if [[ "${started}" -eq 0 && "${step}" != prereqs ]]; then
      continue
    fi
    [[ "${step}" == "${TIMER_FROM:-}" ]] && TIMER_T0="${SECONDS}"
    echo "==> [${n}/${total}] ${step}"
    # set -e dentro da subshell: um comando que falha no meio da etapa para a etapa.
    # Nao pode ficar num "||" (o bash desliga o set -e la dentro).
    set +e
    ( set -e; "${prefix}${step//-/_}" )
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      continue
    fi
    if [[ "${step}" == prereqs && "${mode}" != all ]]; then
      return 1
    fi
    if [[ "${mode}" == all ]]; then
      cont="./larcerto.sh all --from ${step}"
    elif [[ "${mode}" == clear ]]; then
      cont="./larcerto.sh clear-all --yes"
    elif [[ "${mode}" == recreate && "${step}" == destroy ]]; then
      cont="./larcerto.sh recreate-app"
    elif [[ "${mode}" == install || "${mode}" == recreate ]]; then
      cont="./larcerto.sh install-app --from ${step}"
    else
      cont="./larcerto.sh start-app"
    fi
    fail_block "${n}" "${total}" "${step}" "${rc}" "${hint}" "${cont}"
    return "${rc}"
  done
  return 0
}

# Ultima linha de sucesso: a URL e como fazer o navegador confiar na CA.
resumo_sucesso() {
  echo "Pronto. Abra ${DOMAIN_URL}"
  echo "Para o navegador confiar no HTTPS: ./larcerto.sh cert trust (ou importe ${CA_CERT} a mao)."
}

install_app() {
  local from="prereqs"
  if [[ "${1:-}" == --from ]]; then
    from="${2:-}"
    if [[ -z "${from}" ]] || ! [[ " ${INSTALL_STEPS[*]} " == *" ${from} "* ]]; then
      echo "Etapa desconhecida: '${from}'. Etapas validas: ${INSTALL_STEPS[*]}" >&2
      return 1
    fi
  elif [[ -n "${1:-}" ]]; then
    echo "Uso: ./larcerto.sh install-app [--from <etapa>]" >&2
    return 1
  fi
  MODE=install
  run_steps install "${from}" "${INSTALL_STEPS[@]}"
  resumo_sucesso
}

run_all() {
  local from="prep"
  if [[ "${1:-}" == --from && $# -le 2 ]]; then
    from="${2:-}"
    if [[ -z "${from}" ]] || ! [[ " ${ALL_STEPS[*]} " == *" ${from} "* ]]; then
      echo "Etapa desconhecida: '${from}'. Etapas validas: ${ALL_STEPS[*]}" >&2
      return 1
    fi
  elif [[ $# -gt 0 ]]; then
    echo "Uso: ./larcerto.sh all [--from <etapa>]" >&2
    return 1
  fi
  MODE=install
  run_steps all "${from}" "${ALL_STEPS[@]}"
  resumo_sucesso
  echo "Painel: https://${CERT_CLOUD_FQDN}"
}

start_app() {
  if [[ -n "${1:-}" ]]; then
    echo "Uso: ./larcerto.sh start-app" >&2
    return 1
  fi
  MODE=start
  run_steps start prereqs "${START_APP_STEPS[@]}"
  resumo_sucesso
}

# Apaga a infra da app (Terraform) e recria tudo; o projeto, o devops1 e a CA ficam.
recreate_app() {
  local yes=0 resposta="" s
  case "${1:-}" in
    "") ;;
    --yes) yes=1 ;;
    *) echo "Uso: ./larcerto.sh recreate-app [--yes]" >&2; return 1 ;;
  esac
  if [[ -n "${2:-}" ]]; then
    echo "Uso: ./larcerto.sh recreate-app [--yes]" >&2
    return 1
  fi
  if [[ "${yes}" -eq 0 ]]; then
    echo "Isto apaga as 4 VMs do projeto larcerto (dns, ca, db, web), a rede, o roteador e os floating IPs."
    echo "Anuncios e fotos criados na nuvem se perdem (a semente volta). O projeto, o devops1 e a CA ficam."
    printf 'Apagar e recriar as VMs do projeto larcerto? Digite larcerto para confirmar: '
    read -r resposta || true
    if [[ "${resposta}" != larcerto ]]; then
      echo "Cancelado."
      return 1
    fi
  fi
  MODE=recreate
  TIMER_FROM=destroy
  TIMER_T0="${SECONDS}"
  run_steps recreate prereqs "${RECREATE_STEPS[@]}"
  s=$((SECONDS - TIMER_T0))
  printf 'Recriado em %dmin%02ds\n' $((s / 60)) $((s % 60))
  resumo_sucesso
}


# clear-all: apaga o projeto inteiro e nao sobe nada de volta. Cada etapa pula o que ja nao existe,
# entao repetir o comando e o jeito de continuar depois de uma falha.
clear_tem_kolla() {
  docker_cmd ps -aq --filter label=kolla_version 2>/dev/null | grep -q .
}

# 0 = ha VMs do Terraform para apagar com a nuvem no ar; senao diz por que pula.
clear_ha_app() {
  if ! clear_tem_kolla; then
    echo "pulado: nenhum container do Kolla (a nuvem ja foi apagada)"
    return 1
  fi
  if [[ ! -f "${TFSTATE}" ]]; then
    echo "pulado: sem terraform/terraform.tfstate (nenhuma VM do Terraform para apagar)"
    return 1
  fi
}

clear_start() {
  clear_ha_app || return 0
  cmd_start
}

clear_destroy_app() {
  clear_ha_app || return 0
  step_destroy
}

clear_dns_host() {
  step "dns-host --down: removendo DNS de ${DNS_DOMAIN} da br-ex"
  if ! run_as_root resolvectl revert br-ex 2>/dev/null; then
    echo "pulado: resolvectl revert br-ex falhou (br-ex ja nao existe?)"
  fi
}

clear_ext_net() {
  if ! ip link show br-ex >/dev/null 2>&1; then
    echo "pulado: br-ex nao existe"
    return 0
  fi
  cmd_ext_net --down
}

clear_kolla() {
  cmd_kolla destroy
}

clear_app_local() {
  local ids
  step "App local (Docker Compose larcerto): containers, volumes e imagens"
  ids="$(docker_cmd ps -aq --filter label=com.docker.compose.project=larcerto)"
  if [[ -n "${ids}" ]]; then
    # shellcheck disable=SC2086
    docker_cmd rm -f ${ids} >/dev/null
  fi
  docker_cmd volume rm larcerto_db_data larcerto_uploads >/dev/null 2>&1 || true
  docker_cmd image rm larcerto-web larcerto-tests >/dev/null 2>&1 || true
  echo "App local apagada."
}

clear_files() {
  step "Arquivos gerados: state do Terraform, inventario, credenciais, CA e certificados"
  rm -f "${TFSTATE}" "${TFSTATE}.backup" "${HOSTS_INI}" "${CLOUDS_YAML}" \
    "${SCRIPT_DIR}/cloud/secrets/devops1.password" "${SCRIPT_DIR}/kolla-config/clouds.yaml" \
    "${SCRIPT_DIR}"/kolla-config/*-openrc*.sh
  if [[ -d "${CERT_PKI_DIR}" ]]; then
    find "${CERT_PKI_DIR}" -mindepth 1 -maxdepth 1 ! -name .gitkeep -exec rm -rf {} +
  fi
  echo "Arquivos gerados apagados."
}

clear_trust() {
  local db
  if ! command -v certutil >/dev/null 2>&1; then
    echo "pulado: certutil ausente"
    return 0
  fi
  cert_bancos_nss
  if [[ "${#CERT_BANCOS[@]}" -eq 0 ]]; then
    echo "pulado: nenhum banco NSS do usuario"
    return 0
  fi
  for db in "${CERT_BANCOS[@]}"; do
    if ! certutil -L -d "${db}" -n "${CERT_NOME_NSS}" >/dev/null 2>&1; then
      echo "${db}: nao estava"
    elif certutil -D -d "${db}" -n "${CERT_NOME_NSS}" >/dev/null 2>&1; then
      echo "${db}: removido"
    else
      echo "${db}: falhou (remova a CA LarCerto pelas configuracoes do navegador)"
    fi
  done
}

clear_cabo() {
  cmd_fix_wired
}

clear_hint() {
  case "$1" in
    start) echo "D a API da nuvem nao respondeu, e o destroy-app precisa dela"
      echo "V ./larcerto.sh status|estado do Kolla" ;;
    destroy-app) echo "D veja o erro do terraform destroy acima; repetir e seguro: ele so apaga o que ainda existe" ;;
    ext-net) echo "D veja o erro do iptables acima; o ext-net --down pode ser repetido" ;;
    kolla) echo "D veja o erro do kolla-ansible destroy acima; se ele reclamou de processos qemu, sobrou VM fora do Terraform: apague-as"
      echo "V openstack server list --all-projects|com o kolla-config/clouds.yaml do admin" ;;
    cabo) echo "D o cabo ficou sem IPv4: confira o cabo e o DHCP"
      echo "A ./larcerto.sh fix-wired|pede o IP do cabo de novo" ;;
    *) echo "D veja o erro acima; repetir o clear-all e seguro" ;;
  esac
}

clear_all() {
  local yes=0 resposta="" s
  case "${1:-}" in
    "") ;;
    --yes) yes=1 ;;
    *) echo "Uso: ./larcerto.sh clear-all [--yes]" >&2; return 1 ;;
  esac
  if [[ $# -gt 1 ]]; then
    echo "Uso: ./larcerto.sh clear-all [--yes]" >&2
    return 1
  fi
  if [[ "${yes}" -eq 0 ]]; then
    echo "Isto APAGA o projeto inteiro e nao sobe nada de volta:"
    echo "  - as VMs da app (terraform destroy) e o OpenStack (kolla-ansible destroy: containers e volumes)"
    echo "  - a app local: containers, volumes larcerto_db_data e larcerto_uploads, imagens"
    echo "  - terraform.tfstate, ansible/inventory/hosts.ini, cloud/secrets/, kolla-config/clouds.yaml e openrc"
    echo "  - a CA e todos os certificados (ansible/files/pki) e a CA LarCerto nos navegadores"
    echo "Ficam: kolla-config/passwords.yml, kolla-config/globals.yml, app/.env,"
    echo "  ansible/group_vars/all/secrets.yml, a chave SSH e as imagens do Kolla."
    printf 'Digite yes para apagar tudo, ou qualquer outra coisa para cancelar: '
    read -r resposta || true
    if [[ "${resposta}" != yes ]]; then
      echo "Cancelado."
      echo "Nada foi apagado."
      return 1
    fi
  fi
  MODE=clear
  TIMER_T0="${SECONDS}"
  run_steps clear start "${CLEAR_STEPS[@]}"
  s=$((SECONDS - TIMER_T0))
  printf 'Tudo apagado em %dmin%02ds\n' $((s / 60)) $((s % 60))
  echo "Para subir de novo: ./larcerto.sh all"
}
