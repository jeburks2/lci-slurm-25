# LCI Advanced 2025 - Slurm mTLS Certificate Management with HashiCorp Vault - Lab Guide

## Lab Overview

In this hands-on session, you'll implement a complete certificate management solution for Slurm using HashiCorp Vault as a Certificate Authority (CA) and key-value store. This lab demonstrates enterprise-grade security practices for HPC environments.

### Prerequisites

- Cluster with 1 head node running slurmctld, slurmdbd, and slurmrestd and at least 1 compute node running slurmd (provided)
- Slurm 25.05 or later compiled with s2n support
- jq package installed on the head node
- Passwordless SSH access from head node to compute nodes

## Architecture Overview

This solution implements a comprehensive certificate management system:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                          HashiCorp Vault Server                             │
│                                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐              │
│  │   PKI Engine    │  │  KV Secrets v2  │  │  Token Auth     │              │
│  │                 │  │                 │  │                 │              │
│  │ • Root CA       │  │ • Node tokens   │  │ • Agent tokens  │              │
│  │ • Cert signing  │  │ • Per-node auth │  │ • Policies      │              │
│  │ • Auto-renewal  │  │ • Secure store  │  │ • TTL/renewal   │              │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘              │
└─────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        │ Vault API
                                        │ Certificate Operations
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Slurm Head Node                                   │
│                                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐              │
│  │   Slurmctld     │  │   Slurmdbd      │  │  Slurmrestd     │              │
│  │                 │  │                 │  │                 │              │
│  │ • TLS enabled   │  │ • TLS enabled   │  │ • TLS enabled   │              │
│  │ • Vault certs   │  │ • Vault certs   │  │ • Vault certs   │              │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘              │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    Vault Integration                                  │  │
│  │                                                                       │  │
│  │ • Vault Agent (auto-renewal service)                                  │  │
│  │ • Certificate management scripts                                      │  │
│  │ • Token-based authentication                                          │  │
│  │ • CSR signing via Vault API (slurmctld_sign_csr)                      │  │
│  │ • Node token validation (slurmctld_validate_node_token)               │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        │ mTLS Communication
                                        │ Certificate Signing
                                        │
                    ┌───────────────────┼───────────────────┐
                    │                   │                   │
                    ▼                   ▼                   ▼
        ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
        │ Compute Node 1  │ │ Compute Node 2  │ │ Compute Node N  │
        │                 │ │                 │ │                 │
        │ ┌─────────────┐ │ │ ┌─────────────┐ │ │ ┌─────────────┐ │
        │ │   Slurmd    │ │ │ │   Slurmd    │ │ │ │   Slurmd    │ │
        │ │             │ │ │ │             │ │ │ │             │ │
        │ │• TLS enabled│ │ │ │• TLS enabled│ │ │ │• TLS enabled│ │
        │ │• Vault certs│ │ │ │• Vault certs│ │ │ │• Vault certs│ │
        │ └─────────────┘ │ │ └─────────────┘ │ │ └─────────────┘ │
        │                 │ │                 │ │                 │
        │ Scripts:        │ │ Scripts:        │ │ Scripts:        │
        │ • CSR generation│ │ • CSR generation│ │ • CSR generation│
        │ • Key retrieval │ │ • Key retrieval │ │ • Key retrieval │
        │ • Token auth    │ │ • Token auth    │ │ • Token auth    │
        │ • Vault CA cert │ │ • Vault CA cert │ │ • Vault CA cert │
        └─────────────────┘ └─────────────────┘ └─────────────────┘

Certificate Lifecycle with Vault:
1. Node generates CSR using slurmd_generate_csr.sh
2. Node presents token using slurmd_get_node_token.sh  
3. Head node validates token against Vault KV store
4. Head node signs CSR using Vault PKI engine
5. Node retrieves private key using slurmd_get_cert_key.sh
6. Vault Agent automatically renews certificates before expiration
7. mTLS communication established with Vault-issued certificates
```

## Important Note About Vault Setup

HashiCorp Vault is a sophisticated secrets management platform with extensive configuration options for production environments. Proper production setup involves considerations for high availability, disaster recovery, hardware security modules (HSMs), enterprise authentication backends, and complex policy frameworks.

**For simplicity in this lab**, the provided scripts will set up Vault with a basic file storage backend and minimal configuration suitable for learning and demonstration purposes. This setup is **not recommended for production use** but allows you to focus on understanding the certificate management concepts without getting overwhelmed by Vault's operational complexity.

## Slurm Security Plugins Overview

This lab configures three key Slurm security plugins:

### TLS Plugin (`tls/s2n`)

- **Purpose**: Handles the underlying TLS/SSL encryption and certificate validation
- **Implementation**: Uses AWS's s2n-tls (signal-to-noise) library for cryptographic operations
- **Function**: Establishes secure channels between Slurm daemons (slurmctld, slurmd, slurmdbd, slurmrestd) and client commands

### Certmgr Plugin (`certmgr/script`)

- **Purpose**: Manages certificate lifecycle through external scripts
- **Implementation**: Calls user-defined scripts for certificate operations (generation, signing, retrieval)
- **Function**: Integrates Slurm with external certificate authorities (like Vault)
- **Scripts**: Generate CSRs, sign certificates, validate node tokens, retrieve keys

### Certgen Plugin (`certgen/script`)

- **Purpose**: Generates certificates on the fly for client commands
- **Implementation**: Built-in certificate generation without external scripts
- **Function**: Self-signed certificates or simple CA integration
- **Scripts**: Slurm ships with basic scripts to generate certificates, but custom scripts can be provided



### Directory Structure

This lab will create the following directory structure on the head node:

```text
/etc/slurm/certmgr/
├── slurm_ca.pem                        # Root CA certificate
├── slurmctld.key                       # Slurmctld private key (Managed by vault-agent)
├── slurmctld.pem                       # Slurmctld certificate (Managed by vault-agent)
├── slurmdbd.key                        # Slurmdbd private key (Managed by vault-agent)
├── slurmdbd.pem                        # Slurmdbd certificate (Managed by vault-agent)
├── slurmrestd.key                      # Slurmrestd private key (Managed by vault-agent)
├── slurmrestd.pem                      # Slurmrestd certificate (Managed by vault-agent)
├── slurmctld_validate_node_token.sh    # Script to verify authenticity of a node
├── slurmctld_sign_csr.sh               # Script to sign certificate signing requests
└── vault-sink-token                    # Token Slurm uses to interface with Vault (Managed by vault-agent)

/etc/vault.d/
├── vault.hcl                           # Vault server configuration file

/etc/vault-agent.d/
├── vault-agent-slurm.hcl               # Vault Agent configuration for Slurm
├── vault-agent-token                   # Token file Vault Agent uses to authenticate with Vault
├── templates/
│   ├── ctld_cert_key.tmpl               # Template for Vault Agent to write Slurmctld key
│   ├── ctld_cert.tmpl                   # Template for Vault Agent to write Slurmctld cert
│   ├── dbd_cert_key.tmpl                # Template for Vault Agent to write Slurmdbd key
│   ├── dbd_cert.tmpl                    # Template for Vault Agent to write Slurmdbd cert
│   ├── restd_cert_key.tmpl              # Template for Vault Agent to write Slurmrestd key
│   └── restd_cert.tmpl                  # Template for Vault Agent to write Slurmrestd cert
```

This lab will create the following directory structure on the compute nodes:

```text
/etc/slurm/certmgr/
├── slurm_ca.pem                 # Root CA certificate
├── slurmd.key                   # Slurmd private key
├── token                        # Pre-Shared Token authorizing a node to request a certificate
├── slurmd_get_node_token.sh     # Script slurmd calls to retrieve the node token
├── slurmd_generate_csr.sh       # Script slurmd calls to generate certificate signing request
└── slurmd_get_cert_key.sh       # Script slurmd calls to retrieve certificate's private key
```

## Lab Execution Steps

### Step 0: Cluster State Verification

Before proceeding, verify your cluster is operational and the s2n-tls library is installed on all nodes:

```bash
# Verify controller and database daemons are running
scontrol ping
sacctmgr ping

# Verify nodes are online
sinfo
scontrol show nodes

# Ensure jq can parse node information
scontrol show nodes --json | jq -r '.nodes[].hostname'

# Install s2n-tls-devel on all nodes if not already installed
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
    ssh $node "dnf -yq install s2n-tls-devel"
done
```

## Step 1: Prepare and Run Setup Scripts

Download this git repository to your Slurm head node and run the provided vault setup script on the head node:

```bash
git clone https://github.com/jeburks2/lci-slurm-25/
cd lci-slurm-25/13-slurm-security-lab/with_vault
./01_setup_vault.sh
```

Vault is a complex system with many configuration options. The provided script sets up a basic Vault server with a file storage backend, initializes and unseals it, and configures the PKI and KV secrets engines for this lab. It also creates the necessary policies, roles, and tokens for Slurm integration, creating a role that allows Slurm to request certificates and store node tokens.
Since this lab is about Slurm TLS and not Vault administration, we recommend using the provided script as-is to avoid unnecessary complexity.

After running this script, you can verify Vault is running and the token authentication method is enabled.

   ```bash
   source 00_config.sh
   vault status
   systemctl status vault
   vault token lookup
   ```

## Step 2: Generate a Root CA

We need to generate a root CA certificate using vault, it will be used to sign all Slurm service certificates.

   ```bash
   source 00_config.sh
   vault write -field=certificate pki/root/generate/internal common_name="slurm-internal-ca" issuer_name="LCI-Advanced-2025" ttl="87600h" > /etc/slurm/certmgr/slurm_ca.pem
   chmod 0644 /etc/slurm/certmgr/slurm_ca.pem
   ```

The private key is securely stored within vault, and the public CA certificate is exported to `/etc/slurm/certmgr/slurm_ca.pem` for use by Slurm services.

View the generated CA certificate:

```bash
openssl x509 -in /etc/slurm/certmgr/slurm_ca.pem -text -noout
```

Then, install the root CA into the system trust store so that all services on the node trust certificates signed by this CA.

```bash
cp /etc/slurm/certmgr/slurm_ca.pem /etc/pki/ca-trust/source/anchors/
update-ca-trust extract
```

Then, push this CA certificate to all compute nodes:

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
    ssh root@"$node" "mkdir -p /etc/slurm/certmgr"
    scp /etc/slurm/certmgr/slurm_ca.pem $node:/etc/slurm/certmgr/slurm_ca.pem
    ssh $node "cp /etc/slurm/certmgr/slurm_ca.pem /etc/pki/ca-trust/source/anchors/ && update-ca-trust extract"
done
```

## Step 3: Setup Vault Agent for Certificate Management

Vault Agent is a lightweight process that automates authentication and secret retrieval from Vault. In this lab, Vault Agent will manage the lifecycle of Slurm service certificates, automatically renewing them before expiration.
Run the provided setup script to install and configure Vault Agent on the head node:

```bash
./03_setup_vault_agent.sh
```

This script creates the necessary configuration files, systemd service units, templates for Vault Agent to manage Slurm certificates, and a token file for Vault authentication. It also starts the Vault Agent service and verifies the certificates are generated. Vault Agent also creates a sink file for Slurmctld to use to sign CSRs and validate node tokens.

Verify the certificates are created and linked to the CA:

```bash
ls -la /etc/slurm/certmgr/
openssl x509 -in /etc/slurm/certmgr/slurmctld.pem -text -noout
openssl verify -CAfile /etc/slurm/certmgr/slurm_ca.pem /etc/slurm/certmgr/slurmctld.pem
```

## Step 4: Generate Node Private Keys

In order for compute nodes to request certificates, they need to have a private key for which to generate a CSR. We can use Vault to generate these keys securely.

```bash
source 00_config.sh
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
   vault write -field=private_key "pki/issue/${ROLE_NAME}" common_name="${node}-slurmd" ttl="${CERT_TTL}" > /tmp/${node}_slurmd_key.pem
   scp /tmp/${node}_slurmd_key.pem $node:/etc/slurm/certmgr/slurmd.key
   rm -f /tmp/${node}_slurmd_key.pem
done
```

## Step 5: Generate Node Tokens

Each compute node needs a pre-shared token to authenticate with slurmctld when requesting a certificate. Slurmctl validates this token belongs to this node when the CSR is received. Vault has a key-value secrets engine that we can use to store these tokens. We will generate these tokens and store them in Vault's KV secrets engine.

```bash
source 00_config.sh
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
   vault kv put "node-tokens/${node}" token="$(openssl rand -hex 32)"
done
```

Then, distribute these tokens to each compute node:

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
   vault kv get -field=token "node-tokens/${node}" | ssh $node "tee /etc/slurm/certmgr/token"
done
```

## Step 6: Install Certificate Management Scripts

The certmgr plugin requires several scripts to handle certificate operations. Slurm does not provide these scripts out of the box, so we will create custom scripts that interface with Vault to perform these operations.

### Create slurmctld_validate_node_token Script

The slurmctld_validate_node_token script is responsible for validating the authenticity of a compute node by checking its presented token against the token stored in Vault's KV secrets engine. The script is passed the node name and token as arguments $1 and $2 and compares the presented token to the known token stored in Vault. It only needs to be present on the head node.

```bash
cat > ${OUTDIR}/slurmctld_validate_node_token.sh << EOF
#!/bin/bash
set -euo pipefail
NODE_NAME="\${1:-}"
NODE_TOKEN="\${2:-}"
VAULT_ADDR="${VAULT_ADDR}"
VAULT_TOKEN=\$(cat "${SLURM_TOKEN_FILE}")
known_token=\$(VAULT_ADDR="\$VAULT_ADDR" VAULT_TOKEN="\$VAULT_TOKEN" vault kv get -field=token "node-tokens/\$NODE_NAME") || {
  echo "Error retrieving token for node \$NODE_NAME" >&2
  exit 1
}
[ "\$known_token" != "\$NODE_TOKEN" ] && { echo "Invalid token for node \$NODE_NAME" >&2; exit 1; }
exit 0
EOF
chown slurm:slurm /etc/slurm/certmgr/slurmctld_validate_node_token.sh
chmod 700 /etc/slurm/certmgr/slurmctld_validate_node_token.sh
```

### Create slurmctld_sign_csr Script

The slurmctld_sign_csr script is responsible for signing CSRs submitted by compute nodes. It uses the Vault API to sign the CSR using the PKI engine. It only needs to be present on the head node.

```bash
source 00_config.sh
cat > /etc/slurm/certmgr/slurmctld_sign_csr.sh << EOF
#!/bin/bash
set -euo pipefail
CSR="\${1:-}"
VAULT_ADDR="${VAULT_ADDR}"
VAULT_TOKEN=\$(cat "${SLURM_TOKEN_FILE}")
[ -z "\$CSR" ] && { echo "Usage: \$0 <csr>" >&2; exit 1; }
VAULT_ADDR="\$VAULT_ADDR" VAULT_TOKEN="\$VAULT_TOKEN" \
  vault write -field=certificate pki/sign/slurm-agent csr="\$CSR" ttl=72h use_csr_common_name=true
EOF
chown slurm:slurm /etc/slurm/certmgr/slurmctld_sign_csr.sh
chmod 700 /etc/slurm/certmgr/slurmctld_sign_csr.sh
```

### Create the slurmd_get_node_token Script

The slurmd_get_node_token script retrieves the node's token from the filesystem. It only needs to be present on compute nodes.

```bash
cat > "/etc/slurm/certmgr/slurmd_get_node_token.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
TOKEN_PATH="/etc/slurm/certmgr/token"
[ -f "$TOKEN_PATH" ] || { echo "$0: token missing"; exit 1; }
cat "$TOKEN_PATH"
exit 0
EOF
```

### Create the slurmd_generate_csr Script

The slurmd_generate_csr script generates a CSR using the node's private key. It only needs to be present on compute nodes.

```bash
cat > "/etc/slurm/certmgr/slurmd_generate_csr.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
KEY="/etc/slurm/certmgr/slurmd.key"
[[ ! -f "$KEY" ]] && { echo "$0: Cannot find node private key at '$KEY'" ; exit 1; }
openssl req -new -key "$KEY" -subj "/C=US/ST=Oklahoma/L=Norman/O=LinuxClusterInstitute/OU=LCIAdvancedSlurm2025/CN=$(hostname -s)"
[[ $? -eq 0 ]] && exit 0 || echo "$0: Failed to generate certificate signing request"
exit 1
EOF
```

### Create the slurmd_get_cert_key Script

The slurmd_get_cert_key script retrieves the node's private key from the filesystem. It only needs to be present on compute nodes.

```bash
cat > "/etc/slurm/certmgr/slurmd_get_cert_key.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
KEY_FILE="/etc/slurm/certmgr/slurmd.key"
[ -r "$KEY_FILE" ] || { echo "key missing" >&2; exit 1; }
cat "$KEY_FILE"
exit 0
EOF
```

### Deploy Scripts to Compute Nodes

Now copy all three scripts to each compute node and set proper permissions:

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
    for script in slurmd_get_cert_key.sh slurmd_generate_csr.sh slurmd_get_node_token.sh; do
        scp /etc/slurm/certmgr/${script} $node:/etc/slurm/certmgr/${script}
    done
    ssh $node "chmod 700 /etc/slurm/certmgr/*.sh"
done
# Cleanup temporary scripts from head node
rm -f /etc/slurm/certmgr/slurmd_*.sh
```

## Step 7: Configure Slurm

Now that the certificates and scripts are in place, we need to configure Slurm to use mTLS with the certmgr and certgen plugins and where to find the scripts and certificates.

### Configure Compute Nodes

First, we need to tell slurmd where to find the CA by adding the --ca_cert_file parameter to slurmd when it starts. If this parameter is set, slurmd will attempt to load the s2n TLS plugin and use mTLS for communication with slurmctld.
We can do this by editing /etc/default/slurmd and adding the following line:

`SLURMD_OPTIONS= --ca-cert-file=/etc/slurm/certmgr/slurm_ca.pem\"`

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
   ssh $node 'eval "$(grep -m1 "^SLURMD_OPTIONS=" /etc/default/slurmd)"; printf "%s\n" "SLURMD_OPTIONS=\"${SLURMD_OPTIONS} --ca-cert-file=/etc/slurm/certmgr/slurm_ca.pem\"" > /etc/default/slurmd'
done
```

### Configure The Head Node

Then, add these lines to `/etc/slurm/slurm.conf`

```conf
TLSType=tls/s2n
TLSParameters=ca_cert_file=/etc/slurm/certmgr/slurm_ca.pem,ctld_cert_file=/etc/slurm/certmgr/slurmctld.pem,ctld_cert_key_file=/etc/slurm/certmgr/slurmctld.key,restd_cert_file=/etc/slurm/certmgr/slurmrestd.pem,restd_cert_key_file=/etc/slurm/certmgr/slurmrestd.key
CertmgrType=certmgr/script
CertmgrParameters=generate_csr_script=/etc/slurm/certmgr/slurmd_generate_csr.sh,get_node_cert_key_script=/etc/slurm/certmgr/slurmd_get_cert_key.sh,get_node_token_script=/etc/slurm/certmgr/slurmd_get_node_token.sh,sign_csr_script=/etc/slurm/certmgr/slurmctld_sign_csr.sh,validate_node_script=/etc/slurm/certmgr/slurmctld_validate_node_token.sh
CertgenType=certgen/script
```

And finally, add these lines to `/etc/slurm/slurmdbd.conf`

```conf
TLSType=tls/s2n
TLSParameters=ca_cert_file=/etc/slurm/certmgr/slurm_ca.pem,dbd_cert_file=/etc/slurm/certmgr/slurmdbd.pem,dbd_cert_key_file=/etc/slurm/certmgr/slurmdbd.key
```

### Restart Head Node Services

```bash
systemctl restart slurmctld.service
systemctl restart slurmdbd.service
systemctl restart slurmrestd.service
```

### Verify Head Node is Ready

Ensure Slurm controller and database are responding before proceeding:

```bash
scontrol ping
sacctmgr ping
```

Expected output should show the controller responding. If there are errors, check the Slurm logs:

```bash
journalctl -u slurmctld.service -f
```

### Restart Compute Node Services

Once the head node is confirmed working, restart the compute nodes:

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
    ssh $node "systemctl restart slurmd.service"
done
```

### Final Verification

Verify all nodes are communicating with TLS:

```bash
sinfo
scontrol show nodes
```

All nodes should show as available. If any nodes show as down, check their logs:

```bash
ssh <nodename> "journalctl -u slurmd.service -f"
```

## Step 9: Verify TLS is Working

This step confirms that your Slurm cluster is successfully using TLS encryption for all communications. You'll submit a test job and verify that certificates are being generated and used properly.

### Submit a Test Job

```bash
srun --nodes=1 --ntasks=1 hostname
```

This should complete successfully, demonstrating that TLS communication is working between the head node and compute nodes.

### Check Certificate Generation

Verify that dynamic certificates are being created on the compute nodes by checking the certmgr state file:

```bash
cat /var/spool/slurmd/certmgr_state
```

You should see certificate files being created as needed for client communications.

## Step 10: Advanced TLS Debugging (Bonus)

These optional steps help you understand how Slurm's TLS implementation works under the hood and provide debugging techniques for troubleshooting certificate issues.

### Watch Certgen Certificate Generation in Real-Time

Run `scontrol ping` with strace to see Certgen plugin's certificate generation in action:

```bash
strace -s 99 -e trace=openat,memfd_create,write,access,read scontrol ping
```

The output is quite verbose, so we can filter out the binary read/writes with:

```bash
strace -s 99 -e trace=openat,memfd_create,write,access,read scontrol ping 2>&1 | grep -Pv '[^\x09\x0A\x20-\x7E]' | grep -Pv '\\([0-7]{1,3}|x[0-9A-Fa-f]{2})|\\177ELF'
```

Notice the lines where keygen.sh and certgen.sh are ephemerally created and called. These are built in scripts that [ship with slurm](https://github.com/SchedMD/slurm/blob/35dcdcb813f5863c7edaffb1ee8eb0dbe071b9e0/src/plugins/certgen/script/certgen.sh.txt), but can be customized.

```bash
memfd_create("keygen.sh", MFD_CLOEXEC)  = 4
write(4, "#!/bin/sh\nopenssl ecparam -name prime256v1 -genkey\n", 51) = 51
access("/proc/21384/fd/4", R_OK|X_OK)   = 0
read(5, "-----BEGIN EC PARAMETERS-----\nBggqhkjOPQMBBw==\n-----END EC PARAMETERS-----\n-----BEGIN EC PRIVATE KE"..., 1024) = 302
--- SIGCHLD {si_signo=SIGCHLD, si_code=CLD_EXITED, si_pid=21385, si_uid=0, si_status=0, si_utime=0, si_stime=0} ---
memfd_create("certgen.sh", MFD_CLOEXEC) = 4
write(4, "#!/bin/sh\nprintf '%s' \"$1\" | openssl req -x509 -key /dev/stdin -subj \"/C=XX/ST=StateName/L=CityName"..., 152) = 152
access("/proc/21384/fd/4", R_OK|X_OK)   = 0
read(5, "-----BEGIN CERTIFICATE-----\nMIICUDCCAfWgAwIBAgIUZ1aUzoyAbGi56/gDCVWd5Q4gZwQwCgYIKoZIzj0EAwIw\nfTELMA"..., 1024) = 863
--- SIGCHLD {si_signo=SIGCHLD, si_code=CLD_EXITED, si_pid=21387, si_uid=0, si_status=0, si_utime=0, si_stime=0} ---
```

If we write our own keygen and certgen scripts

```bash
cat > /usr/local/bin/mykeygen.sh << 'EOF'
#!/bin/sh
wall -n "Generating Key with $0"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256
EOF
chmod 755 /usr/local/bin/mykeygen.sh

cat > /usr/local/bin/mycertgen.sh << 'EOF'
#!/bin/sh
wall -n "Generating Cert With $0"
printf '%s' "$1" | openssl req -x509 -key /dev/stdin -subj "/C=US/ST=Oklahoma/L=Norman/O=LinuxClusterInstitute/OU=LCIAdvancedSlurm2025/CN=$(hostname -s)"
EOF
chmod 755 /usr/local/bin/mycertgen.sh

for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
    scp /usr/local/bin/mycertgen.sh $node:/usr/local/bin/mycertgen.sh
    scp /usr/local/bin/mykeygen.sh $node:/usr/local/bin/mykeygen.sh
    ssh $node "chmod 755 /usr/local/bin/*gen.sh"
done
```

We can tell certgen to use our scripts instead of the stock scripts by adding these lines to `/etc/slurm/slurm.conf`

```conf
CertgenParameters=certgen_script=/usr/local/bin/mycertgen.sh,keygen_script=/usr/local/bin/mykeygen.sh
```

Now, when we restart slurmctld and rerun strace

```bash
systemctl restart slurmctld
strace -s 99 -e trace=openat,memfd_create,write,access,read scontrol ping 2>&1 | grep -Pv '[^\x09\x0A\x20-\x7E]' | grep -Pv '\\([0-7]{1,3}|x[0-9A-Fa-f]{2})|\\177ELF'
```

And can see our scripts being called

```bash
access("/usr/local/bin/mykeygen.sh", R_OK|X_OK) = 0
read(4, "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgXDbljEk+Qa+r/WF6\nHQs/6d"..., 1024) = 241
--- SIGCHLD {si_signo=SIGCHLD, si_code=CLD_EXITED, si_pid=20434, si_uid=0, si_status=0, si_utime=0, si_stime=0} ---
access("/usr/local/bin/mycertgen.sh", R_OK|X_OK) = 0
read(4, "-----BEGIN CERTIFICATE-----\nMIICVzCCAf2gAwIBAgIUA+ypu9+H0DOooyc5c1l4awnNIiIwCgYIKoZIzj0EAwIw\ngYAxCz"..., 1024) = 871
--- SIGCHLD {si_signo=SIGCHLD, si_code=CLD_EXITED, si_pid=20437, si_uid=0, si_status=0, si_utime=0, si_stime=0} ---
```

The `wall` commands in our mykeygen.sh / mycertgen.sh are to demonstright how often these certs are generated. Obviously do not keep these in production.
Run a few slurm commands and watch the output!

### Enable TLS Debug Logging

Enable debug to see detailed TLS operations:

```bash
scontrol setdebugflags +TLS
scontrol setdebug debug
journalctl -u slurmctld.service -f
```

In anouther terminal, ssh to a compute node and remove the nodes certificate and watch it get regenerated:

```bash
ssh <compute node>
rm -f /var/spool/slurmd/certmgr_state

# Restart slurmd and watch certificate regeneration
systemctl restart slurmd.service
```

Monitor the logs as you restart a compute node to see the full certificate request and signing process in action.

## Backing Out TLS Changes

If you need to disable TLS and return your Slurm cluster to its original non-encrypted state, follow these steps. This is useful for troubleshooting, testing, or reverting to a simpler configuration.

### Remove TLS Configuration from Compute Nodes

Remove the CA certificate option from slurmd on all compute nodes:

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
    ssh "$node" "sed -i 's/ --ca-cert-file=[^\" ]*//g' /etc/default/slurmd"
done
```

### Remove TLS Configuration from Head Node

Remove the TLS configuration lines from `/etc/slurm/slurm.conf`:

```bash
# Backup the current configuration
cp /etc/slurm/slurm.conf /etc/slurm/slurm.conf.with-tls

# Remove TLS-related lines
sed -i '/^TLSType=/d' /etc/slurm/slurm.conf
sed -i '/^TLSParameters=/d' /etc/slurm/slurm.conf
sed -i '/^CertgenType=/d' /etc/slurm/slurm.conf
sed -i '/^CertgenParameters=/d' /etc/slurm/slurm.conf
sed -i '/^CertmgrType=/d' /etc/slurm/slurm.conf
sed -i '/^CertmgrParameters=/d' /etc/slurm/slurm.conf
sed -i '/^DebugFlags=.*TLS/d' /etc/slurm/slurm.conf
```

Remove TLS configuration from `/etc/slurm/slurmdbd.conf`:

```bash
# Backup the current configuration
cp /etc/slurm/slurmdbd.conf /etc/slurm/slurmdbd.conf.with-tls

# Remove TLS-related lines
sed -i '/^TLSType=/d' /etc/slurm/slurmdbd.conf
sed -i '/^TLSParameters=/d' /etc/slurm/slurmdbd.conf
```

### Restart Services Without TLS

Restart all Slurm services to disable TLS:

```bash
# Restart head node services
systemctl restart slurmctld.service
systemctl restart slurmdbd.service
systemctl restart slurmrestd.service

# Verify head node is responding
scontrol ping

# Restart compute nodes
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
    ssh $node "systemctl restart slurmd.service"
done
```

### Verify Non-TLS Operation

Confirm the cluster is working without TLS:

```bash
# Check cluster status
sinfo
scontrol show nodes

# Submit a test job
srun --nodes=1 --ntasks=1 hostname
```

## Troubleshooting Guide

### Common Issues

**Vault Service Won't Start:**

- Check `/var/log/messages` or `journalctl -u vault`
- Verify configuration file syntax: `vault server -config=/etc/vault.d/vault.hcl -test`
- Ensure vault user has access to data directory

**Certificate Generation Fails:**

- Verify Vault Agent is running: `systemctl status vault-agent@slurm`
- Check agent logs: `journalctl -u vault-agent@slurm`
- **Token Auth**: Validate token file exists and is readable: `cat /etc/slurm/certmgr/vault-token`
- Test token authentication: `VAULT_TOKEN=$(cat /etc/slurm/certmgr/vault-token) vault token lookup`

**Token Authentication Issues:**

- Check token file permissions: should be 0400 owned by slurm:slurm
- Verify token is valid: `VAULT_TOKEN=$(cat /etc/slurm/certmgr/vault-token) vault auth -method=token`
- Check systemd service has access to token file
- Ensure symlink exists: `ls -la /etc/slurm/certmgr/vault-agent-token`

**Node Authentication Errors:**

- Verify node tokens are distributed: `ls -la /etc/slurm/certmgr/`
- Check token permissions: should be 0400 owned by slurm:slurm
- Validate token matches Vault storage: `vault kv get node-tokens/<nodename>`

**Slurm TLS Errors:**

- Ensure CA certificate is installed on all nodes
- Verify certificate files exist and have correct permissions
- Check certificate validity: `openssl x509 -in /path/to/cert -dates -noout`

**TLS Connection/Handshake Issues:**

- Enable TLS debugging by adding `AuditTLS=debug` to slurm.conf
- Restart affected services: `systemctl restart slurmctld slurmdbd slurmd`
- Check logs for detailed TLS handshake information: `journalctl -u slurmctld -f`
- Look for certificate validation errors, cipher negotiation problems, or protocol mismatches
- Remember to remove `AuditTLS=debug` after troubleshooting (generates verbose logs)

### Verification Commands

```bash
# Vault status and health
vault status
vault auth list
vault secrets list

# Token Authentication verification
VAULT_TOKEN=$(cat /etc/slurm/certmgr/vault-token) vault token lookup
VAULT_TOKEN=$(cat /etc/slurm/certmgr/vault-token) vault token renew

# Test token permissions
VAULT_TOKEN=$(cat /etc/slurm/certmgr/vault-token) vault write pki/issue/slurm-agent common_name="test-$(date +%s)" ttl="5m"

# Certificate verification
openssl x509 -in /etc/slurm/ctld_cert.pem -text -noout
openssl verify -CAfile /etc/slurm/certmgr/slurm_ca.pem /etc/slurm/certmgr/slurmctld.pem

# Service status
systemctl status vault vault-agent@slurm slurmctld slurmdbd

# Slurm cluster health
sinfo -Nel
scontrol show config | grep -i tls
```

## Conclusion

This lab demonstrates enterprise-grade certificate management for HPC environments. You've implemented:

- Automated certificate lifecycle management
- Secure node authentication with tokens  
- Centralized PKI with HashiCorp Vault
- Integration with Slurm workload manager
- Operational tooling for ongoing management

The skills and concepts learned here apply broadly to securing distributed systems, implementing zero-trust architectures, and managing PKI at scale.

**Next Steps:**

- Adapt this solution for your production environment
- Implement monitoring and alerting for certificate operations
- Explore Vault's advanced features (namespaces, policies, audit)
- Consider integration with your existing identity and security infrastructure

---

## Documentation References

### HashiCorp Vault

- **[Official Documentation](https://developer.hashicorp.com/vault/docs)** - Complete Vault documentation
- **[PKI Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/pki)** - Certificate Authority functionality
- **[Vault Agent](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent)** - Automated authentication and templating
- **[KV Secrets Engine v2](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2)** - Key-value secret storage
- **[Vault Installation Guide](https://developer.hashicorp.com/vault/tutorials/getting-started/getting-started-install)** - Installation and setup
- **[Seal/Unseal Operations](https://developer.hashicorp.com/vault/docs/concepts/seal)** - Security concepts

### Slurm Man Pages

- **[TLS Configuration](https://slurm.schedmd.com/slurm.conf.html#OPT_TLSParameters)** - Transport Layer Security setup
- **[Certificate Manager](https://slurm.schedmd.com/certmgr.html)** - Certificate management scripts
- **[Certificate Generator](https://slurm.schedmd.com/slurm.conf.html#OPT_CertgenParameters)** - Dynamic certificate generation
- **[Administrator Guide](https://slurm.schedmd.com/quickstart_admin.html)** - Quick start for administrators
- **[Configuration Files](https://slurm.schedmd.com/slurm.conf.html)** - slurm.conf reference

---
