<#
.SYNOPSIS
    Run the read-only structure validation (tests/global/validate_structure.sql) against
    the E2E container's RoboticoOps.

.DESCRIPTION
    Thin wrapper so `npm run db:e2e:validate` works without hand-wiring sqlcmd auth. Resolves
    the sa password from $env:MSSQL_SA_PASSWORD or tests/docker/.env.local, then runs the
    committed validation script (which prints one line per check and RAISERRORs on failure)
    against localhost,14330 / RoboticoOps with SQL auth. Read-only.

.EXAMPLE
    pwsh db-migrations/tests/docker/validate.ps1
#>
[CmdletBinding()]
param(
    [string] $TargetServer = 'localhost,14330',
    [string] $SaPasswordEnv = 'MSSQL_SA_PASSWORD'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptRoot '..' '..' '..')).Path
$validateSql = Join-Path $repoRoot 'db-migrations/tests/global/validate_structure.sql'
if (-not (Test-Path $validateSql)) { throw "Missing $validateSql" }

$sqlcmd = @('/usr/local/bin/sqlcmd', '/opt/mssql-tools18/bin/sqlcmd', 'sqlcmd') |
    ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $sqlcmd) { throw 'No sqlcmd found.' }

$saPassword = [Environment]::GetEnvironmentVariable($SaPasswordEnv)
if ([string]::IsNullOrEmpty($saPassword)) {
    $envFile = Join-Path $scriptRoot '.env.local'
    if (Test-Path $envFile) {
        $line = Get-Content $envFile | Where-Object { $_ -match "^\s*$([regex]::Escape($SaPasswordEnv))\s*=" } | Select-Object -First 1
        if ($line) { $saPassword = ($line -replace "^\s*$([regex]::Escape($SaPasswordEnv))\s*=\s*", '') }
    }
}
if ([string]::IsNullOrEmpty($saPassword)) { throw "sa password not found (env '$SaPasswordEnv' / .env.local). Run setup.ps1 first." }

Write-Host "==> validate_structure.sql against $TargetServer / RoboticoOps" -ForegroundColor Cyan
& $sqlcmd.Source -S $TargetServer -U sa -P $saPassword -C -d RoboticoOps -b -i $validateSql
if ($LASTEXITCODE -ne 0) { throw "Validation reported failures (exit $LASTEXITCODE)." }
Write-Host 'Validation OK.' -ForegroundColor Green
