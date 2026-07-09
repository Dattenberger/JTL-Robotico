<#
.SYNOPSIS
    Thin wrapper around grate for the two JTL-Robotico migration chains.

.DESCRIPTION
    Resolves servers + target databases from targets.config.json (no secrets — Windows
    auth only), then invokes grate once per target database. Ebene A (eazybusiness)
    journals into schema 'Robotico'; Ebene B (global) journals into schema 'ops' in
    RoboticoOps.

    This script never runs autonomously against PROD: -Environment PROD requires an
    interactive Y/N confirmation listing the exact target databases first
    (lesson 5, research/1.1). It applies changes only via grate — no ad-hoc T-SQL.

.PARAMETER Scope
    eazybusiness (Ebene A) | global (Ebene B).

.PARAMETER Environment
    TEST | PROD. Selects the server + DB list from targets.config.json.

.PARAMETER Target
    Optional single target database (must be one of the environment's eazybusiness list).
    Ignored for -Scope global (there is exactly one global DB).

.PARAMETER Baseline
    Pass grate --baseline: mark all current scripts as run WITHOUT executing them.
    Use once to adopt an existing database. See docs/runbooks/migrations-baseline.md.

.PARAMETER DryRun
    Pass grate --dryrun: log what would run, change nothing.

.EXAMPLE
    pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment TEST
.EXAMPLE
    pwsh db-migrations/deploy.ps1 -Scope global -Environment TEST
.EXAMPLE
    pwsh db-migrations/deploy.ps1 -Scope eazybusiness -Environment PROD -Target eazybusiness_tm2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('eazybusiness', 'global')]
    [string] $Scope,

    [Parameter(Mandatory = $true)]
    [ValidateSet('TEST', 'PROD')]
    [string] $Environment,

    [Parameter(Mandatory = $false)]
    [string] $Target,

    [switch] $Baseline,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- grate availability -----------------------------------------------------
if (-not (Get-Command grate -ErrorAction SilentlyContinue)) {
    throw "grate is not on PATH. Install it with: dotnet tool install --global grate"
}

# --- config resolution ------------------------------------------------------
$configPath = Join-Path $scriptRoot 'targets.config.json'
if (-not (Test-Path $configPath)) {
    throw "Missing config: $configPath"
}
$config = Get-Content -Raw -Path $configPath | ConvertFrom-Json

if (-not $config.environments.PSObject.Properties.Name.Contains($Environment)) {
    throw "Environment '$Environment' not found in targets.config.json"
}
$env = $config.environments.$Environment
$server = $env.server

# --- scope -> grate parameters ---------------------------------------------
switch ($Scope) {
    'eazybusiness' {
        $sqlFilesDirectory = Join-Path $scriptRoot 'eazybusiness'
        $schema = 'Robotico'
        $allDbs = @($env.eazybusiness)
        if ($Target) {
            if ($allDbs -notcontains $Target) {
                throw "Target '$Target' is not in the $Environment eazybusiness list: $($allDbs -join ', ')"
            }
            $databases = @($Target)
        }
        else {
            $databases = $allDbs
        }
    }
    'global' {
        $sqlFilesDirectory = Join-Path $scriptRoot 'global'
        $schema = 'ops'
        $databases = @($env.global)
    }
}

# --- PROD gate --------------------------------------------------------------
if ($Environment -eq 'PROD' -and -not $DryRun) {
    Write-Host ''
    Write-Host "You are about to deploy scope '$Scope' to PRODUCTION." -ForegroundColor Yellow
    Write-Host "  Server:    $server" -ForegroundColor Yellow
    Write-Host "  Databases: $($databases -join ', ')" -ForegroundColor Yellow
    if ($Baseline) { Write-Host "  Mode:      BASELINE (mark-as-run, no execution)" -ForegroundColor Yellow }
    $answer = Read-Host 'Proceed? (Y/N)'
    if ($answer -notin @('Y', 'y')) {
        Write-Host 'Aborted by user.' -ForegroundColor Red
        return
    }
}

# --- cert password token (Ebene B signing chain) ----------------------------
# {{CertPassword}} tokens live in global/up/0011 + global/permissions/900. Never in git.
$userTokens = @()
if ($Scope -eq 'global') {
    $certPassword = $env:GRATE_CERT_PASSWORD
    if ([string]::IsNullOrEmpty($certPassword)) {
        $secure = Read-Host 'RoboticoOpsSigning certificate password' -AsSecureString
        $certPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    }
    $userTokens += "CertPassword=$certPassword"
}

# --- version stamp ----------------------------------------------------------
$version = (& git describe --tags --always 2>$null)
if ([string]::IsNullOrEmpty($version)) { $version = 'unknown' }

# --- deploy loop ------------------------------------------------------------
foreach ($db in $databases) {
    $connectionString = "Server=$server;Database=$db;Trusted_Connection=True;TrustServerCertificate=True"

    $grateArgs = @(
        "--connectionstring=$connectionString"
        "--sqlfilesdirectory=$sqlFilesDirectory"
        "--schema=$schema"
        "--environment=$Environment"
        "--version=$version"
        '--transaction'
        '--silent'
    )
    if ($Baseline) { $grateArgs += '--baseline' }
    if ($DryRun) { $grateArgs += '--dryrun' }
    foreach ($t in $userTokens) { $grateArgs += "--usertokens=$t" }

    Write-Host ''
    Write-Host "==> grate: scope=$Scope db=$db schema=$schema env=$Environment" -ForegroundColor Cyan
    & grate @grateArgs
    if ($LASTEXITCODE -ne 0) {
        throw "grate failed for database '$db' (exit $LASTEXITCODE). Stopping — no further targets deployed."
    }
}

Write-Host ''
Write-Host "Done. Scope '$Scope' deployed to: $($databases -join ', ')" -ForegroundColor Green
