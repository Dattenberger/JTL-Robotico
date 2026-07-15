<#
.SYNOPSIS
    Convention lint for the JTL-Robotico grate migrations — the executable form of
    db-migrations/README.md.

.DESCRIPTION
    Recursively checks every *.sql under db-migrations/eazybusiness and
    db-migrations/global against the hard rules (a)-(l) documented in
    db-migrations/README.md §4 (incl. up/-number uniqueness per chain), plus the
    §6 cleanup-script rule (f) against Berechtigungen/cleanup (when that
    directory exists).

    Runs under Linux `pwsh` and Windows PowerShell. Exit code 0 = clean,
    1 = at least one ERROR (WARNINGs alone do not fail the run).
    Rule (i) additionally needs `git` and a work tree; it degrades silently to
    a no-op when either is absent (e.g. linting an exported copy via -Path).

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

# Rule (i) escape hatch: repo-relative up/ paths (as `git status --porcelain` prints
# them) that are ACKNOWLEDGED as edited although already tracked — permissible ONLY for
# scripts that have provably never been applied anywhere (still in authoring). Each entry
# carries its reason and is reported as a WARNING instead of an ERROR. Bulk local
# iteration can alternatively set $env:LINT_ALLOW_UP_EDITS = '1'.
$upEditAcknowledged = @{
    # 'db-migrations/global/up/0042_example.sql' = 'authoring 2026-07-…; not yet deployed anywhere'
}

# Rule (k) collector: THROW numbers per chain (key "<chain>|<number>" -> set of files).
$throwNumbers = @{}

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

    # (h) no ambiguous dashed date/datetime literal. A 'YYYY-MM-DD' string is parsed
    # against the session's language / DATEFORMAT, so on a non-US login (German test1 =
    # dmy) it is read year-day-month and throws (error 190 on CREATE CERTIFICATE
    # EXPIRY_DATE — the 2026-07-13 test1 incident, which passed the us_english E2E
    # container silently). The same DATEFORMAT trap hits the space-separated datetime
    # form 'YYYY-MM-DD hh:mm[:ss]'. Language-neutral and therefore allowed: the basic
    # ISO form 'YYYYMMDD' and the ISO-8601 'T' form 'YYYY-MM-DDThh:mm:ss'. (Comments are
    # already stripped, so header/@see dates never trip this.)
    foreach ($m in [regex]::Matches($code, "'(\d{4})-(\d{2})-(\d{2})([^']*)'")) {
        $iso = $m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value
        $rest = $m.Groups[4].Value
        if ($rest -eq '') {
            Add-Error $rel 'h' "ambiguous dashed date literal $($m.Value) — use the language-neutral basic ISO form '$iso' (a dashed 'YYYY-MM-DD' is reparsed under DATEFORMAT dmy)"
        }
        elseif ($rest -match '^ \d{1,2}:\d{2}') {
            Add-Error $rel 'h' "ambiguous dashed datetime literal $($m.Value) — the space-separated form is reparsed under DATEFORMAT dmy; use the ISO-8601 'T' form ('YYYY-MM-DDThh:mm:ss') or the basic form ('$iso hh:mm:ss')"
        }
        # 'YYYY-MM-DDThh:mm:ss' (ISO 8601 with 'T') is language-neutral — allowed.
    }

    # (j) Ebene-B pipeline steps: uniform contract + clone guard before the first
    # write/EXEC (README §9 recipe; D6). Applies to global/sprocs/reset.spInternal_*
    # except the spInternal_LogStep helper (no @TargetDb, writes only ops.tResetRequest).
    if ($f.FullName -match '[\\/]global[\\/]sprocs[\\/]reset\.spInternal_[^\\/]+\.sql$' -and
        $baseName -ne 'reset.spInternal_LogStep') {

        if ($code -notmatch '(?is)@TargetDb\s+sysname\s*,\s*@RequestId\s+int\s*,\s*@MandantKey\s+sysname') {
            Add-Error $rel 'j' "pipeline step lacks the uniform contract (@TargetDb sysname, @RequestId int, @MandantKey sysname) — the orchestrator calls every step exactly this way (README §9)"
        }

        $guard = [regex]::Match($code, "(?i)NOT\s+LIKE\s+N'eazybusiness\[_\]%'")
        if (-not $guard.Success) {
            Add-Error $rel 'j' "pipeline step lacks the clone guard (IF @TargetDb = N'eazybusiness' OR @TargetDb NOT LIKE N'eazybusiness[_]%' THROW 51xxx) — a step without it runs against ANY database under job sysadmin rights (README §9, D6)"
        }
        else {
            $firstWrite = [regex]::Match($code, '(?im)^\s*(UPDATE|DELETE|INSERT|MERGE|EXEC(?:UTE)?)\b')
            if ($firstWrite.Success -and $firstWrite.Index -lt $guard.Index) {
                Add-Error $rel 'j' "clone guard appears AFTER the first write/EXEC ('$($firstWrite.Groups[1].Value)') — the guard must be the first executable statement (README §9, D6)"
            }
        }
    }

    # (k) collect THROW numbers for the per-chain uniqueness check below.
    $chainName = ($f.FullName.Substring($migrationsRoot.Length).TrimStart('/', '\') -split '[\\/]')[0]
    foreach ($m in [regex]::Matches($code, '(?i)\bTHROW\s+(\d{5})\b')) {
        $key = "$chainName|$($m.Groups[1].Value)"
        if (-not $throwNumbers.ContainsKey($key)) {
            $throwNumbers[$key] = New-Object System.Collections.Generic.HashSet[string]
        }
        [void]$throwNumbers[$key].Add($rel)
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
# (i) up/ immutability: no uncommitted edits to a git-TRACKED up/ script.
# This is exactly the QG3-C1 incident shape: an applied one-time script edited in
# place breaks the next deploy with a grate hash-mismatch — the correct move is a
# NEW NNNN script (README §2 CAUTION). Untracked/staged-new files are authoring and
# fine. Commit history is deliberately NOT checked: pre-first-apply iteration on a
# feature branch is legitimate, and grate's hash check stays the deploy-time backstop.
# Degrades to a no-op when git or a work tree is unavailable (-Path exports).
# --------------------------------------------------------------------------
$gitTop = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitTop = & git -C $migrationsRoot rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { $gitTop = $null }
}
if ($gitTop) {
    $gitTopNorm = "$gitTop" -replace '\\', '/'
    $upPathspecs = @()
    foreach ($d in $chainDirs) {
        $upDir = Join-Path $d 'up'
        if (Test-Path $upDir) {
            $upNorm = (Resolve-Path $upDir).Path -replace '\\', '/'
            if ($upNorm.StartsWith($gitTopNorm)) {
                $upPathspecs += $upNorm.Substring($gitTopNorm.Length).TrimStart('/')
            }
        }
    }
    if ($upPathspecs.Count -gt 0) {
        $porcelain = & git -C $gitTop status --porcelain -- @upPathspecs 2>$null
        foreach ($line in @($porcelain)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $xy = $line.Substring(0, 2)
            if ($xy -eq '??') { continue }              # untracked: new script in authoring
            if ($xy -notmatch '[MDR]') { continue }     # staged-new (A) etc.: fine
            $p = $line.Substring(3).Trim('"')
            if ($p -match '->') { $p = ($p -split '->')[-1].Trim().Trim('"') }
            $msg = "tracked up/ script has uncommitted modifications ($($xy.Trim())) — up/ scripts are immutable once applied; add a NEW NNNN_… script instead (README §4 rule i / §2 CAUTION)"
            if ($upEditAcknowledged.ContainsKey($p)) {
                Add-Warning $p 'i' "acknowledged up/ edit ($($upEditAcknowledged[$p])) — ensure the script has NEVER been applied anywhere"
            }
            elseif ($env:LINT_ALLOW_UP_EDITS -eq '1') {
                Add-Warning $p 'i' "$msg [downgraded: LINT_ALLOW_UP_EDITS=1]"
            }
            else {
                Add-Error $p 'i' $msg
            }
        }
    }
}

# --------------------------------------------------------------------------
# (k) THROW numbers unique per chain (numbers double as step identifiers in
# errors/logs — allocation table: README §4 rule k). Re-use of the same number
# WITHIN one file is fine; the same number in two files is the ambiguity.
# --------------------------------------------------------------------------
foreach ($entry in ($throwNumbers.GetEnumerator() | Sort-Object Key)) {
    if ($entry.Value.Count -gt 1) {
        $chainName, $num = $entry.Key -split '\|'
        $files = ($entry.Value | Sort-Object) -join ', '
        Add-Error $files 'k' "THROW number $num is used in multiple files of the '$chainName' chain — numbers must be unique per chain (README §4 rule k)"
    }
}

# --------------------------------------------------------------------------
# (l) every global/ proc is registered in tests/global/validate_structure.sql —
# a deployed but unregistered proc silently escapes the rollout gate (README §9
# step 3). Skipped when the structure test is absent (-Path exports).
# --------------------------------------------------------------------------
$structureSql = Join-Path $migrationsRoot 'tests/global/validate_structure.sql'
if (Test-Path $structureSql) {
    $structText = Get-Content -Raw -Path $structureSql
    foreach ($dirName in @('sprocs', 'runAfterOtherAnyTimeScripts')) {
        $dir = Join-Path (Join-Path $migrationsRoot 'global') $dirName
        if (-not (Test-Path $dir)) { continue }
        foreach ($f in (Get-ChildItem -Path $dir -Filter '*.sql' -File)) {
            $obj = $f.BaseName
            $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('/', '\')
            if ($structText -notmatch [regex]::Escape("N'$obj'")) {
                Add-Error $rel 'l' "object '$obj' is missing from the required-objects list in tests/global/validate_structure.sql (README §9 step 3)"
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
