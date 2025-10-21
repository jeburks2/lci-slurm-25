#!/usr/bin/env bash
set -euo pipefail

source 00_config.sh

echo-blue "Step 1/10 - Install Vault and prerequisites"
if ! rpm -q vault >/dev/null 2>&1; then
  cat > "/etc/yum.repos.d/hashicorp.repo" <<'REPO'
[hashicorp]
name=HashiCorp Stable - $basearch
baseurl=https://rpm.releases.hashicorp.com/RHEL/9/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://rpm.releases.hashicorp.com/gpg
REPO
  dnf -y makecache
  dnf -y install vault jq s2n-tls-devel
else
  echo-cyan "vault already installed"
fi

echo-blue "Step 2/10 - Configure Vault directories and storage backend"
# Purpose: set a simple file storage backend and a localhost listener for demo.
mkdir -p /etc/vault.d /var/lib/vault/data
chown -R vault:vault /etc/vault.d /var/lib/vault/data
VAULT_CONF_FILE=/etc/vault.d/vault.hcl
cat > "$VAULT_CONF_FILE" <<HCL
ui = false
api_addr="${VAULT_ADDR}"

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}

storage "file" {
  path = "/var/lib/vault/data"
}
HCL
chown vault:vault "$VAULT_CONF_FILE"
chmod 0640 "$VAULT_CONF_FILE"
echo-green "Wrote Vault config to $VAULT_CONF_FILE"

echo-blue "Step 3/10 - Start Vault service"
systemctl enable --now vault
sleep 2
systemctl is-active --quiet vault && echo-green "Vault service is active" || (journalctl -u vault -n 50 --no-pager; exit 1)
systemctl status vault --no-pager

echo-blue "Step 4/10 - Initialize Vault"
# create the root token and unseal keys
if [ -f "$ROOT_TOKEN_FILE" ] && [ -s "$ROOT_TOKEN_FILE" ]; then
  echo-cyan "Vault already initialized; using saved root token"
  ROOT_TOKEN="$(cat "$ROOT_TOKEN_FILE")"
else
  vault operator init -key-shares=5 -key-threshold=3 -format=json > /root/vault-init.json
  jq -r '.root_token' /root/vault-init.json > "$ROOT_TOKEN_FILE"
  jq -r '.unseal_keys_b64[]' /root/vault-init.json > "$UNSEAL_KEYS_FILE"
  chmod 600 "$ROOT_TOKEN_FILE" "$UNSEAL_KEYS_FILE"
  ROOT_TOKEN="$(cat "$ROOT_TOKEN_FILE")"
  echo-green "Initialized Vault; root token and unseal keys written to $ROOT_TOKEN_FILE and $UNSEAL_KEYS_FILE"
fi
export VAULT_TOKEN="$ROOT_TOKEN"

echo-blue "Step 5/10 - Unseal Vault"
# unseal keys until Vault reports unsealed
if vault status -format=json | jq -e '.sealed == false' >/dev/null 2>&1; then
  echo-cyan "Vault already unsealed"
else
 # Read the unseal keys from the file and unseal Vault
  while read -r key; do
    [ -z "$key" ] && continue
    vault operator unseal "$key" || true
    if vault status -format=json | jq -e '.sealed == false' >/dev/null 2>&1; then
      echo-green "Vault unsealed"
      break
    fi
  done < "$UNSEAL_KEYS_FILE"
  if vault status -format=json | jq -e '.sealed == true' >/dev/null 2>&1; then
    echo-red "Failed to unseal Vault after trying available keys" >&2
    exit 1
  fi
fi

echo-blue "Step 6/10 - Enable PKI secrets engine"
# enable Vault's PKI secrets engine under path pki if not present.
# Vault's PKI secrets engine is used to generate and manage the certificates and certificate authorities for the Slurm services
if vault secrets list -format=json | jq -e 'has("pki/")' >/dev/null 2>&1; then
  echo-cyan "PKI already enabled"
else
  vault secrets enable -path=pki pki
  vault secrets tune -max-lease-ttl=87600h pki
  echo-green "PKI enabled at path pki"
fi

echo-blue "Step 7/10 - Configure issuing and CRL URLs"
# set useful issuing and CRL endpoints in PKI metadata so clients can fetch CA and CRL
# A CA is a certificate authority that is used to sign the certificates for the Slurm services
# A CRL is a certificate revocation list that is used to revoke the certificates for the Slurm services
if vault read -field=issuing_certificates pki/config/urls >/dev/null 2>&1; then
  echo-cyan "Issuing and CRL URLs already configured in PKI"
else
  echo-white "Configuring issuing and CRL URLs in PKI"
  vault write pki/config/urls \
    issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
    crl_distribution_points="${VAULT_ADDR}/v1/pki/crl" > /dev/null 2>&1 || true
  echo-green "Configured issuing and CRL URLs in PKI"
fi

echo-blue "Step 8/10 - Enable Vault's key/value secrets engine at path node-tokens/"
if ! vault secrets list -format=json | jq -e "has(\"node-tokens/\")" >/dev/null 2>&1; then
  vault secrets enable -path=node-tokens kv-v2 >/dev/null 2>&1 || true
  echo-green "Enabled key/value secrets engine at path node-tokens/"
else
  echo-cyan "Key/value secrets engine already enabled at path node-tokens/"
fi

echo-blue "Step 9/10 - Create PKI role for Slurm"
# Purpose: define constraints (allowed domains, TTLs) for certificates issued to Slurm components
if vault read -field=role_name pki/roles/${ROLE_NAME} >/dev/null 2>&1; then
  echo-cyan "PKI role ${ROLE_NAME} already exists"
else
  vault write pki/roles/${ROLE_NAME} \
  allowed_domains="novalocal" \
  allow_any_name=true \
  allow_subdomains=true \
  use_csr_common_name=true \
  key_type=ec key_bits=256 \
  ttl=${CERT_TTL} \
  max_ttl="720h" > /dev/null 2>&1 || true
  echo-green "Created PKI role ${ROLE_NAME}"
fi

echo-blue "Step 10/10 - Create signing policy to allow Vault Agent to request certs and read node tokens"
# create a Vault policy that allows clients to call pki/sign/<role> as needed.
POLICY_FILE=/etc/vault.d/slurm-agent-policy.hcl
mkdir -p "$(dirname "$POLICY_FILE")"
cat > "$POLICY_FILE" << HCL
path "pki/sign/${ROLE_NAME}" {
  capabilities = ["update", "create", "read"]
}
path "pki/issue/${ROLE_NAME}" {
  capabilities = ["update", "create", "read"]
}
path "node-tokens/*" {
  capabilities = ["read","list"]
}
path "node-tokens/data/*" {
  capabilities = ["read","list"]
}
path "node-tokens/metadata/*" {
  capabilities = ["list"]
}
HCL
vault policy write "${POLICY_NAME}" "$POLICY_FILE" || true
echo-green "Wrote policy ${POLICY_NAME}"
cat "$POLICY_FILE"

echo-green "Vault setup complete"
echo-white "Root token saved at: $ROOT_TOKEN_FILE"
echo-white "Unseal keys saved at: $UNSEAL_KEYS_FILE"
echo-white "If you ever need to re-unseal Vault, you can rerun this script"
echo-green "Vault is ready to use! \n"

