<#
.SYNOPSIS
    Convention lint for the JTL-Robotico grate migrations — the executable form of
    db-migrations/README.md.

.DESCRIPTION
    Recursively checks every *.sql under db-migrations/eazybusiness and
    db-migrations/global against the hard rules (a)-(g) documented in
    db-migrations/README.md §4, plus the §6 cleanup-script rule (f) against
    Berechtigungen/cleanup (when that directory exists).

    Runs under Linux `pwsh` and Windows PowerShell. Exit code 0 = clean,
    1 = at least one ERROR (WARNINGs alone do not fail the run).

.EXAMPLE
    pwsh db-migrations/tests/lint-migrations.ps1
.EXAMPLE
    pwsh db-migrations/tests/lint-migrations.ps1 -Path /path/to/db-migrations

.NOTES
    This lint is tier 1 of the plan's three-tier test strategy (the other two are
    compare-objects.sql and the eazybusiness/*_Tests.sql suite).
    @see docs/plans/2026-07-10 - mssql-ops-infrastruktur/mssql-ops-infrastruktur.md §7 Test Strategy
#>
[CmdletBinding()]
param(
    # Root of db-migrations (defaults to the parent of this script's tests/ folder).
    [string] $Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path            # …/db-migrations/tests
$migrationsRoot = if ($Path) { $Path } else { Split-Path -Parent $scriptRoot }  # …/db-migrations
$repoRoot = Split-Path -Parent $migrationsRoot

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Error([string] $file, [string] $rule, [string] $message) {
    $script:errors.Add("ERROR   [$rule] ${file}: $message")
}
function Add-Warning([string] $file, [string] $rule, [string] $message) {
    $script:warnings.Add("WARNING [$rule] ${file}: $message")
}

# Remove SQL comments so reference/keyword checks do not fire on commentary.
# Strips /* … */ block comments and -- … line comments (pragmatic: does not model
# string literals, which is acceptable — the forbidden tokens must not appear in
# strings either).
function Remove-SqlComments([string] $text) {
    $noBlock = [regex]::Replace($text, '(?s)/\*.*?\*/', ' ')
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in ($noBlock -split "`n")) {
        $idx = $line.IndexOf('--')
        if ($idx -ge 0) { $line = $line.Substring(0, $idx) }
        [void]$sb.AppendLine($line)
    }
    return $sb.ToString()
}

# Folder → grate class, derived from the immediate parent directory name.
function Get-FolderClass([string] $relativeDir) {
    $leaf = ($relativeDir -split '[\\/]') | Where-Object { $_ } | Select-Object -Last 1
    switch ($leaf) {
        'up' { 'one-time' }
        'functions' { 'anytime' }
        'views' { 'anytime' }
        'sprocs' { 'anytime' }
        'runAfterOtherAnyTimeScripts' { 'anytime' }
        'runAfterCreateDatabase' { 'anytime' }
        'permissions' { 'everytime' }
        default { 'other' }
    }
}

$forbiddenTokens = @('spCMArtikelNeu', 'spCMArtikel', 'RoboticoEKL')

# --------------------------------------------------------------------------
# Main chains: eazybusiness/ + global/
# --------------------------------------------------------------------------
$chainDirs = @('eazybusiness', 'global') |
    ForEach-Object { Join-Path $migrationsRoot $_ } |
    Where-Object { Test-Path $_ }

$sqlFiles = @()
foreach ($d in $chainDirs) {
    $sqlFiles += Get-ChildItem -Path $d -Recurse -Filter '*.sql' -File
}

foreach ($f in $sqlFiles) {
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('/', '\')
    $raw = Get-Content -Raw -Path $f.FullName
    if ($null -eq $raw) { $raw = '' }
    $code = Remove-SqlComments $raw
    $dirClass = Get-FolderClass (Split-Path -Parent $f.FullName)
    $baseName = $f.BaseName

    # (a) no USE statement
    if ($code -match '(?im)^\s*USE\s+') {
        Add-Error $rel 'a' 'contains a USE statement (grate selects the target DB itself)'
    }

    # (b) no GO;  (batch separator must be GO alone on its line)
    if ($code -match '(?im)^\s*GO\s*;') {
        Add-Error $rel 'b' "uses 'GO;' — the batch separator must be 'GO' alone on a line"
    }

    # (d) forbidden references (outside comments)
    foreach ($tok in $forbiddenTokens) {
        if ($code -match [regex]::Escape($tok)) {
            Add-Error $rel 'd' "references '$tok' (excel_ekl territory / vendor boundary — D10)"
            break
        }
    }
    if ($code -match '(?i)DROP\s+SCHEMA') {
        Add-Error $rel 'd' 'contains DROP SCHEMA (never drop a shared/vendor schema)'
    }
    if ($code -match '(?i)TRUNCATE\s+TABLE\s+dbo\.') {
        Add-Error $rel 'd' 'contains TRUNCATE TABLE dbo.<…> (destructive against vendor tables)'
    }

    # (c)+(e) naming + single-object rules
    switch ($dirClass) {
        'one-time' {
            # (e) up/ files: NNNN_snake_case.sql
            if ($baseName -notmatch '^[0-9]{4}_[a-z0-9_]+$') {
                Add-Error $rel 'e' "one-time script name must match NNNN_snake_case (got '$baseName')"
            }
        }
        'anytime' {
            # (e) anytime files: Schema.Object.sql
            if ($baseName -notmatch '^[A-Za-z][A-Za-z0-9]*\.[A-Za-z_][A-Za-z0-9_]*$') {
                Add-Error $rel 'e' "anytime script name must match Schema.Object (got '$baseName')"
            }
            # (c) exactly one main CREATE object (function/view/procedure)
            $createMatches = [regex]::Matches($code, '(?im)\bCREATE\s+(?:OR\s+ALTER\s+)?(FUNCTION|VIEW|PROCEDURE|PROC)\s+(\[?[A-Za-z][A-Za-z0-9]*\]?\.\[?[A-Za-z_][A-Za-z0-9_]*\]?)')
            if ($createMatches.Count -eq 0) {
                Add-Error $rel 'c' 'anytime script contains no CREATE [OR ALTER] FUNCTION/VIEW/PROCEDURE'
            }
            elseif ($createMatches.Count -gt 1) {
                Add-Error $rel 'c' "anytime script contains $($createMatches.Count) CREATE objects — exactly one allowed"
            }
            else {
                $created = $createMatches[0].Groups[2].Value -replace '[\[\]]', ''
                if ($created -ne $baseName) {
                    Add-Error $rel 'c' "CREATE object '$created' does not match filename '$baseName'"
                }
            }
        }
        'everytime' {
            if ($baseName -notmatch '^[0-9]{3}_[a-z0-9_]+$') {
                Add-Warning $rel 'e' "everytime (permissions) script name should match NNN_snake_case (got '$baseName')"
            }
        }
    }

    # (g) dynamic-SQL heuristic: data concatenated into an EXEC-string. Only fires
    # inside an actual string-execution context — EXEC(<string>) or sp_executesql —
    # NOT for ordinary proc calls (EXEC sp_foo, EXEC schema.proc) or PRINT/URL
    # string building. Within each such context window it flags '+ @var' that is
    # not wrapped in QUOTENAME (object/DB names must go through QUOTENAME; data
    # values must be sp_executesql parameters).
    $execContexts = [regex]::Matches($code, '(?i)(?:EXEC(?:UTE)?\s*\(|sp_executesql)')
    foreach ($ctxMatch in $execContexts) {
        $winStart = $ctxMatch.Index
        $winLen = [Math]::Min(600, $code.Length - $winStart)
        $window = $code.Substring($winStart, $winLen)
        foreach ($m in [regex]::Matches($window, '(?i)\+\s*(@[A-Za-z0-9_]+)')) {
            $var = $m.Groups[1].Value
            $near = $window.Substring([Math]::Max(0, $m.Index - 40),
                        [Math]::Min(80, $window.Length - [Math]::Max(0, $m.Index - 40)))
            if ($near -notmatch '(?i)QUOTENAME') {
                Add-Warning $rel 'g' "possible data concatenation into dynamic SQL near '$var' (use sp_executesql params / QUOTENAME)"
            }
        }
    }
}

# --------------------------------------------------------------------------
# up/ numbering: the 4-digit prefix must be unique per chain. grate runs
# one-time scripts in filename order and tracks them by hash, so a duplicate
# NNNN is an ordering hazard the per-file shape check (rule e) cannot catch.
# --------------------------------------------------------------------------
foreach ($d in $chainDirs) {
    $upDir = Join-Path $d 'up'
    if (-not (Test-Path $upDir)) { continue }
    $seenPrefixes = @{}
    foreach ($f in (Get-ChildItem -Path $upDir -Filter '*.sql' -File | Sort-Object Name)) {
        if ($f.BaseName -match '^([0-9]{4})_') {
            $prefix = $Matches[1]
            $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('/', '\')
            if ($seenPrefixes.ContainsKey($prefix)) {
                Add-Error $rel 'e' "duplicate up/ number prefix '$prefix' (already used by '$($seenPrefixes[$prefix])')"
            }
            else {
                $seenPrefixes[$prefix] = $rel
            }
        }
    }
}

# --------------------------------------------------------------------------
# (f) §6 cleanup scripts: no un-commented writing statement
# --------------------------------------------------------------------------
$cleanupDir = Join-Path $repoRoot 'Berechtigungen/cleanup'
if (Test-Path $cleanupDir) {
    $writeVerb = '(?im)^\s*(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|GRANT|REVOKE|DENY|TRUNCATE|EXEC|EXECUTE)\b'
    foreach ($f in (Get-ChildItem -Path $cleanupDir -Recurse -Filter '*.sql' -File)) {
        $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('/', '\')
        $code = Remove-SqlComments (Get-Content -Raw -Path $f.FullName)
        # Block-comment /* … */ writes are also inert; Remove-SqlComments already stripped them.
        if ($code -match $writeVerb) {
            Add-Error $rel 'f' "cleanup script has an un-commented writing statement ('$($Matches[1])') — must be commented for manual review"
        }
    }
}

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
Write-Host ''
Write-Host "lint-migrations: scanned $($sqlFiles.Count) file(s) under db-migrations/{eazybusiness,global}"

foreach ($w in $warnings) { Write-Host $w -ForegroundColor Yellow }
foreach ($e in $errors) { Write-Host $e -ForegroundColor Red }

Write-Host ''
if ($errors.Count -gt 0) {
    Write-Host "FAIL: $($errors.Count) error(s), $($warnings.Count) warning(s)." -ForegroundColor Red
    exit 1
}
Write-Host "OK: 0 errors, $($warnings.Count) warning(s)." -ForegroundColor Green
exit 0
