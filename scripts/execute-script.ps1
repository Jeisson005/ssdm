param(
    [Parameter(Mandatory=$false)]
    [string]$FilePath = $null
,
    [Parameter()]
    [switch]$Force = $false
)

$ErrorActionPreference = 'Stop'

if (-not $FilePath) {
    Write-Host "Usage: docker compose run --rm db execute <path-to-sql-file>"
    Write-Host ""
    Write-Host "Executes a custom SQL script against the database."
    Write-Host "Prompts for confirmation before executing."
    Write-Host ""
    Write-Host "Example:"
    Write-Host "  docker compose run --rm db execute ./temp/migration.sql"
    exit 1
}

function Get-EnvValue {
    param(
        [string]$EnvName,
        [switch]$Required
    )

    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if ($null -ne $envValue -and $envValue -ne '') {
        return $envValue
    }

    if ($Required) {
        throw "Missing required configuration: $EnvName"
    }

    return $null
}

$instance = Get-EnvValue -EnvName 'SQL_HOST' -Required
$port = Get-EnvValue -EnvName 'SQL_PORT'
$user = Get-EnvValue -EnvName 'SQL_USER'
$password = Get-EnvValue -EnvName 'SQL_PASSWORD'
$database = Get-EnvValue -EnvName 'SQL_DATABASE' -Required
$trustServerCertificate = Get-EnvValue -EnvName 'SQL_TRUST_CERT'

$sqlInstance = if ($port) { "$instance,$port" } else { $instance }

$connectParams = @{
    SqlInstance = $sqlInstance
    Database = $database
    TrustServerCertificate = ($trustServerCertificate -eq 'true')
}

if ($user) {
    if (-not $password) {
        throw "SQL_PASSWORD is required when SQL_USER is set"
    }
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($user, $securePassword)
    $connectParams.SqlCredential = $credential
}

$resolvedPath = if ([System.IO.Path]::IsPathRooted($FilePath)) {
    $FilePath
} else {
    Join-Path (Get-Location) $FilePath
}

if (-not (Test-Path $resolvedPath)) {
    Write-Host "File not found: $resolvedPath"
    exit 1
}

$content = Get-Content $resolvedPath -Raw
if (-not $content) {
    Write-Host "Empty file: $resolvedPath"
    exit 1
}

Write-Host "File: $resolvedPath"
Write-Host ""
Write-Host "Content preview (first 500 chars):"
Write-Host "-----------------------------------"
$preview = if ($content.Length -gt 500) { $content.Substring(0, 500) + "..." } else { $content }
Write-Host $preview
Write-Host ""
Write-Host "-----------------------------------"
Write-Host ""

$confirmation = 'yes'
if (-not $Force) {
    $confirmation = Read-Host "Do you want to execute this script against database '$database'? (yes/no)"
}
if ($confirmation -ne 'yes') {
    Write-Host "Execution cancelled."
    exit 0
}

Write-Host "Executing script..."
$server = Connect-DbaInstance @connectParams

try {
    Invoke-DbaQuery -SqlInstance $server -Database $database -Query $content
    Write-Host "Script executed successfully."
} catch {
    Write-Host "Error executing script: $_"
    exit 1
}