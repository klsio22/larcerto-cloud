#!/usr/bin/env bash
# Prepara a nuvem como admin (idempotente; pode rodar de novo):
#   rede externa public, flavor ds1G, imagem ubuntu-22.04, projeto larcerto,
#   grupo devops + usuario devops1 (member) e quotas.
# Gera cloud/secrets/clouds.yaml (fora do git) para o Terraform/CLI como devops1.
# Uso: ./cloud/bootstrap.sh
set -euo pipefail

CLOUD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${CLOUD_DIR}/.." && pwd)"

VENV_PATH="${VENV_PATH:-$HOME/venvs/kolla}"
OPENSTACK="${OPENSTACK:-${VENV_PATH}/bin/openstack}"
SECRETS_DIR="${SECRETS_DIR:-${CLOUD_DIR}/secrets}"
IMAGE_CACHE="${IMAGE_CACHE:-$HOME/.cache/larcerto}"
API_WAIT_TRIES="${API_WAIT_TRIES:-30}"

export OS_CLIENT_CONFIG_FILE="${OS_CLIENT_CONFIG_FILE:-${PROJECT_DIR}/kolla-config/clouds.yaml}"
export OS_CLOUD="${OS_CLOUD:-kolla-admin}"

EXT_NET="public"
EXT_SUBNET="public-subnet"
EXT_CIDR="172.24.4.0/24"
EXT_GW="172.24.4.1"
EXT_POOL="start=172.24.4.100,end=172.24.4.199"

FLAVOR="ds1G"
IMAGE="ubuntu-22.04"
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

PROJECT="larcerto"
GROUP="devops"
USER_NAME="devops1"

step() {
  echo "==> $*"
}

os() {
  "${OPENSTACK}" "$@"
}

# exists <recurso> <nome> [args de show...]
exists() {
  local kind="$1" name="$2"
  shift 2
  os "${kind}" show "$@" "${name}" >/dev/null 2>&1
}

if [[ ! -x "${OPENSTACK}" ]]; then
  echo "Erro: cliente openstack nao encontrado em ${OPENSTACK}" >&2
  echo "Instale no venv: ${VENV_PATH}/bin/pip install python-openstackclient" >&2
  exit 1
fi
if [[ ! -f "${OS_CLIENT_CONFIG_FILE}" ]]; then
  echo "Erro: ${OS_CLIENT_CONFIG_FILE} nao existe (rode ./lab.sh post-deploy)" >&2
  exit 1
fi

# Logo depois do lab.sh start, o fix-wired reconecta o cabo e o VIP some por alguns segundos.
# Sem esperar, um "show" que falha por rede vira "nao existe" e o create bate em recurso existente.
step "Esperando a API do OpenStack responder"
api_ok=0
for _ in $(seq 1 "${API_WAIT_TRIES}"); do
  if os network list -f value -c ID >/dev/null 2>&1; then
    api_ok=1
    break
  fi
  sleep 2
done
if [[ "${api_ok}" -ne 1 ]]; then
  echo "Erro: a API do OpenStack nao respondeu em $((API_WAIT_TRIES * 2))s (teste ./lab.sh status)" >&2
  exit 1
fi

err_file="$(mktemp)"
trap 'rm -f "${err_file}"' EXIT

# 409 "physnet1 is in use": ja ha uma rede externa na physnet1; pula e segue com o resto.
network_create_failed() {
  if grep -q 'is in use' "${err_file}"; then
    echo "    physnet1 ja tem uma rede externa: pulando a criacao de ${EXT_NET}"
    return 0
  fi
  cat "${err_file}" >&2
  return 1
}

step "Rede externa ${EXT_NET} (flat, physnet1 = br-ex)"
if ! exists network "${EXT_NET}"; then
  os network create --external --provider-network-type flat \
    --provider-physical-network physnet1 "${EXT_NET}" >/dev/null 2>"${err_file}" || network_create_failed
fi
if ! exists subnet "${EXT_SUBNET}"; then
  os subnet create --network "${EXT_NET}" --subnet-range "${EXT_CIDR}" \
    --gateway "${EXT_GW}" --allocation-pool "${EXT_POOL}" --no-dhcp "${EXT_SUBNET}" >/dev/null
fi

step "Flavor ${FLAVOR} (1 vCPU, 1 GB RAM, 10 GB disco)"
if ! exists flavor "${FLAVOR}"; then
  os flavor create --vcpus 1 --ram 1024 --disk 10 --public "${FLAVOR}" >/dev/null
fi

step "Imagem ${IMAGE} (Ubuntu 22.04 jammy cloudimg)"
image_status="$(os image show "${IMAGE}" -f value -c status 2>/dev/null || true)"
if [[ -n "${image_status}" && "${image_status}" != "active" ]]; then
  # Upload interrompido deixa a imagem em queued/saving: recria.
  echo "    imagem ${IMAGE} em '${image_status}', recriando"
  os image delete "${IMAGE}"
fi
if ! exists image "${IMAGE}"; then
  mkdir -p "${IMAGE_CACHE}"
  local_img="${IMAGE_CACHE}/$(basename "${IMAGE_URL}")"
  if [[ ! -s "${local_img}" ]]; then
    curl -fL --retry 3 -o "${local_img}.part" "${IMAGE_URL}"
    mv "${local_img}.part" "${local_img}"
  fi
  os image create --disk-format qcow2 --container-format bare --public \
    --file "${local_img}" "${IMAGE}" >/dev/null
fi

step "Projeto ${PROJECT}, grupo ${GROUP}, usuario ${USER_NAME}"
if ! exists project "${PROJECT}" --domain default; then
  os project create --domain default --description "LarCerto - Trabalho 1" "${PROJECT}" >/dev/null
fi
if ! exists group "${GROUP}" --domain default; then
  os group create --domain default "${GROUP}" >/dev/null
fi

mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"
password_file="${SECRETS_DIR}/${USER_NAME}.password"
if [[ ! -s "${password_file}" ]]; then
  (umask 077 && openssl rand -base64 18 | tr -d '/+=' >"${password_file}")
fi
password="$(cat "${password_file}")"

if ! exists user "${USER_NAME}" --domain default; then
  os user create --domain default --project "${PROJECT}" \
    --password "${password}" "${USER_NAME}" >/dev/null
else
  # Mantem a senha do usuario igual a do arquivo (o arquivo pode ter sido recriado).
  os user set --password "${password}" "${USER_NAME}" >/dev/null
fi
# Idempotente: o Keystone aceita adicionar quem ja e membro.
os group add user "${GROUP}" "${USER_NAME}" >/dev/null
os role add --group "${GROUP}" --group-domain default \
  --project "${PROJECT}" --project-domain default member >/dev/null

step "Quotas do projeto ${PROJECT}"
os quota set --instances 10 --cores 16 --ram 8192 --floating-ips 10 "${PROJECT}" >/dev/null

auth_url="$(os endpoint list --service identity --interface public -f value -c URL | head -1)"
clouds_file="${SECRETS_DIR}/clouds.yaml"
(umask 077 && cat >"${clouds_file}" <<EOF
# Gerado por cloud/bootstrap.sh - NAO commitar.
clouds:
  larcerto-devops1:
    auth:
      auth_url: ${auth_url}
      project_name: ${PROJECT}
      project_domain_name: Default
      username: ${USER_NAME}
      user_domain_name: Default
      password: ${password}
    region_name: RegionOne
    identity_api_version: 3
EOF
)

echo
echo "Pronto. Como ${USER_NAME}:"
echo "  export OS_CLIENT_CONFIG_FILE=${clouds_file} OS_CLOUD=larcerto-devops1"
echo "  cd terraform && terraform init && terraform apply"
