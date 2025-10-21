# LCI Advanced 2025 - Slurm TLS Certificate Management - Lab Guide

## Lab Overview

In this hands-on session, you'll implement a complete certificate management solution for Slurm using basic shell commands to create a Certificate Authority (CA) and key-value store. This lab demonstrates the concepts for enabling TLS for HPC environments.

### Prerequisites

- Cluster with 1 head node running slurmctld, slurmdbd, and slurmrestd and at least 1 compute node running slurmd (provided)
- Slurm 25.05 or later compiled with s2n support
- jq package installed on the head node
- Passwordless SSH access from head node to compute nodes

## Architecture Overview

This solution implements a shell script-based certificate management system:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Slurm Head Node                                   │
│                                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐              │
│  │   Slurmctld     │  │   Slurmdbd      │  │  Slurmrestd     │              │
│  │                 │  │                 │  │                 │              │
│  │ • TLS enabled   │  │ • TLS enabled   │  │ • TLS enabled   │              │
│  │ • Service cert  │  │ • Service cert  │  │ • Service cert  │              │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘              │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    Certificate Management                             │  │
│  │                                                                       │  │
│  │ • Root CA (slurm_ca.key/pem)                                          │  │
│  │ • Service certificates (slurmctld.pem, slurmdbd.pem, slurmrestd.pem)  │  │
│  │ • Node token validation (node_token_list)                             │  │
│  │ • CSR signing script (slurmctld_sign_csr.sh)                          │  │
│  │ • Token validation script (slurmctld_validate_node_token.sh)          │  │
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
        │ │• Node cert  │ │ │ │• Node cert  │ │ │ │• Node cert  │ │
        │ └─────────────┘ │ │ └─────────────┘ │ │ └─────────────┘ │
        │                 │ │                 │ │                 │
        │ Scripts:        │ │ Scripts:        │ │ Scripts:        │
        │ • CSR generation│ │ • CSR generation│ │ • CSR generation│
        │ • Key retrieval │ │ • Key retrieval │ │ • Key retrieval │
        │ • Token auth    │ │ • Token auth    │ │ • Token auth    │
        │ • CA cert       │ │ • CA cert       │ │ • CA cert       │
        └─────────────────┘ └─────────────────┘ └─────────────────┘

Certificate Lifecycle:
1. Node generates CSR using slurmd_generate_csr.sh
2. Node presents token using slurmd_get_node_token.sh  
3. Head node validates token using slurmctld_validate_node_token.sh
4. Head node signs CSR using slurmctld_sign_csr.sh
5. Node retrieves private key using slurmd_get_cert_key.sh
6. mTLS communication established
```

## Important Note About This Lab

This lab creates a certificate authority with the private key stored locally, adjacent to slurm.conf. This means that any compromise of the slurm user, or RCE vulnerability in slurm could result in this key being leaked. It is not recommended to store the private key locally. This key is needed for signing certs, so a better production example would use a secrets engine, such as HashiCorp Vault, or AWS KMS. This is not intended to be production ready.

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
├── slurm_ca.key                        # Root CA private key
├── slurm_ca.pem                        # Root CA certificate
├── slurmctld.key                       # Slurmctld private key
├── slurmctld.pem                       # Slurmctld certificate
├── slurmdbd.key                        # Slurmdbd private key
├── slurmdbd.pem                        # Slurmdbd certificate
├── slurmrestd.key                      # Slurmrestd private key
├── slurmrestd.pem                      # Slurmrestd certificate
├── node_token_list                     # Node authentication tokens
├── slurmctld_validate_node_token.sh    # Script to verify authenticity of a node
└── slurmctld_sign_csr.sh               # Script to sign certificate signing requests
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

## Step 1: Generate Root CA

This step creates the Certificate Authority (CA) that will serve as the root of trust for all certificates in your Slurm cluster. The CA's private key will be used to sign all service and node certificates, while the CA certificate will be distributed to verify those signatures.

Generate the CA private key

```bash
mkdir -p /etc/slurm/certmgr
chmod 750 /etc/slurm/certmgr
chown slurm:rocky /etc/slurm/certmgr/
openssl ecparam -name prime256v1 -genkey -noout -out /etc/slurm/certmgr/slurm_ca.key
chmod 400 /etc/slurm/certmgr/slurm_ca.key
chown slurm:slurm /etc/slurm/certmgr/slurm_ca.key
```

Generate the CA public certificate

```bash
openssl req -x509 -new -key /etc/slurm/certmgr/slurm_ca.key -sha256 -days 3650 -out /etc/slurm/certmgr/slurm_ca.pem -subj /C=US/ST=Oklahoma/L=Norman/O=LinuxClusterInstitute/OU=LCIAdvancedSlurm2025/CN=slurm_ca
chmod 644 /etc/slurm/certmgr/slurm_ca.pem
chown slurm:slurm /etc/slurm/certmgr/slurm_ca.key
```

Then install into the system trust store

```bash
mkdir -p /etc/pki/ca-trust/source/anchors
cp /etc/slurm/certmgr/slurm_ca.pem /etc/pki/ca-trust/source/anchors/
update-ca-trust extract || true
```

## Step 2: Copy CA Public Key to Compute Nodes

This step distributes the CA certificate to all compute nodes so they can verify certificates signed by the CA. Each compute node needs this certificate to establish trust with the head node and validate incoming connections.

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
   scp /etc/slurm/certmgr/slurm_ca.pem  $node:/etc/slurm/certmgr/slurm_ca.pem
   ssh $node "chmod 444 /etc/slurm/certmgr/slurm_ca.pem && cp /etc/slurm/certmgr/slurm_ca.pem /etc/pki/ca-trust/source/anchors/ && update-ca-trust extract || true"
done
```

## Step 3: Generate Certificates for Slurmctld, Slurmdbd, and Slurmrestd

This step creates individual certificates for each Slurm service running on the head node. Each service gets its own private key and certificate signed by the CA, enabling secure communication between services and with compute nodes.

```bash
for service in slurmctld slurmdbd slurmrestd; do
    openssl ecparam -name prime256v1 -genkey -noout -out /etc/slurm/certmgr/${service}.key
    openssl req -new -key /etc/slurm/certmgr/${service}.key -out /etc/slurm/certmgr/${service}.csr -subj "/C=US/ST=Oklahoma/L=Norman/O=LinuxClusterInstitute/OU=LCIAdvancedSlurm2025/CN=${service}"
    openssl x509 -req -in /etc/slurm/certmgr/${service}.csr -CA /etc/slurm/certmgr/slurm_ca.pem  -CAkey /etc/slurm/certmgr/slurm_ca.key -out /etc/slurm/certmgr/${service}.pem -sha384
    chmod 0400 /etc/slurm/certmgr/${service}.key
    chmod 0400 /etc/slurm/certmgr/${service}.pem
    if [[ "${service}" == "slurmrestd" ]]; then
        chown rocky:rocky /etc/slurm/certmgr/${service}.key
        chown rocky:rocky /etc/slurm/certmgr/${service}.pem
    else
        chown slurm:slurm /etc/slurm/certmgr/${service}.key
        chown slurm:slurm /etc/slurm/certmgr/${service}.pem
    fi
    rm -f /etc/slurm/certmgr/${service}.csr
done
```

## Step 4: Generate A Private Key and Pre-Shared Token Per Node

This step sets up the authentication infrastructure for compute nodes. Each node gets a unique private key for certificate generation and a pre-shared token that authorizes it to request certificates from the head node, creating a secure bootstrap mechanism.

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
    ssh $node "mkdir -p /etc/slurm/certmgr && chmod 700 /etc/slurm/certmgr"
    ssh $node "openssl ecparam -name prime256v1 -genkey -noout -out /etc/slurm/certmgr/slurmd.key"
    ssh $node "chmod 400 /etc/slurm/certmgr/slurmd.key"
done
```

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
    openssl rand -hex 32 > ${node}_token
    echo -e "${node} $(<${node}_token)" >> /etc/slurm/certmgr/node_token_list
    ssh $node "mkdir -p /etc/slurm/certmgr && chmod 700 /etc/slurm/certmgr"
    scp ${node}_token $node:/etc/slurm/certmgr/token
    ssh $node "chmod 400 /etc/slurm/certmgr/token"
    rm -f ${node}_token
done
chmod 400 /etc/slurm/certmgr/node_token_list
chown slurm:slurm /etc/slurm/certmgr/node_token_list
```

## Step 5: Create Slurmctld's Scripts

This script enables the head node to verify that a compute node is authorized to request certificates. When a node requests a certificate, slurmctld calls this script to check if the provided token matches the pre-shared token for that specific node.

This script is passed the node name as arg $1 and the node token as arg $2

```bash
cat > /etc/slurm/certmgr/slurmctld_validate_node_token.sh << 'EOF'
#!/bin/bash
set -euo pipefail
NODE_NAME="${1:-}"
NODE_TOKEN="${2:-}"
grep "$NODE_NAME $NODE_TOKEN" /etc/slurm/certmgr/node_token_list
[ $? -eq 0 ] && exit 0 || echo "$0: Failed to validate token for '$NODE_NAME'"
exit 1
EOF
```

This script performs the actual certificate signing on the head node. When a compute node submits a Certificate Signing Request (CSR), slurmctld calls this script to sign the CSR with the CA's private key and return a valid certificate.

This script is passed the CSR as $1

```bash
cat > /etc/slurm/certmgr/slurmctld_sign_csr.sh << 'EOF'
#!/bin/bash
set -euo pipefail
CSR="${1:-}"
CA_CERT=/etc/slurm/certmgr/slurm_ca.pem
CA_KEY=/etc/slurm/certmgr/slurm_ca.key
printf '%s' "$CSR" | openssl x509 -req -in /dev/stdin -CA $CA_CERT -CAkey $CA_KEY -sha384
[[ $? -eq 0 ]] && exit 0 || echo "$0: Failed to generate signed certificate"
exit 1
EOF
```

Set the correct permissions on these scripts

```bash
chmod 700 /etc/slurm/certmgr/*.sh
chown slurm:slurm /etc/slurm/certmgr/*.sh
```

## Step 6: Create Slurmd's Scripts

This step creates the client-side scripts that compute nodes use to participate in the certificate management process. These scripts handle token retrieval, CSR generation, and private key access, enabling automated certificate lifecycle management on each compute node.

### Create the Token Retrieval Script

This script allows slurmd to authenticate itself when requesting certificates. It reads the pre-shared token that was distributed in Step 4 and returns it to the Slurm certificate manager for validation.

```bash
cat > /etc/slurm/certmgr/slurmd_get_node_token.sh << 'EOF'
#!/bin/bash
set -euo pipefail
TOKEN_PATH="/etc/slurm/certmgr/token"
[ -f "$TOKEN_PATH" ] || { echo "$0: token missing"; exit 1; }
cat "$TOKEN_PATH"
exit 0
EOF
```

### Create the Certificate Signing Request Generation Script

This script generates a Certificate Signing Request (CSR) using the node's private key. The CSR contains the node's identity information and public key, which will be sent to the head node for signing. The resulting certificate will prove the node's identity in TLS communications.

```bash
cat > /etc/slurm/certmgr/slurmd_generate_csr.sh << 'EOF'
#!/bin/bash
set -euo pipefail
KEY="/etc/slurm/certmgr/slurmd.key"
[[ ! -f "$KEY" ]] && { echo "$0: Cannot find node private key at '$KEY'" ; exit 1; }
openssl req -new -key "$KEY" -subj "/C=US/ST=Oklahoma/L=Norman/O=LinuxClusterInstitute/OU=LCIAdvancedSlurm2025/CN=$(hostname -s)"
[[ $? -eq 0 ]] && exit 0 || echo "$0: Failed to generate certificate signing request"
exit 1
EOF
```

### Create the Private Key Retrieval Script

This script provides access to the node's private key when Slurm needs to establish TLS connections. The private key is used in conjunction with the signed certificate to prove the node's identity and enable encrypted communication.

```bash
cat > /etc/slurm/certmgr/slurmd_get_cert_key.sh << 'EOF'
#!/bin/bash
set -euo pipefail
KEY="/etc/slurm/certmgr/slurmd.key"
[[ ! -f "$KEY" ]] && { echo "$0: Cannot find node private key at '$KEY'" ; exit 1; }
cat "$KEY"
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
```

## Step 7: Configure Slurm

This step modifies Slurm configuration files to enable TLS encryption and integrate with the certificate management scripts you've created. These settings tell Slurm where to find certificates, which scripts to call for certificate operations, and how to validate node authentication.

### Configure Compute Nodes

On each compute node, add the CA certificate path to the slurmd daemon options in `/etc/default/slurmd`:

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
   ssh $node 'echo SLURMD_OPTIONS=--ca-cert-file=/etc/slurm/certmgr/slurm_ca.pem >> /etc/default/slurmd'
done
```

### Configure the Head Node

Add the following TLS configuration to `/etc/slurm/slurm.conf`:

```conf
TLSType=tls/s2n
TLSParameters=ca_cert_file=/etc/slurm/certmgr/slurm_ca.pem,ctld_cert_file=/etc/slurm/certmgr/slurmctld.pem,ctld_cert_key_file=/etc/slurm/certmgr/slurmctld.key,restd_cert_file=/etc/slurm/certmgr/slurmrestd.pem,restd_cert_key_file=/etc/slurm/certmgr/slurmrestd.key,slurmd_cert_file=/etc/slurm/certmgr/slurmd.pem,slurmd_cert_key_file=/etc/slurm/certmgr/slurmd.key
CertgenType=certgen/script
CertmgrType=certmgr/script
CertmgrParameters=generate_csr_script=/etc/slurm/certmgr/slurmd_generate_csr.sh,get_node_cert_key_script=/etc/slurm/certmgr/slurmd_get_cert_key.sh,get_node_token_script=/etc/slurm/certmgr/slurmd_get_node_token.sh,sign_csr_script=/etc/slurm/certmgr/slurmctld_sign_csr.sh,validate_node_script=/etc/slurm/certmgr/slurmctld_validate_node_token.sh
```

Add TLS configuration to `/etc/slurm/slurmdbd.conf`:

```conf
TLSType=tls/s2n
TLSParameters=ca_cert_file=/etc/slurm/certmgr/slurm_ca.pem,dbd_cert_file=/etc/slurm/certmgr/slurmdbd.pem,dbd_cert_key_file=/etc/slurm/certmgr/slurmdbd.key
```

## Step 8: Restart Slurm Services

This final step restarts all Slurm services to activate TLS encryption. The head node services are restarted first to ensure they're ready to handle TLS connections, then compute nodes are restarted to establish secure communication with the head node.

### Restart Head Node Services

```bash
systemctl restart slurmctld.service
systemctl restart slurmdbd.service
systemctl restart slurmrestd.service
```

### Verify Head Node is Ready

Ensure Slurm controller is responding before proceeding:

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
srun --nodes=1 --ntasks=1 -p general --chdir=/root hostname
```

This should complete successfully, demonstrating that TLS communication is working between the head node and compute nodes.

### Check Certificate Generation

Verify that dynamic certificates are being created on the compute nodes by checking the certmgr state file:

```bash
for node in $(scontrol show nodes --json | jq -r '.nodes[].hostname'); do
    ssh $node "cat /var/spool/slurmd.spool/certmgr_state"
done
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

If we wite our own keygen and certgen scripts

```bash
cat > /usr/local/bin/mykeygen.sh << EOF
#!/bin/sh
wall -n "Generating Key with \$0"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256
EOF
chmod 755 /usr/local/bin/mykeygen.sh

cat > /usr/local/bin/mycertgen.sh << EOF
#!/bin/sh
wall -n "Generating Cert With \$0"
printf '%s' "\$1" | openssl req -x509 -key /dev/stdin -subj "/C=US/ST=Oklahoma/L=Norman/O=LinuxClusterInstitute/OU=LCIAdvancedSlurm2025/CN=\$(hostname -s)"
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

The `wall` commands in our mykeygen.sh / mycertgen.sh are to demonstrate how often these certs are generated. Obviously do not keep these in production.
Run a few slurm commands and watch the output!

### Enable TLS Debug Logging

Enable debug to see detailed TLS operations:

```bash
scontrol setdebugflags +TLS
scontrol setdebug debug
journalctl -u slurmctld.service -f
```

In another terminal, ssh to a compute node and remove the nodes certificate and watch it get regenerated:

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
srun --nodes=1 --ntasks=1 -p general --chdir=/root hostname
```

## Documentation References

### Slurm Man Pages

- **[TLS Configuration](https://slurm.schedmd.com/slurm.conf.html#OPT_TLSParameters)** - Transport Layer Security setup
- **[Certificate Manager](https://slurm.schedmd.com/certmgr.html)** - Certificate management scripts
- **[Certificate Generator](https://slurm.schedmd.com/slurm.conf.html#OPT_CertgenParameters)** - Dynamic certificate generation
- **[Administrator Guide](https://slurm.schedmd.com/quickstart_admin.html)** - Quick start for administrators
- **[Configuration Files](https://slurm.schedmd.com/slurm.conf.html)** - slurm.conf reference

---
