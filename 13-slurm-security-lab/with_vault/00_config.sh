#!/usr/bin/env bash
# Vault address
export VAULT_ADDR=http://127.0.0.1:8200

# Path to root token file
# This token is used to authenticate with Vault as the admin
export ROOT_TOKEN_FILE=/root/vault-root-token

if [ -f "$ROOT_TOKEN_FILE" ] && [ -s "$ROOT_TOKEN_FILE" ]; then
  export VAULT_TOKEN="$(cat "$ROOT_TOKEN_FILE")"
fi

# Path to unseal keys file
# This file contains the unseal keys that are used to unseal the Vault
export UNSEAL_KEYS_FILE=/root/vault-unseal-keys

# Path to certificates output directory for the Slurm services
export OUTDIR=/etc/slurm/certmgr

# Path to the outputed public CA directory for the root CA
# The public CA is used to validate the certificates for the Slurm services
export CA_FILE=$OUTDIR/slurm_ca.pem

# Path to Vault token file slurm will use to sign certs 
export SLURM_TOKEN_FILE=$OUTDIR/vault-sink-token

# Policy name that slurm will use to authenticate with Vault using Vault's Token auth method
export POLICY_NAME=slurm-agent

# PKI role name for certificate issuance (independent of auth method)
export ROLE_NAME=slurm-agent

# Maximum TTL for generating certificates
export CERT_TTL="72h" # CERT_TTL defines the default/requested lifetime for each certificate (3 days)

# colored echo helpers
echo-red()     { echo -e "\033[1;31m$*\033[0m"; }
echo-green()   { echo -e "  \033[32m$*\033[0m"; }
echo-yellow()  { echo -e "  \033[33m$*\033[0m"; }
echo-blue()    { echo -e "\n\033[1;34m$*\033[0m\n"; }
echo-magenta() { echo -e "\033[35m$*\033[0m"; }
echo-cyan()    { echo -e "  \033[36m$*\033[0m"; }
echo-white()   { echo -e "  \033[37m$*\033[0m"; }