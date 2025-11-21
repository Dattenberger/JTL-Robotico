<#
.SYNOPSIS
    Sets up the JTL test environment by running a sequence of SQL scripts.

.DESCRIPTION
    This script orchestrates the refresh of the test database.
    It executes the following SQL scripts in order:
    1. copy_test_db.sql (Clones source DB to target DB)
    2. invalidate-credentials-for-testing.sql (Deactivates passwords/emails)
    3. clear-customer-fields.sql (Anonymizes customer data)
    4. grant-database-access.sql (Grants access to the developer user)

    The script stops immediately if any SQL script fails.

.PARAMETER EasyBusinessMandant
    The suffix for the target database (e.g., 'tm2', 'tm3').
    The full database name will be 'eazybusiness_' + EasyBusinessMandant.
    Default is 'tm2'.

.PARAMETER LoginName
    The SQL Server login name to grant access to the test database.
    Default is 'dbuser_dev_dana_for_development'.

.PARAMETER ServerInstance
    The SQL Server instance to connect to. Default is 'localhost'.

.EXAMPLE
    .\setup-test-environment.ps1 -EasyBusinessMandant tm3
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$EasyBusinessMandant = 'tm2',

    [Parameter(Mandatory = $false)]
    [string]$LoginName = 'dbuser_dev_dana_for_development',

    [Parameter(Mandatory = $false)] 
    [string]$ServerInstance = 'VM-SQL2'
)

$ErrorActionPreference = "Stop"
$ScriptDirectory = $PSScriptRoot

# Check if sqlcmd is available
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "ERROR: 'sqlcmd' is not found in your PATH." -ForegroundColor Red
    Write-Host "Please install 'Command Line Tools for SQL Server'." -ForegroundColor Red
    Write-Host "You can install it via winget: winget install Microsoft.SQLServer.CommandLineTools" -ForegroundColor Red
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    exit 1
}

# Construct full database name
$TargetDatabase = "eazybusiness_" + $EasyBusinessMandant

# Define the sequence of SQL scripts
$SqlScripts = @(
    # "force-error.sql", # Uncomment to test error handling
    #"copy_test_db.sql",
    "invalidate-credentials-for-testing.sql",
    "clear-customer-fields.sql",
    "grant-database-access.sql"
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Starting Test Environment Setup" -ForegroundColor Cyan
Write-Host "Target Database: $TargetDatabase" -ForegroundColor Yellow
Write-Host "Login Name:      $LoginName" -ForegroundColor Yellow
Write-Host "Server Instance: $ServerInstance" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

foreach ($ScriptName in $SqlScripts) {
    $ScriptPath = Join-Path $ScriptDirectory $ScriptName

    if (-not (Test-Path $ScriptPath)) {
        Write-Error "Script file not found: $ScriptPath"
        exit 1
    }

    Write-Host "Executing: $ScriptName ..." -ForegroundColor Green

    # Execute SQL script using sqlcmd
    # -b: On error, exit
    # -v: Define variables
    # -E: Trusted connection (Windows Auth)
    # -S: Server instance
    # -i: Input file
    & sqlcmd -S $ServerInstance -E -b -v TargetDb="$TargetDatabase" -v LoginName="$LoginName" -i "$ScriptPath"

    # Check exit code
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host "ERROR: Execution failed at script '$ScriptName'" -ForegroundColor Red
        Write-Host "Exit Code: $LASTEXITCODE" -ForegroundColor Red
        Write-Host "Aborting remaining steps." -ForegroundColor Red
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        exit $LASTEXITCODE
    }

    Write-Host "Successfully executed: $ScriptName" -ForegroundColor Gray
    Write-Host "------------------------------------------" -ForegroundColor Gray
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Test Environment Setup COMPLETED SUCCESSFULLY" -ForegroundColor Cyan
Write-Host "Target Database: $TargetDatabase" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
