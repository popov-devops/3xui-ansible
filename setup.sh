#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

INVENTORY_DIR="${ROOT_DIR}/inventory/production"
GROUP_VARS_DIR="${INVENTORY_DIR}/group_vars"
HOST_VARS_DIR="${INVENTORY_DIR}/host_vars"

HOSTS_FILE="${INVENTORY_DIR}/hosts.yml"
ALL_VARS_FILE="${GROUP_VARS_DIR}/all.yml"
VAULT_FILE="${GROUP_VARS_DIR}/vault.yml"
HOST_VARS_FILE="${HOST_VARS_DIR}/xui-node.yml"

MODE="deploy"

case "${1:-}" in
    --dry-run)
        MODE="dry-run"
        ;;
    --reconfigure)
        MODE="reconfigure"
        ;;
    --help|-h)
        cat <<USAGE
Usage:
  ./setup.sh
  ./setup.sh --reconfigure
  ./setup.sh --dry-run

Modes:
  default        Deploy or update node
  --reconfigure  Reconfigure existing deployment
  --dry-run      Validate configuration without changing remote hosts
USAGE
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

VAULT_PASSWORD_FILE="${TMP_DIR}/vault-password"
TMP_VAULT="${TMP_DIR}/vault.yml"
TMP_NODE_TOKEN="${TMP_DIR}/node-token"

mkdir -p \
    "${GROUP_VARS_DIR}" \
    "${HOST_VARS_DIR}"

echo "=== 3x-ui Ansible setup ==="
echo

read -r -p "Primary URL [https://192.168.1.100:2053]: " PRIMARY_URL
PRIMARY_URL="${PRIMARY_URL:-https://192.168.1.100:2053}"

read -r -p "Primary IP [192.168.1.100]: " PRIMARY_IP
PRIMARY_IP="${PRIMARY_IP:-192.168.1.100}"

read -r -s -p "Primary API token: " PRIMARY_API_TOKEN_INPUT
echo

read -r -p "Node name [edge-test-01]: " NODE_NAME
NODE_NAME="${NODE_NAME:-edge-test-01}"

read -r -p "Node IP [192.168.1.101]: " NODE_IP
NODE_IP="${NODE_IP:-192.168.1.101}"

read -r -p "Node address [${NODE_IP}]: " NODE_ADDRESS
NODE_ADDRESS="${NODE_ADDRESS:-${NODE_IP}}"

read -r -p "SSH user [root]: " SSH_USER
SSH_USER="${SSH_USER:-root}"

read -r -p "SSH port [22]: " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"

read -r -s -p "Ansible Vault password: " VAULT_PASSWORD
echo

printf '%s' "${VAULT_PASSWORD}" > "${VAULT_PASSWORD_FILE}"
chmod 600 "${VAULT_PASSWORD_FILE}"

export ANSIBLE_CONFIG="${ROOT_DIR}/ansible.cfg"

echo
echo "Preparing inventory..."

cat > "${HOSTS_FILE}" <<YAML
---
all:
  children:
    xui_nodes:
      hosts:
        xui-node:
          ansible_host: ${NODE_IP}
          ansible_user: ${SSH_USER}
          ansible_port: ${SSH_PORT}
YAML

cat > "${HOST_VARS_FILE}" <<YAML
---
xui_node_name: "${NODE_NAME}"
xui_node_address: "${NODE_ADDRESS}"
YAML

cat > "${ALL_VARS_FILE}" <<YAML
---
xui_version: "v3.8.5"
xui_image: "ghcr.io/mhsanaei/3x-ui:v3.8.5"

xui_container_name: "3x-ui"

xui_install_dir: "/opt/3x-ui"
xui_db_dir: "/opt/3x-ui/db"
xui_cert_dir: "/opt/3x-ui/cert"
xui_acme_dir: "/opt/3x-ui/acme"

xui_panel_port: 2053
xui_node_api_port: 2053

xui_restart_policy: "unless-stopped"

xui_node_scheme: "http"
xui_node_base_path: "/"

xui_primary_url: "${PRIMARY_URL}"
xui_primary_ip: "${PRIMARY_IP}"
xui_primary_verify_tls: true

xui_node_inbound_sync_mode: "all"
xui_node_tls_verify_mode: "skip"
YAML

echo "Checking Ansible..."

ansible-galaxy collection install -r "${ROOT_DIR}/requirements.yml"

ansible-inventory --graph
ansible-playbook --syntax-check "${ROOT_DIR}/playbooks/site.yml"

if [[ "${MODE}" == "dry-run" ]]; then
    echo
    echo "Dry-run checks passed."
    exit 0
fi

echo
echo "Testing SSH..."

ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    -p "${SSH_PORT}" \
    "${SSH_USER}@${NODE_IP}" \
    "true"

echo "SSH OK."

echo
echo "=== Bootstrap ==="

ansible-playbook "${ROOT_DIR}/playbooks/bootstrap.yml"

echo
echo "=== Deploy 3x-ui ==="

ansible-playbook "${ROOT_DIR}/playbooks/deploy.yml"

echo
echo "=== Reading existing Vault ==="

EXISTING_NODE_TOKEN=""

if [[ -f "${VAULT_FILE}" ]]; then
    ansible-vault view \
        --vault-password-file "${VAULT_PASSWORD_FILE}" \
        "${VAULT_FILE}" > "${TMP_VAULT}"

    EXISTING_NODE_TOKEN="$(
        awk -F': ' '$1 == "xui_node_api_token" {
            gsub(/^"/, "", $2)
            gsub(/"$/, "", $2)
            print $2
        }' "${TMP_VAULT}"
    )"
fi

if [[ -n "${PRIMARY_API_TOKEN_INPUT}" ]]; then
    PRIMARY_API_TOKEN="${PRIMARY_API_TOKEN_INPUT}"
else
    PRIMARY_API_TOKEN="$(
        awk -F': ' '$1 == "xui_primary_api_token" {
            gsub(/^"/, "", $2)
            gsub(/"$/, "", $2)
            print $2
        }' "${TMP_VAULT}" 2>/dev/null || true
    )"
fi

if [[ -z "${PRIMARY_API_TOKEN}" ]]; then
    echo "ERROR: Primary API token is required."
    exit 1
fi

if [[ -n "${EXISTING_NODE_TOKEN}" ]]; then
    echo "Node API token already exists in Vault."
    NODE_API_TOKEN="${EXISTING_NODE_TOKEN}"
else
    echo "Node API token not found. Generating it once..."

    ansible-playbook \
        "${ROOT_DIR}/playbooks/generate-node-token.yml" \
        -e "token_output_file=${TMP_NODE_TOKEN}"

    NODE_API_TOKEN="$(cat "${TMP_NODE_TOKEN}")"

    if [[ -z "${NODE_API_TOKEN}" ]]; then
        echo "ERROR: Failed to obtain node API token."
        exit 1
    fi

    echo "Node API token generated."
fi

echo
echo "Updating Vault..."

cat > "${TMP_VAULT}" <<YAML
---
xui_primary_api_token: "${PRIMARY_API_TOKEN}"
xui_node_api_token: "${NODE_API_TOKEN}"
YAML

ansible-vault encrypt \
    --vault-password-file "${VAULT_PASSWORD_FILE}" \
    "${TMP_VAULT}"

mv "${TMP_VAULT}" "${VAULT_FILE}"

chmod 600 "${VAULT_FILE}"

echo
echo "=== Register node in primary ==="

ansible-playbook "${ROOT_DIR}/playbooks/register.yml"

echo
echo "========================================"
echo "Deployment completed."
echo "========================================"
echo
echo "Primary: ${PRIMARY_URL}"
echo "Node:    ${NODE_NAME} (${NODE_ADDRESS})"
echo
echo "Vault:   ${VAULT_FILE}"
echo
