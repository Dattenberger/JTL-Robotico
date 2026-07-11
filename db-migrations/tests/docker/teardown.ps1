<#
.SYNOPSIS
    Tear down the ephemeral E2E MSSQL container and delete its volume.

.DESCRIPTION
    Idempotent. `docker compose down -v` removes the container AND the named
    data volume (full wipe — the next setup.ps1 starts from a clean engine).
    .env.local is left in place so the same secrets can be reused; pass
    -PurgeSecrets to also delete it.

.PARAMETER PurgeSecrets
    Also delete .env.local (the generated SA / cert secrets).

.EXAMPLE
    pwsh db-migrations/tests/docker/teardown.ps1
.EXAMPLE
    pwsh db-migrations/tests/docker/teardown.ps1 -PurgeSecrets
#>
[CmdletBinding()]
param(
    [switch] $PurgeSecrets
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $scriptRoot '.env.local'
$composeFile = Join-Path $scriptRoot 'docker-compose.yml'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'docker is not on PATH.'
}

# compose needs the env file resolved even for `down` (the file references
# ${MSSQL_SA_PASSWORD}); fall back to a dummy so down never blocks on a missing
# .env.local after -PurgeSecrets on a previous run.
$envArgs = if (Test-Path $envFile) { @('--env-file', $envFile) } else { @() }

Write-Host '==> docker compose down -v' -ForegroundColor Cyan
if ($envArgs.Count -gt 0) {
    & docker compose @envArgs -f $composeFile down -v
}
else {
    # No env file: provide the var inline so compose interpolation succeeds.
    $env:MSSQL_SA_PASSWORD = 'unused_for_down'
    & docker compose -f $composeFile down -v
}
if ($LASTEXITCODE -ne 0) { throw "docker compose down failed (exit $LASTEXITCODE)." }

if ($PurgeSecrets -and (Test-Path $envFile)) {
    Remove-Item $envFile -Force
    Write-Host "Removed $envFile (-PurgeSecrets)." -ForegroundColor Yellow
}

Write-Host 'Torn down. Container and volume removed.' -ForegroundColor Green
