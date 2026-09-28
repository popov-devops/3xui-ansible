# 3x-ui Ansible

Ansible-based automation for deploying and registering a new 3x-ui node with an existing primary 3x-ui instance.

The repository is designed for repeatable provisioning of single-node 3x-ui deployments on Ubuntu servers.

---

## Architecture

```text
                         ┌─────────────────────┐
                         │   PRIMARY 3x-ui     │
                         │                     │
                         │  Management / API   │
                         └──────────┬──────────┘
                                    │
                              Node API / Sync
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │     NEW NODE        │
                         │                     │
                         │      3x-ui          │
                         │                     │
                         │  VLESS      :443    │
                         │  Hysteria  :21123   │
                         │  Trojan    :21124   │
                         └─────────────────────┘
```

The Ansible control machine is the local workstation from which deployment is executed.

```text
Omarchy / Ansible Controller
            │
            │ SSH
            ▼
      Ubuntu VM / Node
            │
            │ 3x-ui API
            ▼
       Primary 3x-ui
```

---

## What it does

The deployment automates:

1. Ansible inventory generation
2. Ansible Vault configuration
3. Ubuntu base system preparation
4. Firewall configuration
5. Docker installation
6. 3x-ui deployment
7. 3x-ui container startup
8. Node API validation
9. Registration of the node in the primary 3x-ui instance

Current 3x-ui version:

```text
v3.8.5
```

Docker image:

```text
ghcr.io/mhsanaei/3x-ui:v3.8.5
```

---

## Requirements

### Control machine

Required:

- Git
- OpenSSH client
- Ansible
- `ansible-playbook`
- `ansible-vault`
- `ansible-galaxy`

Example on Arch Linux:

```bash
sudo pacman -S ansible openssh git
```

### Target server

The new node should provide:

- Ubuntu Server
- SSH access
- `root` or a user with sufficient `sudo` privileges
- Internet access
- x86_64/AMD64 architecture

The current Docker role assumes an AMD64 Ubuntu host.

---

## Quick start

Clone the repository:

```bash
git clone git@github.com:popov-devops/3xui-ansible.git
cd 3xui-ansible
```

Make the setup script executable:

```bash
chmod +x setup.sh
```

Validate it:

```bash
bash -n setup.sh
```

Run the provisioner:

```bash
./setup.sh
```

The script asks for:

- primary 3x-ui URL
- primary 3x-ui IP
- primary API token
- new node name
- new node IP
- new node address
- SSH username
- SSH port
- node API token
- Ansible Vault password

Generated secrets are stored in an encrypted Ansible Vault file.

---

## Deployment flow

```text
                    ./setup.sh
                         │
                         ▼
                Collect configuration
                         │
                         ▼
              Generate local inventory
                         │
                         ▼
               Create Ansible Vault
                         │
                         ▼
                 SSH connectivity
                         │
                         ▼
                  Ansible ping
                         │
                         ▼
              ┌────────────────────┐
              │   bootstrap.yml    │
              │                    │
              │  Ubuntu + UFW      │
              │  Docker            │
              └─────────┬──────────┘
                        │
                        ▼
              ┌────────────────────┐
              │     deploy.yml     │
              │                    │
              │     3x-ui          │
              │     Docker         │
              └─────────┬──────────┘
                        │
                        ▼
              ┌────────────────────┐
              │   3xui-node role   │
              │                    │
              │  Validate API      │
              │  Register node     │
              │  in primary        │
              └────────────────────┘
```

---

## Repository structure

```text
3xui-ansible/
├── setup.sh
├── ansible.cfg
├── requirements.yml
├── .gitignore
│
├── inventory/
│   └── production/
│       ├── hosts.yml
│       ├── group_vars/
│       │   ├── all.yml
│       │   └── vault.yml
│       └── host_vars/
│           └── xui-node.yml
│
├── playbooks/
│   ├── bootstrap.yml
│   ├── deploy.yml
│   └── site.yml
│
├── roles/
│   ├── common/
│   │   └── tasks/main.yml
│   ├── docker/
│   │   └── tasks/main.yml
│   ├── 3xui/
│   │   ├── tasks/main.yml
│   │   └── templates/compose.yml.j2
│   └── 3xui-node/
│       └── tasks/main.yml
│
└── inbounds/
    └── *.json
```

---

## Playbooks

### `bootstrap.yml`

Prepares the Ubuntu node:

- updates APT metadata
- installs base packages
- configures UFW
- allows SSH
- allows required proxy ports
- restricts the 3x-ui node API to the primary IP
- installs Docker

### `deploy.yml`

Deploys 3x-ui using Docker Compose.

The container uses:

```yaml
network_mode: host
```

Persistent data is stored under:

```text
/opt/3x-ui/
├── db/
├── cert/
└── acme/
```

### `site.yml`

Main entry point:

```text
bootstrap
    ↓
deploy 3x-ui
    ↓
register node in primary
```

Run manually:

```bash
ansible-playbook playbooks/site.yml
```

---

## 3x-ui configuration

Current node configuration:

| Service | Port | Protocol |
|---|---:|---|
| VLESS | `443` | TCP |
| Hysteria | `21123` | UDP |
| Trojan | `21124` | TCP |
| 3x-ui Node API | `2053` | HTTP |

The node API port is not intended to be publicly accessible.

UFW restricts port `2053` to the configured primary 3x-ui IP.

---

## Ansible Vault

Sensitive credentials are stored in:

```text
inventory/production/group_vars/vault.yml
```

This file must remain encrypted.

Example structure:

```yaml
---
xui_node_api_token: "..."
xui_primary_api_token: "..."
```

The actual file must never be committed to Git.

Check:

```bash
git status
```

and:

```bash
git ls-files | grep -E 'vault\.yml|inbounds/.*\.json'
```

The second command should return nothing for sensitive local files.

---

## Sensitive configuration

The following files are intentionally excluded from Git:

```text
inventory/production/group_vars/vault.yml
inventory/production/host_vars/*.yml
inbounds/*.json
```

Inbound configuration files may contain:

- client UUIDs
- passwords
- subscription identifiers
- Reality keys
- other authentication material

Do not commit them to a public repository.

---

## Firewall

The node firewall is configured using UFW.

Allowed inbound traffic:

```text
SSH                 configured SSH port
VLESS               TCP/443
Hysteria            UDP/21123
Trojan              TCP/21124
3x-ui Node API      TCP/2053 from PRIMARY_IP only
```

Default policy:

```text
INPUT   DROP
OUTPUT  ALLOW
```

Make sure the configured SSH port is correct before allowing Ansible to enable UFW.

---

## Manual Ansible usage

After `setup.sh` has generated the inventory and Vault, individual stages can be executed separately.

### Test inventory

```bash
ansible-inventory --graph
```

### Test connectivity

```bash
ansible xui_nodes -m ping
```

### Bootstrap

```bash
ansible-playbook playbooks/bootstrap.yml
```

### Deploy 3x-ui

```bash
ansible-playbook playbooks/deploy.yml
```

### Full deployment

```bash
ansible-playbook playbooks/site.yml
```

If Ansible Vault is required:

```bash
ansible-playbook   --ask-vault-pass   playbooks/site.yml
```

---

## Idempotency

The playbooks are designed to be safely re-run.

Running:

```bash
ansible-playbook playbooks/site.yml
```

multiple times should converge the node toward the desired state instead of creating duplicate Docker containers or repeatedly registering duplicate nodes.

The primary node registration logic checks for an existing node by name before creating or updating it.

---

## Security model

The initial implementation intentionally keeps the architecture simple.

### Primary → Node

The primary 3x-ui instance communicates with the node through its API.

### Firewall

The node API is restricted at the firewall level:

```text
PRIMARY_IP → NODE:2053
```

Other sources should not be able to access the node API.

### Secrets

Secrets are stored using Ansible Vault.

They are not intended to be stored in:

- Git
- `group_vars/all.yml`
- shell scripts
- Docker Compose files
- README documentation

---

## Current limitations

### Node API token

The node API token currently needs to be supplied during setup.

The long-term goal is to minimize manual steps during node provisioning.

### HTTP node API

The current configuration uses:

```text
http://NODE:2053
```

with the API protected by network-level restrictions.

A future implementation may use HTTPS and/or mTLS between the primary and nodes.

### Single-node inventory

The current setup script is optimized for provisioning one new node at a time.

The architecture can later be extended to manage multiple nodes from the same inventory.

### Inbound synchronization

The current configuration uses:

```yaml
xui_node_inbound_sync_mode: "all"
```

More granular inbound selection can be introduced later.

---

## Roadmap

- [ ] fully automate node API token creation
- [ ] add `--dry-run`
- [ ] add `--reconfigure`
- [ ] support multiple nodes in one inventory
- [ ] improve input validation
- [ ] use architecture-aware Docker repository configuration
- [ ] HTTPS/mTLS for primary ↔ node API
- [ ] certificate fingerprint pinning
- [ ] selective inbound synchronization
- [ ] automated subscription balancer configuration
- [ ] node health checks
- [ ] deployment rollback strategy
- [ ] CI validation with `ansible-lint`
- [ ] YAML validation
- [ ] ShellCheck
- [ ] GitHub Actions
- [ ] version pinning and controlled upgrades

---

## Versioning

3x-ui version is currently pinned to:

```text
v3.8.5
```

Docker image:

```text
ghcr.io/mhsanaei/3x-ui:v3.8.5
```

The version should be changed deliberately rather than automatically tracking `latest`.

---

## Development

Check Ansible syntax:

```bash
ansible-playbook --syntax-check playbooks/site.yml
```

Check inventory:

```bash
ansible-inventory --graph
```

Check target connectivity:

```bash
ansible xui_nodes -m ping
```

Recommended local checks before committing:

```bash
bash -n setup.sh
ansible-playbook --syntax-check playbooks/site.yml
git status
```

---

## Git security check

Before every commit:

```bash
git status
```

Then:

```bash
git diff --cached --name-only
```

Make sure sensitive files are absent.

Useful check:

```bash
git ls-files | grep -E   'vault\.yml|\.env|inbounds/.*\.json|\.pem$|\.key$'
```

No output should be produced for files containing credentials or private keys.

---

## License

This repository contains automation and configuration developed for personal infrastructure management.

The 3x-ui software itself is maintained by the upstream project:

https://github.com/MHSanaei/3x-ui

Refer to the upstream repository for its license and terms.
