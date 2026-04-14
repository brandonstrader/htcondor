[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PoolHost,
    [Parameter(Mandatory=$true)][string]$CreddHost,
    [Parameter(Mandatory=$true)][ValidateSet('cm','submit','execute')][string]$Role,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [switch]$RunSmoke,
    [switch]$RunAsOwner,
    [string]$SharePath,
    [string]$FetchLogsFrom,
    [int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Run-Phase {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [Parameter(Mandatory=$true)][hashtable]$Params
    )
    Write-Host "==> Running $([System.IO.Path]::GetFileName($ScriptPath))"
    & $ScriptPath @Params
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

Run-Phase -ScriptPath (Join-Path $root 'tests/01-Get-Baseline.ps1') -Params @{ OutFile = (Join-Path $OutDir '01-baseline.json'); Role = $Role }
Run-Phase -ScriptPath (Join-Path $root 'tests/02-Test-Config.ps1') -Params @{ OutFile = (Join-Path $OutDir '02-config.json') }
Run-Phase -ScriptPath (Join-Path $root 'tests/03-Test-Security.ps1') -Params @{ PoolHost = $PoolHost; CreddHost = $CreddHost; OutFile = (Join-Path $OutDir '03-security.json') }
Run-Phase -ScriptPath (Join-Path $root 'tests/04-Test-Credd.ps1') -Params @{ PoolHost = $PoolHost; OutFile = (Join-Path $OutDir '04-credd.json') }
Run-Phase -ScriptPath (Join-Path $root 'tests/05-Test-Queue.ps1') -Params @{ OutFile = (Join-Path $OutDir '05-queue.json') }

if ($RunSmoke) {
    Run-Phase -ScriptPath (Join-Path $root 'tests/06-Test-SubmitSmoke.ps1') -Params @{ OutDir = $OutDir; TargetOS = 'WINDOWS'; OutFile = (Join-Path $OutDir '06-smoke-windows.json'); TimeoutSeconds = $TimeoutSeconds }
}

if ($RunAsOwner) {
    if ([string]::IsNullOrWhiteSpace($SharePath)) {
        throw 'SharePath is required when -RunAsOwner is specified.'
    }
    Run-Phase -ScriptPath (Join-Path $root 'tests/07-Test-RunAsOwner.ps1') -Params @{ OutDir = $OutDir; SharePath = $SharePath; OutFile = (Join-Path $OutDir '07-runasowner.json'); TimeoutSeconds = $TimeoutSeconds }
}

if ($FetchLogsFrom) {
    Run-Phase -ScriptPath (Join-Path $root 'tests/08-Collect-Logs.ps1') -Params @{ Machine = $FetchLogsFrom; OutDir = (Join-Path $OutDir 'logs'); OutFile = (Join-Path $OutDir '08-logs.json') }
}

Write-Host "Results written to $OutDir"
