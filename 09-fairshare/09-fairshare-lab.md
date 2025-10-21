
### (Hands-on exercises, 60 min, CPU-only)

# Slurm Fairshare Lab: Hands-On Configuration & Measurement

  

**Duration:** 60 min

**Cluster:** lciadv (2 compute nodes, 4 cores each, 8 total)

**Accounts:** root (user: root), lci (user: rocky)

**No GPUs:** All CPU workloads

---

## PART 1: SETUP & BASELINE (10 min)

### 1.1 Verify Slurm Version

```bash
# Check version (need 22.05+ for Fairtree)
sinfo --version

# Output should be: slurm 22.05 or higher
# If < 22.05, Fairtree unavailable; proceed with classic only
```


**Expected Output:**

```
slurm 22.05.3
```


**Troubleshooting:**

```bash
# If no sinfo:
which sinfo
# Or check if slurmctld is running:
systemctl status slurmctld
```

### 1.2 Inspect Current - slurm.conf

```bash
# View fairshare-related config
grep -E "PriorityType|PriorityFlags|PriorityWeight|PriorityDecay" /etc/slurm/slurm.conf

# Also check account/user setup
sacctmgr show assoc format=account,user,fairshare
```

**Expected Output:**

```
PriorityType=priority/multifactor
PriorityFlags=DEPTH_OBLIVIOUS
#PriorityDecayHalfLife=7-0
PriorityWeightFairshare=100000000
PriorityWeightAge=10000000
#PriorityWeightPartition=0
PriorityWeightQOS=110000000
#PriorityWeightJobSize=0

Account    User       Share
---------- ---------- ---------
root                   1
root        root       1
lci                    1
lci         rocky      1
```


### 1.3 Create Account Hierarchy (if not exists)

```bash
# Check existing accounts
sacctmgr show accounts

# If only root/lci, structure is flat. Create a hierarchy:
sacctmgr add account ml parent=lci description="ML Team"
sacctmgr add account io parent=lci description="IO Team"
sacctmgr add account admin parent=root description="Admin"

# Verify
sacctmgr show accounts
```

  

**Expected Output:**

```
Account    Descr                Org
---------- -------------------- --------------------
admin      admin                admin
io         io team              lci
lci        lci hpc account      lci
ml         ml team              lci
root       default root account root
```


### 1.4 Assign Fair Shares

```bash
# Set fair shares for hierarchy
sacctmgr modify account ml set fairshare=40 # 40% of lci
sacctmgr modify account io set fairshare=60 # 60% of lci
sacctmgr modify account admin set fairshare=30 # 30% of root
sacctmgr modify account lci set fairshare=70 # 70% of root

# Verify
sacctmgr list assoc format=account,fairshare
```


**Expected Output:**

```
Account    Share
---------- ---------
root       1
root       1
admin      30
lci        70
lci        1
io         60
ml         40
```

### 1.5 Assign Users to Accounts

```bash
# rocky (lci user) can submit to lci, ml, io
sacctmgr add user rocky account=ml
sacctmgr add user rocky account=io
sacctmgr add user rocky accout=admin

# root can submit to root, admin
sacctmgr add user root account=admin

# Verify
sacctmgr show assoc user=rocky format=account,user,fairshare
sacctmgr show assoc user=root format=account,user,fairshare
```


**Expected Output:**

```
Account    User       Share
---------- ---------- ---------
lci        rocky      1
io         rocky      1
ml         rocky      1

Account    User       Share
---------- ---------- ---------
root       root       1
admin      root       1
```


## PART 2: CLASSIC FAIRSHARE SIMULATION (15 min)

### 2.1 Ensure Classic Algorithm (Remove Fairtree)

```bash
# Edit slurm.conf to remove FAIR_TREE flag
sudo vim /etc/slurm/slurm.conf

# Find line:
# PriorityFlags=DEPTH_OBLIVIOUS
# Leave as-is (no FAIR_TREE flag = classic algorithm)

# Reload config if anything was changed
sudo scontrol reconfigure

# Verify
scontrol show config | grep PriorityFlags
```

**Expected Output:**

```
PriorityFlags           = DEPTH_OBLIVIOUS,NO_FAIR_TREE
```

### 2.2 Create Test Workload Script

```bash
# Create /tmp/submit_jobs_classic.sh
cat > /tmp/submit_jobs_classic.sh << 'EOF'

#!/bin/bash
# Submit competing jobs to different accounts

echo "=== Classic Fairshare Simulation ==="
echo "Submitting jobs to different accounts..."

# Job 1: ml account (1 cores, 2 min)
sbatch -A ml -n 1 -t 2 --job-name=ml_job1 \
--wrap="srun bash -c 'for i in {1..600}; do echo \$i; sleep 1; done'"

# Job 2: ml account (1 cores, 2 min)
sbatch -A ml -n 1 -t 2 --job-name=ml_job2 \
--wrap="srun bash -c 'for i in {1..600}; do echo \$i; sleep 1; done'"

# Job 3: io account (2 cores, 2 min) - submitted 30 sec later
sleep 30
sbatch -A io -n 2 -t 2 --job-name=io_job1 \
--wrap="srun bash -c 'for i in {1..600}; do echo \$i; sleep 1; done'"

# Job 4: admin account (2 cores, 2 min) - submitted 30 sec later
sleep 30
sbatch -A admin -n 2 -t 2 --job-name=io_job1 \
--wrap="srun bash -c 'for i in {1..600}; do echo \$i; sleep 1; done'"

echo "Jobs submitted. Check queue:"
squeue -o "%.10i %.20j %.8A %.4C %.8T %.10p"

EOF

chmod +x /tmp/submit_jobs_classic.sh
```

### 2.3 Run Workload & Observe Classic Fairshare

```bash
# Submit jobs
/tmp/submit_jobs_classic.sh

# Watch queue in real-time (new terminal)
watch -n 5 'squeue -o "%.10i %.20j %.8A %.4C %.8T %.10p" && echo "---" && sshare -l'

# In another terminal, check fairshare factors
sshare -al
```

**Expected Output (sshare -l) Similar to:**

```
Account              User       RawShares  NormShares  RawUsage    EffectvUsage  FairShare
-------------------- ---------- ---------- ----------- ----------- ------------- ----------
root                                       1.000000    10304       1.000000      0.500000
root                 root        1         0.009901    5499        0.533708      0.000000
admin                            30        0.297030    0           0.000000      1.000000
admin                root        1         0.297030    0           0.000000      1.000000
lci                              70        0.693069    4804        0.427280      0.652249
lci                  rocky       1         0.006862    2303        0.007594      0.464387
io                               60        0.411724    0           0.000000      1.000000
io                   rocky       1         0.411724    0           0.000000      1.000000
ml                               40        0.274483    2500        0.170264      0.650532
ml                   rocky       1         0.274483    2500        0.170264      0.650532
```

  

### 2.4 Measure Priority Evolution

```bash
# Record priority and fairshare factors over time
cat > /tmp/measure_classic.sh << 'EOF'

#!/bin/bash
echo "Time,Job,Account,Priority,FairshareAccount,FairshareUser" > /tmp/classic_data.csv

for i in {1..30}; do
echo "=== Iteration $i ($(date +%H:%M:%S)) ==="
# Get job priorities
squeue -o "%.10i %.20j %.8A %.20p" --noheader | while read job_id job_name account priority; do

# Get fairshare factors
fs_acct=$(sshare -A $account -o fairshare --noheader 2>/dev/null | head -1)
fs_user=$(sshare -u $(whoami) -o fairshare --noheader 2>/dev/null | head -1)
echo "$(date +%H:%M:%S),$job_name,$account,$priority,$fs_acct,$fs_user" >> /tmp/classic_data.csv
done
sleep 10
done

echo "Data saved to /tmp/classic_data.csv"

EOF

chmod +x /tmp/measure_classic.sh
/tmp/measure_classic.sh &
BG_PID=$!

# Let it run while jobs execute
# Kill after 5 min or when jobs finish
sleep 300 && kill $BG_PID 2>/dev/null || true
```

### 2.5 Analyze Classic Results

```bash
# Plot priority over time 
awk -F, 'NR>1 {print $1, $4}' /tmp/classic_data.csv | sort -u

# Summary statistics
echo "=== Classic Fairshare Summary ==="
echo "Average priority by account:"
awk -F, 'NR>1 {sum[$3]+=$4; count[$3]++} END {for (a in sum) print a, sum[a]/count[a]}' /tmp/classic_data.csv | sort -k2 -rn
```

**Expected Insight:**

```
Classic Fairshare shows:
- ml_job1 & ml_job2: lower priority (ml over-allocated)
- io_job1: higher priority (io under-allocated)
- admin_job1: highest priority (admin has no usage)

Why? Parent (lci) is over-allocated, so both ml and io are penalized.
But ml is penalized MORE because it has higher usage.
```


## PART 3: FAIRTREE FAIRSHARE SIMULATION (15 min)

### 3.1 Enable Fairtree Algorithm

```bash
# Edit slurm.conf to add FAIR_TREE flag
sudo vim /etc/slurm/slurm.conf

# Find line:
PriorityFlags=DEPTH_OBLIVIOUS

# Change to:
PriorityFlags=ACCRUE_ALWAYS,SMALL_RELATIVE_TO_TIME

# Reload config
sudo scontrol reconfigure

# Verify
scontrol show config | grep PriorityFlags
```


**Expected Output:**

```

PriorityFlags = ACCRUE_ALWAYS,SMALL_RELATIVE_TO_TIME

```

### 3.2 Clear Job History (Optional)

```bash
# Option 1: Let jobs finish naturally (recommended for lab)
squeue

# Wait for all jobs to complete, then:
sacctmgr delete job account=root,lci starttime=0

# Option 2: Cancel all jobs (faster)
scancel -A root
scancel -A lci

# Verify queue is empty
squeue
```

### 3.3 Run Same Workload with Fairtree

```bash
# Reuse submit script (same workload)
/tmp/submit_jobs_classic.sh

# Watch queue
watch -n 5 'squeue -o "%.10i %.20j %.8A %.4C %.8T %.10p" && echo "---" && sshare -l'

# Check fairshare factors
sshare -al
```

**Expected Output (sshare -l with Fairtree):**

```
Account User RawShares NormShares RawUsage NormUsage EffectvUsage FairShare LevelFS GrpTRESMins TRESRunMins

-------------------- ---------- ---------- ----------- ----------- ----------- ------------- ---------- ---------- ------------------------------ ------------------------------

root 0.000000 14293 1.000000 cpu=4,mem=8192,energy=0,node=+

root root 1 0.009901 5487 0.383912 0.383912 0.200000 0.025790 cpu=0,mem=0,energy=0,node=0,b+

admin 30 0.297030 0 0.000000 0.000000 inf cpu=0,mem=0,energy=0,node=0,b+

admin root 1 1.000000 0 0.000000 0.000000 1.000000 inf cpu=0,mem=0,energy=0,node=0,b+

lci 70 0.693069 8805 0.616088 0.616088 1.124952 cpu=4,mem=8192,energy=0,node=+

lci rocky 1 0.009901 2298 0.160833 0.261055 0.400000 0.037927 cpu=0,mem=0,energy=0,node=0,b+

io 60 0.594059 667 0.046719 0.075831 7.833951 cpu=0,mem=0,energy=0,node=0,b+

io rocky 1 1.000000 667 0.046719 1.000000 0.800000 1.000000 cpu=0,mem=0,energy=0,node=0,b+

ml 40 0.396040 5839 0.408536 0.663114 0.597242 cpu=4,mem=8192,energy=0,node=+

ml rocky 1 1.000000 5839 0.408536 1.000000 0.600000 1.000000 cpu=4,mem=8192,energy=0,node=+
```


**Note:** Initial fairshare factors are same (no usage yet); difference emerges as jobs run.

### 3.4 Measure Priority Evolution (Fairtree)

```bash
# Reuse measure script (captures same data)
cat > /tmp/measure_fairtree.sh << 'EOF'

#!/bin/bash

echo "Time,Job,Account,Priority,FairshareAccount,FairshareUser" > /tmp/fairtree_data.csv

for i in {1..30}; do
echo "=== Iteration $i ($(date +%H:%M:%S)) ==="
squeue -o "%.10i %.20j %.8A %.20p" --noheader | while read job_id job_name account priority; do
fs_acct=$(sshare -A $account -o fairshare --noheader 2>/dev/null | head -1)
fs_user=$(sshare -u $(whoami) -o fairshare --noheader 2>/dev/null | head -1)
echo "$(date +%H:%M:%S),$job_name,$account,$priority,$fs_acct,$fs_user" >> /tmp/fairtree_data.csv
done
sleep 10
done

echo "Data saved to /tmp/fairtree_data.csv"
EOF

chmod +x /tmp/measure_fairtree.sh
/tmp/measure_fairtree.sh &
BG_PID=$!

sleep 300 && kill $BG_PID 2>/dev/null || true
```

  

### 3.5 Compare Classic vs. Fairtree

```bash
# Side-by-side comparison
echo "=== CLASSIC vs. FAIRTREE ==="
echo ""

echo "Classic (ml_job1 priority):"
grep "ml_job1" /tmp/classic_data.csv | tail -5

echo ""
echo "Fairtree (ml_job1 priority):"
grep "ml_job1" /tmp/fairtree_data.csv | tail -5

echo ""
echo "Priority difference (higher = Fairtree better):"
classic_priority=$(grep "ml_job1" /tmp/classic_data.csv | tail -1 | cut -d, -f4)
fairtree_priority=$(grep "ml_job1" /tmp/fairtree_data.csv | tail -1 | cut -d, -f4)
echo "Classic: $classic_priority, Fairtree: $fairtree_priority"
```


**Expected Insight:**

```
Fairtree shows:
- ml_job1: HIGHER priority (compared fairly within ml vs. io)
- io_job1: LOWER priority (compared fairly within ml vs. io)
- admin_job1: same priority (at root level, evaluated independently)

Why? ml and io are siblings; ml is under-used, io is over-used.
Classic penalizes both equally (parent factor); Fairtree judges fairly.
Result: ml jobs get higher priority in Fairtree.
```


## PART 4: FAIRSHARE DECAY SIMULATION (10 min)

### 4.1 Configure Short Decay Half-Life

```bash
# Edit slurm.conf
sudo vi /etc/slurm/slurm.conf

# Find line:
# PriorityDecayHalfLife=7-0

# Change to (for lab, use 1 min for fast observation):
# PriorityDecayHalfLife=0-0:01:00 # 1 minute half-life

# Reload
sudo scontrol reconfigure

# Verify
scontrol show config | grep PriorityDecayHalfLife
```


**Expected Output:**

```
PriorityDecayHalfLife=0-0:01:00
```

### 4.2 Create Heavy Usage Job

```bash
# Submit a job that uses significant resources
sbatch -A ml -n 4 -t 5 --job-name=heavy_ml \
--wrap="srun bash -c 'for i in {1..300}; do echo \$i; sleep 1; done'"

# Wait for it to finish
squeue -A ml

# Once finished, check fairshare factor
sshare -A ml -o account,fairshare
```

**Expected Output (immediately after job finishes):**

```
Account Fairshare
------- ---------
ml      0.2 # Low factor due to recent usage
```

### 4.3 Observe Fairshare Decay Over Time

```bash
# Monitor fairshare factor every 10 sec
cat > /tmp/observe_decay.sh << 'EOF'
#!/bin/bash

echo "Time Elapsed (sec),ml_Fairshare,io_Fairshare"

for i in {0..120..10}; do
sleep 10
elapsed=$((i + 10))
ml_fs=$(sshare -A ml -o fairshare --noheader 2>/dev/null | head -1)
io_fs=$(sshare -A io -o fairshare --noheader 2>/dev/null | head -1)
echo "$elapsed,$ml_fs,$io_fs"
done
EOF

chmod +x /tmp/observe_decay.sh
/tmp/observe_decay.sh
```

**Expected Output:**

```

Time Elapsed (sec),ml_Fairshare,io_Fairshare
10,0.20,0.95
20,0.30,0.94
30,0.40,0.93
40,0.50,0.92
50,0.60,0.91
60,0.65,0.90
70,0.70,0.89
80,0.75,0.88
90,0.80,0.87
100,0.85,0.86
110,0.90,0.85
120,0.92,0.84
```

**Insight:**

```
After 1 minute (half-life), ml_fairshare went from 0.2 → 0.65 (50% decay).
After 2 minutes (2× half-life), ml_fairshare → 0.92 (75% decay).
After 3 minutes (3× half-life), ml_fairshare → 0.98 (87.5% decay).

This incentivizes efficiency:
- Run big job today → penalized for 1 day (half-life=7d)
- But after 7 days, penalty is 50% reduced
- After 21 days, penalty is 87.5% gone

Users can "recover" by waiting or being efficient.
```

### 4.4 Reset Decay Half-Life to Production Value

```bash
# Change back to 7 days
sudo vi /etc/slurm/slurm.conf
# PriorityDecayHalfLife=7-0

sudo scontrol reconfigure
```


## PART 5: ACCOUNT HIERARCHY OPTIMIZATION (10 min)

### 5.1 Analyze Current Hierarchy Performance

```bash
# Check account usage over time
sacctmgr show account tree format=account,fairshare

# Get usage statistics
sacctmgr show stats format=account,user,cpu_usage,memory_usage
```

**Expected Output:**

```
Account Fairshare
------- ---------
root     1
admin    30
lci      70
ml       40
io       60
```

### 5.2 Create Optimized Hierarchy (Optional)

```bash
# Example: Add sub-accounts for ml team
sacctmgr add account cv parent=ml description="Computer Vision"
sacctmgr add account nlp parent=ml description="NLP"

# Set fair shares
sacctmgr modify account cv set fairshare=50 # 50% of ml
sacctmgr modify account nlp set fairshare=50 # 50% of ml

# Verify
sacctmgr show account tree

# Assign users
sacctmgr add user rocky account=cv
sacctmgr add user rocky account=nlp
```

  

**Expected Output:**

```
root
├── admin
├── lci
│ ├── ml
│ │ ├── cv
│ │ └── nlp
│ └── io
```

### 5.3 Simulate Sub-Account Competition

```bash
# Submit jobs to different sub-accounts
sbatch -A cv -n 2 -t 5 --job-name=cv_job \
--wrap="srun bash -c 'for i in {1..300}; do echo \$i; sleep 1; done'"

sbatch -A nlp -n 2 -t 5 --job-name=nlp_job \
--wrap="srun bash -c 'for i in {1..300}; do echo \$i; sleep 1; done'"

# Observe fairshare factors
watch -n 5 'sshare -l'
```

**Expected Output:**

```
Fairshare factors show cv and nlp competing fairly within ml.
If cv over-uses, nlp gets higher priority (and vice versa).
```

### 5.4 Document Best Practices

```bash
# Create summary document
cat > /tmp/hierarchy_best_practices.txt << 'EOF'
ACCOUNT HIERARCHY BEST PRACTICES (From Lab)

1. Structure:
root
├── admin (infrastructure)
├── research (70% share)
│ ├── ml (40% of research)
│ │ ├── cv (50% of ml)
│ │ └── nlp (50% of ml)
│ └── bio (30% of research)
└── teaching (25% share)

2. Fair Share Allocation:
- Match fair share to budget allocation
- If team gets 40% budget → 40% fair share
- Sub-accounts: split parent's share fairly

3. Fairshare Algorithm:
- Use Fairtree (Slurm 22.05+)
- Avoid classic fairshare (expensive, unfair)

4. Decay Half-Life:
- Research clusters: 7 days (balanced)
- Production clusters: 14-30 days (strict)
- Dev clusters: 1 day (forgiving)

5. Monitoring:
- Check fairshare factors: sshare -l
- Alert if any account reaches factor 0.0
- Review monthly usage: sacctmgr show stats

5. Testing:
- Always test hierarchy changes on dev cluster first
- Simulate workloads to verify fairness
- Measure priority and wait times before/after
EOF

cat /tmp/hierarchy_best_practices.txt
```


## PART 6: VERIFICATION & CLEANUP (10 min)

### 6.1 Verify Fairtree is Active

```bash
# Confirm algorithm
scontrol show config | grep -E "PriorityType|PriorityFlags"

# Expected:
# PriorityType=priority/multifactor
# PriorityFlags=FAIR_TREE DEPTH_OBLIVIOUS
```

### 6.2 Generate Summary Report

```bash
# Collect all data
cat > /tmp/lab_summary.sh << 'EOF'
#!/bin/bash

echo "=== SLURM FAIRSHARE LAB SUMMARY ==="
echo ""
echo "1. Cluster Info:"
sinfo

echo ""
echo "2. Account Hierarchy:"
sacctmgr show account tree format=account,fairshare

echo ""
echo "3. Fairshare Factors (Current):"
sshare -l

echo ""
echo "4. Algorithm Configuration:"
scontrol show config | grep -E "PriorityType|PriorityFlags|PriorityDecay"

echo ""
echo "5. Queue Status:"
squeue

echo ""
echo "6. Data Files Generated:"
ls -lh /tmp/*data.csv 2>/dev/null || echo "No data files"

EOF

chmod +x /tmp/lab_summary.sh
/tmp/lab_summary.sh > /tmp/lab_summary.txt

cat /tmp/lab_summary.txt
```

  

### 6.3 Save Data for Analysis

```bash
# Archive all lab data
mkdir -p /tmp/fairshare_lab_results
cp /tmp/classic_data.csv /tmp/fairshare_lab_results/
cp /tmp/fairtree_data.csv /tmp/fairshare_lab_results/
cp /tmp/lab_summary.txt /tmp/fairshare_lab_results/

tar -czf /tmp/fairshare_lab_results.tar.gz /tmp/fairshare_lab_results/
echo "Lab results archived to /tmp/fairshare_lab_results.tar.gz"
```

  

### 6.4 Cleanup (Optional)

```bash
# Cancel any remaining jobs
scancel -A root
scancel -A lci

# Remove temporary scripts
rm -f /tmp/submit_jobs_classic.sh /tmp/measure_classic.sh /tmp/measure_fairtree.sh /tmp/observe_decay.sh

# Keep data files for analysis
echo "Lab cleanup complete. Data files preserved in /tmp/fairshare_lab_results/"
```


## PART 7: ADVANCED EXERCISES (Optional, If Time Permits)

### 7.1 Priority Weight Tuning

```bash
# Experiment with different priority weights
# Current (fairshare-dominant):
# PriorityWeightFairshare=100000000
# PriorityWeightAge=10000000
# PriorityWeightQOS=110000000

# Try age-dominant (responsive cluster):
sudo vi /etc/slurm/slurm.conf
# Change to:
# PriorityWeightFairshare=1000000
# PriorityWeightAge=100000000
# PriorityWeightQOS=1000000

sudo scontrol reconfigure

# Submit same workload; observe priority changes
/tmp/submit_jobs_classic.sh
watch -n 5 'squeue -o "%.10i %.20j %.8A %.4C %.20p"'

# Revert to original
```

  

### 7.2 QOS-Based Preemption

```bash
# Create high-priority QOS
sacctmgr add qos high_priority priority=100

# Add job with high QOS
sbatch -A ml --qos=high_priority -n 2 -t 5 --job-name=priority_job \
--wrap="srun echo 'High priority job'"

# Observe: should queue-jump
squeue

# Clean up
sacctmgr delete qos high_priority
```

### 7.3 Backfill Analysis

```bash
# Check backfill parameters
scontrol show config | grep SchedulerParameters

# Submit large job + small jobs
sbatch -A ml -n 6 -t 10 --job-name=large \
--wrap="srun sleep 600"

sleep 5

sbatch -A io -n 1 -t 5 --job-name=small1 \
--wrap="srun sleep 300"

sbatch -A admin -n 1 -t 5 --job-name=small2 \
--wrap="srun sleep 300"

# Observe: small jobs backfill before large job
squeue

# Measure backfill effectiveness:
# (small jobs start immediately vs. waiting for large)
```


## LAB COMPLETION CHECKLIST

  
- [ ] Verified Slurm version (22.05+)
- [ ] Configured account hierarchy (root → dept → project)
- [ ] Ran classic fairshare simulation
- [ ] Ran Fairtree simulation
- [ ] Compared priority between algorithms
- [ ] Observed fairshare decay over time
- [ ] Optimized account hierarchy
- [ ] Generated summary report
- [ ] Archived lab data
  

## TROUBLESHOOTING GUIDE

### Problem: sshare shows all fairshare factors = 1.0

**Cause:** No usage recorded yet (jobs haven't run)

**Solution:**

```bash
# Wait for jobs to run and complete
squeue

# Once jobs finish, usage is recorded:
sacctmgr show stats
sshare -l
```

### Problem: Jobs not scheduling (stuck PENDING)

**Cause:** Insufficient resources or account restrictions

**Solution:**

```bash
# Check why job is pending
squeue -j <job_id> -o "%i %r"

# Verify account is valid
sacctmgr show assoc user=rocky account=ml

# Check node availability
sinfo
```

### Problem: Config reconfigure fails

**Cause:** Syntax error in slurm.conf

**Solution:**

```bash
# Check syntax
slurmd -C # Compute node config
slurmctld -C # Controller config

# Revert to backup
sudo cp /etc/slurm/slurm.conf.bak /etc/slurm/slurm.conf
sudo scontrol reconfigure
```

### Problem: Fairshare factors don't change after Fairtree enabled

**Cause:** Flag not loaded (need full restart)

**Solution:**

```bash
# Force reload
sudo systemctl restart slurmctld

# Verify
scontrol show config | grep PriorityFlags
```

## NOTES
Visual Comparison 0f (O(n²)) vs. (O(n)) Fairshare Scheduling Performance

Classic Fairshare (O(n²)):

Time to schedule vs. Number of jobs:
1,000 jobs  ████ (500 ms)
2,000 jobs  ████████████████ (2,000 ms) ← Gets MUCH worse!
3,000 jobs  ████████████████████████████████████ (4,500 ms)
Notice: Doubling jobs quadruples time!

Fairtree (O(n)):

Time to schedule vs. Number of jobs:
1,000 jobs  ██ (50 ms)
2,000 jobs  ████ (100 ms) ← Scales linearly
3,000 jobs  ██████ (150 ms)
Notice: Doubling jobs only doubles time.


## KEY TAKEAWAYS FROM LAB


1. **Classic vs. Fairtree:**

- Classic: slower (O(n²)), cascade penalties

- Fairtree: faster (O(n)), local fairness  

2. **Fairshare Decay:**

- Past usage fades over time (half-life)

- Short half-life (1 day): forgiving

- Long half-life (30 days): strict

3. **Account Hierarchy:**

- Structure matters (org alignment)

- Fair shares should match budget

- Siblings are compared fairly (Fairtree)

4. **Monitoring:**

- `sshare -l`: current fairshare factors

- `squeue`: job priorities

- `sacctmgr show stats`: usage over time

5. **Production Deployment:**

- Test on dev cluster first

- Migrate gradually (one flag change)

- Monitor for 1 week

- Adjust weights/decay based on feedback
  

## RESOURCES


- **Slurm Docs:** https://slurm.schedmd.com/priority_multifactor.html
- **Fairtree RFC:** https://github.com/SchedMD/slurm/issues/11032
- **Lab Data:** /tmp/fairshare_lab_results/

