<#
.SYNOPSIS
    Post-rollout validation of the MSSQL ops infrastructure against any environment.

.DESCRIPTION
    Environment-agnostic verification that a full rollout (Ebene A + Ebene B) landed and
    is operable on the selected target. Reuses lib/targets.ps1 as the single auth SSoT, so
    the SAME script validates TEST (Windows/Kerberos), E2E (SQL auth) and later PROD without
    duplicating connection logic. Read-only by default; -FullReset opts into a throwaway
    reset roundtrip.

    Companion to tests/docker/validate.ps1 (which stays as the quick SQL-auth container
    check). This script is the rollout gate referenced by
    docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/test1-rollout-plan.md (§f).

    Checks (all read-only unless -FullReset):
      1. tests/global/validate_structure.sql  — objects / columns / signatures / roles.
      2. tests/global/validate_rollout.sql     — journals, reset-step registry, agent job,
                                                  master signing/impersonation principals.
      3. Roundtrip: reset.spPub_ListMandants + reset.spPub_GetResetStatus run and return.
      4. (optional -RightsTestLogin) low-priv negative test: direct SELECT cShopLicense denied.
      5. (optional -FullReset) create a throwaway mandant, poll to succeeded/failed, then
         run the runbook's read-only outcome checks against the clone.

    Exit code is non-zero if any check fails.

.PARAMETER Environment
    TEST | PROD | E2E (from targets.config.json). Default TEST.

.PARAMETER FullReset
    Drive a real reset of -MandantKey and verify the clone. Registers + resets a throwaway
    mandant (see the reset-validation runbook). NOT read-only. On TEST this requires the
    JTL worker stopped and the SQL Agent running (host actions).

.PARAMETER MandantKey
    Throwaway mandant key for -FullReset (must match tm<number>). Default tm9.

.PARAMETER LoginName
    Developer login granted db_owner on the clone by -FullReset (must exist on the target).
    Default: the seed template login (skipped by spInternal_GrantAccess if absent).

.PARAMETER RightsTestLogin / .PARAMETER RightsTestPasswordEnv
    Optional low-privilege SQL login (+ env var holding its password) for the rights
    negative test. When omitted, that check is skipped with a note.

.PARAMETER ReuseExisting
    For -FullReset: if the mandant already exists, re-trigger its reset instead of failing.

.EXAMPLE
    pwsh db-migrations/tests/validate-rollout.ps1 -Environment TEST
.EXAMPLE
    pwsh db-migrations/tests/validate-rollout.ps1 -Environment TEST -FullReset -LoginName dbuser_dev_test1
#>
[CmdletBinding()]
param(
    [ValidateSet('TEST', 'PROD', 'E2E')]
    [string] $Environment = 'TEST',

    [switch] $FullReset,
    [string] $MandantKey = 'tm9',
    [string] $LoginName,
    [string] $RightsTestLogin,
    [string] $RightsTestPasswordEnv,
    [switch] $ReuseExisting
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$migrationsRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $migrationsRoot '..')).Path

. (Join-Path $migrationsRoot 'lib' 'targets.ps1')
$target = Get-RoboticoTarget -Environment $Environment -ConfigPath (Join-Path $migrationsRoot 'targets.config.json')

# Shared resolver (lib/targets.ps1): ODBC-build sqlcmd first (Kerberos -E needs mssql-tools18).
$sqlcmdPath = Get-RoboticoSqlcmd
$authArgs = Get-SqlcmdAuthArgs -Target $target

$structureSql = Join-Path $migrationsRoot 'tests/global/validate_structure.sql'
$rolloutSql   = Join-Path $migrationsRoot 'tests/global/validate_rollout.sql'
foreach ($f in @($structureSql, $rolloutSql)) { if (-not (Test-Path $f)) { throw "Missing $f" } }

$script:failures = @()
function Fail([string] $msg) { $script:failures += $msg; Write-Host "  FAIL: $msg" -ForegroundColor Red }
function Pass([string] $msg) { Write-Host "  PASS: $msg" -ForegroundColor Green }

# Run an -i file against RoboticoOps; -b makes sqlcmd exit non-zero on a RAISERROR sev>=11.
# The SQL-auth password (E2E) goes via SQLCMDPASSWORD, never `-P` on argv (Sec-I2).
function Invoke-SqlFile([string] $File, [string] $Label) {
    Write-Host "==> $Label" -ForegroundColor Cyan
    $a = $authArgs + @('-d', $target.GlobalDb, '-C', '-b', '-i', $File)
    $r = Invoke-RoboticoSqlcmd -SqlcmdPath $sqlcmdPath -Arguments $a -Password $target.SqlPassword
    $r.Raw | ForEach-Object { Write-Host "     $_" }
    if ($r.Exit -ne 0) { Fail "$Label reported failures (exit $($r.Exit))." } else { Pass $Label }
}

# Run a -Q query against a chosen DB; returns the raw output, throws on connect error.
function Invoke-Query([string] $Query, [string] $Db, [string[]] $ExtraArgs) {
    $a = $authArgs + @('-d', $Db, '-C', '-b', '-h', '-1', '-W', '-Q', $Query)
    if ($ExtraArgs) { $a += $ExtraArgs }
    $r = Invoke-RoboticoSqlcmd -SqlcmdPath $sqlcmdPath -Arguments $a -Password $target.SqlPassword
    return [pscustomobject]@{ Exit = $r.Exit; Out = $r.Out }
}

Write-Host ""
Write-Host "Rollout validation — $Environment / $($target.GlobalDb) @ $($target.Server)" -ForegroundColor White

# --- 1 + 2: static + live-instance structure ------------------------------------
Invoke-SqlFile $structureSql 'validate_structure.sql (objects / columns / signatures / roles)'
Invoke-SqlFile $rolloutSql   'validate_rollout.sql (journals / registry / agent job / master principals)'

# --- 3: consumer roundtrip ------------------------------------------------------
Write-Host "==> Consumer roundtrip (spPub_ListMandants + spPub_GetResetStatus)" -ForegroundColor Cyan
$rt = Invoke-Query 'SET NOCOUNT ON; EXEC reset.spPub_ListMandants;' $target.GlobalDb
if ($rt.Exit -ne 0) { Fail "reset.spPub_ListMandants failed: $($rt.Out)" } else { Pass "reset.spPub_ListMandants returned" }
$gs = Invoke-Query 'SET NOCOUNT ON; EXEC reset.spPub_GetResetStatus;' $target.GlobalDb
if ($gs.Exit -ne 0) { Fail "reset.spPub_GetResetStatus failed: $($gs.Out)" } else { Pass "reset.spPub_GetResetStatus returned" }

# --- 4: rights negative test (optional) -----------------------------------------
if ($RightsTestLogin) {
    Write-Host "==> Rights negative test as '$RightsTestLogin' (expect DENY on ops.tMandant.cShopLicense)" -ForegroundColor Cyan
    $pw = if ($RightsTestPasswordEnv) { [Environment]::GetEnvironmentVariable($RightsTestPasswordEnv) } else { $null }
    if ([string]::IsNullOrEmpty($pw)) {
        Fail "RightsTestLogin given but no password in env '$RightsTestPasswordEnv' — cannot run the negative test."
    }
    else {
        # Password via SQLCMDPASSWORD (Invoke-RoboticoSqlcmd), never `-P` on argv (Sec-I2).
        $a = @('-S', $target.Server, '-U', $RightsTestLogin, '-d', $target.GlobalDb, '-C', '-b', '-h', '-1', '-W',
               '-Q', 'SET NOCOUNT ON; SELECT TOP 1 cShopLicense FROM ops.tMandant;')
        $rt = Invoke-RoboticoSqlcmd -SqlcmdPath $sqlcmdPath -Arguments $a -Password $pw
        $out = $rt.Out
        if ($out -match 'permission was denied|SELECT permission') { Pass "column DENY enforced ($RightsTestLogin cannot read cShopLicense)" }
        else { Fail "expected a SELECT-permission-denied error, got: $out" }
    }
}
else {
    Write-Host "==> Rights negative test skipped (no -RightsTestLogin). The column-DENY path is proven in the container E2E (assertion 13)." -ForegroundColor DarkGray
}

# --- 5: full reset roundtrip (optional) -----------------------------------------
if ($FullReset) {
    Write-Host ""
    Write-Host "==> FULL RESET roundtrip for '$MandantKey' (NOT read-only)" -ForegroundColor Yellow
    if ($Environment -eq 'PROD') { throw "-FullReset is refused against PROD by this validation script." }

    # Register + kick via the mandant wrapper (admin). Reuse if it already exists and -ReuseExisting.
    $exists = Invoke-Query "SET NOCOUNT ON; SELECT COUNT(*) FROM ops.tMandant WHERE cMandantKey = N'$($MandantKey.Replace("'","''"))';" $target.GlobalDb
    $alreadyThere = ($exists.Out.Trim() -match '^\d+$') -and ([int]$exists.Out.Trim() -gt 0)

    if ($alreadyThere -and -not $ReuseExisting) {
        Fail "mandant '$MandantKey' already exists (pass -ReuseExisting to re-trigger, or pick another key)."
    }
    else {
        if ($alreadyThere) {
            Write-Host "   '$MandantKey' exists — re-triggering its reset." -ForegroundColor DarkGray
            $kick = Invoke-Query "SET NOCOUNT ON; EXEC reset.spPub_StartTestmandantReset @MandantKey = N'$MandantKey';" $target.GlobalDb
            if ($kick.Exit -ne 0) { Fail "spPub_StartTestmandantReset failed: $($kick.Out)" }
        }
        else {
            $mandantArgs = @('-Environment', $Environment, '-Create', '-MandantKey', $MandantKey, '-DisplayName', 'Rollout validation')
            if ($LoginName) { $mandantArgs += @('-LoginName', $LoginName) }
            & pwsh (Join-Path $migrationsRoot 'mandant.ps1') @mandantArgs
            if ($LASTEXITCODE -ne 0) { Fail "mandant.ps1 -Create failed (exit $LASTEXITCODE)." }
        }

        # Poll spPub_GetResetStatus until succeeded / failed (or timeout).
        $deadline = (Get-Date).AddMinutes(40)
        $status = 'unknown'
        do {
            Start-Sleep -Seconds 15
            $r = Invoke-Query "SET NOCOUNT ON; SELECT TOP 1 cStatus FROM ops.tResetRequest WHERE cMandantKey = N'$MandantKey' ORDER BY kResetRequest DESC;" $target.GlobalDb
            $status = $r.Out.Trim()
            Write-Host "   status: $status" -ForegroundColor DarkGray
        } while ($status -notin @('succeeded', 'failed') -and (Get-Date) -lt $deadline)

        if ($status -eq 'succeeded') {
            Pass "reset '$MandantKey' reached 'succeeded'"

            # Read-only outcome checks against the clone (runbook §4 subset).
            $cloneDb = (Invoke-Query "SET NOCOUNT ON; SELECT TOP 1 cTargetDb FROM ops.tMandant WHERE cMandantKey = N'$MandantKey';" $target.GlobalDb).Out.Trim()
            Write-Host "==> Clone outcome checks against '$cloneDb'" -ForegroundColor Cyan

            $ver = (Invoke-Query "SET NOCOUNT ON; SELECT cVersion FROM dbo.tVersion;" $cloneDb).Out.Trim()
            if ($ver) { Pass "clone version cVersion=$ver" } else { Fail "could not read dbo.tVersion.cVersion from clone" }

            $queues = Invoke-Query @"
SET NOCOUNT ON;
SELECT SUM(n) FROM (
  SELECT COUNT(*) n FROM dbo.tQueue
  UNION ALL SELECT COUNT(*) FROM dbo.tWorkflowQueue
  UNION ALL SELECT COUNT(*) FROM dbo.ebay_queue_out
) q;
"@ $cloneDb
            if ($queues.Out.Trim() -eq '0') { Pass "worker queues drained (tQueue/tWorkflowQueue/ebay_queue_out = 0)" }
            else { Fail "worker queues not empty in clone (sum=$($queues.Out.Trim()))" }

            $regd = (Invoke-Query "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.tMandant WHERE cDB = N'$cloneDb';" $target.Eazybusiness[0]).Out.Trim()
            if ($regd -eq '1') { Pass "mandant registered in source (dbo.tMandant has '$cloneDb')" }
            else { Fail "registration check: dbo.tMandant rows for '$cloneDb' = $regd (expected 1)" }

            Write-Host ""
            Write-Host "Clone '$cloneDb' left in place for inspection. Cleanup when done:" -ForegroundColor Yellow
            Write-Host "  ALTER DATABASE [$cloneDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$cloneDb];" -ForegroundColor Yellow
            Write-Host "  DELETE FROM dbo.tMandant WHERE cDB = '$cloneDb';   -- in $($target.Eazybusiness[0]), reviewed" -ForegroundColor Yellow
        }
        elseif ($status -eq 'failed') {
            $err = (Invoke-Query "SET NOCOUNT ON; SELECT TOP 1 cErrorMessage FROM ops.tResetRequest WHERE cMandantKey = N'$MandantKey' ORDER BY kResetRequest DESC;" $target.GlobalDb).Out.Trim()
            Fail "reset '$MandantKey' ended 'failed': $err"
        }
        else {
            Fail "reset '$MandantKey' did not finish within the poll window (last status: $status)."
        }
    }
}

# --- verdict --------------------------------------------------------------------
Write-Host ""
if ($script:failures.Count -gt 0) {
    Write-Host "Rollout validation FAILED ($($script:failures.Count) problem(s)):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Rollout validation OK." -ForegroundColor Green
