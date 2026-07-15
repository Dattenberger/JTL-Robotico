<#
.SYNOPSIS
    Shared target + auth resolution for the JTL-Robotico migration tooling.

.DESCRIPTION
    Single source of truth for reading targets.config.json and resolving how to connect to a
    given environment. Dot-sourced by deploy.ps1 (grate connection strings) and mandant.ps1
    (sqlcmd) so the config/auth logic lives in exactly one place.

    NO secrets in the config. auth='sql' (E2E container) reads the password at call time from
    the env var named by sqlPasswordEnv; auth omitted / 'integrated' = Windows auth.
#>

function Get-RoboticoTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $ConfigPath
    )

    if (-not (Test-Path $ConfigPath)) { throw "Missing config: $ConfigPath" }
    $config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

    if (-not $config.environments.PSObject.Properties.Name.Contains($Environment)) {
        throw "Environment '$Environment' not found in $ConfigPath"
    }
    $envConfig = $config.environments.$Environment

    $authMode = if ($envConfig.PSObject.Properties.Name -contains 'auth') { $envConfig.auth } else { 'integrated' }
    $sqlUser = $null
    $sqlPassword = $null
    if ($authMode -eq 'sql') {
        $sqlUser = $envConfig.sqlUser
        $passwordEnvName = $envConfig.sqlPasswordEnv
        $sqlPassword = [Environment]::GetEnvironmentVariable($passwordEnvName)
        if ([string]::IsNullOrEmpty($sqlPassword)) {
            throw "Environment '$Environment' uses SQL auth but env var '$passwordEnvName' is empty. For the E2E container, run tests/docker/setup.ps1 and load .env.local (e.g. export MSSQL_SA_PASSWORD=... from that file)."
        }
        if ($sqlPassword.Contains(';')) {
            throw "The '$passwordEnvName' password must not contain a semicolon (';') — it would break the connection string."
        }
    }
    elseif ($authMode -ne 'integrated') {
        throw "Unknown auth mode '$authMode' for environment '$Environment' (expected 'integrated' or 'sql')."
    }

    [pscustomobject]@{
        Environment  = $Environment
        Server       = $envConfig.server
        AuthMode     = $authMode           # 'integrated' | 'sql'
        SqlUser      = $sqlUser             # $null for integrated
        SqlPassword  = $sqlPassword         # $null for integrated
        GlobalDb     = $envConfig.global
        Eazybusiness = @($envConfig.eazybusiness)
    }
}

# Resolve the sqlcmd binary path (SSoT for every tool here: deploy.ps1, mandant.ps1,
# validate-rollout.ps1). Prefers the ODBC-build under /opt/mssql-tools*/bin because a
# Windows / Kerberos connection (`-E`, integrated auth) needs it — the go-sqlcmd on
# /usr/local/bin cannot do Kerberos, so a bare `Get-Command sqlcmd` would silently pick
# the wrong one and break integrated-auth probes (the 2026-07-13 Test-SigningCertExists
# regression). Falls back to whatever `sqlcmd` is on PATH. Throws if none is found.
function Get-RoboticoSqlcmd {
    [CmdletBinding()]
    param()
    $candidate = @(
        '/opt/mssql-tools18/bin/sqlcmd',
        '/opt/mssql-tools/bin/sqlcmd',
        '/usr/local/bin/sqlcmd',
        'sqlcmd'
    ) | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $candidate) {
        throw 'No sqlcmd found (looked for the ODBC-build /opt/mssql-tools*/bin/sqlcmd first, then PATH).'
    }
    return $candidate.Source
}

# Base sqlcmd argument array (server + auth) for a resolved target. Callers append
# -d / -Q / -i etc. Uses the ODBC-build sqlcmd path passed in (Kerberos needs mssql-tools18).
#
# SECRETS (Sec-I2): the SQL-auth USERNAME (-U) is placed on argv, but the PASSWORD is
# deliberately NOT. It would otherwise be world-readable via `ps` / /proc/<pid>/cmdline for
# the lifetime of the sqlcmd process. Hand the password to Invoke-RoboticoSqlcmd instead — it
# exports it to the SQLCMDPASSWORD environment variable only for the duration of the call.
function Get-SqlcmdAuthArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Target)

    $a = @('-S', $Target.Server, '-C')
    if ($Target.AuthMode -eq 'sql') { $a += @('-U', $Target.SqlUser) }
    else { $a += '-E' }
    return $a
}

# Single choke point for running sqlcmd WITHOUT leaking secrets onto the process command
# line (Sec-I2). Two hazards are handled here so no caller has to reinvent them:
#   * Password  — exported to the SQLCMDPASSWORD environment variable for the duration of the
#                 call only (restored/removed in finally), instead of a `-P <plaintext>` argv
#                 entry that `ps` / /proc exposes to any local user.
#   * StdinText — T-SQL that itself carries a secret (e.g. a shop license inside an EXEC) is
#                 piped via stdin so it never reaches argv (-Q) or disk (-i). Callers using
#                 -StdinText must NOT also pass -Q/-i in $Arguments (sqlcmd would ignore stdin).
# Returns Exit (sqlcmd exit code) / Out (joined string) / Raw (line array).
function Invoke-RoboticoSqlcmd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $SqlcmdPath,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $Password,
        [string] $StdinText
    )

    $hadPw  = Test-Path Env:SQLCMDPASSWORD
    $prevPw = if ($hadPw) { $env:SQLCMDPASSWORD } else { $null }
    try {
        if (-not [string]::IsNullOrEmpty($Password)) { $env:SQLCMDPASSWORD = $Password }
        if ($PSBoundParameters.ContainsKey('StdinText')) {
            $raw = $StdinText | & $SqlcmdPath @Arguments 2>&1
        }
        else {
            $raw = & $SqlcmdPath @Arguments 2>&1
        }
        $code = $LASTEXITCODE
        return [pscustomobject]@{ Exit = $code; Out = ($raw -join "`n"); Raw = $raw }
    }
    finally {
        if ($hadPw) { $env:SQLCMDPASSWORD = $prevPw }
        else { Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue }
    }
}
