# =============================================================================
# DEPRECATED (plan 2026-07-10 - mssql-ops-infrastruktur, decision D12).
#
# This PowerShell reset is kept only as a working FALLBACK. The reset is now
# server-side, audited, and needs no personal admin rights on production:
#
#     EXEC RoboticoOps.reset.StartTestmandantReset @MandantKey = N'tm4';
#     EXEC RoboticoOps.reset.GetResetStatus        @MandantKey = N'tm4';  -- poll
#
# See: Projekte/Testsystem/README.md
#      docs/runbooks/testmandant-reset-validierung.md
#      docs/SQL/MSSQL-OPS-ARCHITECTURE.md
#      docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md §D12
#
# Do not delete this script until the new reset has run cleanly for real
# mandants (rollout Phase 7). The logic below is unchanged.
# =============================================================================

<#
.SYNOPSIS
    Sets up the JTL test environment by running a sequence of SQL scripts.

.DESCRIPTION
    This script orchestrates the refresh of the test database.
    The staging shop URL and license per mandant are read from the registry file
    'test-environment.config.json' (next to this script). This lets colleagues run
    production tests against a per-developer staging shop without any reconfiguration.

    It executes the following SQL scripts in order:
    1. copy_test_db.sql (Clones source DB to target DB)
    2. invalidate-credentials-for-testing.sql (Deactivates passwords/emails, disables
       eBay sync, and repoints the online shop to the staging URL/license from the config)
    3. clear-customer-fields.sql (Anonymizes customer data)
    4. grant-database-access.sql (Grants db_owner to the developer user)
    5. Berechtigungen/JTL-Rollen.sql (Applies the standard JTL_Reader/JTL_Writer
       roles to the test DB, so the normal JTL user group - which only has read
       access on production - is properly authorized on the test mandant too)

    The script stops immediately if any SQL script fails.

.PARAMETER EasyBusinessMandant
    The suffix for the target database (e.g., 'tm2', 'tm3').
    The full database name will be 'eazybusiness_' + EasyBusinessMandant.
    This parameter is mandatory.

.PARAMETER LoginName
    The SQL Server login name to grant access to the test database.
    Default is 'dbuser_dev_dana_for_development'.

.PARAMETER ServerInstance
    The SQL Server instance to connect to. Default is 'localhost'.

.EXAMPLE
    .\setup-test-environment.ps1 -EasyBusinessMandant tm3
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$EasyBusinessMandant,

    [Parameter(Mandatory = $false)]
    [string]$LoginName = 'dbuser_dev_dana_for_development',

    [Parameter(Mandatory = $false)] 
    [string]$ServerInstance = 'VM-SQL2'
)

$ErrorActionPreference = "Stop"
$ScriptDirectory = $PSScriptRoot

# Check if sqlcmd is available
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "ERROR: 'sqlcmd' is not found in your PATH." -ForegroundColor Red
    Write-Host "Please install 'Command Line Tools for SQL Server'." -ForegroundColor Red
    Write-Host "You can install it via winget: winget install Microsoft.SQLServer.CommandLineTools" -ForegroundColor Red
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    exit 1
}

# Construct full database name
$TargetDatabase = "eazybusiness_" + $EasyBusinessMandant

# ------------------------------------------------------------------
# Load the staging-shop registry (config file next to this script) and
# resolve the entry for the current mandant. If the mandant is not listed,
# abort - we must never run with an empty/wrong shop URL.
# ------------------------------------------------------------------
$ConfigPath = Join-Path $ScriptDirectory "test-environment.config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath"
    exit 1
}

try {
    $Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
}
catch {
    Write-Error "Could not parse config file '$ConfigPath': $($_.Exception.Message)"
    exit 1
}

$EnvConfig = $Config.environments.$EasyBusinessMandant
if (-not $EnvConfig) {
    Write-Error "No configuration found for mandant '$EasyBusinessMandant' in $ConfigPath. Add an entry under 'environments' (Developer, ShopUrl, ShopLicense)."
    exit 1
}

$Developer   = $EnvConfig.Developer
$ShopUrl     = $EnvConfig.ShopUrl
$ShopLicense = $EnvConfig.ShopLicense

if ([string]::IsNullOrWhiteSpace($ShopUrl) -or [string]::IsNullOrWhiteSpace($ShopLicense)) {
    Write-Error "ShopUrl and/or ShopLicense missing for mandant '$EasyBusinessMandant' in $ConfigPath."
    exit 1
}

# Anzeigename fuer die JTL-Mandanten-Registry (dbo.tMandant), damit der
# Mandant in der WaWi-Mandantenauswahl erscheint. Konvention:
# "Testmandant<N> (<Developer>)"  -  z.B. tm4/lukas -> "Testmandant4 (Lukas)".
$MandantNumber = ($EasyBusinessMandant -replace '\D', '')
$MandantDev    = if ([string]::IsNullOrWhiteSpace($Developer)) { $EasyBusinessMandant } else { (Get-Culture).TextInfo.ToTitleCase($Developer.ToLower()) }
$MandantName   = "Testmandant$MandantNumber ($MandantDev)"

# Pass ShopUrl/ShopLicense to sqlcmd via ENVIRONMENT VARIABLES (not -v).
# sqlcmd resolves $(VarName) from OS environment variables as well, and unlike
# the -v command-line switch its value parser does NOT choke on the ':' in the
# URL (a known sqlcmd quirk: "-v var=http://..." fails with "'-' or '/' has no
# associated argument"). Env vars carry ':' and '/' safely.
$env:ShopUrl     = $ShopUrl
$env:ShopLicense = $ShopLicense

# Define the sequence of SQL scripts
$SqlScripts = @(
    # "force-error.sql", # Uncomment to test error handling
    "copy_test_db.sql",
    "invalidate-credentials-for-testing.sql",
    "clear-customer-fields.sql",
    "grant-database-access.sql"
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Starting Test Environment Setup" -ForegroundColor Cyan
Write-Host "Target Database: $TargetDatabase" -ForegroundColor Yellow
Write-Host "Developer:       $Developer" -ForegroundColor Yellow
Write-Host "Login Name:      $LoginName" -ForegroundColor Yellow
Write-Host "Staging Shop:    $ShopUrl" -ForegroundColor Yellow
Write-Host "Mandant-Name:    $MandantName" -ForegroundColor Yellow
Write-Host "Server Instance: $ServerInstance" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

foreach ($ScriptName in $SqlScripts) {
    $ScriptPath = Join-Path $ScriptDirectory $ScriptName

    if (-not (Test-Path $ScriptPath)) {
        Write-Error "Script file not found: $ScriptPath"
        exit 1
    }

    Write-Host "Executing: $ScriptName ..." -ForegroundColor Green

    # Execute SQL script using sqlcmd
    # -b: On error, exit
    # -v: Define variables (TargetDb/LoginName; ShopUrl/ShopLicense come from env vars, see above)
    # -E: Trusted connection (Windows Auth)
    # -S: Server instance
    # -i: Input file
    & sqlcmd -S $ServerInstance -E -b -v TargetDb="$TargetDatabase" -v LoginName="$LoginName" -i "$ScriptPath"

    # Check exit code
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host "ERROR: Execution failed at script '$ScriptName'" -ForegroundColor Red
        Write-Host "Exit Code: $LASTEXITCODE" -ForegroundColor Red
        Write-Host "Aborting remaining steps." -ForegroundColor Red
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        exit $LASTEXITCODE
    }

    Write-Host "Successfully executed: $ScriptName" -ForegroundColor Gray
    Write-Host "------------------------------------------" -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Register the Mandant in dbo.tMandant so it appears in the JTL login
# (Mandantenauswahl). tMandant is JTL's Mandanten registry; without an
# entry the freshly cloned test DB is invisible in the WaWi client.
# register-mandant.sql keeps the entry consistent across all Mandanten
# DBs and is idempotent (keyed by cDB).
#
# MandantName is passed via ENVIRONMENT VARIABLE (not -v): sqlcmd's -v
# value parser chokes on the spaces/parentheses in the name, whereas
# scripting variables are also resolved from env vars (same technique as
# ShopUrl/ShopLicense above). TargetDb has no such chars -> stays on -v.
# ------------------------------------------------------------------
$RegisterMandantScript = Join-Path $ScriptDirectory "register-mandant.sql"

if (-not (Test-Path $RegisterMandantScript)) {
    Write-Error "Register-Mandant script not found: $RegisterMandantScript"
    exit 1
}

$env:MandantName = $MandantName

Write-Host "Executing: register-mandant.sql ($MandantName) ..." -ForegroundColor Green

& sqlcmd -S $ServerInstance -E -b -v TargetDb="$TargetDatabase" -i "$RegisterMandantScript"

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "ERROR: Execution failed at script 'register-mandant.sql'" -ForegroundColor Red
    Write-Host "Exit Code: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "Aborting." -ForegroundColor Red
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "Successfully executed: register-mandant.sql" -ForegroundColor Gray
Write-Host "------------------------------------------" -ForegroundColor Gray

# ------------------------------------------------------------------
# Additional step: Apply the standard JTL roles (JTL_Reader/JTL_Writer)
# to the test database.
#
# The normal JTL user group (AD group ZDBIKES\sql-jtl-users + read
# service accounts) only has read access on the production eazybusiness
# DB. This step re-applies the single-source-of-truth role script against
# the test mandant so those users are properly authorized there as well.
#
# Note: JTL-Rollen.sql operates on the *connected* database (no USE inside),
# so it must be run with -d $TargetDatabase - it lives in the repo-root
# 'Berechtigungen' folder, hence the separate invocation outside the loop.
# ------------------------------------------------------------------
$JtlRolesScript = Join-Path $ScriptDirectory "..\..\Berechtigungen\JTL-Rollen.sql"

if (-not (Test-Path $JtlRolesScript)) {
    Write-Error "JTL roles script not found: $JtlRolesScript"
    exit 1
}

Write-Host "Executing: JTL-Rollen.sql (against [$TargetDatabase]) ..." -ForegroundColor Green

& sqlcmd -S $ServerInstance -E -b -d "$TargetDatabase" -i "$JtlRolesScript"

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "ERROR: Execution failed at script 'JTL-Rollen.sql'" -ForegroundColor Red
    Write-Host "Exit Code: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "Aborting." -ForegroundColor Red
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "Successfully executed: JTL-Rollen.sql" -ForegroundColor Gray
Write-Host "------------------------------------------" -ForegroundColor Gray

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Test Environment Setup COMPLETED SUCCESSFULLY" -ForegroundColor Cyan
Write-Host "Target Database: $TargetDatabase" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
