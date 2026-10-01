#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ANSIBLE_PLAYBOOK="${SCRIPT_DIR}/playbooks/site.yml"
REQUIREMENTS="${SCRIPT_DIR}/requirements.yml"

DRY_RUN=false

case "${1:-}" in
    "")
        ;;
    --dry-run)
        DRY_RUN=true
        ;;
    *)
        echo "ERROR: unknown argument: $1"
        echo
        echo "Usage:"
        echo "  ./setup.sh"
        echo "  ./setup.sh --dry-run"
        exit 1
        ;;
esac

TMP_DIR=""
RUNTIME_INVENTORY=""
RUNTIME_VARS=""
VAULT_PASS_FILE=""
KNOWN_HOSTS_FILE=""

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf -- "${TMP_DIR}"
    fi
}

trap cleanup EXIT

trap '
    echo >&2
    echo "ERROR: setup failed on line ${LINENO}" >&2
' ERR

prompt_required() {
    local prompt="$1"
    local value=""

    while [[ -z "${value}" ]]; do
        read -r -p "${prompt}: " value
    done

    printf '%s' "${value}"
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value=""

    read -r -p "${prompt} [${default}]: " value

    if [[ -z "${value}" ]]; then
        value="${default}"
    fi

    printf '%s' "${value}"
}

prompt_secret_optional() {
    local prompt="$1"
    local value=""

    read -r -s -p "${prompt}: " value
    echo

    printf '%s' "${value}"
}

prompt_secret_required() {
    local prompt="$1"
    local value=""

    while [[ -z "${value}" ]]; do
        read -r -s -p "${prompt}: " value
        echo
    done

    printf '%s' "${value}"
}

yaml_quote() {
    local value="$1"

    value="${value//\'/\'\'}"

    printf "'%s'" "${value}"
}

if [[ ! -f "${ANSIBLE_PLAYBOOK}" ]]; then
    echo "ERROR: playbook not found:"
    echo "  ${ANSIBLE_PLAYBOOK}"
    exit 1
fi

if [[ ! -f "${REQUIREMENTS}" ]]; then
    echo "ERROR: requirements.yml not found:"
    echo "  ${REQUIREMENTS}"
    exit 1
fi

for command in ansible ansible-playbook ansible-galaxy ssh-keyscan; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "ERROR: required command not found: ${command}"
        exit 1
    fi
done

echo
echo "=============================================="
echo "       3x-ui Ansible node setup"
echo "=============================================="
echo

if [[ "${DRY_RUN}" == true ]]; then
    echo "Mode: DRY RUN"
    echo
fi

echo "Primary 3x-ui"
echo "-------------"

PRIMARY_URL="$(prompt_required "Primary 3x-ui URL")"
PRIMARY_IP="$(prompt_required "Primary IP/address")"
PRIMARY_API_TOKEN="$(prompt_secret_required "Primary admin API token")"

echo
echo "New node"
echo "--------"

NODE_NAME="$(prompt_default "Node name" "edge-01")"
NODE_IP="$(prompt_required "Node IP")"
NODE_ADDRESS="$(prompt_default "Node public/address" "${NODE_IP}")"

echo
echo "SSH"
echo "---"

SSH_USER="$(prompt_default "SSH user" "root")"
SSH_PORT="$(prompt_default "SSH port" "22")"

SSH_PASSWORD="$(prompt_secret_optional "SSH password (leave empty for SSH key)")"

SUDO_PASSWORD=""

if [[ -n "${SSH_PASSWORD}" ]]; then
    SUDO_PASSWORD="$(prompt_secret_optional "Sudo password (Enter = same as SSH password)")"

    if [[ -z "${SUDO_PASSWORD}" ]]; then
        SUDO_PASSWORD="${SSH_PASSWORD}"
    fi
else
    SUDO_PASSWORD="$(prompt_secret_optional "Sudo password (leave empty if passwordless sudo)")"
fi

if [[ -n "${SSH_PASSWORD}" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo
        echo "ERROR: sshpass is required for SSH password authentication."
        echo
        echo "Install it with:"
        echo "  sudo pacman -S sshpass"
        exit 1
    fi
fi

echo

TMP_DIR="$(mktemp -d -t 3xui-ansible.XXXXXXXX)"

chmod 700 "${TMP_DIR}"

RUNTIME_INVENTORY="${TMP_DIR}/inventory.yml"
RUNTIME_VARS="${TMP_DIR}/runtime.yml"
VAULT_PASS_FILE="${TMP_DIR}/vault-password"
KNOWN_HOSTS_FILE="${TMP_DIR}/known_hosts"

touch \
    "${RUNTIME_INVENTORY}" \
    "${RUNTIME_VARS}" \
    "${VAULT_PASS_FILE}" \
    "${KNOWN_HOSTS_FILE}"

chmod 600 \
    "${RUNTIME_INVENTORY}" \
    "${RUNTIME_VARS}" \
    "${VAULT_PASS_FILE}" \
    "${KNOWN_HOSTS_FILE}"

cat > "${RUNTIME_INVENTORY}" <<EOF
---
all:
  children:
    xui_nodes:
      hosts:
        xui-node:
          ansible_host: $(yaml_quote "${NODE_IP}")
          ansible_user: $(yaml_quote "${SSH_USER}")
          ansible_port: ${SSH_PORT}
          ansible_ssh_common_args: "-o UserKnownHostsFile=${KNOWN_HOSTS_FILE}"
EOF

chmod 600 "${RUNTIME_INVENTORY}"

cat > "${RUNTIME_VARS}" <<EOF
---
xui_primary_url: $(yaml_quote "${PRIMARY_URL}")
xui_primary_ip: $(yaml_quote "${PRIMARY_IP}")
xui_primary_api_token: $(yaml_quote "${PRIMARY_API_TOKEN}")
xui_primary_verify_tls: true

xui_node_name: $(yaml_quote "${NODE_NAME}")
xui_node_address: $(yaml_quote "${NODE_ADDRESS}")

xui_version: "v3.8.5"

xui_panel_port: 2053
xui_web_base_path: "/"

xui_node_scheme: "http"
xui_node_base_path: "/"
xui_node_api_port: 2053

xui_node_inbound_sync_mode: "selected"
xui_node_tls_verify_mode: "skip"

xui_inbounds:
  - name: "EVA04_vless"
    file: "EVA04_vless.json"

  - name: "EVA04_hysteria"
    file: "EVA04_hysteria.json"

  - name: "EVA04_troj"
    file: "EVA04_troj.json"
EOF

if [[ -n "${SSH_PASSWORD}" ]]; then
    printf '%s\n' \
        "ansible_password: $(yaml_quote "${SSH_PASSWORD}")" \
        >> "${RUNTIME_VARS}"
fi

if [[ -n "${SUDO_PASSWORD}" ]]; then
    printf '%s\n' \
        "ansible_become_password: $(yaml_quote "${SUDO_PASSWORD}")" \
        >> "${RUNTIME_VARS}"
fi

chmod 600 "${RUNTIME_VARS}"

: > "${VAULT_PASS_FILE}"
chmod 600 "${VAULT_PASS_FILE}"

echo "Installing Ansible collections..."
echo

ansible-galaxy collection install \
    -r "${REQUIREMENTS}"

if [[ "${DRY_RUN}" == true ]]; then
    echo
    echo "Generated inventory:"
    echo "--------------------"
    cat "${RUNTIME_INVENTORY}"

    echo
    echo "Generated runtime variables:"
    echo "----------------------------"

    sed \
        -e 's/^xui_primary_api_token:.*/xui_primary_api_token: "***REDACTED***"/' \
        -e 's/^ansible_password:.*/ansible_password: "***REDACTED***"/' \
        -e 's/^ansible_become_password:.*/ansible_become_password: "***REDACTED***"/' \
        "${RUNTIME_VARS}"

    echo
    echo "No SSH connection was attempted."
    echo "No Ansible playbook was executed."

    echo
    echo "=============================================="
    echo "       Dry run completed"
    echo "=============================================="
    echo

    exit 0
fi

echo "Checking SSH host key..."
echo

if ! ssh-keyscan \
    -p "${SSH_PORT}" \
    -H "${NODE_IP}" \
    >> "${KNOWN_HOSTS_FILE}" 2>/dev/null; then

    echo "ERROR: failed to obtain SSH host key."
    echo "Target: ${NODE_IP}:${SSH_PORT}"
    exit 1
fi

if [[ ! -s "${KNOWN_HOSTS_FILE}" ]]; then
    echo "ERROR: SSH host key was not obtained."
    echo "Target: ${NODE_IP}:${SSH_PORT}"
    exit 1
fi

echo
echo "Testing SSH connectivity..."
echo

ansible \
    -i "${RUNTIME_INVENTORY}" \
    xui_nodes \
    -m ansible.builtin.ping \
    -e "@${RUNTIME_VARS}"

echo
echo "Starting provisioning..."
echo

ansible-playbook \
    -i "${RUNTIME_INVENTORY}" \
    "${ANSIBLE_PLAYBOOK}" \
    -e "@${RUNTIME_VARS}" \
    --vault-password-file "${VAULT_PASS_FILE}"

echo
echo "=============================================="
echo "       3x-ui node setup completed"
echo "=============================================="
echo
echo "Node:"
echo "  Name:    ${NODE_NAME}"
echo "  Address: ${NODE_ADDRESS}"
echo

