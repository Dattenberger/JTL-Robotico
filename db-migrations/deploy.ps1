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
    # Out-Host is deliberate: it writes grate's stdout to the console WITHOUT letting it
    # land in the function's success stream. Without it, '$exit = Invoke-Grate' captures
    # every grate log line PLUS the exit code into an array, and the caller's
    # 'if ($exit -ne 0)' then filters that array (non-empty ⇒ truthy) and throws a FALSE
    # failure even when grate exited 0. Out-Host keeps the return value the scalar exit
    # code. ($LASTEXITCODE is set by the external grate/docker process; the Out-Host
    # cmdlet does not overwrite it.)
    switch ($grateRunner.Mode) {
        'native' {
            & $grateRunner.Path @CommonArgs "--sqlfilesdirectory=$SqlDir" | Out-Host
            return $LASTEXITCODE
        }
        'docker' {
            $dockerArgs = @(
                'run', '--rm', '--network', 'host',
                '--entrypoint', '/app/grate',
                '-v', "${SqlDir}:/db:ro",
                $grateRunner.Image
            ) + $CommonArgs + '--sqlfilesdirectory=/db'
            & docker @dockerArgs | Out-Host
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
# Declared up front (StrictMode) so the cert-existence safety probe can reference them
# in the integrated case too, where the sql branch below never sets them.
$sqlUser = $null
$sqlPassword = $null
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
#
# Password resolution order (global scope only):
#   1. $env:GRATE_CERT_PASSWORD           — explicit session override.
#   2. persisted per-environment store    — survives sessions (Windows: a User env var
#      GRATE_CERT_PASSWORD_<ENV>; Linux/macOS: ~/.robotico-ops/grate-cert.env, chmod 600).
#   3. auto-generate + persist            — first-run convenience, HARD-GUARDED: only when
#      the target instance has NO RoboticoOpsSigning certificate yet. If the cert already
#      exists but no password is known, ABORT — never generate a fresh one (it would not
#      match the immutable private key from up/0011, and every re-sign would fail; CQG-4).

# Per-environment key so TEST / PROD / E2E each keep their own cert password.
function Get-CertStoreKey { param([string] $Environment) "GRATE_CERT_PASSWORD_$Environment" }

# Linux/macOS persisted store file (KEY=VALUE lines).
function Get-CertStoreFile { Join-Path (Join-Path $HOME '.robotico-ops') 'grate-cert.env' }

function Read-PersistedCertPassword {
    param([string] $Environment)
    $key = Get-CertStoreKey $Environment
    if ($env:OS -eq 'Windows_NT') {
        return [Environment]::GetEnvironmentVariable($key, 'User')
    }
    $file = Get-CertStoreFile
    if (-not (Test-Path $file)) { return $null }
    foreach ($line in (Get-Content -Path $file)) {
        if ($line -match "^\s*$([regex]::Escape($key))\s*=\s*(.*)$") { return $Matches[1] }
    }
    return $null
}

function Save-PersistedCertPassword {
    param([string] $Environment, [string] $Password)
    $key = Get-CertStoreKey $Environment
    if ($env:OS -eq 'Windows_NT') {
        [Environment]::SetEnvironmentVariable($key, $Password, 'User')
        return "user environment variable $key (persisted for this Windows account)"
    }
    $file = Get-CertStoreFile
    $dir = Split-Path -Parent $file
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        & chmod 700 $dir 2>$null
    }
    $existing = if (Test-Path $file) {
        @(Get-Content -Path $file | Where-Object { $_ -notmatch "^\s*$([regex]::Escape($key))\s*=" })
    }
    else { @() }
    Set-Content -Path $file -Value ($existing + "$key=$Password") -Encoding utf8
    & chmod 600 $file 2>$null
    return $file
}

# 100 chars, [A-Za-z0-9] only (alphanumeric ⇒ no single-quote / connection-string / shell
# escaping hazard), CSPRNG, guaranteed >=1 upper / lower / digit (SQL password complexity).
function New-CertPassword {
    $upper = ([char[]](65..90))
    $lower = ([char[]](97..122))
    $digit = ([char[]](48..57))
    $all = $upper + $lower + $digit
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $pick = { param($set) $b = [byte[]]::new(1); $rng.GetBytes($b); $set[$b[0] % $set.Length] }
        $chars = @((& $pick $upper), (& $pick $lower), (& $pick $digit))
        while ($chars.Count -lt 100) { $chars += (& $pick $all) }
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $b4 = [byte[]]::new(4); $rng.GetBytes($b4)
            $j = [int]([System.BitConverter]::ToUInt32($b4, 0) % ($i + 1))
            $t = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $t
        }
        return (-join $chars)
    }
    finally { $rng.Dispose() }
}

# Safety probe for tier 3. Returns $true (cert present), $false (absent — safe to generate),
# or $null (unknown: no sqlcmd, or server unreachable). Connects to master so it works even
# before the global DB exists (a greenfield instance has neither DB nor cert).
function Test-SigningCertExists {
    param([string] $Server, [string] $GlobalDb, [string] $AuthMode, [string] $SqlUser, [string] $SqlPassword)
    $cmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $q = "SET NOCOUNT ON; IF DB_ID('$GlobalDb') IS NULL SELECT 0 ELSE " +
         "SELECT COUNT(*) FROM [$GlobalDb].sys.certificates WHERE name='RoboticoOpsSigning';"
    $a = @('-S', $Server, '-C', '-h', '-1', '-W', '-b', '-Q', $q)
    if ($AuthMode -eq 'sql') { $a += @('-U', $SqlUser, '-P', $SqlPassword) } else { $a += '-E' }
    $out = & $cmd.Source @a 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $n = ($out | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    if ($null -eq $n) { return $null }
    return ([int]($n.Trim()) -gt 0)
}

$userTokens = @()
if ($Scope -eq 'global') {
    $globalDb = $databases[0]

    # Tier 1: session override.
    $certPassword = $env:GRATE_CERT_PASSWORD
    $certSource = 'session env $GRATE_CERT_PASSWORD'

    # Tier 2: persisted per-environment store.
    if ([string]::IsNullOrEmpty($certPassword)) {
        $certPassword = Read-PersistedCertPassword -Environment $Environment
        if (-not [string]::IsNullOrEmpty($certPassword)) {
            $certSource = "persisted store ($(Get-CertStoreKey $Environment))"
        }
    }

    # Tier 3: auto-generate — guarded by the cert-absence safety invariant.
    if ([string]::IsNullOrEmpty($certPassword)) {
        $certExists = Test-SigningCertExists -Server $server -GlobalDb $globalDb `
            -AuthMode $authMode -SqlUser $sqlUser -SqlPassword $sqlPassword

        if ($certExists -eq $true) {
            throw ("Certificate RoboticoOpsSigning already exists on $server / $globalDb, but no " +
                   "password is known (not in `$env:GRATE_CERT_PASSWORD nor the persisted store " +
                   "'$(Get-CertStoreKey $Environment)'). Refusing to auto-generate: a new password " +
                   "would NOT match the immutable private key from up/0011 and every re-sign would " +
                   "fail. Obtain the original password (password manager / ~/.claude-secrets.md) and " +
                   "set it via `$env:GRATE_CERT_PASSWORD or the persisted store.")
        }
        if ($null -eq $certExists) {
            throw ("Cannot verify whether RoboticoOpsSigning already exists on $server / $globalDb " +
                   "(sqlcmd missing or server unreachable). Refusing to auto-generate a cert password " +
                   "blind — set `$env:GRATE_CERT_PASSWORD explicitly, or run where sqlcmd can reach the " +
                   "target so the safety check can confirm the certificate is absent.")
        }

        # $certExists -eq $false → greenfield instance, safe to mint a fresh password.
        $certPassword = New-CertPassword
        $savedTo = Save-PersistedCertPassword -Environment $Environment -Password $certPassword
        $certSource = "auto-generated (first run) + persisted"
        Write-Host ''
        Write-Host "No cert password found and RoboticoOpsSigning is absent on the target — generated a new one." -ForegroundColor Yellow
        Write-Host "  Persisted to : $savedTo" -ForegroundColor Yellow
        Write-Host "  Password     : $certPassword" -ForegroundColor Yellow
        Write-Host "  ^ Shown ONCE. Also save it in your password manager: up/0011 is immutable, so this" -ForegroundColor Yellow
        Write-Host "    is the only key to the RoboticoOpsSigning private key. A lost password means" -ForegroundColor Yellow
        Write-Host "    dropping + recreating the certificate via a new up/ script." -ForegroundColor Yellow
        Write-Host ''
    }

    # The token is substituted TEXTUALLY into a single-quoted SQL literal in 0011/900 —
    # grate cannot escape it, so a single quote would break out of the literal. Reject it
    # here with a clear message rather than producing a broken deploy. (Auto-generated
    # passwords are alphanumeric and never hit this; a store/env value still might.)
    if ($certPassword.Contains("'")) {
        throw "The RoboticoOpsSigning certificate password must not contain a single quote ('): it is substituted textually into a single-quoted SQL literal in global/up/0011 + global/permissions/900."
    }
    Write-Host "Cert password source: $certSource" -ForegroundColor DarkGray
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
        '--silent'
    )
    # Transaction wrapping is scope-specific. Ebene A (eazybusiness) is single-DB object
    # DDL — wrapping the run in one transaction lets a failed deploy roll back cleanly.
    # Ebene B (global) contains statements that CANNOT run inside a user transaction:
    # ALTER DATABASE SET (RECOVERY/TRUSTWORTHY), ALTER AUTHORIZATION, the cross-DB cert /
    # msdb writes, and sp_add_job. grate --transaction fails those with error 226
    # ("… not allowed within a multi-statement transaction"). Every global up/ script is
    # individually idempotent (IF NOT EXISTS guards, D2), so per-script execution without a
    # wrapping transaction is the correct — and only workable — model for Ebene B.
    if ($Scope -eq 'eazybusiness') { $grateArgs += '--transaction' }
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
