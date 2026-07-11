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
    TEST | PROD | E2E. Selects the server + DB list from targets.config.json.
    E2E targets the disposable local Docker container (db-migrations/tests/docker)
    with SQL authentication — never a real server. See that folder's README.

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
    [ValidateSet('TEST', 'PROD', 'E2E')]
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
# Two runner shapes, auto-detected (see tests/docker/README §grate path):
#   native  — a `grate` binary on PATH (dotnet global tool). The normal path on
#             an operator workstation for TEST/PROD deploys.
#   docker  — no grate/dotnet available: run grate from its official image
#             (erikbra/grate) via `docker run`. Used for the E2E container path
#             on machines without the .NET SDK. Set GRATE_DOCKER_IMAGE to pin a
#             different tag (default below).
$grateRunner = $null
$nativeGrate = Get-Command grate -ErrorAction SilentlyContinue
if ($nativeGrate) {
    $grateRunner = @{ Mode = 'native'; Path = $nativeGrate.Source }
}
elseif (Get-Command docker -ErrorAction SilentlyContinue) {
    $grateImage = if ($env:GRATE_DOCKER_IMAGE) { $env:GRATE_DOCKER_IMAGE } else { 'erikbra/grate:1.6.0' }
    $grateRunner = @{ Mode = 'docker'; Image = $grateImage }
    Write-Host "grate not on PATH — using Docker image '$grateImage'." -ForegroundColor DarkGray
}
else {
    throw "No grate available: neither a 'grate' binary on PATH (dotnet tool install --global grate) nor docker to run erikbra/grate."
}

# Runs grate with a fixed argument list. The docker runner overrides the image's
# baked env-var entrypoint with the grate binary directly (so --schema /
# --usertokens etc. are honoured), mounts the SQL folder read-only at /db, and
# uses the host network so a 'localhost,PORT' connection string reaches the
# published container port exactly as the host sqlcmd does.
function Invoke-Grate {
    param(
        [Parameter(Mandatory)] [string]   $SqlDir,
        [Parameter(Mandatory)] [string[]] $CommonArgs   # everything except --sqlfilesdirectory
    )
    switch ($grateRunner.Mode) {
        'native' {
            & $grateRunner.Path @CommonArgs "--sqlfilesdirectory=$SqlDir"
            return $LASTEXITCODE
        }
        'docker' {
            $dockerArgs = @(
                'run', '--rm', '--network', 'host',
                '--entrypoint', '/app/grate',
                '-v', "${SqlDir}:/db:ro",
                $grateRunner.Image
            ) + $CommonArgs + '--sqlfilesdirectory=/db'
            & docker @dockerArgs
            return $LASTEXITCODE
        }
    }
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
# Named $envConfig (not $env) to avoid visual collision with PowerShell's $env: drive.
$envConfig = $config.environments.$Environment
$server = $envConfig.server

# --- authentication ---------------------------------------------------------
# Default = integrated (Windows auth) for real environments; NO secrets in the
# config. auth='sql' (E2E container only) reads the password at deploy time from
# the env var named by sqlPasswordEnv — the password never lives in the config.
$authMode = if ($envConfig.PSObject.Properties.Name -contains 'auth') { $envConfig.auth } else { 'integrated' }
$authFragment = 'Trusted_Connection=True'
if ($authMode -eq 'sql') {
    $sqlUser = $envConfig.sqlUser
    $passwordEnvName = $envConfig.sqlPasswordEnv
    $sqlPassword = [Environment]::GetEnvironmentVariable($passwordEnvName)
    if ([string]::IsNullOrEmpty($sqlPassword)) {
        throw "Environment '$Environment' uses SQL auth but env var '$passwordEnvName' is empty. For the E2E container, run tests/docker/setup.ps1 and load .env.local (e.g. export MSSQL_SA_PASSWORD=... from that file)."
    }
    # Connection-string values are semicolon-delimited; a stray ';' in the
    # password would corrupt the string. Reject it with a clear message.
    if ($sqlPassword.Contains(';')) {
        throw "The '$passwordEnvName' password must not contain a semicolon (';') — it would break the connection string."
    }
    $authFragment = "User ID=$sqlUser;Password=$sqlPassword"
}
elseif ($authMode -ne 'integrated') {
    throw "Unknown auth mode '$authMode' for environment '$Environment' (expected 'integrated' or 'sql')."
}

# --- scope -> grate parameters ---------------------------------------------
switch ($Scope) {
    'eazybusiness' {
        $sqlFilesDirectory = Join-Path $scriptRoot 'eazybusiness'
        $schema = 'Robotico'
        $allDbs = @($envConfig.eazybusiness)
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
        if ($Target) {
            Write-Warning "-Target '$Target' is ignored for -Scope global (there is exactly one global DB: $($envConfig.global))."
        }
        $sqlFilesDirectory = Join-Path $scriptRoot 'global'
        $schema = 'ops'
        $databases = @($envConfig.global)
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
        # Non-zero exit so scripted callers (e.g. `deploy.ps1 ... && next-step`)
        # can distinguish an operator abort from a successful deploy.
        exit 1
    }
}

# --- cert password token (Ebene B signing chain) ----------------------------
# {{CertPassword}} tokens live in global/up/0011 + global/permissions/900. Never in git.
# The SQL side (0011/900) documents the single-quote + immutability constraints (CQG-3);
# this block enforces the single-quote rule before grate ever sees the value.
# @see db-migrations/global/up/0011_signing_certificate.sql
# @see db-migrations/global/permissions/900_resign_procedures.sql
# GOTCHA — process-argument exposure: grate accepts the password ONLY as a --usertokens
#   CLI argument (built below), so it is briefly visible in the host's process table while
#   grate runs. Run global deploys on a single-operator / least-privilege host, and NEVER
#   print or log $grateArgs. See README §7.
$userTokens = @()
if ($Scope -eq 'global') {
    $certPassword = $env:GRATE_CERT_PASSWORD
    if ([string]::IsNullOrEmpty($certPassword)) {
        $secure = Read-Host 'RoboticoOpsSigning certificate password' -AsSecureString
        # Free the unmanaged plaintext buffer promptly (ZeroFreeBSTR) once copied out.
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $certPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    # The token is substituted TEXTUALLY into a single-quoted SQL literal in 0011/900 —
    # grate cannot escape it, so a single quote would break out of the literal. Reject it
    # here with a clear message rather than producing a broken deploy.
    if ($certPassword.Contains("'")) {
        throw "The RoboticoOpsSigning certificate password must not contain a single quote ('): it is substituted textually into a single-quoted SQL literal in global/up/0011 + global/permissions/900."
    }
    $userTokens += "CertPassword=$certPassword"
}

# --- version stamp ----------------------------------------------------------
$version = (& git describe --tags --always 2>$null)
if ([string]::IsNullOrEmpty($version)) { $version = 'unknown' }

# --- deploy loop ------------------------------------------------------------
foreach ($db in $databases) {
    $connectionString = "Server=$server;Database=$db;$authFragment;TrustServerCertificate=True"

    # --sqlfilesdirectory is supplied by Invoke-Grate (the docker runner maps it
    # to the in-container mount point), so it is NOT part of the common args.
    $grateArgs = @(
        "--connectionstring=$connectionString"
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
    Write-Host "==> grate: scope=$Scope db=$db schema=$schema env=$Environment runner=$($grateRunner.Mode)" -ForegroundColor Cyan
    $exit = Invoke-Grate -SqlDir $sqlFilesDirectory -CommonArgs $grateArgs
    if ($exit -ne 0) {
        throw "grate failed for database '$db' (exit $exit). Stopping — no further targets deployed."
    }
}

Write-Host ''
Write-Host "Done. Scope '$Scope' deployed to: $($databases -join ', ')" -ForegroundColor Green
