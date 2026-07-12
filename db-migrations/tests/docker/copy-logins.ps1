<#
.SYNOPSIS
    Copy real server logins from a source SQL Server into the E2E container, preserving
    their original SIDs, so the reset pipeline's orphan-remap / grant paths can be tested
    against genuine SIDs instead of synthetic ones.

.DESCRIPTION
    Reads the source **read-only** (Windows/Kerberos auth, `-E`) and recreates each eligible
    login in the container (`localhost,14330`, SQL auth as sa). Original `SID` is always
    preserved — that is the whole point (orphaned DB users in a restored clone match by SID).

    Login classes:
      * SQL login, password hash readable  → CREATE LOGIN … WITH PASSWORD = <hash> HASHED,
        SID = <orig>. The real hash is applied directly, never written to disk.
      * SQL login, hash NOT readable        → created with a random password + original SID,
        flagged 'sql-random-pw' (SID mapping still works; the password is unknown/unusable).
      * Windows user / group                → cannot be `FROM WINDOWS` without the domain, so
        created as a **disabled** SQL login of the same name with the original SID, flagged
        'windows-sid-stub (AD not available in container)'. Enough for SID-mapping / orphan
        tests; it can never actually authenticate.

    System / service principals (`##…##`, `NT SERVICE\…`, `NT AUTHORITY\…`, `BUILTIN\…`, `sa`)
    are excluded. Idempotent: a login that already exists on the target is skipped.

    SECURITY: password hashes and generated passwords are applied via the target sqlcmd's
    STDIN — they are NEVER written to a file or placed on a command line. Only the target SA
    password is passed via `-P` (same as the rest of the harness).

.PARAMETER SourceServer
    Read-only source (default vm-sql-test1.zdbikes.local). Windows/Kerberos auth (`-E`).

.PARAMETER TargetServer
    Target container (default localhost,14330). SQL auth as sa.

.PARAMETER SaPasswordEnv
    Env var holding the target sa password (default MSSQL_SA_PASSWORD). Falls back to
    tests/docker/.env.local if the env var is empty.

.PARAMETER WhatIf
    Print what would be created (hashes/passwords redacted) and change nothing.

.EXAMPLE
    pwsh db-migrations/tests/docker/copy-logins.ps1 -WhatIf
.EXAMPLE
    pwsh db-migrations/tests/docker/copy-logins.ps1
#>
[CmdletBinding()]
param(
    [string] $SourceServer = 'vm-sql-test1.zdbikes.local',
    [string] $TargetServer = 'localhost,14330',
    [string] $SaPasswordEnv = 'MSSQL_SA_PASSWORD',
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- sqlcmd (ODBC build for Kerberos -E against the source) ------------------
$sqlcmd = @('/opt/mssql-tools18/bin/sqlcmd', '/opt/mssql-tools/bin/sqlcmd', 'sqlcmd') |
    ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $sqlcmd) { throw 'No sqlcmd found (need /opt/mssql-tools18/bin/sqlcmd for Kerberos -E).' }
$sqlcmdPath = $sqlcmd.Source

# --- target sa password -----------------------------------------------------
$saPassword = [Environment]::GetEnvironmentVariable($SaPasswordEnv)
if ([string]::IsNullOrEmpty($saPassword)) {
    $envFile = Join-Path $scriptRoot '.env.local'
    if (Test-Path $envFile) {
        $line = Get-Content $envFile | Where-Object { $_ -match "^\s*$([regex]::Escape($SaPasswordEnv))\s*=" } | Select-Object -First 1
        if ($line) { $saPassword = ($line -replace "^\s*$([regex]::Escape($SaPasswordEnv))\s*=\s*", '') }
    }
}
if ([string]::IsNullOrEmpty($saPassword)) {
    throw "Target sa password not found (env '$SaPasswordEnv' empty and not in .env.local). Run setup.ps1 first."
}

# --- random password generator (for hash-less SQL logins + windows stubs) ---
function New-RandomPassword {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $set = ([char[]](65..90)) + ([char[]](97..122)) + ([char[]](48..57)) + ('!#%&*+-_=.'.ToCharArray())
        $b = [byte[]]::new(24); $rng.GetBytes($b)
        -join ($b | ForEach-Object { $set[$_ % $set.Length] })
    }
    finally { $rng.Dispose() }
}

# --- 1. read eligible logins from the source (READ-ONLY) --------------------
Write-Host "Reading logins from $SourceServer (read-only, Kerberos) ..." -ForegroundColor Cyan
# COLLATE DATABASE_DEFAULT on every string piece: the source server/catalog collation
# (e.g. Latin1_General_CI_AS_KS_WS on test1) otherwise conflicts with the varchar CONVERT
# results in the '+' concatenation ("cannot resolve collation conflict").
$q = @"
SET NOCOUNT ON;
SELECT CONVERT(varchar(256), sp.name) COLLATE DATABASE_DEFAULT + '|'
     + CONVERT(varchar(2), sp.type)  COLLATE DATABASE_DEFAULT + '|'
     + CONVERT(varchar(max), sp.sid, 1) COLLATE DATABASE_DEFAULT + '|'
     + CAST(sp.is_disabled AS varchar(1)) + '|'
     + ISNULL(CONVERT(varchar(max), LOGINPROPERTY(sp.name, 'PasswordHash'), 1), 'NULL') COLLATE DATABASE_DEFAULT
FROM sys.server_principals sp
WHERE sp.type IN ('S','U','G')
  AND sp.name NOT LIKE '##%'
  AND sp.name NOT LIKE 'NT SERVICE\%'
  AND sp.name NOT LIKE 'NT AUTHORITY\%'
  AND sp.name NOT LIKE 'NT-DIENST\%'         -- German 'NT SERVICE'
  AND sp.name NOT LIKE 'NT-AUTORIT%'         -- German 'NT-AUTORITÄT' (ASCII-safe prefix)
  AND sp.name NOT LIKE 'BUILTIN\%'
  AND sp.name <> 'sa'
  -- well-known system SIDs (locale-independent): S-1-5-18/19/20 (Local System /
  -- Local Service / Network Service). NT SERVICE (S-1-5-80-*) and BUILTIN (S-1-5-32-*)
  -- are already excluded by name above; guard the three short ones by SID too.
  AND sp.sid NOT IN (0x010100000000000512000000, 0x010100000000000513000000, 0x010100000000000514000000)
ORDER BY sp.name;
"@
$rows = & $sqlcmdPath -S $SourceServer -E -C -l 30 -h -1 -W -b -Q $q 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to read logins from ${SourceServer}: $rows" }
$rows = @($rows | Where-Object { $_ -match '\|' })
Write-Host "  $($rows.Count) eligible login(s) found." -ForegroundColor Cyan

# --- 2. build CREATE LOGIN statements ---------------------------------------
# Hard SQL Server constraint: a SQL login's SID is binary(16). Windows/AD SIDs are longer
# (domain SIDs are 28 bytes), and CREATE LOGIN … FROM WINDOWS needs the domain the container
# is NOT joined to. So Windows/AD logins genuinely cannot be mirrored with their real SID in
# a stand-alone container — they are reported as skipped (with the reason), not faked. Only
# SQL logins (16-byte SID) are mirrored, preserving their SID (and password hash if readable).
$batch = New-Object System.Text.StringBuilder
$summary = @()
$skipped = @()
foreach ($r in $rows) {
    $parts = $r -split '\|', 5
    if ($parts.Count -lt 5) { continue }
    $name = $parts[0].Trim()
    $type = $parts[1].Trim()
    $sid = $parts[2].Trim()
    $disabled = ($parts[3].Trim() -eq '1')
    $hash = $parts[4].Trim()

    if ($type -ne 'S') {
        $sidBytes = [Math]::Max(0, ($sid.Length - 2) / 2)
        $skipped += [pscustomobject]@{ Source = $name; Type = $type; Sid = $sid
            Reason = "Windows/AD principal — SID is $sidBytes bytes; SQL logins require binary(16) and FROM WINDOWS needs the (absent) domain" }
        continue
    }

    $nameLit = $name.Replace("'", "''")
    $quoted = '[' + $name.Replace(']', ']]') + ']'

    if ($hash -ne 'NULL' -and $hash -match '^0x') {
        $create = "CREATE LOGIN $quoted WITH PASSWORD = $hash HASHED, SID = $sid, CHECK_POLICY = OFF, DEFAULT_DATABASE = [master];"
        $class = 'sql-hashed'
    }
    else {
        $pw = New-RandomPassword
        $create = "CREATE LOGIN $quoted WITH PASSWORD = '$pw', SID = $sid, CHECK_POLICY = OFF, DEFAULT_DATABASE = [master];"
        $class = 'sql-random-pw'
    }
    $disableStmt = if ($disabled) { " ALTER LOGIN $quoted DISABLE;" } else { '' }

    [void]$batch.AppendLine("IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$nameLit')")
    [void]$batch.AppendLine("BEGIN $create$disableStmt PRINT 'created: $nameLit'; END")
    [void]$batch.AppendLine("ELSE PRINT 'skipped (exists): $nameLit';")

    $summary += [pscustomobject]@{ Source = $name; Target = $name; Type = $type; Class = $class; Sid = $sid }
}

# --- report plan ------------------------------------------------------------
Write-Host ''
Write-Host "Plan: mirror $($summary.Count) SQL login(s) (SID preserved), skip $($skipped.Count) Windows/AD login(s)." -ForegroundColor Cyan
foreach ($s in $summary) {
    Write-Host ("  MIRROR  {0,-16} {1,-42} SID={2}" -f $s.Class, $s.Source, $s.Sid)
}
foreach ($k in $skipped) {
    Write-Host ("  SKIP    {0,-16} {1,-42} ({2})" -f "windows-$($k.Type)", $k.Source, $k.Reason) -ForegroundColor DarkYellow
}

if ($WhatIf) {
    Write-Host ''
    Write-Host '-WhatIf: nothing applied. Hashes/passwords are never printed.' -ForegroundColor Yellow
    return
}

# --- 3. apply to the container via STDIN (no secrets on disk / argv) ---------
Write-Host ''
Write-Host "Applying to $TargetServer ..." -ForegroundColor Cyan
$applyOut = $batch.ToString() | & $sqlcmdPath -S $TargetServer -U sa -P $saPassword -C -b 2>&1
if ($LASTEXITCODE -ne 0) { throw "Applying logins failed: $applyOut" }
$applyOut | Where-Object { $_ -match 'created:|skipped' } | ForEach-Object { Write-Host "  $_" }

# --- 4. verify SIDs on 3 samples --------------------------------------------
Write-Host ''
Write-Host 'Verifying SIDs (source vs container) on up to 3 samples:' -ForegroundColor Cyan
foreach ($s in ($summary | Select-Object -First 3)) {
    $tgtSid = & $sqlcmdPath -S $TargetServer -U sa -P $saPassword -C -h -1 -W -b -Q `
        "SET NOCOUNT ON; SELECT CONVERT(varchar(max), sid, 1) FROM sys.server_principals WHERE name = N'$($s.Target.Replace("'","''"))';" 2>&1
    $tgtSid = ($tgtSid | Where-Object { $_ -match '^0x' } | Select-Object -First 1)
    $ok = ($tgtSid -eq $s.Sid)
    Write-Host ("  {0,-45} {1}" -f $s.Source, $(if ($ok) { "MATCH ($tgtSid)" } else { "MISMATCH src=$($s.Sid) tgt=$tgtSid" })) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}
Write-Host ''
Write-Host "Done. $($summary.Count) login(s) processed." -ForegroundColor Green
