# HTCondor Health Scripts (Windows-focused)

This bundle runs layered HTCondor health checks for a mixed Windows/Linux pool, with special emphasis on Windows `run_as_owner`.

## Scripts

- `Run-CondorHealth.ps1` - wrapper/orchestrator
- `lib/CondorHealth.Common.ps1` - common helpers
- `tests/01-Get-Baseline.ps1` - daemon/version/config inventory
- `tests/02-Test-Config.ps1` - effective config audit for key macros
- `tests/03-Test-Security.ps1` - `condor_ping` matrix for local and CM targets
- `tests/04-Test-Credd.ps1` - `condor_store_cred` + `LocalCredd` checks
- `tests/05-Test-Queue.ps1` - queue visibility, schedd write, analyze helpers
- `tests/06-Test-SubmitSmoke.ps1` - optional submit/monitor/collect smoke jobs
- `tests/07-Test-RunAsOwner.ps1` - optional Windows `run_as_owner` validation
- `tests/08-Collect-Logs.ps1` - targeted `condor_fetchlog` collection

## Example usage

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd .\htcondor-health-scripts

# Safe read-only checks
.\Run-CondorHealth.ps1 -PoolHost cm01.foo.bar.com -CreddHost cm01.foo.bar.com -Role submit -OutDir .\output\run1

# Add smoke submit checks
.\Run-CondorHealth.ps1 -PoolHost cm01.foo.bar.com -CreddHost cm01.foo.bar.com -Role submit -OutDir .\output\run2 -RunSmoke

# Add Windows run_as_owner share test
.\Run-CondorHealth.ps1 -PoolHost cm01.foo.bar.com -CreddHost cm01.foo.bar.com -Role submit -OutDir .\output\run3 -RunSmoke -RunAsOwner -SharePath \\fileserver\share
```

## Notes

- Run as the real submitting user for submit-side tests.
- If you want to test the Windows pool-password path (`DAEMON` + `PASSWORD`) from a shell, run the shell as `LOCAL_SYSTEM`; a normal or elevated admin shell is often not sufficient.
- The submit tests intentionally use explicit `requirements` to avoid OS-default matching surprises.
