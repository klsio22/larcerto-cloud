# install-app, start-app e recreate-app: sobem a nuvem e a app numa sequencia de etapas, com retorno em caso de erro.
# Carregado pelo lab.sh (SCRIPT_DIR = pasta project/). Cada etapa roda numa subshell, para o
# exit dela nao derrubar o lab.sh e o codigo volta para quem chamou.
# shellcheck shell=bash

INSTALL_STEPS=(prereqs start bootstrap terraform nuvem app dns-host checks)
START_APP_STEPS=(prereqs start vms dns-host checks)
RECREATE_STEPS=(prereqs start destroy terraform nuvem app dns-host checks)

CLOUDS_YAML="${SCRIPT_DIR}/cloud/secrets/clouds.yaml"
HOSTS_INI="${SCRIPT_DIR}/ansible/inventory/hosts.ini"
SECRETS_YML="${SCRIPT_DIR}/ansible/group_vars/all/secrets.yml"
VENV_DIR="${VENV_PATH:-$HOME/venvs/kolla}"
OPENSTACK_BIN="${VENV_DIR}/bin/openstack"
ANSIBLE_PLAYBOOK_BIN="${VENV_DIR}/bin/ansible-playbook"
LOCAL_BIN="${HOME}/.local/bin"
SSH_PUB="${HOME}/.ssh/id_ed25519.pub"
TF_CHECKPOINT_URL="https://checkpoint-api.hashicorp.com/v1/check/terraform"
START_APP_WAIT="${START_APP_WAIT:-120}"
DOMAIN_URL="https://larcerto.com.br"
CA_CERT="project/ansible/files/pki/ca.crt"

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

# App local ja criada: reaproveita o DB_PASSWORD de project/app/.env no secrets.yml.
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
    echo "DB_PASSWORD de project/app/.env tem aspas simples, que o role db nao aceita: preencha o secrets.yml a mao" >&2
    return 1
  fi
  (umask 077 && printf -- "---\n# Gerado pelo lab.sh install-app a partir de project/app/.env (DB_PASSWORD).\ndb_password: '%s'\n" \
    "${val}" >"${SECRETS_YML}") || return 1
  chmod 600 "${SECRETS_YML}"
  echo "secrets.yml criado a partir de project/app/.env (mesma senha do banco da app local)"
}

# Pre-requisitos do install-app ou do start-app.
step_prereqs() {
  FALTAM=0
  if [[ "${MODE}" == install || "${MODE}" == recreate ]]; then
    if ! command -v terraform >/dev/null 2>&1; then
      if [[ ! -x "${LOCAL_BIN}/terraform" ]] && ! install_terraform; then
        falta "Terraform (>= 1.5)" "instale a mao: ver project/README.md, secao Requisitos"
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
      secrets_from_app_env || falta "senha do banco em project/ansible/group_vars/all/secrets.yml" \
        "cp project/ansible/group_vars/all/secrets.yml.example project/ansible/group_vars/all/secrets.yml (e troque a senha), ou crie a app local antes (./project/app/run.sh setup)"
    fi
  fi
  if [[ "${MODE}" == recreate && ! -f "${CLOUDS_YAML}" ]]; then
    falta "cloud/secrets/clouds.yaml do devops1 (o projeto ainda nao foi criado)" "./project/lab.sh install-app"
  fi
  if [[ "${MODE}" == start && ( ! -f "${CLOUDS_YAML}" || ! -f "${HOSTS_INI}" ) ]]; then
    echo "Nao encontrei uma instalacao anterior (falta cloud/secrets/clouds.yaml ou ansible/inventory/hosts.ini)." >&2
    echo "Rode antes: ./project/lab.sh install-app" >&2
    return 1
  fi
  if ! (docker_cmd ps -aq --filter label=kolla_version 2>/dev/null | grep -q .); then
    falta "containers do Kolla (o deploy ainda nao rodou)" "./project/lab.sh deploy"
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

# Dica por etapa, mostrada no bloco de falha.
step_hint() {
  case "$1" in
    start) echo "veja a saida do lab.sh start acima (se a API nao respondeu no VIP, espere uns segundos e continue); ./project/lab.sh status mostra o estado do Kolla" ;;
    bootstrap) echo "veja o erro do bootstrap acima; ele pula o que ja existe, entao repetir e seguro (./project/lab.sh status mostra o Kolla)" ;;
    destroy) echo "veja o erro do terraform destroy acima; repetir e seguro: ele so apaga o que ainda existe" ;;
    terraform) echo "veja o erro do terraform acima; VM em ERROR: ./project/lab.sh vms mostra o status (depois de um reboot, ./project/lab.sh start para o libvirt do host, que faz as VMs nascerem em ERROR); repetir o apply e seguro: ele so cria o que falta" ;;
    nuvem) echo "veja o erro do ansible acima para as VMs dns e ca; o playbook pode ser rodado de novo" ;;
    app) echo "veja o erro do ansible acima para as VMs db e web; o playbook pode ser rodado de novo" ;;
    dns-host) echo "./project/lab.sh dns-host precisa do ip da VM dns no inventario (ansible/inventory/hosts.ini)" ;;
    checks) echo "uma checagem da nuvem falhou (a saida do cloud-checks.sh mostra qual); a nuvem subiu mas nao esta provada" ;;
    vms) echo "uma VM falta ou nao ligou; ./project/lab.sh install-app --from terraform cria o que falta (o apply so cria o que nao existe)" ;;
  esac
}

# Roda a lista de etapas. Argumentos: modo (install|start), etapa inicial (--from), etapas...
run_steps() {
  local mode="$1" from="$2"
  shift 2
  local steps=("$@") total="${#steps[@]}" n=0 started=0 step rc
  local cont
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
    ( set -e; "step_${step//-/_}" )
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      continue
    fi
    if [[ "${step}" == prereqs ]]; then
      return 1
    fi
    if [[ "${mode}" == recreate && "${step}" == destroy ]]; then
      cont="./project/lab.sh recreate-app"
    elif [[ "${mode}" == install || "${mode}" == recreate ]]; then
      cont="./project/lab.sh install-app --from ${step}"
    else
      cont="./project/lab.sh start-app"
    fi
    echo "FALHOU na etapa ${n}/${total} (${step}), codigo ${rc}" >&2
    echo "Dica: $(step_hint "${step}")" >&2
    echo "Para continuar: ${cont}" >&2
    return "${rc}"
  done
  return 0
}

# Ultima linha de sucesso: a URL e como fazer o navegador confiar na CA.
resumo_sucesso() {
  echo "Pronto. Abra ${DOMAIN_URL}"
  echo "Para o navegador confiar no HTTPS: ./project/lab.sh cert trust (ou importe ${CA_CERT} a mao)."
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
    echo "Uso: ./project/lab.sh install-app [--from <etapa>]" >&2
    return 1
  fi
  MODE=install
  run_steps install "${from}" "${INSTALL_STEPS[@]}"
  resumo_sucesso
}

start_app() {
  if [[ -n "${1:-}" ]]; then
    echo "Uso: ./project/lab.sh start-app" >&2
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
    *) echo "Uso: ./project/lab.sh recreate-app [--yes]" >&2; return 1 ;;
  esac
  if [[ -n "${2:-}" ]]; then
    echo "Uso: ./project/lab.sh recreate-app [--yes]" >&2
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
