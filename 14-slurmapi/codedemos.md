## RUNNING THE DEMONSTRATIONS

### Setup Before Presentation

```bash
# 1. Verify Slurm installation
which slurmctld
which slurmd
which slurmrestd

# 2. Ensure slurmrestd is running
sudo systemctl status slurmrestd
# If not running:
sudo systemctl start slurmrestd

# 3. Verify port 6820 is listening
netstat -tlnp | grep 6820

# 4. Test basic connectivity
curl -H "X-SLURM-USER-NAME: $(whoami)" \
     http://localhost:6820/slurm/v0.0.38/ping

# 5. Prepare test jobs
sbatch --wrap="sleep 60" -N1 -t5 --job-name=demo1
sbatch --wrap="sleep 120" -N1 -t5 --job-name=demo2

# 6. Verify jobs exist
squeue
```

### Demo 1: Query Jobs
```bash
# Show running jobs with squeue
squeue

# Now show via REST API
python3 examples/01_query_jobs.py

# Explain the difference in output
```

### Demo 2: Submit Job
```bash
# Show the job before
squeue | wc -l

# Submit via Python/REST
python3 examples/02_submit_job.py

# Verify it appeared
squeue | tail -1
```

### Demo 3: Monitor Job
```bash
# Get a short job ID
JOB_ID=$(squeue | grep "demo" | awk '{print $1}' | head -1)

# Monitor it
python3 examples/03_monitor_job.py $JOB_ID

# Watch it transition
```

### Demo 4: Node Status
```bash
# Show nodes with sinfo
sinfo

# Show via Python/REST
python3 examples/04_node_status.py

# Highlight differences
```

---

## PACKAGE INSTALLATION INSTRUCTIONS

### For Ubuntu/Debian Systems

```bash
# Update package manager
sudo apt-get update

# Install Python and pip
sudo apt-get install -y python3 python3-pip python3-dev

# Install required Python packages
pip3 install requests pyyaml typing-extensions

# Verify installation
python3 -c "import requests; print(requests.__version__)"
```

### For CentOS/RHEL Systems

```bash
# Update package manager
sudo yum update -y

# Install Python and pip
sudo yum install -y python3 python3-devel python3-pip

# Install required Python packages
pip3 install requests pyyaml typing-extensions

# Verify installation
python3 -c "import requests; print(requests.__version__)"
```

### For macOS (if needed for prep)

```bash
# Install Homebrew if not present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Python
brew install python3

# Install required packages
pip3 install requests pyyaml typing-extensions
```

### Verification

```bash
# Test all imports
python3 << 'EOF'
import requests
import json
import time
import subprocess
print("All imports successful")
EOF
```

---

## TROUBLESHOOTING DURING PRESENTATION

### slurmrestd not running
```bash
# Start it
sudo systemctl start slurmrestd

# Check status
sudo systemctl status slurmrestd

# Check logs
sudo journalctl -u slurmrestd -n 50
```

### Port 6820 not accessible
```bash
# Verify listening
sudo netstat -tlnp | grep 6820

# Check firewall
sudo ufw allow 6820  # Ubuntu
sudo firewall-cmd --add-port=6820/tcp --permanent  # CentOS

# Test connectivity
curl http://localhost:6820/slurm/v0.0.38/ping
```

### Authentication errors
```bash
# Verify munge is running
sudo systemctl status munge

# Check Slurm config
slurmctld -Dvvvvv

# Test basic squeue
squeue
```

### No jobs to demonstrate
```bash
# Submit some quick test jobs
for i in {1..5}; do
  sbatch --wrap="sleep 60" -N1 -t10 --job-name=demo$i
done

# Verify
squeue
```

---

## TIMING GUIDE FOR 45-MINUTE PRESENTATION

| Slide | Duration | Content |
|-------|----------|---------|
| 1-2 | 2 min | Introduction & Agenda |
| 3-7 | 8 min | Slurm Architecture & REST Intro |
| 8-10 | 7 min | Communication Methods |
| 11-16 | 12 min | Practical Examples (with live demos) |
| 17-20 | 6 min | Performance & Production |
| 21-24 | 6 min | Decision Making & Case Studies |
| 25-27 | 4 min | Resources & Q&A |
| **Total** | **45 min** | |

**Buffer:** You have about 5 minutes of flexibility. Use it where audience engagement requires deeper explanation.

---

## NOTES FOR INSTRUCTORS

### Audience Knowledge Assumptions
- Familiar with Slurm CLI (squeue, sbatch, etc.)
- Basic Python knowledge
- Understanding of HPC terminology
- Linux system familiarity

### Accessibility Considerations
- Large fonts for code examples (18pt minimum)
- High contrast for terminal output
- Clear verbal explanations of code
- Handouts with all code examples

### Interactive Elements
- Stop for questions after Section 4 (API types)
- Live code modifications show flexibility
- Ask audience about their use cases
- Solicit real-world problems they face

### Post-Session
- Provide all code examples
- Provide installation instructions
- Offer office hours for follow-ups
- Share documentation links