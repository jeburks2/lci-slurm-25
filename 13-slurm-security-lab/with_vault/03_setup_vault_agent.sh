#!/usr/bin/env bash

set -euo pipefail
source 00_config.sh

if [ -z "${VAULT_TOKEN:-}" ]; then
  if [ -f "$ROOT_TOKEN_FILE" ] && [ -s "$ROOT_TOKEN_FILE" ]; then
    export VAULT_TOKEN="$(cat "$ROOT_TOKEN_FILE")"
  else
    echo-red "Error: VAULT_TOKEN is not set and root token file $ROOT_TOKEN_FILE does not exist or is empty" >&2
    exit 1
  fi
fi

echo-blue "Step 1/3 - Configure Vault Agent for Slurm cert management"
# Configure Vault Agent to use token authentication and request certs
# render separate key and cert files for each Slurm service, and restart services when certs are updated. 
# Agent will also renew certs automatically.
# See: https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent for details.

AGENT_CFG_DIR=/etc/vault-agent.d
TEMPLATE_DIR=${AGENT_CFG_DIR}/templates
AGENT_TOKEN_FILE=${AGENT_CFG_DIR}/vault-agent-token
mkdir -p "$AGENT_CFG_DIR" "$TEMPLATE_DIR" "$OUTDIR"
echo-white "Creating Vault Agent config at ${AGENT_CFG_DIR}/vault-agent.hcl"
cat > "$AGENT_CFG_DIR/vault-agent.hcl" <<HCL
pid_file = "/var/run/vault-agent-slurm.pid"

vault {
  address = "${VAULT_ADDR}"
  tls_skip_verify = true
  retry {
    num_retries = 5
  }
}

auto_auth {
  method "token_file" {
    config = {
      token_file_path = "${AGENT_TOKEN_FILE}"
    }
  }
  sink "file" {
    config = {
      path = "${SLURM_TOKEN_FILE}"
      owner = 600
      group = 600
      mode  = 256
    }
  }
}

# Templates: each template issues a cert and writes either a private key or a cert bundle
# The command runs after template render to set ownership and restart the consuming service.

# slurmctld (key + cert)
template {
  source      = "${TEMPLATE_DIR}/ctld_cert_key.tmpl"
  destination = "${OUTDIR}/slurmctld.key"
  perms       = "0400"
  command     = "bash -c 'chown slurm:slurm ${OUTDIR}/slurmctld.key || true; systemctl reload slurmctld || true'"
}
template {
  source      = "${TEMPLATE_DIR}/ctld_cert.tmpl"
  destination = "${OUTDIR}/slurmctld.pem"
  perms       = "0640"
  command     = "bash -c 'chown slurm:slurm ${OUTDIR}/slurmctld.pem || true; systemctl reload slurmctld || true'"
}

# slurmdbd (key + cert)
template {
  source      = "${TEMPLATE_DIR}/dbd_cert_key.tmpl"
  destination = "${OUTDIR}/slurmdbd.key"
  perms       = "0400"
  command     = "bash -c 'chown slurm:slurm ${OUTDIR}/slurmdbd.key || true; systemctl reload slurmdbd || true'"
}
template {
  source      = "${TEMPLATE_DIR}/dbd_cert.tmpl"
  destination = "${OUTDIR}/slurmdbd.pem"
  perms       = "0640"
  command     = "bash -c 'chown slurm:slurm ${OUTDIR}/slurmdbd.pem || true; systemctl reload slurmdbd || true'"
}

# slurmrestd (key + cert)
template {
  source      = "${TEMPLATE_DIR}/restd_cert_key.tmpl"
  destination = "${OUTDIR}/slurmrestd.key"
  perms       = "0400"
  command     = "bash -c 'chown slurmrestd:slurmrestd ${OUTDIR}/slurmrestd.key || true; systemctl reload slurmrestd || true'"
}
template {
  source      = "${TEMPLATE_DIR}/restd_cert.tmpl"
  destination = "${OUTDIR}/slurmrestd.pem"
  perms       = "0640"
  command     = "bash -c 'chown slurmrestd:slurmrestd ${OUTDIR}/slurmrestd.pem || true; systemctl reload slurmrestd || true'"
}
HCL

echo-white "Creating Vault Agent templates in ${TEMPLATE_DIR}"
# Templates used by Vault Agent to request certs (private key only)
cat > "${TEMPLATE_DIR}/ctld_cert_key.tmpl" <<T
{{- with secret "pki/issue/${ROLE_NAME}" "common_name=$(hostname -s)-ctld"  "ttl=${CERT_TTL}" -}}
{{ .Data.private_key }}
{{- end }}
T
cat > "${TEMPLATE_DIR}/dbd_cert_key.tmpl" <<T
{{- with secret "pki/issue/${ROLE_NAME}" "common_name=$(hostname -s)-dbd" "ttl=${CERT_TTL}" -}}
{{ .Data.private_key }}
{{- end }}
T
cat > "${TEMPLATE_DIR}/restd_cert_key.tmpl" <<T
{{- with secret "pki/issue/${ROLE_NAME}" "common_name=$(hostname -s)-restd" "ttl=${CERT_TTL}" -}}
{{ .Data.private_key }}
{{- end }}
T

cat > "${TEMPLATE_DIR}/ctld_cert.tmpl" <<T
{{- with secret "pki/issue/${ROLE_NAME}" "common_name=$(hostname -s)-ctld" "ttl=${CERT_TTL}" -}}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end }}
T
cat > "${TEMPLATE_DIR}/dbd_cert.tmpl" <<T
{{- with secret "pki/issue/${ROLE_NAME}" "common_name=$(hostname -s)-dbd" "ttl=${CERT_TTL}" -}}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end }}
T
cat > "${TEMPLATE_DIR}/restd_cert.tmpl" <<T
{{- with secret "pki/issue/${ROLE_NAME}" "common_name=$(hostname -s)-restd" "ttl=${CERT_TTL}" -}}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end }}
T

chmod 750 "$AGENT_CFG_DIR" "$TEMPLATE_DIR"
chmod 640 "$AGENT_CFG_DIR/vault-agent.hcl"
chmod 640 "${TEMPLATE_DIR}/"*.tmpl

echo-blue "Step 2/3 - Create limited-permission token for Vault Agent"
# Create a renewable token with the same limited permissions as the policy
# Token auth is simpler than AppRole - no role_id/secret_id complexity
echo-white "Creating Vault token with policy: ${POLICY_NAME}"

# Create token with limited permissions and long TTL
vault_token=$(vault token create \
  -policy="${POLICY_NAME}" \
  -ttl="8760h" \
  -renewable=true \
  -display-name="slurm-$(hostname -s)" \
  -metadata="service=slurm" \
  -metadata="node=$(hostname -s)" \
  -metadata="created=$(date -Iseconds)" \
  -format=json | jq -r '.auth.client_token')

# Ensure directory exists and save token securely
mkdir -p $(dirname "$AGENT_TOKEN_FILE")
printf '%s' "$vault_token" > "$AGENT_TOKEN_FILE"
chmod 0400 "$AGENT_TOKEN_FILE"

echo-blue "Step 3/3 - Create and enable systemd unit for Vault Agent"
echo-white "Creating systemd unit file for Vault Agent"
# Purpose: register Vault Agent as a per-host service that will manage auth and templating
# With token auth, we set VAULT_TOKEN environment variable from the token file
cat > "/etc/systemd/system/vault-agent@slurm.service" <<UNIT
[Unit]
Description=Vault Agent (slurm)
After=network.target

[Service]
User=root
ExecStart=/usr/bin/vault agent -config=${AGENT_CFG_DIR}/vault-agent.hcl
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

# Reload systemd and enable agent
echo-yellow "Reloading systemd and starting Vault Agent service"
systemctl daemon-reload
systemctl enable --now vault-agent@slurm || true
sleep 2
systemctl is-active --quiet vault-agent@slurm || (journalctl -u vault-agent@slurm -n 50 --no-pager; exit 1)
echo-green "Vault Agent service is active"
systemctl status vault-agent@slurm --no-pager

echo-blue "Verification - Vault Agent is running and has generated certs..."
sleep 3
[ -f ${OUTDIR}/slurmctld.key ] && [ -s ${OUTDIR}/slurmctld.key ] || (echo-red "slurmctld key missing" >&2; exit 1)
[ -f ${OUTDIR}/slurmctld.pem ] && [ -s ${OUTDIR}/slurmctld.pem ] || (echo-red "slurmctld cert missing" >&2; exit 1)
[ -f ${OUTDIR}/slurmdbd.key ] && [ -s ${OUTDIR}/slurmdbd.key ] || (echo-red "slurmdbd key missing" >&2; exit 1)
[ -f ${OUTDIR}/slurmdbd.pem ] && [ -s ${OUTDIR}/slurmdbd.pem ] || (echo-red "slurmdbd cert missing" >&2; exit 1)
[ -f ${OUTDIR}/slurmrestd.key ] && [ -s ${OUTDIR}/slurmrestd.key ] || (echo-red "slurmrestd key missing" >&2; exit 1)
[ -f ${OUTDIR}/slurmrestd.pem ] && [ -s ${OUTDIR}/slurmrestd.pem ] || (echo-red "slurmrestd cert missing" >&2; exit 1)

echo-green "Certificates setup complete!"
echo-white "The certs are:"
echo-white "  slurmctld key: ${OUTDIR}/slurmctld.key"
echo-white "  slurmctld cert: ${OUTDIR}/slurmctld.pem"
echo-white "  slurmdbd key: ${OUTDIR}/slurmdbd.key"
echo-white "  slurmdbd cert: ${OUTDIR}/slurmdbd.pem"
echo-white "  slurmrestd key: ${OUTDIR}/slurmrestd.key"
echo-white "  slurmrestd cert: ${OUTDIR}/slurmrestd.pem"
echo-white "Vault Agent will automatically renew these certs before they expire and reload the services"
echo-white "This script is idempotent and safe to re-run"
echo-green "Slurm certificates are ready to use! \n"

