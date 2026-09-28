#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# 3x-ui Ansible Node Provisioner
# ============================================================

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

INVENTORY_DIR="${ROOT_DIR}/inventory/production"
GROUP_VARS_DIR="${INVENTORY_DIR}/group_vars"
HOST_VARS_DIR="${INVENTORY_DIR}/host_vars"

HOSTS_FILE="${INVENTORY_DIR}/hosts.yml"
ALL_VARS_FILE="${GROUP_VARS_DIR}/all.yml"
VAULT_FILE="${GROUP_VARS_DIR}/vault.yml"
HOST_VARS_FILE="${HOST_VARS_DIR}/xui-node.yml"

TMP_VAULT="$(mktemp)"
VAULT_PASSWORD_FILE="$(mktemp)"

cleanup() {
    rm -f "${TMP_VAULT}" "${VAULT_PASSWORD_FILE}"
}

trap cleanup EXIT

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo
    echo "==> $*"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ask_required() {
    local prompt="$1"
    local value

    while true; do
        read -r -p "${prompt}: " value

        if [[ -n "${value}" ]]; then
            printf '%s' "${value}"
            return
        fi

        echo "Value cannot be empty."
    done
}

ask_default() {
    local prompt="$1"
    local default="$2"
    local value

    read -r -p "${prompt} [${default}]: " value
    printf '%s' "${value:-$default}"
}

ask_secret() {
    local prompt="$1"
    local value

    while true; do
        read -r -s -p "${prompt}: " value
        echo

        if [[ -n "${value}" ]]; then
            printf '%s' "${value}"
            return
        fi

        echo "Value cannot be empty."
    done
}

# ------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------

cd "${ROOT_DIR}"

[[ -f "${ROOT_DIR}/ansible.cfg" ]] ||
    die "ansible.cfg not found."

[[ -f "${ROOT_DIR}/requirements.yml" ]] ||
    die "requirements.yml not found."

command_exists ansible ||
    die "Ansible is not installed."

command_exists ansible-playbook ||
    die "ansible-playbook is not installed."

command_exists ansible-vault ||
    die "ansible-vault is not installed."

command_exists ssh ||
    die "ssh is not installed."

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

clear 2>/dev/null || true

cat <<'EOF'

============================================================
             3x-ui Ansible Node Provisioner
============================================================

This script will:

  1. Configure a new 3x-ui node
  2. Generate local Ansible inventory
  3. Store secrets in Ansible Vault
  4. Bootstrap Ubuntu
  5. Install Docker
  6. Deploy 3x-ui
  7. Register the node in the primary 3x-ui

Secrets are NOT stored in Git.

============================================================

EOF

# ------------------------------------------------------------
# Input
# ------------------------------------------------------------

info "Primary 3x-ui"

PRIMARY_URL="$(ask_required 'Primary URL (example: https://panel.example.com)')"
PRIMARY_IP="$(ask_required 'Primary IP address')"
PRIMARY_API_TOKEN="$(ask_secret 'Primary API token')"

info "New node"

NODE_NAME="$(ask_default 'Node name' 'edge-01')"
NODE_IP="$(ask_required 'Node IP address')"
NODE_ADDRESS="$(ask_default 'Node address' "${NODE_IP}")"

SSH_USER="$(ask_default 'SSH user' 'root')"
SSH_PORT="$(ask_default 'SSH port' '22')"

info "3x-ui node API"

echo
echo "The node API token must already exist on the new 3x-ui node."
echo "It will be stored only inside Ansible Vault."
echo

NODE_API_TOKEN="$(ask_secret 'Node API token')"

info "Ansible Vault"

while true; do
    VAULT_PASSWORD="$(ask_secret 'Create Vault password')"
    VAULT_PASSWORD_CONFIRM="$(ask_secret 'Repeat Vault password')"

    if [[ "${VAULT_PASSWORD}" == "${VAULT_PASSWORD_CONFIRM}" ]]; then
        break
    fi

    echo
    echo "Vault passwords do not match."
    echo
done

printf '%s\n' "${VAULT_PASSWORD}" > "${VAULT_PASSWORD_FILE}"
chmod 600 "${VAULT_PASSWORD_FILE}"

# ------------------------------------------------------------
# Basic validation
# ------------------------------------------------------------

[[ "${SSH_PORT}" =~ ^[0-9]+$ ]] ||
    die "SSH port must be numeric."

[[ "${SSH_PORT}" -ge 1 && "${SSH_PORT}" -le 65535 ]] ||
    die "SSH port must be between 1 and 65535."

[[ "${NODE_IP}" != "${PRIMARY_IP}" ]] ||
    die "Primary IP and node IP are identical."

# ------------------------------------------------------------
# Create directories
# ------------------------------------------------------------

info "Creating Ansible structure"

mkdir -p \
    "${GROUP_VARS_DIR}" \
    "${HOST_VARS_DIR}"

# ------------------------------------------------------------
# Inventory
# ------------------------------------------------------------

cat > "${HOSTS_FILE}" <<EOF
---
all:
  children:
    xui_nodes:
      hosts:
        xui-node:
          ansible_host: "${NODE_IP}"
          ansible_user: "${SSH_USER}"
          ansible_port: ${SSH_PORT}
EOF

cat > "${HOST_VARS_FILE}" <<EOF
---
xui_node_name: "${NODE_NAME}"
xui_node_address: "${NODE_ADDRESS}"
EOF

# ------------------------------------------------------------
# Global variables
# ------------------------------------------------------------

cat > "${ALL_VARS_FILE}" <<EOF
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

xui_inbounds:
  - name: "EVA04_vless"
    file: "EVA04_vless.json"

  - name: "EVA04_hysteria"
    file: "EVA04_hysteria.json"

  - name: "EVA04_troj"
    file: "EVA04_troj.json"
EOF

# ------------------------------------------------------------
# Vault
# ------------------------------------------------------------

info "Preparing Ansible Vault"

if [[ -f "${VAULT_FILE}" ]]; then
    echo
    echo "Existing Vault found:"
    echo "  ${VAULT_FILE}"
    echo

    read -r -p "Overwrite existing Vault? [y/N]: " overwrite

    case "${overwrite}" in
        y|Y)
            rm -f "${VAULT_FILE}"
            ;;
        *)
            die "Existing Vault was not modified."
            ;;
    esac
fi

cat > "${TMP_VAULT}" <<EOF
---
xui_node_api_token: "${NODE_API_TOKEN}"
xui_primary_api_token: "${PRIMARY_API_TOKEN}"
EOF

chmod 600 "${TMP_VAULT}"

ANSIBLE_VAULT_PASSWORD_FILE="${VAULT_PASSWORD_FILE}" \
    ansible-vault encrypt \
    "${TMP_VAULT}"

mv "${TMP_VAULT}" "${VAULT_FILE}"

chmod 600 "${VAULT_FILE}"

# ------------------------------------------------------------
# Install collections
# ------------------------------------------------------------

info "Installing Ansible collections"

ansible-galaxy collection install \
    -r "${ROOT_DIR}/requirements.yml"

# ------------------------------------------------------------
# Inventory validation
# ------------------------------------------------------------

info "Validating inventory"

ANSIBLE_VAULT_PASSWORD_FILE="${VAULT_PASSWORD_FILE}" \
    ansible-inventory \
    --graph

echo

ANSIBLE_VAULT_PASSWORD_FILE="${VAULT_PASSWORD_FILE}" \
    ansible-inventory \
    --list >/dev/null

echo "Inventory: OK"

# ------------------------------------------------------------
# SSH connectivity
# ------------------------------------------------------------

info "Testing SSH connectivity"

echo
echo "Target:"
echo "  ${SSH_USER}@${NODE_IP}:${SSH_PORT}"
echo

read -r -p "Continue with SSH test? [Y/n]: " continue_ssh

if [[ ! "${continue_ssh}" =~ ^[nN]$ ]]; then

    ssh \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        -p "${SSH_PORT}" \
        "${SSH_USER}@${NODE_IP}" \
        'echo "SSH connection: OK"'
fi

# ------------------------------------------------------------
# Ansible ping
# ------------------------------------------------------------

info "Testing Ansible connectivity"

ANSIBLE_VAULT_PASSWORD_FILE="${VAULT_PASSWORD_FILE}" \
    ansible \
    xui_nodes \
    -m ping

# ------------------------------------------------------------
# Confirmation
# ------------------------------------------------------------

cat <<EOF

============================================================
Deployment target
============================================================

Primary:
  URL: ${PRIMARY_URL}
  IP:  ${PRIMARY_IP}

New node:
  Name:    ${NODE_NAME}
  Address: ${NODE_ADDRESS}
  IP:      ${NODE_IP}
  SSH:     ${SSH_USER}@${NODE_IP}:${SSH_PORT}

3x-ui:
  Version: v3.8.5
  API:     ${NODE_ADDRESS}:2053
  VLESS:   TCP/443
  Hysteria UDP/21123
  Trojan:  TCP/21124

============================================================

EOF

read -r -p "Run Ansible deployment now? [Y/n]: " deploy

if [[ "${deploy}" =~ ^[nN]$ ]]; then
    echo
    echo "Configuration created. Deployment skipped."
    echo
    echo "Run later with:"
    echo
    echo "  ANSIBLE_VAULT_PASSWORD_FILE=<password-file> ansible-playbook playbooks/site.yml"
    echo
    exit 0
fi

# ------------------------------------------------------------
# Deployment
# ------------------------------------------------------------

info "Running deployment"

ANSIBLE_VAULT_PASSWORD_FILE="${VAULT_PASSWORD_FILE}" \
    ansible-playbook \
    playbooks/site.yml

# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

cat <<EOF

============================================================
Deployment finished
============================================================

Node:
  ${NODE_NAME}

Inventory:
  ${HOSTS_FILE}

Vault:
  ${VAULT_FILE}

The Vault file is encrypted and excluded from Git.

Check repository state with:

  git status

============================================================

EOF
