# HTCondor Cluster Health & `run_as_owner` Diagnostic Playbooks

**Scope:** Windows CM, Windows Server 2022 execute nodes, RHEL 10 execute nodes,
Windows workstation submit nodes. Mixed pool with `condor_credd` on a Windows
Server node. Tests proceed from isolated subsystems to full end-to-end functional
verification.

**Conventions used throughout:**
- `[WIN-CMD]` — run in an elevated (`Run as Administrator`) Command Prompt
- `[WIN-PS]` — run in an elevated PowerShell session
- `[RHEL]` — run as root or via sudo on RHEL 10
- `[ANY]` — can be run from any node in the pool
- Variables like `<CREDD_HOST>`, `<CM_HOST>` etc. are placeholders — substitute real values
- Collected output should be saved; many later playbooks reference earlier results

---

## Playbook 0 — Environment Baseline

Run first on every node type. Establishes ground truth before testing anything else.

### 0.1 — HTCondor version and platform

```cmd
:: [WIN-CMD] on CM, execute nodes, submit nodes
condor_version
```

Expected: all nodes report the same version string (25.0.x). Any mismatch should
be noted — version skew between CM and nodes can cause subtle auth failures.

```bash
# [RHEL] on all Linux execute nodes
condor_version
rpm -qi condor | grep -E "Version|Release|Architecture"
```

### 0.2 — Dump effective configuration to a file for comparison

```cmd
:: [WIN-CMD] — run on EACH node type, save output
condor_config_val -dump > C:\Temp\condor_config_dump_%COMPUTERNAME%.txt 2>&1
```

```bash
# [RHEL]
condor_config_val -dump > /tmp/condor_config_dump_$(hostname).txt 2>&1
```

Cross-check these files for the following variables — they MUST be identical
across all nodes unless intentionally per-node:

```
CONDOR_HOST
COLLECTOR_HOST
UID_DOMAIN
FILESYSTEM_DOMAIN
CREDD_HOST
TRUST_UID_DOMAIN
SEC_DEFAULT_AUTHENTICATION
SEC_DEFAULT_AUTHENTICATION_METHODS
SEC_DAEMON_AUTHENTICATION_METHODS
ALLOW_READ
ALLOW_WRITE
ALLOW_DAEMON
ALLOW_NEGOTIATOR
```

Quick extraction:

```cmd
:: [WIN-CMD]
for %v in (CONDOR_HOST COLLECTOR_HOST UID_DOMAIN FILESYSTEM_DOMAIN CREDD_HOST TRUST_UID_DOMAIN) do (
    echo %v = && condor_config_val %v
)
```

```bash
# [RHEL]
for v in CONDOR_HOST COLLECTOR_HOST UID_DOMAIN FILESYSTEM_DOMAIN \
         CREDD_HOST TRUST_UID_DOMAIN; do
    printf "%s = %s\n" "$v" "$(condor_config_val $v)"
done
```

### 0.3 — Identify config file sources (detect overrides)

```cmd
:: [WIN-CMD]
condor_config_val -config
```

This lists every file contributing to the effective configuration, in parse order.
Verify the expected drop-in files appear and no unexpected files are present.

### 0.4 — Check which Windows account the condor service runs as

```powershell
# [WIN-PS] — run on CM, credd host, execute nodes, submit nodes
Get-WmiObject Win32_Service -Filter "Name='condor'" |
    Select-Object Name, State, StartName, PathName |
    Format-List

# Also check the process token directly
$p = Get-Process condor_master -ErrorAction SilentlyContinue
if ($p) {
    & whoami /all | Select-String "User Name|SID"
}
```

Record the `StartName` value. This is the identity that daemon-to-daemon NTSSPI
connections will present. It needs to appear in `ALLOW_DAEMON` on every receiving node.

---

## Playbook 1 — Daemon Health

### 1.1 — Verify all expected daemons are running

```cmd
:: [WIN-CMD] — CM (should show MASTER COLLECTOR NEGOTIATOR CREDD)
condor_config_val DAEMON_LIST
condor_status -any -direct <CM_HOST> 2>&1

:: Windows execute node (should show MASTER STARTD)
condor_config_val DAEMON_LIST
condor_status -any -direct <EXEC_HOST> 2>&1

:: Windows submit node (should show MASTER SCHEDD)
condor_config_val DAEMON_LIST
condor_status -any -direct <SUBMIT_HOST> 2>&1
```

```bash
# [RHEL] — Linux execute node (should show MASTER STARTD)
condor_config_val DAEMON_LIST
systemctl status condor
condor_status -any -direct $(hostname -f) 2>&1
```

### 1.2 — Check daemon process list

```powershell
# [WIN-PS]
Get-Process condor_* | Select-Object Name, Id, CPU, StartTime | Sort-Object Name
```

```bash
# [RHEL]
ps aux | grep condor_ | grep -v grep
```

Expected processes per role:

| Node role | Expected processes |
|---|---|
| CM | condor_master, condor_collector, condor_negotiator, condor_credd |
| Win execute | condor_master, condor_startd, condor_starter (when job running) |
| Win submit | condor_master, condor_schedd |
| RHEL execute | condor_master, condor_startd |

### 1.3 — Check for recent daemon restarts or crashes in logs

```powershell
# [WIN-PS] — check for ERROR or STARTING UP lines in the last 100 lines of each log
$logdir = condor_config_val LOG
foreach ($log in Get-ChildItem "$logdir\*Log" -ErrorAction SilentlyContinue) {
    $last = Get-Content $log.FullName -Tail 100
    $hits = $last | Select-String "STARTING UP|EXITING|ERROR|EXCEPTION"
    if ($hits) {
        Write-Host "=== $($log.Name) ===" -ForegroundColor Yellow
        $hits
    }
}
```

```bash
# [RHEL]
logdir=$(condor_config_val LOG)
for log in "$logdir"/*Log; do
    hits=$(tail -100 "$log" 2>/dev/null | grep -E "STARTING UP|EXITING|ERROR|EXCEPTION")
    if [ -n "$hits" ]; then
        echo "=== $(basename $log) ==="
        echo "$hits"
    fi
done
```

### 1.4 — Verify credd daemon is listed in collector

```cmd
:: [ANY WIN-CMD]
condor_status -any | findstr /i "credd"
```

If `condor_credd` does not appear here, it is not advertising to the collector.
The startd on execute nodes cannot locate it, which directly causes `LocalCredd = UNDEF`.

---

## Playbook 2 — Network and DNS

DNS failures are the silent killer in HTCondor pools. Every subsequent test depends
on this working correctly.

### 2.1 — Forward and reverse DNS for all pool nodes

Run from every node type targeting every other node type:

```powershell
# [WIN-PS] — test all pool hostnames
$hosts = @("<CM_HOST>", "<CREDD_HOST>", "<EXEC_WIN_01>", "<EXEC_RHEL_01>", "<SUBMIT_01>")
foreach ($h in $hosts) {
    try {
        $fwd = [System.Net.Dns]::GetHostAddresses($h)
        foreach ($ip in $fwd) {
            $rev = [System.Net.Dns]::GetHostEntry($ip.ToString())
            Write-Host "FWD: $h -> $($ip.ToString())   REV: $($ip.ToString()) -> $($rev.HostName)"
        }
    } catch {
        Write-Host "FAIL: $h -- $_" -ForegroundColor Red
    }
}
```

```bash
# [RHEL]
HOSTS=("<CM_HOST>" "<CREDD_HOST>" "<EXEC_WIN_01>" "<EXEC_RHEL_01>" "<SUBMIT_01>")
for h in "${HOSTS[@]}"; do
    ip=$(dig +short "$h" 2>/dev/null | tail -1)
    rev=$(dig +short -x "$ip" 2>/dev/null | sed 's/\.$//')
    printf "FWD: %-30s -> %-15s   REV: %-15s -> %s\n" "$h" "$ip" "$ip" "$rev"
done
```

**Pass criteria:** Forward and reverse DNS must agree on the FQDN for every node.
HTCondor uses reverse DNS to verify identity claims. Mismatches cause auth failures
that are difficult to trace.

### 2.2 — Verify HTCondor's own hostname resolution

HTCondor determines its hostname independently of the OS. Check what it resolves:

```cmd
:: [WIN-CMD]
condor_config_val FULL_HOSTNAME
condor_config_val IP_ADDRESS
```

```bash
# [RHEL]
condor_config_val FULL_HOSTNAME
condor_config_val IP_ADDRESS
```

The `FULL_HOSTNAME` value must be the FQDN that other nodes can resolve. If it
returns just a short hostname or the wrong FQDN, set `NETWORK_HOSTNAME` explicitly:

```ini
NETWORK_HOSTNAME = correct-fqdn.example.com
```

### 2.3 — Verify UID_DOMAIN matches across all nodes

```cmd
:: [ANY WIN-CMD or RHEL] — from CM, query all nodes at once
condor_status -af Machine UID_DOMAIN | sort
```

Every line must show the same `UID_DOMAIN` value. Any node showing a different
value will fail job matching and credential lookups.

### 2.4 — TCP port 9618 reachability

```powershell
# [WIN-PS] — test from submit node to CM, credd host, and execute nodes
$targets = @("<CM_HOST>", "<CREDD_HOST>", "<EXEC_WIN_01>")
foreach ($t in $targets) {
    $result = Test-NetConnection -ComputerName $t -Port 9618 -WarningAction SilentlyContinue
    $status = if ($result.TcpTestSucceeded) { "OPEN" } else { "BLOCKED" }
    Write-Host "$t :9618 -> $status"
}
```

```bash
# [RHEL]
for t in <CM_HOST> <CREDD_HOST> <EXEC_WIN_01>; do
    if nc -z -w3 "$t" 9618 2>/dev/null; then
        echo "$t :9618 -> OPEN"
    else
        echo "$t :9618 -> BLOCKED"
    fi
done
```

If port 9618 is blocked between any pair of nodes, HTCondor will fail silently
or with confusing error messages. Ensure Windows Firewall and any network ACLs
permit TCP 9618 bidirectionally among all pool members.

---

## Playbook 3 — Pool Signing Key / Pool Password Verification

These must be correct before any authentication tests will succeed.

### 3.1 — Verify the POOL signing key file exists on all Windows nodes

```powershell
# [WIN-PS] — run on CM, credd host, all execute nodes, all submit nodes
$keydir = condor_config_val SEC_PASSWORD_DIRECTORY
if (-not $keydir) { $keydir = "C:\ProgramData\HTCondor\passwords.d" }
$keyfile = Join-Path $keydir "POOL"

if (Test-Path $keyfile) {
    $fi = Get-Item $keyfile
    $acl = Get-Acl $keyfile
    Write-Host "EXISTS: $keyfile"
    Write-Host "  Size:     $($fi.Length) bytes"
    Write-Host "  Modified: $($fi.LastWriteTime)"
    Write-Host "  Owner:    $($acl.Owner)"
    # Show SHA256 of file for cross-node comparison
    $hash = Get-FileHash $keyfile -Algorithm SHA256
    Write-Host "  SHA256:   $($hash.Hash)"
} else {
    Write-Host "MISSING: $keyfile" -ForegroundColor Red
}
```

**Critical check:** Run this on every Windows node and compare the SHA256 hashes.
They must all be identical. A node with a different or missing POOL file cannot
validate IDTOKENS from the CM and cannot use the PASSWORD authentication method
correctly.

### 3.2 — Verify the POOL signing key on RHEL nodes

```bash
# [RHEL]
keydir=$(condor_config_val SEC_PASSWORD_DIRECTORY 2>/dev/null || echo "/etc/condor/passwords.d")
keyfile="$keydir/POOL"

if [ -f "$keyfile" ]; then
    echo "EXISTS: $keyfile"
    echo "  Size:     $(stat -c%s $keyfile) bytes"
    echo "  Modified: $(stat -c%y $keyfile)"
    echo "  Owner:    $(stat -c%U:%G $keyfile)"
    echo "  Perms:    $(stat -c%a $keyfile)"
    echo "  SHA256:   $(sha256sum $keyfile | awk '{print $1}')"
    # Permissions must be 600 or the daemon will refuse to use it
    perms=$(stat -c%a $keyfile)
    if [ "$perms" != "600" ]; then
        echo "  WARNING: permissions should be 600, got $perms" >&2
    fi
else
    echo "MISSING: $keyfile" >&2
fi
```

### 3.3 — Verify the pool password is stored for condor_pool identity

```cmd
:: [WIN-CMD on credd host] — as Administrator
condor_store_cred query -c
```

Expected output: `Credential is stored for condor_pool@<UID_DOMAIN>`

If it says "no credential" or returns an error, re-store it:

```cmd
condor_store_cred add -c
:: Enter the pool password when prompted
```

### 3.4 — Verify IDTOKEN infrastructure

```cmd
:: [WIN-CMD on CM]
condor_token_list
```

```bash
# [RHEL CM]
condor_token_list
```

Check that daemon tokens exist in `C:\ProgramData\HTCondor\tokens.d\` (Windows)
or `/etc/condor/tokens.d/` (RHEL) on each non-CM node:

```powershell
# [WIN-PS] — on execute/submit nodes
$tokendir = "C:\ProgramData\HTCondor\tokens.d"
if (Test-Path $tokendir) {
    Get-ChildItem $tokendir | ForEach-Object {
        Write-Host "Token file: $($_.Name)  Size: $($_.Length)"
    }
} else {
    Write-Host "Token directory missing: $tokendir" -ForegroundColor Red
}
```

---

## Playbook 4 — Authentication Tests (`condor_ping` Progression)

Work through authorization levels from weakest to strongest. Each successive
level requires more trust. Stop at the first failure and investigate before
continuing — later levels will not pass if earlier ones fail.

### 4.1 — Enable security debugging for all ping tests

Set this environment variable in your shell before running any `condor_ping` commands:

```cmd
:: [WIN-CMD]
set _condor_SEC_TOOL_DEBUG=D_SECURITY:2
```

```bash
# [RHEL]
export _condor_SEC_TOOL_DEBUG=D_SECURITY:2
```

### 4.2 — Local self-ping (baseline)

```cmd
:: [WIN-CMD on each node — targets local master]
condor_ping -verbose DAEMON CONFIG READ WRITE
```

This must succeed everywhere with no auth errors. If a node can't ping itself,
the local HTCondor installation is broken before any networking is involved.

### 4.3 — CM → execute node pings

```cmd
:: [WIN-CMD on CM] — test all authorization levels against each execute node
for %h in (<EXEC_WIN_01> <EXEC_WIN_02> <EXEC_RHEL_01> <EXEC_RHEL_02>) do (
    echo === Testing %h ===
    condor_ping -verbose -name %h -type STARTD READ WRITE DAEMON CONFIG
    echo.
)
```

### 4.4 — Execute node → CM pings

```cmd
:: [WIN-CMD on each execute node]
condor_ping -verbose -type COLLECTOR READ WRITE DAEMON
condor_ping -verbose -type NEGOTIATOR READ WRITE DAEMON NEGOTIATOR
```

### 4.5 — Submit node → CM pings

```cmd
:: [WIN-CMD on submit node]
condor_ping -verbose -type COLLECTOR READ WRITE
condor_ping -verbose -type SCHEDD READ WRITE DAEMON
```

### 4.6 — Critical: all Windows nodes → credd host

```cmd
:: [WIN-CMD on each execute node and submit node]
condor_ping -verbose -name <CREDD_HOST> -type CREDD READ WRITE DAEMON
```

DAEMON must succeed here. If it fails, `LocalCredd` will never populate.

### 4.7 — Capture and compare `condor_ping` identity strings

```cmd
:: [WIN-CMD] — run on each node, record the "Identity" column for DAEMON level
condor_ping -verbose -name <CREDD_HOST> -type CREDD DAEMON 2>&1 | findstr /i "identity\|authenticated\|denied\|allow"
```

Create a table:

| Source node | Target | Identity presented | DAEMON decision |
|---|---|---|---|
| CM | credd | ? | ? |
| EXEC_WIN_01 | credd | ? | ? |
| SUBMIT_01 | credd | ? | ? |
| EXEC_RHEL_01 | credd | ? | ? |

The identity in the DAEMON row must match what is in `CREDD.ALLOW_DAEMON` on the
credd host. If it doesn't, that is your authorization mismatch.

---

## Playbook 5 — Authorization Configuration Verification

### 5.1 — Dump and verify all ALLOW_* lists on all nodes

```cmd
:: [WIN-CMD] — run on each node
for %v in (ALLOW_READ ALLOW_WRITE ALLOW_DAEMON ALLOW_ADMINISTRATOR ALLOW_NEGOTIATOR ALLOW_CONFIG ALLOW_ADVERTISE_STARTD ALLOW_ADVERTISE_SCHEDD) do (
    echo %v:
    condor_config_val %v
    echo.
)
```

```bash
# [RHEL]
for v in ALLOW_READ ALLOW_WRITE ALLOW_DAEMON ALLOW_ADMINISTRATOR \
         ALLOW_NEGOTIATOR ALLOW_CONFIG ALLOW_ADVERTISE_STARTD \
         ALLOW_ADVERTISE_SCHEDD; do
    printf "%s:\n  %s\n\n" "$v" "$(condor_config_val $v)"
done
```

### 5.2 — Verify credd-specific authorization

```cmd
:: [WIN-CMD on credd host]
for %v in (CREDD.ALLOW_DAEMON CREDD.ALLOW_WRITE CREDD.ALLOW_READ CREDD.SEC_DAEMON_AUTHENTICATION_METHODS CREDD.SEC_DEFAULT_AUTHENTICATION CREDD.SEC_DEFAULT_ENCRYPTION CREDD.SEC_DEFAULT_INTEGRITY) do (
    echo %v:
    condor_config_val %v
    echo.
)
```

Expected values for a correctly configured credd:

```
CREDD.ALLOW_DAEMON             = condor_pool@EXAMPLE.COM
CREDD.SEC_DAEMON_AUTHENTICATION_METHODS = PASSWORD
CREDD.SEC_DEFAULT_AUTHENTICATION = REQUIRED
CREDD.SEC_DEFAULT_ENCRYPTION   = REQUIRED
CREDD.SEC_DEFAULT_INTEGRITY    = REQUIRED
```

### 5.3 — Verify PASSWORD is in daemon auth methods on all Windows nodes

```cmd
:: [WIN-CMD] — run on credd host, all execute nodes, all submit nodes
condor_config_val SEC_DAEMON_AUTHENTICATION_METHODS
```

The word `PASSWORD` must appear in the output. If it is absent, daemon-to-daemon
connections will never authenticate as `condor_pool@...`, and the credd will
reject them.

### 5.4 — Check that STARTER_ALLOW_RUNAS_OWNER is set on execute nodes

```cmd
:: [WIN-CMD on each Windows execute node]
condor_config_val STARTER_ALLOW_RUNAS_OWNER
```

Must return `True`. If False or undefined, run_as_owner jobs will silently fall
back to the slot user.

### 5.5 — Check CREDD_CACHE_LOCALLY

```cmd
:: [WIN-CMD on all Windows nodes except credd host itself]
condor_config_val CREDD_CACHE_LOCALLY
condor_config_val CREDD_HOST
```

`CREDD_CACHE_LOCALLY` must be `True` and `CREDD_HOST` must resolve to the correct hostname.

---

## Playbook 6 — Credd Subsystem Isolation Tests

These tests isolate the credd daemon independently from job submission.

### 6.1 — Verify credd is listening and reachable

```cmd
:: [WIN-CMD on credd host]
condor_status -any | findstr /i credd

:: From a remote node:
condor_ping -verbose -name <CREDD_HOST> -type CREDD READ WRITE DAEMON
```

### 6.2 — Turn up credd logging to maximum

Add to credd host config temporarily:

```ini
CREDD_DEBUG    = D_FULLDEBUG D_SECURITY:2 D_COMMAND
MAX_CREDD_LOG  = 200000000
```

```cmd
condor_reconfig
```

Leave this in place for all subsequent credd tests. The CreddLog will now show
every connection attempt, auth method tried, identity established, and credential
fetch request.

### 6.3 — Attempt pool password store from each node type

Run from each Windows node type in sequence, watching CreddLog in real time:

```cmd
:: [WIN-CMD — new window, on credd host, watch log]
powershell -Command "Get-Content 'C:\ProgramData\HTCondor\log\CreddLog' -Wait -Tail 20"
```

Then from the CM, execute node, and submit node:

```cmd
:: [WIN-CMD — on each source node]
condor_store_cred add -c -debug
:: Enter the pool password
```

For each attempt, CreddLog should show:
```
PERMISSION GRANTED to condor_pool@EXAMPLE.COM from <source-ip>
```

If you see `PERMISSION DENIED`, note the identity string in the log line — that
is what you need to add to `CREDD.ALLOW_DAEMON`.

### 6.4 — Query pool credential from each node

```cmd
:: [WIN-CMD on each node]
condor_store_cred query -c -debug
```

Expected: `Credential is stored for condor_pool@EXAMPLE.COM`

If this fails from some nodes and not others, compare the `ALLOW_CONFIG` and
`ALLOW_WRITE` settings — `condor_store_cred query` uses CONFIG-level access
for the initial connection to the schedd.

### 6.5 — Test user credential storage

For each test user, from their own submit node session:

```cmd
:: [WIN-CMD — as the test user, not as Administrator]
condor_store_cred query -debug
```

Then store it:

```cmd
condor_store_cred add -debug
:: Enter the user's Windows domain password
```

Then query again to confirm it was stored:

```cmd
condor_store_cred query -debug
```

Check CreddLog on the credd host — it should show the user's credential being stored:
```
PERMISSION GRANTED to <USERNAME>@EXAMPLE.COM from <source-ip>
```

---

## Playbook 7 — LocalCredd Population Tests

`LocalCredd` appearing in the startd ClassAd is the gating signal for `run_as_owner`
job matching. This playbook verifies and forces its population.

### 7.1 — Check current LocalCredd status across all execute nodes

```cmd
:: [ANY WIN-CMD or RHEL]
condor_status -af Machine LocalCredd | sort
```

Each Windows execute node should show the credd hostname. RHEL nodes will show
nothing (LocalCredd is a Windows-only attribute). If any Windows execute node
shows blank, `LocalCredd` is not set on that node.

More detailed per-slot view:

```cmd
condor_status -f "%-30s" Name -f "%-30s" Machine -f "%s\n" ifThenElse(isUndefined(LocalCredd),"UNDEF",LocalCredd)
```

### 7.2 — Check HasWindowsRunAsOwner

```cmd
condor_status -af Machine HasWindowsRunAsOwner
```

For Windows execute nodes, this must be `true`. If it is `false` or undefined,
`STARTER_ALLOW_RUNAS_OWNER` is not set, or the startd ClassAd has not refreshed.

### 7.3 — Force a startd ClassAd refresh

If LocalCredd is UNDEF despite the credd being reachable:

```cmd
:: [WIN-CMD on CM]
condor_reconfig -all
```

Wait 60 seconds. The startd on each execute node will re-run its credd probe and
update its ClassAd.

```cmd
:: Wait, then check again
ping -n 60 localhost > nul
condor_status -f "%-30s" Machine -f "%s\n" ifThenElse(isUndefined(LocalCredd),"UNDEF",LocalCredd)
```

### 7.4 — Manually probe credd connectivity from an execute node's StartLog

On a Windows execute node where LocalCredd is UNDEF, add to config:

```ini
STARTD_DEBUG = D_FULLDEBUG D_SECURITY:2
```

Reconfig, then check StartLog for lines containing `credd` or `LocalCredd`:

```powershell
# [WIN-PS on execute node]
$log = condor_config_val LOG
Get-Content "$log\StartLog" | Select-String -Pattern "credd|LocalCredd|credential" -CaseSensitive:$false
```

Look for lines like:
```
Contacting CREDD at <ip>:port
Successfully contacted CREDD: set LocalCredd to <hostname>
```
or failure lines:
```
Failed to contact CREDD at <ip>: <reason>
```

---

## Playbook 8 — UID_DOMAIN and Identity Consistency

### 8.1 — Verify UID_DOMAIN is consistent across the pool

```cmd
:: [ANY WIN-CMD]
condor_status -af Machine UID_DOMAIN | sort -u
```

Must return exactly one unique value. Multiple values indicate misconfiguration.

### 8.2 — Verify what identity a job will be recorded under

Submit a test probe job and check what Owner attribute it receives:

Create `probe.sub`:
```
executable = C:\Windows\System32\cmd.exe
arguments  = /C whoami > C:\Temp\whoami_test.txt
output     = C:\Temp\probe.out
error      = C:\Temp\probe.err
log        = C:\Temp\probe.log
queue
```

```cmd
condor_submit probe.sub
condor_q -format "%s\n" Owner
```

Note the Owner format. It must be `username` (not `DOMAIN\username`). HTCondor
stores the job owner without the domain prefix; the domain is inferred from
`UID_DOMAIN`. If the owner shows `DOMAIN\username`, the UID_DOMAIN matching is
broken.

### 8.3 — Verify credential is stored under the correct identity

```cmd
:: [WIN-CMD on submit node — as the test user]
condor_store_cred query -debug 2>&1 | findstr /i "account\|credential\|user"
```

The account name reported must match the format `username@UID_DOMAIN`. If it
shows `DOMAIN\username@UID_DOMAIN` (double-qualified), the credd lookup will fail.

### 8.4 — Cross-check via condor_store_cred query with explicit username

```cmd
:: [WIN-CMD on credd host as Administrator]
condor_store_cred query -u testuser@EXAMPLE.COM
```

If this fails but `condor_store_cred query -u testuser` succeeds, there is a
domain name format mismatch. Ensure `UID_DOMAIN` equals the domain portion of
what Windows presents.

---

## Playbook 9 — Job Matching Verification

Before testing actual execution, verify the ClassAd requirements will match.

### 9.1 — Verify `HasWindowsRunAsOwner` and `LocalCredd` requirements match

```cmd
:: [WIN-CMD on submit node]
condor_status -constraint "HasWindowsRunAsOwner == true && isString(LocalCredd)" \
    -af Machine LocalCredd
```

This lists all execute nodes that are eligible for `run_as_owner` jobs. If empty,
no jobs with `run_as_owner = True` will ever be matched.

### 9.2 — Run condor_q -better-analyze on a held or idle run_as_owner job

If a job is already stuck idle or on hold:

```cmd
condor_q -better-analyze <JOBID>
```

Look for the `TARGET.HasWindowsRunAsOwner` and `TARGET.LocalCredd` conditions
in the output. These show which requirement is failing and how many machines
satisfy each condition.

### 9.3 — Simulate a run_as_owner requirements expression

```cmd
:: [WIN-CMD] — count machines that would match a run_as_owner job
condor_status -constraint "(OpSys == \"WINDOWS\") && HasWindowsRunAsOwner && isString(LocalCredd)" \
    -af Machine HasWindowsRunAsOwner LocalCredd
```

---

## Playbook 10 — Functional Job Tests (Build-Up Sequence)

Each test builds on the previous. Do not proceed to the next test until the
current one passes cleanly.

### Test 10.1 — Baseline: plain job to Windows execute node, no run_as_owner

Creates `test01_baseline.sub`:

```
# test01_baseline.sub
# Simplest possible Windows job. No run_as_owner. Verifies basic job flow.
executable   = C:\Windows\System32\cmd.exe
arguments    = /C echo Baseline OK > C:\Temp\condor_test01.txt
output       = C:\Temp\test01.out
error        = C:\Temp\test01.err
log          = C:\Temp\test01.log
requirements = (OpSys == "WINDOWS")
queue
```

```cmd
condor_submit test01_baseline.sub
condor_watch_q
```

**Pass criteria:**
- Job leaves queue without going on hold
- `C:\Temp\condor_test01.txt` exists on the execute node containing `Baseline OK`
- No errors in `test01.log`

### Test 10.2 — Baseline: plain job to RHEL execute node

Creates `test02_linux.sub`:

```
# test02_linux.sub
executable   = /bin/hostname
output       = /tmp/condor_test02.out
error        = /tmp/condor_test02.err
log          = /tmp/condor_test02.log
requirements = (OpSys == "LINUX")
queue
```

```bash
condor_submit test02_linux.sub
condor_watch_q
```

### Test 10.3 — run_as_owner: verify identity in job output

Creates `test03_whoami.sub`. The job writes `whoami` output to a local path so we
can confirm it ran as the correct user:

```
# test03_whoami.sub
executable   = C:\Windows\System32\cmd.exe
arguments    = /C whoami /all > C:\Temp\condor_test03_whoami.txt
output       = C:\Temp\test03.out
error        = C:\Temp\test03.err
log          = C:\Temp\test03.log
requirements = (OpSys == "WINDOWS")
run_as_owner = True
queue
```

```cmd
condor_submit test03_whoami.sub
condor_watch_q
```

**Pass criteria:**
- Job completes without going on hold
- `C:\Temp\condor_test03_whoami.txt` on the execute node contains the **submitting
  user's domain username**, not a slot user (e.g. `condor-slot1` or similar)

If the job goes on hold, retrieve the hold reason:
```cmd
condor_q -hold -format "%-12d" ClusterId -format "%-12d" ProcId -format "%s\n" HoldReason
```

### Test 10.4 — run_as_owner: UNC path read access

This test verifies that credentials are being impersonated correctly — the job
reads from a UNC share that only the submitting user can access.

Pre-requisite: ensure `\\<FILESERVER>\<SHARE>\condor_test_input.txt` exists and
is readable only by the test user (not by the machine account or slot users).

Creates `test04_unc_read.sub`:

```
# test04_unc_read.sub
executable   = C:\Windows\System32\cmd.exe
arguments    = /C type \\<FILESERVER>\<SHARE>\condor_test_input.txt > C:\Temp\test04_output.txt
output       = C:\Temp\test04.out
error        = C:\Temp\test04.err
log          = C:\Temp\test04.log
requirements = (OpSys == "WINDOWS")
run_as_owner = True
queue
```

**Pass criteria:**
- Job completes without hold
- `C:\Temp\test04_output.txt` on execute node contains the content of the input file
- No `Access Denied` or `Network path not found` in error output

If this fails but test 10.3 passed (identity was correct), the issue is Kerberos
ticket delegation or SMB session token propagation — confirm the file server grants
access to the user identity seen in test 10.3.

### Test 10.5 — run_as_owner: UNC path write access

Creates `test05_unc_write.sub`:

```
# test05_unc_write.sub
# Output and log files go directly to the UNC share
executable   = C:\Windows\System32\cmd.exe
arguments    = /C echo Write test OK
output       = \\<FILESERVER>\<SHARE>\condor_test05.out
error        = \\<FILESERVER>\<SHARE>\condor_test05.err
log          = \\<FILESERVER>\<SHARE>\condor_test05.log
requirements = (OpSys == "WINDOWS")
run_as_owner = True
queue
```

**Pass criteria:**
- Job completes without hold
- Output file appears on the UNC share with correct content
- Log file appears on the UNC share

### Test 10.6 — run_as_owner: multi-slot stress test

Submit 20 concurrent run_as_owner jobs to stress the credential caching:

```cmd
:: Create test06_stress.sub
(
echo executable   = C:\Windows\System32\cmd.exe
echo arguments    = /C whoami
echo output       = C:\Temp\test06_$(Process).out
echo error        = C:\Temp\test06_$(Process).err
echo log          = C:\Temp\test06.log
echo requirements = (OpSys == "WINDOWS"^)
echo run_as_owner = True
echo queue 20
) > test06_stress.sub

condor_submit test06_stress.sub
condor_watch_q
```

**Pass criteria:**
- All 20 jobs complete without holds
- None run as slot user (spot-check a few output files)
- CreddLog on credd host shows successful credential fetches, no auth failures

### Test 10.7 — run_as_owner: job targeting both Windows and RHEL (platform switching)

This verifies that `run_as_owner = True` in a submit file does not prevent the
job from also running on RHEL (where it should be ignored gracefully):

```
# test07_any_platform.sub
executable   = /usr/bin/id
# On Windows this would be: executable = C:\Windows\System32\cmd.exe
# This test uses Linux exec nodes only
output       = /tmp/test07.out
error        = /tmp/test07.err
log          = /tmp/test07.log
requirements = (OpSys == "LINUX")
run_as_owner = True
queue
```

```bash
condor_submit test07_any_platform.sub
condor_watch_q
```

**Pass criteria:**
- Job runs on a RHEL execute node without error
- The `run_as_owner` attribute is silently ignored on Linux (not held)

---

## Playbook 11 — Log Analysis Scripts

### 11.1 — Unified PERMISSION DENIED scanner

Run after any failed test to gather all denial events:

```powershell
# [WIN-PS] — scan all daemon logs for denials
$logdir = & condor_config_val LOG
$pattern = "PERMISSION DENIED|DC_AUTHENTICATE.*failed|SECMAN.*error|authentication.*failed"
Get-ChildItem "$logdir\*Log" | ForEach-Object {
    $matches = Select-String -Path $_.FullName -Pattern $pattern -CaseSensitive:$false
    if ($matches) {
        Write-Host "`n=== $($_.Name) ===" -ForegroundColor Red
        $matches | ForEach-Object { Write-Host $_.Line }
    }
}
```

```bash
# [RHEL]
logdir=$(condor_config_val LOG)
pattern="PERMISSION DENIED|DC_AUTHENTICATE.*failed|SECMAN.*error|authentication.*failed"
for log in "$logdir"/*Log; do
    hits=$(grep -iE "$pattern" "$log" 2>/dev/null)
    if [ -n "$hits" ]; then
        echo -e "\n=== $(basename $log) ==="
        echo "$hits"
    fi
done
```

### 11.2 — credd credential fetch scanner

After submitting run_as_owner jobs, confirm the credd served credentials:

```powershell
# [WIN-PS on credd host]
$logdir = & condor_config_val LOG
$creddlog = "$logdir\CreddLog"
Write-Host "=== Credential fetches ==="
Select-String -Path $creddlog -Pattern "credential for user|PERMISSION GRANTED|PERMISSION DENIED" |
    Select-Object -Last 50 |
    ForEach-Object { Write-Host $_.Line }
```

### 11.3 — LocalCredd timeline from StartLog

```powershell
# [WIN-PS on execute node]
$logdir = & condor_config_val LOG
Select-String -Path "$logdir\StartLog" -Pattern "LocalCredd|credd|credential" |
    ForEach-Object { Write-Host $_.Line }
```

---

## Playbook 12 — Comprehensive Health Summary Script

Run this script from the CM to produce a go/no-go summary across the entire pool.
Save as `C:\Temp\htcondor_health_check.ps1` on the CM:

```powershell
# htcondor_health_check.ps1
# Run from the CM as Administrator.
# Produces a pass/fail summary for all major subsystems.

$errors = @()
$warnings = @()
$uidDomain = & condor_config_val UID_DOMAIN

function Check($label, $expr, $expected, $actual) {
    if ($actual -match [regex]::Escape($expected)) {
        Write-Host "[PASS] $label" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $label" -ForegroundColor Red
        Write-Host "       Expected: $expected"
        Write-Host "       Got:      $actual"
        $script:errors += $label
    }
}

Write-Host "`n====== HTCondor Health Check ======`n"

# --- Daemon checks ---
Write-Host "-- Daemon Health --"
$anyOutput = & condor_status -any 2>&1
Check "Collector has entries" "MyType" "MyType" ($anyOutput -join "`n")
Check "CREDD advertised" "credd" "credd" ($anyOutput -join "`n")

# --- UID_DOMAIN consistency ---
Write-Host "`n-- UID_DOMAIN Consistency --"
$domains = & condor_status -af Machine UID_DOMAIN 2>&1 | Sort-Object -Unique
if ($domains.Count -eq 1) {
    Write-Host "[PASS] UID_DOMAIN consistent: $($domains[0])" -ForegroundColor Green
} else {
    Write-Host "[FAIL] UID_DOMAIN inconsistent across nodes:" -ForegroundColor Red
    $domains | ForEach-Object { Write-Host "       $_" }
    $errors += "UID_DOMAIN inconsistency"
}

# --- HasWindowsRunAsOwner ---
Write-Host "`n-- run_as_owner Readiness --"
$runas = & condor_status -constraint "(OpSys == `"WINDOWS`") && HasWindowsRunAsOwner && isString(LocalCredd)" -af Machine 2>&1
if ($runas) {
    Write-Host "[PASS] Windows execute nodes ready for run_as_owner:" -ForegroundColor Green
    $runas | ForEach-Object { Write-Host "       $_" }
} else {
    Write-Host "[FAIL] No Windows execute nodes are ready for run_as_owner" -ForegroundColor Red
    $errors += "No run_as_owner capable nodes"
}

# --- LocalCredd UNDEF check ---
$undefNodes = & condor_status -constraint "(OpSys == `"WINDOWS`") && isUndefined(LocalCredd)" -af Machine 2>&1
if ($undefNodes) {
    Write-Host "[WARN] Windows nodes with LocalCredd UNDEF:" -ForegroundColor Yellow
    $undefNodes | ForEach-Object { Write-Host "       $_" }
    $warnings += "Some nodes have LocalCredd UNDEF"
}

# --- Pool password ---
Write-Host "`n-- Pool Password --"
$credq = & condor_store_cred query -c 2>&1
if ($credq -match "Credential is stored") {
    Write-Host "[PASS] Pool password stored: $credq" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Pool password NOT stored on this node" -ForegroundColor Red
    $errors += "Pool password not stored on CM"
}

# --- STARTER_ALLOW_RUNAS_OWNER ---
Write-Host "`n-- STARTER_ALLOW_RUNAS_OWNER (local check) --"
$sarow = & condor_config_val STARTER_ALLOW_RUNAS_OWNER 2>&1
Check "STARTER_ALLOW_RUNAS_OWNER" "True" "True" $sarow

# --- condor_ping DAEMON to credd host ---
Write-Host "`n-- condor_ping DAEMON to credd host --"
$creddHost = & condor_config_val CREDD_HOST
$pingResult = & condor_ping -verbose -name $creddHost -type CREDD DAEMON 2>&1
if ($pingResult -match "ALLOW") {
    Write-Host "[PASS] DAEMON ping to credd host succeeded" -ForegroundColor Green
} else {
    Write-Host "[FAIL] DAEMON ping to credd host failed" -ForegroundColor Red
    $errors += "DAEMON ping to credd host failed"
}

# --- Summary ---
Write-Host "`n====== Summary ======"
if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
} else {
    if ($errors.Count -gt 0) {
        Write-Host "ERRORS ($($errors.Count)):" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  - $_" }
    }
    if ($warnings.Count -gt 0) {
        Write-Host "WARNINGS ($($warnings.Count)):" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  - $_" }
    }
}
```

Run it:
```powershell
powershell -ExecutionPolicy Bypass -File C:\Temp\htcondor_health_check.ps1
```

---

## Playbook 13 — Windows Firewall and Security Policy

Windows Firewall rules and Windows Defender can silently block HTCondor traffic
without leaving any HTCondor log evidence. Test this subsystem independently
before assuming any auth problem is config-based.

### 13.1 — Check Windows Firewall state

```powershell
# [WIN-PS] — on CM, credd host, execute nodes, submit nodes
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction

# Check specifically whether the HTCondor rule exists
Get-NetFirewallRule | Where-Object { $_.DisplayName -match "condor|htcondor" } |
    Select-Object DisplayName, Enabled, Direction, Action, Profile |
    Format-Table -AutoSize
```

If no HTCondor rules appear, the installer did not create firewall exceptions, or
they were removed. Create them manually:

```powershell
# [WIN-PS as Administrator] — create inbound rule for HTCondor shared port
New-NetFirewallRule `
    -DisplayName "HTCondor Daemon Port 9618 Inbound" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 9618 `
    -Action Allow `
    -Profile Domain,Private `
    -Enabled True

# Allow HTCondor binaries inbound (catches dynamic ports)
$htcDir = & condor_config_val BIN
New-NetFirewallRule `
    -DisplayName "HTCondor Binaries Inbound" `
    -Direction Inbound `
    -Program "$htcDir\condor_master.exe" `
    -Action Allow `
    -Profile Domain,Private `
    -Enabled True
```

### 13.2 — Test connectivity bypassing HTCondor entirely

```powershell
# [WIN-PS on submit node] — raw TCP test to each execute node and credd host
function Test-Port {
    param($Host, $Port)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect($Host, $Port, $null, $null)
        $wait = $ar.AsyncWaitHandle.WaitOne(3000, $false)
        if ($wait -and -not $tcp.Client.Connected) { throw }
        $tcp.EndConnect($ar)
        $tcp.Close()
        return "OPEN"
    } catch { return "BLOCKED" }
}

$nodes = @("<CM_HOST>", "<CREDD_HOST>", "<EXEC_WIN_01>", "<EXEC_WIN_02>")
foreach ($n in $nodes) {
    $result = Test-Port $n 9618
    Write-Host "$n`:9618 -> $result" -ForegroundColor $(if ($result -eq "OPEN") {"Green"} else {"Red"})
}
```

### 13.3 — Check Windows Defender exclusions

```powershell
# [WIN-PS]
$htcBin = & condor_config_val BIN
$htcLog = & condor_config_val LOG
$htcSpool = & condor_config_val SPOOL
$htcExec = & condor_config_val EXECUTE

$prefs = Get-MpPreference
Write-Host "Excluded paths:"
$prefs.ExclusionPath | ForEach-Object { Write-Host "  $_" }
Write-Host "Excluded processes:"
$prefs.ExclusionProcess | ForEach-Object { Write-Host "  $_" }

# Check if HTCondor directories are excluded
$htcDirs = @($htcBin, $htcLog, $htcSpool, $htcExec)
foreach ($dir in $htcDirs) {
    $excluded = $prefs.ExclusionPath -contains $dir
    $status = if ($excluded) { "EXCLUDED" } else { "NOT EXCLUDED (may cause issues)" }
    Write-Host "$dir -> $status"
}
```

Defender scanning the execute directory mid-job can cause file access errors
that look like permission problems. Add exclusions if not present:

```powershell
# [WIN-PS as Administrator]
$htcBin   = & condor_config_val BIN
$htcExec  = & condor_config_val EXECUTE
$htcSpool = & condor_config_val SPOOL
Add-MpPreference -ExclusionPath $htcBin, $htcExec, $htcSpool
Add-MpPreference -ExclusionProcess "condor_master.exe","condor_startd.exe",
    "condor_schedd.exe","condor_starter.exe","condor_credd.exe"
```

### 13.4 — Check Local Security Policy for impersonation rights

`run_as_owner` requires HTCondor to impersonate Windows users via `LogonUser()`.
The service account needs the correct privileges:

```powershell
# [WIN-PS] — export local security policy and check relevant rights
secedit /export /cfg C:\Temp\secpol_export.cfg /quiet
$policy = Get-Content C:\Temp\secpol_export.cfg

# Look for SeAssignPrimaryTokenPrivilege and SeImpersonatePrivilege
$policy | Select-String "SeAssignPrimaryTokenPrivilege|SeImpersonatePrivilege|SeTcbPrivilege"
```

The HTCondor service account (or `SYSTEM`) must appear in:
- `SeImpersonatePrivilege` — impersonate a client after authentication
- `SeAssignPrimaryTokenPrivilege` — replace a process-level token

If missing, add via Group Policy or `ntrights.exe`:

```cmd
:: [WIN-CMD as Administrator]
ntrights +r SeImpersonatePrivilege -u "SYSTEM"
ntrights +r SeAssignPrimaryTokenPrivilege -u "SYSTEM"
```

### 13.5 — Check User Account Control (UAC) settings

UAC can interfere with HTCondor's token impersonation. Check the current level:

```powershell
# [WIN-PS]
$uacKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$level = (Get-ItemProperty $uacKey).EnableLUA
$consent = (Get-ItemProperty $uacKey).ConsentPromptBehaviorAdmin
Write-Host "EnableLUA: $level (1=UAC on, 0=UAC off)"
Write-Host "ConsentPromptBehaviorAdmin: $consent (0=no prompt, 5=prompt)"
```

UAC at the default level should not prevent HTCondor from working if it runs
as `SYSTEM`. If jobs fail with token errors specifically on Windows Server nodes
with non-default UAC settings, setting `ConsentPromptBehaviorAdmin = 0` on
execute nodes (not workstations) may be required.

---

## Playbook 14 — Active Directory Integration Checks

### 14.1 — Verify domain membership and DC reachability

```powershell
# [WIN-PS] — on all Windows nodes
(Get-WmiObject Win32_ComputerSystem).PartOfDomain
(Get-WmiObject Win32_ComputerSystem).Domain

# Check DC connectivity
$domain = (Get-WmiObject Win32_ComputerSystem).Domain
nltest /dsgetdc:$domain
```

If any node is not domain-joined or cannot reach a DC, NTSSPI authentication
will fail silently. All Windows nodes in the pool must be in the same domain
(or a trusted domain) for NTSSPI to work across them.

### 14.2 — Verify the test user exists in AD with correct attributes

```powershell
# [WIN-PS] — requires RSAT tools or domain controller access
$testUser = "testuser"  # substitute actual username
try {
    $user = Get-ADUser $testUser -Properties PasswordLastSet, PasswordNeverExpires,
            AccountExpirationDate, LockedOut, Enabled
    $user | Select-Object SamAccountName, Enabled, LockedOut,
            PasswordLastSet, PasswordNeverExpires, AccountExpirationDate |
            Format-List
} catch {
    Write-Host "Could not query AD: $_" -ForegroundColor Yellow
    Write-Host "Trying net user instead..."
    net user $testUser /domain
}
```

A locked, disabled, or password-expired account will cause `condor_store_cred`
to appear to succeed (the password is stored) but the `LogonUser()` call in the
starter will fail at job execution time with a non-obvious error.

### 14.3 — Manually verify the stored credential works for LogonUser

The following script tests whether Windows will actually accept the stored
credential for impersonation — this is the same call HTCondor makes internally:

```powershell
# [WIN-PS on credd host or execute node] — as Administrator
# Tests if Windows can log on the user with a given password
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinLogon {
    [DllImport("advapi32.dll")]
    public static extern bool LogonUser(string user, string domain, string pass,
        int logonType, int logonProvider, out IntPtr token);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);
}
'@

$username = "testuser"
$domain   = "EXAMPLE"       # NetBIOS domain name
$password = Read-Host "Enter password for $domain\$username" -AsSecureString
$plainPw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))

$token = [IntPtr]::Zero
# LOGON32_LOGON_NETWORK = 3, LOGON32_PROVIDER_DEFAULT = 0
$ok = [WinLogon]::LogonUser($username, $domain, $plainPw, 3, 0, [ref]$token)
if ($ok) {
    Write-Host "LogonUser SUCCEEDED — credential is valid" -ForegroundColor Green
    [WinLogon]::CloseHandle($token) | Out-Null
} else {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Host "LogonUser FAILED — Win32 error: $err" -ForegroundColor Red
    # 1326 = wrong password, 1330 = password expired, 1331 = account disabled
    # 1909 = account locked out
    switch ($err) {
        1326 { Write-Host "Cause: Wrong password or username" }
        1330 { Write-Host "Cause: Password expired" }
        1331 { Write-Host "Cause: Account disabled" }
        1909 { Write-Host "Cause: Account locked out" }
        default { Write-Host "Cause: See Win32 error $err" }
    }
}
```

This eliminates the question of whether the credential stored in the credd is
actually valid before spending time on HTCondor-level debugging.

### 14.4 — Check Kerberos ticket availability (for UNC share access)

```cmd
:: [WIN-CMD — as the test user, on a submit node]
klist
```

The output must show a ticket for `krbtgt/<DOMAIN>` and ideally also for the
file server's `cifs/<FILESERVER>` service. If no tickets are present, the user
is not authenticated via Kerberos, and UNC path access will fail even if
`run_as_owner` correctly impersonates them — because the impersonated token will
not carry a Kerberos TGT to the execute node.

This is a fundamental limitation: HTCondor's `run_as_owner` uses `LogonUser()` with
`LOGON32_LOGON_NETWORK`, which creates a network-level token without a TGT. For
access to shares that require Kerberos (which is most modern AD shares), the user's
password must allow NTLM authentication, or an alternative arrangement (pre-mapped
drives, stored Windows credentials on execute nodes) is needed.

Verify NTLM is enabled on the file server:

```powershell
# [WIN-PS on file server or via GP]
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" |
    Select-Object LmCompatibilityLevel
# 0-3: NTLM accepted; 4-5: NTLMv2 only or Kerberos only
```

---

## Playbook 15 — IDTOKEN Inspection and Validation

### 15.1 — List all tokens on each node

```powershell
# [WIN-PS] — on each node
condor_token_list
```

```bash
# [RHEL]
condor_token_list
```

For each token, note the identity, the `authz` scope (what authorization levels
it grants), and the expiry. A token without `DAEMON` in its authz list will fail
DAEMON-level pings even if authentication itself succeeds.

### 15.2 — Decode a token manually (JWT inspection)

IDTOKENS are standard JWTs. You can decode the payload without any HTCondor tools:

```powershell
# [WIN-PS] — substitute actual token file path
$tokenFile = "C:\ProgramData\HTCondor\tokens.d\cm-token"
if (Test-Path $tokenFile) {
    $raw = Get-Content $tokenFile -Raw
    # JWT is header.payload.signature — decode the payload (second segment)
    $parts = $raw.Trim().Split(".")
    if ($parts.Count -ge 2) {
        $payload = $parts[1]
        # Add padding if needed
        $pad = 4 - ($payload.Length % 4)
        if ($pad -ne 4) { $payload += "=" * $pad }
        $payload = $payload.Replace("-","+").Replace("_","/")
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $decoded | ConvertFrom-Json | Format-List
    }
}
```

```bash
# [RHEL] — decode any token file
tokenfile="/etc/condor/tokens.d/cm-token"
if [ -f "$tokenfile" ]; then
    payload=$(cat "$tokenfile" | cut -d. -f2)
    # Add base64 padding
    padded="${payload}$(printf '%0.s=' $(seq 1 $((4 - ${#payload} % 4))))"
    echo "$padded" | base64 -d 2>/dev/null | python3 -m json.tool
fi
```

Expected decoded payload fields:

```json
{
  "sub": "condor@EXAMPLE.COM",
  "iat": 1700000000,
  "exp": 1731536000,
  "scope": "condor:/DAEMON condor:/READ condor:/WRITE condor:/ADVERTISE_STARTD"
}
```

If `scope` is missing or lacks `condor:/DAEMON`, regenerate the token on the CM:

```bash
# [RHEL CM as root]
condor_token_create \
    -identity condor@EXAMPLE.COM \
    -authz DAEMON -authz READ -authz WRITE \
    -authz ADVERTISE_STARTD -authz ADVERTISE_SCHEDD \
    -authz ADVERTISE_MASTER \
    -token execute-node-01
# Copy the resulting file to /etc/condor/tokens.d/ on the target node
```

### 15.3 — Verify the signing key is consistent between issuer and verifier

```bash
# [RHEL CM as root] — get SHA256 of the signing key
sha256sum /etc/condor/passwords.d/POOL
```

```powershell
# [WIN-PS — on each node] — compare to CM's hash
$keydir = & condor_config_val SEC_PASSWORD_DIRECTORY
if (-not $keydir) { $keydir = "C:\ProgramData\HTCondor\passwords.d" }
(Get-FileHash "$keydir\POOL" -Algorithm SHA256).Hash
```

All nodes must show the same hash. A node with a mismatched POOL file will reject
all IDTOKENS — it will authenticate using NTSSPI instead (falling through the method
list), but the identity presented may not match `ALLOW_DAEMON`.

### 15.4 — Test token fetch by a regular user

On Windows submit nodes, users should be able to fetch their own token:

```cmd
:: [WIN-CMD — as the test user, not Administrator]
condor_token_fetch -debug
condor_token_list
```

If this fails, the schedd does not have the signing key, or the user's NTSSPI
identity is not in `ALLOW_WRITE` on the schedd.

---

## Playbook 16 — Schedd and Negotiator Health

### 16.1 — Verify schedd is advertising to the collector

```cmd
:: [ANY WIN-CMD]
condor_status -schedd -af Name Machine ScheddIpAddr
```

Every submit node's schedd must appear here. An absent schedd means it cannot
receive matched jobs from the negotiator.

### 16.2 — Check schedd queue depth and shadow counts

```cmd
:: [ANY WIN-CMD]
condor_status -schedd -af Name TotalRunningJobs TotalIdleJobs TotalHeldJobs
```

A schedd with a large held count during testing indicates a systematic problem
(auth, credential, or configuration) rather than a per-job issue.

### 16.3 — Verify the negotiator is running and cycling

```cmd
:: [ANY WIN-CMD]
condor_status -negotiator -af Name LastNegotiationCycleDuration LastNegotiationCycleTime
```

If `LastNegotiationCycleTime` is more than 5 minutes ago, the negotiator is
stalled. Check the NegotiatorLog for errors.

### 16.4 — Check negotiation cycle log for match failures

```powershell
# [WIN-PS on CM]
$logdir = & condor_config_val LOG
Get-Content "$logdir\NegotiatorLog" -Tail 200 |
    Select-String "Started|Finished|no match|rejected|ERROR|skipping"
```

Look for lines like `Started negotiation cycle` and `Finished negotiation cycle`
with timestamps — these show cycle frequency. Lines containing `no match found`
indicate jobs that could not be matched, which may point to ClassAd requirement
mismatches.

### 16.5 — Manually trigger a negotiation cycle

```cmd
:: [WIN-CMD on CM]
condor_reschedule
```

Then watch `condor_q` and the NegotiatorLog for activity within 30 seconds.

### 16.6 — Inspect job requirements against available slots

```cmd
:: [WIN-CMD — substitute jobid]
condor_q -better-analyze <JOBID>
```

For a run_as_owner job that is idle, the output will show exactly which
requirement clause is failing and how many machines satisfy each condition.
A typical failing output looks like:

```
Condition                          Machines Matched   Suggestion
---------                          ----------------   ----------
1 (OpSys == "WINDOWS")                    10         SATISFIED
2 (TARGET.HasWindowsRunAsOwner)            0         REMOVE
3 (TARGET.LocalCredd is "credd.ex...")     0         REMOVE
```

This directly identifies whether the problem is `HasWindowsRunAsOwner`, `LocalCredd`,
or something else.

---

## Playbook 17 — Job Hold Reason Decoder

When jobs go on hold, the hold reason classifies the problem precisely. This
playbook provides a reference for all hold reasons relevant to `run_as_owner`
and provides the remediation action for each.

### 17.1 — Extract hold reasons from queue

```cmd
:: [WIN-CMD] — list all held jobs with reasons
condor_q -hold -format "Job %d.%d: " ClusterId ProcId -format "%s\n" HoldReason
```

### 17.2 — Hold reason reference for run_as_owner failures

```powershell
# [WIN-PS] — decode hold reason codes for all held jobs
condor_q -hold -af ClusterId ProcId HoldReason HoldReasonCode HoldReasonSubCode |
    ForEach-Object { Write-Host $_ }
```

**Hold reason lookup:**

| HoldReason text (partial) | Root cause | Playbook |
|---|---|---|
| `Could not locate valid credential for user 'X@Y'` | Credential not stored or UID_DOMAIN mismatch | PB 8, PB 6.5 |
| `Failed to initialize user_priv as "(null)\username"` | NTDomain not resolved — UID_DOMAIN wrong | PB 8.3, PB 14.1 |
| `Make sure this account's password is securely stored with condor_store_cred` | Password not in credd | PB 6.5 |
| `Failed to access output file ... Access Denied` | Job ran as slot user, not owner | PB 5.4, PB 7.2 |
| `Error from starter on ... authentication` | Starter cannot auth to schedd | PB 4.3 |
| `Job has gone over memory limit` | Not auth-related — check job requirements | N/A |
| `STARTER_ALLOW_RUNAS_OWNER is false` | Config not applied on execute node | PB 5.4 |

### 17.3 — Release and retry held jobs after a fix

After applying a config fix, test whether the fix resolves holds without
resubmitting:

```cmd
:: Release one specific job to test
condor_release <JOBID>

:: Release all held jobs for a specific user
condor_release -constraint "Owner == \"testuser\""

:: If jobs re-hold immediately with the same reason, the fix did not take effect
:: Check condor_reconfig was run on the execute nodes:
condor_reconfig -all
```

---

## Playbook 18 — StarterLog Deep Dive

The StarterLog on the execute node is the most detailed record of what happens
when a job actually attempts to run. For `run_as_owner` failures, it is the
definitive source of truth.

### 18.1 — Locate and tail the StarterLog for the most recent job

```powershell
# [WIN-PS on execute node] — find the most recent StarterLog
$logdir = & condor_config_val LOG
Get-ChildItem "$logdir\Starter*" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 Name, LastWriteTime, Length

# Tail the most recent one
$latest = Get-ChildItem "$logdir\Starter*" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
Get-Content $latest.FullName -Tail 80
```

### 18.2 — Key patterns to search for in StarterLog

```powershell
# [WIN-PS on execute node]
$logdir = & condor_config_val LOG
$latest = Get-ChildItem "$logdir\Starter*" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

$patterns = @(
    "run_as_owner|RunAsOwner|runas",
    "LogonUser|user_priv|init_user",
    "credential|credd|LocalCredd",
    "PERMISSION|DENIED|ERROR",
    "want user|current is",
    "Found credential|Could not locate",
    "slot\d+.*user",
    "EXITING WITH STATUS"
)

foreach ($p in $patterns) {
    $hits = Select-String -Path $latest.FullName -Pattern $p -CaseSensitive:$false
    if ($hits) {
        Write-Host "`n--- Pattern: $p ---" -ForegroundColor Cyan
        $hits | ForEach-Object { Write-Host $_.Line }
    }
}
```

### 18.3 — Annotated StarterLog sequence for a successful run_as_owner job

A healthy `run_as_owner` job produces this sequence in StarterLog:

```
Starter pid <N> starting up
Job ClassAd: RunAsOwner = true
Attempting to fetch credential for user testuser@EXAMPLE.COM
Successfully contacted credd at <CREDD_HOST>
Found credential for user testuser@EXAMPLE.COM
LogonUser completed for testuser@EXAMPLE.COM
Running job as testuser@EXAMPLE.COM
```

If any line in this sequence is absent or replaced by an error, that step failed.

### 18.4 — Compare StarterLog identity with expected identity

```powershell
# [WIN-PS on execute node]
$logdir = & condor_config_val LOG
$latest = Get-ChildItem "$logdir\Starter*" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

# Extract the user identity the starter tried to use
Select-String -Path $latest.FullName -Pattern "want user|Running job as|init_user_ids" |
    ForEach-Object { Write-Host $_.Line }
```

The identity shown here must exactly match what `condor_store_cred query` shows
as the stored credential. Any format difference (e.g., `testuser@EXAMPLE.COM` vs
`EXAMPLE\testuser`) means the lookup will fail.

---

## Playbook 19 — Remediation Scripts

These scripts apply common fixes. Run the relevant diagnostic playbook first to
confirm the diagnosis before applying any remediation.

### 19.1 — Re-push pool password to all Windows nodes from CM

```powershell
# [WIN-PS on CM as Administrator]
# Pushes the pool password to a list of Windows nodes
# Requires ALLOW_CONFIG access from the CM to each target

$poolNodes = @("<EXEC_WIN_01>", "<EXEC_WIN_02>", "<SUBMIT_01>", "<SUBMIT_02>")
$password = Read-Host "Enter pool password" -AsSecureString
$plainPw = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
               [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))

foreach ($node in $poolNodes) {
    Write-Host "Storing pool password on $node..."
    $result = & condor_store_cred add -c -n $node -p $plainPw 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  SUCCESS" -ForegroundColor Green
    } else {
        Write-Host "  FAILED: $result" -ForegroundColor Red
    }
}
```

### 19.2 — Re-push POOL signing key to all Windows nodes

```powershell
# [WIN-PS on CM as Administrator]
# Copies the POOL signing key to each Windows node via file share or PSSession

$cmKeyDir = & condor_config_val SEC_PASSWORD_DIRECTORY
if (-not $cmKeyDir) { $cmKeyDir = "C:\ProgramData\HTCondor\passwords.d" }
$keyFile = "$cmKeyDir\POOL"
$keyBytes = [IO.File]::ReadAllBytes($keyFile)

$targetNodes = @("<EXEC_WIN_01>", "<EXEC_WIN_02>", "<SUBMIT_01>")
$targetKeyPath = "C:\ProgramData\HTCondor\passwords.d\POOL"

foreach ($node in $targetNodes) {
    try {
        $session = New-PSSession -ComputerName $node -ErrorAction Stop
        Invoke-Command -Session $session -ScriptBlock {
            param($bytes, $path)
            $dir = Split-Path $path
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllBytes($path, $bytes)
            # Lock down permissions
            $acl = Get-Acl $path
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($id in @("SYSTEM","Administrators")) {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $id, "FullControl", "Allow")
                $acl.AddAccessRule($rule)
            }
            Set-Acl $path $acl
            Write-Host "Key written and permissions set"
        } -ArgumentList $keyBytes, $targetKeyPath
        Remove-PSSession $session
        Write-Host "SUCCESS: $node" -ForegroundColor Green
    } catch {
        Write-Host "FAILED: $node -- $_" -ForegroundColor Red
    }
}
```

### 19.3 — Force LocalCredd repopulation on all execute nodes

```powershell
# [WIN-PS on CM as Administrator]
# Sends reconfig to all startd nodes, then polls for LocalCredd population

Write-Host "Sending condor_reconfig -all..."
& condor_reconfig -all

Write-Host "Waiting 90 seconds for ClassAds to update..."
Start-Sleep 90

Write-Host "`nLocalCredd status after reconfig:"
$result = & condor_status -af Machine LocalCredd 2>&1
$undef  = $result | Where-Object { $_ -match "^\s*$" -or $_ -match "undefined" }
$defined = $result | Where-Object { $_ -notmatch "^\s*$" -and $_ -notmatch "undefined" }

Write-Host "Populated ($($defined.Count) nodes):" -ForegroundColor Green
$defined | ForEach-Object { Write-Host "  $_" }

if ($undef.Count -gt 0) {
    Write-Host "Still UNDEF ($($undef.Count) nodes):" -ForegroundColor Red
    $undef | ForEach-Object { Write-Host "  $_" }
}
```

### 19.4 — Fix DAEMON_LIST start order on credd host

If LocalCredd is UNDEF because the credd starts after the startd, fix the
daemon ordering. Run on the credd host if it also runs a startd:

```powershell
# [WIN-PS on credd host as Administrator]
$configDir = "C:\ProgramData\HTCondor\config.d"
$fixFile = "$configDir\10-daemon-order.conf"

$content = @"
## Ensure credd starts before startd so LocalCredd is populated correctly
## See: https://lists.cs.wisc.edu/archive/htcondor-users/2008-December/msg00114.shtml
DAEMON_LIST = MASTER, CREDD, STARTD
"@

Set-Content -Path $fixFile -Value $content -Encoding ASCII
Write-Host "Written: $fixFile"

# Restart condor service to apply
Write-Host "Restarting condor service..."
Restart-Service condor
Start-Sleep 30

# Verify credd started before startd by checking log timestamps
$logdir = & condor_config_val LOG
$creddStart = (Select-String -Path "$logdir\CreddLog" -Pattern "STARTING UP" |
    Select-Object -Last 1).Line
$startdStart = (Select-String -Path "$logdir\StartLog" -Pattern "STARTING UP" |
    Select-Object -Last 1).Line
Write-Host "CreddLog STARTING UP: $creddStart"
Write-Host "StartLog STARTING UP: $startdStart"
```

### 19.5 — Rebuild user credential store for a specific user

Use when a user's credential is stale (e.g., after a password change):

```cmd
:: [WIN-CMD — run as the affected user on their submit workstation]
:: First remove the old credential
condor_store_cred delete -debug

:: Verify it is gone
condor_store_cred query

:: Re-add with new password
condor_store_cred add -debug
:: Enter new Windows domain password at the prompt

:: Verify stored
condor_store_cred query
```

After this, resubmit any held jobs for that user:

```cmd
condor_release -constraint "Owner == \"<USERNAME>\" && HoldReasonCode == 6"
```

---

## Playbook 20 — Continuous Monitoring

These are lightweight checks suitable for running on a schedule (Windows Task
Scheduler or cron) to catch regressions before users notice.

### 20.1 — Scheduled pool health check script

Save as `C:\Scripts\condor_monitor.ps1` on the CM. Schedule via Task Scheduler
to run every 15 minutes as `SYSTEM`.

```powershell
# condor_monitor.ps1
# Lightweight health monitor. Writes status to a log file and sends
# an email alert if critical checks fail.

$logFile  = "C:\Logs\condor_monitor.log"
$alertTo  = "condor-admin@example.com"
$smtpHost = "smtp.example.com"
$failures = @()

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $msg" | Tee-Object -FilePath $logFile -Append
}

function Check($name, $test) {
    if (-not $test) {
        Log "[FAIL] $name"
        $script:failures += $name
    } else {
        Log "[OK]   $name"
    }
}

Log "=== Monitor run start ==="

# 1. Collector has entries
$collectorOk = (& condor_status -any 2>&1) -match "MyType"
Check "Collector responding" $collectorOk

# 2. At least one Windows execute node ready for run_as_owner
$runAsNodes = & condor_status `
    -constraint "(OpSys == `"WINDOWS`") && HasWindowsRunAsOwner && isString(LocalCredd)" `
    -af Machine 2>&1
Check "run_as_owner capable nodes exist" ($runAsNodes -and $runAsNodes.Count -gt 0)

# 3. Credd is advertised
$creddOk = (& condor_status -any 2>&1) -match "credd"
Check "CREDD advertised in pool" $creddOk

# 4. Negotiator ran recently (within last 10 minutes)
$lastCycle = & condor_status -negotiator -af LastNegotiationCycleTime 2>&1
if ($lastCycle -match "^\d+$") {
    $cycleAge = (Get-Date -UFormat %s) - [int]$lastCycle
    Check "Negotiator ran within 10 min" ($cycleAge -lt 600)
} else {
    Check "Negotiator cycle time available" $false
}

# 5. No execute nodes have UNDEF LocalCredd
$undefCount = (& condor_status `
    -constraint "(OpSys == `"WINDOWS`") && isUndefined(LocalCredd)" `
    -af Machine 2>&1 |
    Where-Object { $_ -match '\S' }).Count
Check "No Windows execute nodes with UNDEF LocalCredd" ($undefCount -eq 0)

# 6. Held job count is reasonable
$heldCount = (& condor_q -hold -af ClusterId 2>&1 |
    Where-Object { $_ -match '^\d' }).Count
if ($heldCount -gt 20) {
    Log "[WARN] High held job count: $heldCount"
    $failures += "High held job count: $heldCount"
}

# Alert if failures
if ($failures.Count -gt 0) {
    $body = "HTCondor monitor detected failures on $(hostname) at $(Get-Date):`n`n"
    $body += ($failures | ForEach-Object { "  - $_" }) -join "`n"
    try {
        Send-MailMessage -To $alertTo -From "condor-monitor@example.com" `
            -Subject "HTCondor Alert: $($failures.Count) check(s) failed on $(hostname)" `
            -Body $body -SmtpServer $smtpHost
        Log "Alert email sent to $alertTo"
    } catch {
        Log "Could not send alert email: $_"
    }
}

Log "=== Monitor run complete. Failures: $($failures.Count) ==="
```

### 20.2 — Canary job for run_as_owner end-to-end smoke test

Deploy a canary job that runs every 30 minutes and validates the full
`run_as_owner` pipeline. Save as `C:\Scripts\condor_canary.ps1`:

```powershell
# condor_canary.ps1
# Submits a short run_as_owner job and verifies it completes within timeout.
# Must be run as the canary user (a real domain user with stored credentials).

$canaryDir  = "C:\Canary"
$timeout    = 300  # seconds
$logFile    = "C:\Logs\condor_canary.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $msg" | Tee-Object -FilePath $logFile -Append
}

# Clean up previous canary artifacts
Remove-Item "$canaryDir\canary_*" -Force -ErrorAction SilentlyContinue

# Write submit file
$submitFile = "$canaryDir\canary.sub"
$resultFile = "$canaryDir\canary_result.txt"
@"
executable   = C:\Windows\System32\cmd.exe
arguments    = /C whoami > $resultFile
output       = $canaryDir\canary.out
error        = $canaryDir\canary.err
log          = $canaryDir\canary.log
requirements = (OpSys == "WINDOWS")
run_as_owner = True
queue
"@ | Set-Content $submitFile -Encoding ASCII

Log "Submitting canary job..."
$submitOut = & condor_submit $submitFile 2>&1
$jobId = ($submitOut | Select-String "submitted to cluster (\d+)" |
    ForEach-Object { $_.Matches[0].Groups[1].Value })

if (-not $jobId) {
    Log "FAIL: Could not submit canary job. Output: $submitOut"
    exit 1
}
Log "Submitted as cluster $jobId"

# Poll for completion
$start = Get-Date
$completed = $false
while ((Get-Date) -lt $start.AddSeconds($timeout)) {
    Start-Sleep 10
    $status = & condor_q $jobId -af JobStatus 2>&1
    if ($status -notmatch "^\d") {
        # Job not in queue anymore
        $completed = $true
        break
    }
    $statusCode = [int]($status.Trim())
    if ($statusCode -eq 4) { $completed = $true; break }     # Completed
    if ($statusCode -eq 5) {                                  # Held
        $reason = & condor_q $jobId -af HoldReason 2>&1
        Log "FAIL: Job went on hold. Reason: $reason"
        & condor_rm $jobId 2>&1 | Out-Null
        exit 1
    }
}

if (-not $completed) {
    Log "FAIL: Canary job timed out after $timeout seconds"
    & condor_rm $jobId 2>&1 | Out-Null
    exit 1
}

# Verify result
if (-not (Test-Path $resultFile)) {
    Log "FAIL: Result file not created at $resultFile"
    exit 1
}

$identity = Get-Content $resultFile -Raw
$expectedUser = $env:USERNAME.ToLower()
if ($identity -match $expectedUser) {
    Log "PASS: Canary job ran as $($identity.Trim())"
    exit 0
} else {
    Log "FAIL: Expected user containing '$expectedUser', got '$($identity.Trim())'"
    exit 1
}
```

Register as a scheduled task:

```powershell
# [WIN-PS as Administrator]
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
               -Argument "-NonInteractive -File C:\Scripts\condor_canary.ps1"
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 30) `
               -Once -At (Get-Date)
$principal = New-ScheduledTaskPrincipal -UserId "EXAMPLE\canaryuser" `
                 -LogonType Password -RunLevel Highest
Register-ScheduledTask -TaskName "HTCondor Canary" `
    -Action $action -Trigger $trigger -Principal $principal
```

### 20.3 — cron-based canary on RHEL (Linux execute node health)

```bash
# /etc/cron.d/condor-canary  — runs every 30 minutes
*/30 * * * * condor /usr/local/bin/condor_linux_canary.sh >> /var/log/condor_canary.log 2>&1
```

Script `/usr/local/bin/condor_linux_canary.sh`:

```bash
#!/bin/bash
# Verifies a Linux execute node can accept and complete a job

CANARY_DIR="/tmp/condor_canary_$$"
TIMEOUT=300
mkdir -p "$CANARY_DIR"
trap "rm -rf $CANARY_DIR" EXIT

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

cat > "$CANARY_DIR/canary.sub" <<EOF
executable   = /bin/hostname
output       = $CANARY_DIR/canary.out
error        = $CANARY_DIR/canary.err
log          = $CANARY_DIR/canary.log
requirements = (OpSys == "LINUX")
queue
EOF

log "Submitting Linux canary job..."
output=$(condor_submit "$CANARY_DIR/canary.sub" 2>&1)
jobid=$(echo "$output" | grep -oP "submitted to cluster \K\d+")

if [ -z "$jobid" ]; then
    log "FAIL: Could not submit job. Output: $output"
    exit 1
fi
log "Submitted as cluster $jobid"

start=$(date +%s)
completed=false
while [ $(( $(date +%s) - start )) -lt $TIMEOUT ]; do
    sleep 10
    status=$(condor_q "$jobid" -af JobStatus 2>/dev/null)
    if [ -z "$status" ]; then
        completed=true
        break
    fi
    if [ "$status" -eq 4 ]; then completed=true; break; fi
    if [ "$status" -eq 5 ]; then
        reason=$(condor_q "$jobid" -af HoldReason 2>/dev/null)
        log "FAIL: Job held: $reason"
        condor_rm "$jobid" 2>/dev/null
        exit 1
    fi
done

if $completed && [ -s "$CANARY_DIR/canary.out" ]; then
    log "PASS: $(cat $CANARY_DIR/canary.out | tr -d '\n')"
    exit 0
else
    log "FAIL: Job did not complete within ${TIMEOUT}s"
    condor_rm "$jobid" 2>/dev/null
    exit 1
fi
```

---

## Playbook 21 — Full Automated Test Runner

This script runs all diagnostic playbooks in sequence and produces a structured
report. Run from the CM as Administrator. Replace placeholder values at the top.

Save as `C:\Scripts\condor_full_diagnostic.ps1`:

```powershell
# condor_full_diagnostic.ps1
# Comprehensive automated diagnostic runner for the HTCondor pool.
# Produces a timestamped HTML report.

# ============================================================
# CONFIGURE THESE VALUES FOR YOUR ENVIRONMENT
# ============================================================
$CM_HOST        = "<CM_HOST>"
$CREDD_HOST     = "<CREDD_HOST>"
$EXEC_WIN_NODES = @("<EXEC_WIN_01>", "<EXEC_WIN_02>")
$EXEC_LIN_NODES = @("<EXEC_RHEL_01>", "<EXEC_RHEL_02>")
$SUBMIT_NODES   = @("<SUBMIT_01>")
$UID_DOMAIN     = "<EXAMPLE.COM>"
$TEST_USER      = "<testuser>"
$REPORT_DIR     = "C:\Logs\condor_diagnostics"
# ============================================================

$timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$reportFile  = "$REPORT_DIR\report_$timestamp.html"
$results     = [System.Collections.Generic.List[hashtable]]::new()
New-Item -ItemType Directory -Force -Path $REPORT_DIR | Out-Null

function Run-Check {
    param(
        [string]$Category,
        [string]$Name,
        [scriptblock]$Test,
        [string]$Remediation = ""
    )
    Write-Host "  Checking: $Name..." -NoNewline
    try {
        $output = & $Test 2>&1
        $passed = $LASTEXITCODE -eq 0 -or $output -notmatch "^(FAIL|ERROR|MISSING)"
        # Allow test block to set $script:testPassed
        if ($null -ne $script:testPassed) {
            $passed = $script:testPassed
            $script:testPassed = $null
        }
        $status = if ($passed) { "PASS" } else { "FAIL" }
    } catch {
        $output = $_.Exception.Message
        $status = "ERROR"
        $passed = $false
    }
    $color = switch ($status) { "PASS" {"Green"} "FAIL" {"Red"} default {"Yellow"} }
    Write-Host " $status" -ForegroundColor $color
    $results.Add(@{
        Category    = $Category
        Name        = $Name
        Status      = $status
        Output      = ($output -join "`n")
        Remediation = $Remediation
    })
}

Write-Host "`n=== HTCondor Full Diagnostic ===" -ForegroundColor Cyan
Write-Host "Started: $(Get-Date)"
Write-Host "CM: $CM_HOST  |  Credd: $CREDD_HOST`n"

# ---- Daemon Health ----
Write-Host "[ Daemon Health ]" -ForegroundColor Yellow
Run-Check "Daemon" "HTCondor version readable" {
    condor_version
} "Reinstall HTCondor or check PATH"

Run-Check "Daemon" "Collector responding" {
    $script:testPassed = (condor_status -any 2>&1) -match "MyType"
} "Check condor_collector is in DAEMON_LIST and running"

Run-Check "Daemon" "CREDD advertised in collector" {
    $script:testPassed = (condor_status -any 2>&1) -match "credd"
} "Add CREDD to DAEMON_LIST on credd host; run condor_reconfig"

Run-Check "Daemon" "Negotiator responding" {
    $script:testPassed = (condor_status -negotiator 2>&1) -match "\S"
} "Check condor_negotiator is in DAEMON_LIST on CM"

# ---- UID_DOMAIN ----
Write-Host "`n[ UID_DOMAIN Consistency ]" -ForegroundColor Yellow
Run-Check "Identity" "UID_DOMAIN consistent across pool" {
    $domains = condor_status -af Machine UID_DOMAIN 2>&1 |
        Where-Object { $_ -match '\S' } | Sort-Object -Unique
    $script:testPassed = $domains.Count -eq 1 -and $domains[0] -eq $UID_DOMAIN
    "Found: $($domains -join ', ')  Expected: $UID_DOMAIN"
} "Set UID_DOMAIN = $UID_DOMAIN in 00-common.conf on all nodes; condor_reconfig -all"

# ---- Pool Key ----
Write-Host "`n[ Pool Signing Key ]" -ForegroundColor Yellow
Run-Check "Auth" "POOL signing key exists locally" {
    $dir = condor_config_val SEC_PASSWORD_DIRECTORY
    if (-not $dir) { $dir = "C:\ProgramData\HTCondor\passwords.d" }
    $script:testPassed = Test-Path "$dir\POOL"
    "Checked: $dir\POOL"
} "Copy POOL key from CM to this node (see PB 19.2)"

Run-Check "Auth" "Pool password stored for condor_pool identity" {
    $out = condor_store_cred query -c 2>&1
    $script:testPassed = $out -match "Credential is stored"
    $out
} "Run: condor_store_cred add -c (see PB 6.3)"

# ---- condor_ping ----
Write-Host "`n[ condor_ping Authorization ]" -ForegroundColor Yellow
foreach ($node in ($EXEC_WIN_NODES + @($CREDD_HOST))) {
    Run-Check "Auth" "DAEMON ping to $node" {
        $out = condor_ping -verbose -name $node -type STARTD DAEMON 2>&1
        $script:testPassed = $out -match "ALLOW"
        $out
    } "Check ALLOW_DAEMON on $node includes this node's service account identity (see PB 4, PB 5)"
}

# ---- run_as_owner readiness ----
Write-Host "`n[ run_as_owner Readiness ]" -ForegroundColor Yellow
Run-Check "RunAsOwner" "STARTER_ALLOW_RUNAS_OWNER = True (local)" {
    $val = condor_config_val STARTER_ALLOW_RUNAS_OWNER
    $script:testPassed = $val -eq "True"
    "Value: $val"
} "Set STARTER_ALLOW_RUNAS_OWNER = True in config; condor_reconfig"

Run-Check "RunAsOwner" "Windows execute nodes with HasWindowsRunAsOwner" {
    $nodes = condor_status `
        -constraint "(OpSys == `"WINDOWS`") && HasWindowsRunAsOwner" `
        -af Machine 2>&1 | Where-Object { $_ -match '\S' }
    $script:testPassed = $nodes.Count -gt 0
    "Ready nodes: $($nodes.Count)"
} "Check STARTER_ALLOW_RUNAS_OWNER on each execute node; condor_reconfig -all"

Run-Check "RunAsOwner" "No Windows execute nodes have UNDEF LocalCredd" {
    $undef = condor_status `
        -constraint "(OpSys == `"WINDOWS`") && isUndefined(LocalCredd)" `
        -af Machine 2>&1 | Where-Object { $_ -match '\S' }
    $script:testPassed = $undef.Count -eq 0
    "UNDEF count: $($undef.Count)"
} "Run condor_reconfig -all; check PB 6, PB 7"

Run-Check "RunAsOwner" "User credential stored in credd" {
    $out = condor_store_cred query 2>&1
    $script:testPassed = $out -match "Credential is stored"
    $out
} "Run: condor_store_cred add (as the test user; see PB 6.5)"

# ---- Generate HTML report ----
$passCount = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$failCount = ($results | Where-Object { $_.Status -ne "PASS" }).Count

$rows = $results | ForEach-Object {
    $color = switch ($_.Status) {
        "PASS"  { "#d4edda" }
        "FAIL"  { "#f8d7da" }
        default { "#fff3cd" }
    }
    $rem = if ($_.Remediation) { "<br><small><b>Fix:</b> $([System.Web.HttpUtility]::HtmlEncode($_.Remediation))</small>" } else { "" }
    "<tr style='background:$color'><td>$($_.Category)</td><td>$($_.Name)</td><td><b>$($_.Status)</b></td><td>$rem</td></tr>"
}

$html = @"
<!DOCTYPE html><html><head><meta charset='utf-8'>
<title>HTCondor Diagnostic Report - $timestamp</title>
<style>
  body { font-family: Consolas, monospace; margin: 20px; }
  h1 { color: #333; }
  .summary { font-size: 1.2em; margin: 10px 0; }
  .pass { color: green; } .fail { color: red; }
  table { border-collapse: collapse; width: 100%; }
  th { background: #333; color: white; padding: 8px; text-align: left; }
  td { padding: 6px 8px; border-bottom: 1px solid #ccc; vertical-align: top; }
</style></head><body>
<h1>HTCondor Diagnostic Report</h1>
<p>Generated: $(Get-Date) | CM: $CM_HOST | Credd: $CREDD_HOST</p>
<p class='summary'>
  <span class='pass'>PASS: $passCount</span> &nbsp;|&nbsp;
  <span class='fail'>FAIL: $failCount</span>
</p>
<table>
  <tr><th>Category</th><th>Check</th><th>Result</th><th>Notes / Remediation</th></tr>
  $($rows -join "`n")
</table>
</body></html>
"@

$html | Set-Content $reportFile -Encoding UTF8
Write-Host "`nReport written to: $reportFile" -ForegroundColor Cyan
Write-Host "PASS: $passCount  FAIL: $failCount"
if ($failCount -gt 0) { exit 1 } else { exit 0 }
```

Run it:
```powershell
powershell -ExecutionPolicy Bypass -File C:\Scripts\condor_full_diagnostic.ps1
```

---

## Updated Quick Reference — Full Symptom Lookup

| Symptom | First playbook to check |
|---|---|
| `LocalCredd = UNDEF` on all Windows exec nodes | PB 6 (credd isolation), PB 3.3 (pool password) |
| `LocalCredd = UNDEF` on some nodes only | PB 2 (DNS), PB 4.6 (DAEMON ping to credd) |
| `condor_ping DAEMON` fails, CONFIG passes | PB 5.2 (CREDD.ALLOW_DAEMON), PB 4.2 (identity) |
| `condor_store_cred query` fails with ALLOW_WRITE error | PB 5.1 (ALLOW_CONFIG), PB 2.4 (port 9618) |
| Job holds: `Could not locate valid credential` | PB 8 (UID_DOMAIN / identity format), PB 17.2 |
| Job holds: `Failed to initialize user_priv as (null)\username` | PB 8.3, PB 14.1 (AD membership) |
| Job holds: `Access Denied` on output file | PB 5.4 (STARTER_ALLOW_RUNAS_OWNER), PB 7.2 |
| Job runs as slot user instead of owner | PB 5.4, PB 7.2 (HasWindowsRunAsOwner) |
| Job completes but cannot reach UNC share | PB 14.3 (LogonUser test), PB 14.4 (Kerberos) |
| RHEL execute nodes not appearing in pool | PB 3.2 (POOL key), PB 2.1 (DNS) |
| `condor_status` shows no output | PB 2.4 (port 9618), PB 1.4 (collector) |
| Jobs idle with 0 machines matched | PB 9 (ClassAd requirements), PB 16.6 (analyze) |
| Auth errors only on some node types | PB 13.3 (Defender), PB 13.4 (LSA privileges) |
| `LogonUser FAILED` Win32 error 1326 | PB 14.2 (user in AD), PB 14.3 (LogonUser test) |
| `LogonUser FAILED` Win32 error 1909 | Account locked out — reset in AD |
| High held job count, mixed reasons | PB 17.1 (hold reasons), PB 11.1 (log scan) |
| Canary job passes but user jobs fail | PB 8 (identity mismatch), PB 14.2 (user attributes) |
| Intermittent failures, not consistent | PB 20.2 (canary), PB 2.1 (DNS flapping) |
| Pool healthy but one execute node problematic | PB 1.3 (crash check), PB 18.3 (StarterLog) |
| `IDTOKEN` errors in logs | PB 15.2 (decode token), PB 15.3 (key consistency) |
