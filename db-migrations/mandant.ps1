<#
.SYNOPSIS
    Create / list test mandants via the RoboticoOps registry SPs.

.DESCRIPTION
    Thin sqlcmd wrapper around reset.spPub_CreateTestmandant (admin) and reset.spPub_ListMandants. Reuses
    the shared target/auth resolver (lib/targets.ps1 + targets.config.json) — same servers and
    auth as deploy.ps1, no secrets in config.

    -Create registers a NEW mandant and (unless -NoReset) kicks its first reset, which BUILDS
    the clone database (spInternal_CloneDatabase RESTOREs it). EXECUTE on reset.spPub_CreateTestmandant
    is granted to ops_admin only, so the connecting principal must be an ops_admin member.

    Never runs autonomously against PROD: -Environment PROD + -Create requires an interactive
    Y/N confirmation first (like deploy.ps1).

.PARAMETER Environment
    TEST | PROD | E2E (from targets.config.json).

.PARAMETER Create
    Create a new mandant. Requires -MandantKey + -DisplayName.

.PARAMETER List
    List mandants (wraps reset.spPub_ListMandants).

.PARAMETER MandantKey
    New mandant key, must match tm<number> (e.g. tm5).

.PARAMETER DisplayName
    Human-readable name shown in the JTL login.

.PARAMETER LoginName
    Developer login granted db_owner on the clone (default: the seeded shared dev login).

.PARAMETER TargetDb
    Clone DB name (default: eazybusiness_<MandantKey>).

.PARAMETER ShopUrl / .PARAMETER ShopLicense
    Optional staging shop repoint values (sentinel if omitted).

.PARAMETER NoReset
    Register only; do NOT kick the first reset (no clone is built until a reset runs).

.EXAMPLE
    pwsh db-migrations/mandant.ps1 -Environment E2E -List
.EXAMPLE
    pwsh db-migrations/mandant.ps1 -Environment E2E -Create -MandantKey tm5 -DisplayName "E2E Neu"
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('TEST', 'PROD', 'E2E')]
    [string] $Environment,

    [Parameter(ParameterSetName = 'Create', Mandatory = $true)]
    [switch] $Create,

    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch] $List,

    [Parameter(ParameterSetName = 'Create', Mandatory = $true)]
    [string] $MandantKey,

    [Parameter(ParameterSetName = 'Create', Mandatory = $true)]
    [string] $DisplayName,

    [Parameter(ParameterSetName = 'Create')]
    [string] $LoginName,

    [Parameter(ParameterSetName = 'Create')]
    [string] $TargetDb,

    [Parameter(ParameterSetName = 'Create')]
    [string] $ShopUrl,

    [Parameter(ParameterSetName = 'Create')]
    [string] $ShopLicense,

    [Parameter(ParameterSetName = 'Create')]
    [switch] $NoReset
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $scriptRoot 'lib' 'targets.ps1')
$target = Get-RoboticoTarget -Environment $Environment -ConfigPath (Join-Path $scriptRoot 'targets.config.json')

# ODBC-build sqlcmd (Kerberos -E for TEST/PROD) — shared resolver in lib/targets.ps1.
$sqlcmdPath = Get-RoboticoSqlcmd
$baseArgs = (Get-SqlcmdAuthArgs -Target $target) + @('-d', $target.GlobalDb, '-b')

function Invoke-OpsSql([string] $Query, [switch] $NoHeader) {
    $a = $baseArgs
    if ($NoHeader) { $a += @('-h', '-1', '-W') }
    # Query piped via stdin (not -Q) + password via SQLCMDPASSWORD (Invoke-RoboticoSqlcmd),
    # so a shop license inside the EXEC never lands on the process command line (Sec-I2).
    $r = Invoke-RoboticoSqlcmd -SqlcmdPath $sqlcmdPath -Arguments $a -Password $target.SqlPassword -StdinText $Query
    if ($r.Exit -ne 0) { throw "sqlcmd failed:`n$($r.Out)" }
    return $r.Raw
}

# T-SQL single-quote escape for a literal value.
function Q([string] $v) { $v.Replace("'", "''") }

if ($List) {
    Write-Host "==> reset.spPub_ListMandants ($Environment / $($target.GlobalDb) @ $($target.Server))" -ForegroundColor Cyan
    Invoke-OpsSql 'SET NOCOUNT ON; EXEC reset.spPub_ListMandants;' | Write-Host
    return
}

# --- Create -----------------------------------------------------------------
# PROD gate (mirrors deploy.ps1): creating a mandant on PROD builds a real database.
if ($Environment -eq 'PROD') {
    Write-Host ''
    Write-Host "You are about to CREATE a test mandant on PRODUCTION." -ForegroundColor Yellow
    Write-Host "  Server:     $($target.Server)" -ForegroundColor Yellow
    Write-Host "  MandantKey: $MandantKey" -ForegroundColor Yellow
    Write-Host "  TargetDb:   $(if ($TargetDb) { $TargetDb } else { "eazybusiness_$MandantKey (default)" })" -ForegroundColor Yellow
    Write-Host "  StartReset: $(-not $NoReset) (the first reset RESTOREs the clone DB)" -ForegroundColor Yellow
    $answer = Read-Host 'Proceed? (Y/N)'
    if ($answer -notin @('Y', 'y')) {
        Write-Host 'Aborted by user.' -ForegroundColor Red
        exit 1
    }
}

# Build the EXEC with named params; only pass optionals that were supplied.
$params = @("@MandantKey = N'$(Q $MandantKey)'", "@DisplayName = N'$(Q $DisplayName)'")
if ($PSBoundParameters.ContainsKey('LoginName'))   { $params += "@LoginName = N'$(Q $LoginName)'" }
if ($PSBoundParameters.ContainsKey('TargetDb'))    { $params += "@TargetDb = N'$(Q $TargetDb)'" }
if ($PSBoundParameters.ContainsKey('ShopUrl'))     { $params += "@ShopUrl = N'$(Q $ShopUrl)'" }
if ($PSBoundParameters.ContainsKey('ShopLicense')) { $params += "@ShopLicense = N'$(Q $ShopLicense)'" }
$params += "@StartReset = $(if ($NoReset) { 0 } else { 1 })"
$exec = "SET NOCOUNT ON; EXEC reset.spPub_CreateTestmandant " + ($params -join ', ') + ';'

Write-Host ''
Write-Host "==> reset.spPub_CreateTestmandant $MandantKey ($Environment / $($target.GlobalDb))" -ForegroundColor Cyan
$result = Invoke-OpsSql $exec -NoHeader
$result | Write-Host

if (-not $NoReset) {
    Write-Host ''
    Write-Host "Reset kicked. Poll status with:" -ForegroundColor Green
    Write-Host "  pwsh db-migrations/mandant.ps1 -Environment $Environment -List" -ForegroundColor Green
    Write-Host "  (or EXEC reset.spPub_GetResetStatus @MandantKey = N'$MandantKey'; — until cStatus = succeeded)" -ForegroundColor Green
}
