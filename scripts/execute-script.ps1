param(
    [Parameter(Mandatory=$false)]
    [string]$FilePath = $null
,
    [Parameter()]
    [switch]$Force = $false
)

$ErrorActionPreference = 'Stop'

if (-not $FilePath) {
    Write-Host "Usage: docker compose run --rm db execute <path-to-sql-file> [options]"
    Write-Host ""
    Write-Host "Executes a SQL script against the database with object pre-validation."
    Write-Host ""
    Write-Host "Directories:"
    Write-Host "  migrations/  -> Use for structural alterations (ALTER TABLE, DDL migrations)."
    Write-Host "  temp/        -> Use for disposable queries or one-off data updates/fixes."
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  docker compose run --rm db execute ./migrations/20261030_01_add_column.sql"
    Write-Host "  docker compose run --rm db execute 20261030_01_add_column.sql"
    Write-Host "  docker compose run --rm db execute ./temp/check_data.sql"
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

# Resolve script path (checks current directory, migrations/, temp/)
$resolvedPath = $null
$candidates = @(
    $FilePath,
    (Join-Path (Get-Location) $FilePath),
    (Join-Path '/app' $FilePath),
    (Join-Path '/app/migrations' $FilePath),
    (Join-Path (Get-Location) "migrations/$FilePath"),
    (Join-Path '/app/migrations' "$FilePath.sql"),
    (Join-Path (Get-Location) "migrations/$FilePath.sql"),
    (Join-Path '/app/temp' $FilePath),
    (Join-Path (Get-Location) "temp/$FilePath"),
    (Join-Path '/app/temp' "$FilePath.sql")
)

foreach ($c in $candidates) {
    if ($c -and (Test-Path $c -PathType Leaf)) {
        $resolvedPath = (Resolve-Path $c).Path
        break
    }
}

if (-not $resolvedPath) {
    Write-Host "File not found: $FilePath" -ForegroundColor Red
    Write-Host "Searched in: current path, migrations/, and temp/"
    exit 1
}

$content = Get-Content $resolvedPath -Raw
if (-not $content) {
    Write-Host "Empty file: $resolvedPath" -ForegroundColor Red
    exit 1
}

$isTemp = $resolvedPath -match '[/\\\\]temp[/\\\\]'
$isMigration = $resolvedPath -match '[/\\\\]migrations[/\\\\]'
$hasAlter = $content -match '(?i)\bALTER\s+TABLE\b'
$hasCreateTable = $content -match '(?i)\bCREATE\s+TABLE\b'
$hasDropTable = $content -match '(?i)\bDROP\s+TABLE\b'

# Check architecture convention
if ($isTemp -and ($hasAlter -or $hasCreateTable -or $hasDropTable)) {
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host "⚠️  ARCHITECTURE & WORKFLOW WARNING:" -ForegroundColor Yellow
    Write-Host "This script contains structural database alterations (DDL)," -ForegroundColor Yellow
    Write-Host "but is located in 'temp/' (which is ignored by Git)." -ForegroundColor Yellow
    Write-Host "-> RULE: ALTER/migration scripts MUST be saved in 'migrations/'" -ForegroundColor Yellow
    Write-Host "   to preserve traceability and reproducibility across environments." -ForegroundColor Yellow
    Write-Host "   The 'temp/' directory is strictly for read queries or" -ForegroundColor Yellow
    Write-Host "   temporary data fixes/updates (DML)." -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "Connecting to SQL Server instance '$sqlInstance' (Database: '$database')..."
$server = Connect-DbaInstance @connectParams

Write-Host ""
Write-Host "========================================="
Write-Host "OBJECT PRE-VALIDATION IN DATABASE"
Write-Host "========================================="
Write-Host "Script: $resolvedPath"
Write-Host ""

# Inspect targeted objects in script
$tableMatches = [regex]::Matches($content, '(?i)\b(?:ALTER|DROP|CREATE)\s+TABLE\s+(?:\[?(\w+)\]?\.)?\[?(\w+)\]?')
$inspectedTables = [System.Collections.Generic.HashSet[string]]::new()
$validationErrors = 0
$validationWarnings = 0

foreach ($match in $tableMatches) {
    $schemaPart = $match.Groups[1].Value
    $tablePart = $match.Groups[2].Value
    $fullKey = "$schemaPart.$tablePart".ToLowerInvariant()

    if ($inspectedTables.Contains($fullKey)) { continue }
    $inspectedTables.Add($fullKey) | Out-Null

    $targetSchema = if ($schemaPart) { $schemaPart } else { 'dbo' }
    $targetTable = $tablePart

    $checkSql = @"
SELECT 
    s.name AS SchemaName, 
    t.name AS TableName, 
    t.create_date, 
    t.modify_date,
    ISNULL((SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)), 0) AS TotalRows
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name = '$targetSchema' AND t.name = '$targetTable'
"@
    $dbTable = $null
    try {
        $dbTable = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $checkSql
    } catch {
        Write-Warning "Could not query sys.tables: $_"
    }

    Write-Host "Analyzed Object: [$targetSchema].[$targetTable]" -ForegroundColor Cyan
    if ($dbTable) {
        Write-Host "  State in DB  : EXISTS (User Table)" -ForegroundColor Green
        Write-Host "  Rows in DB   : $($dbTable.TotalRows)"
        Write-Host "  Created in DB: $($dbTable.create_date)"
        Write-Host "  Last Mod.    : $($dbTable.modify_date)"

        # Check column additions if any
        $colAddMatches = [regex]::Matches($content, '(?i)ADD\s+(?:COLUMN\s+)?\[?(\w+)\]?')
        foreach ($cMatch in $colAddMatches) {
            $colName = $cMatch.Groups[1].Value
            $colCheck = @"
SELECT c.name, TYPE_NAME(c.user_type_id) AS TypeName
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name = '$targetSchema' AND t.name = '$targetTable' AND c.name = '$colName'
"@
            $colExists = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $colCheck
            if ($colExists) {
                Write-Host "  ⚠️ Column Warning: Column '$colName' ALREADY EXISTS in table (Type: $($colExists.TypeName)). The ALTER ADD will fail unless an idempotency check is used." -ForegroundColor Yellow
                $validationWarnings++
            } else {
                Write-Host "  ✓ Column Check  : Column '$colName' does not exist yet (safe to add)." -ForegroundColor Green
            }
        }
    } else {
        if ($match.Value -match '(?i)CREATE\s+TABLE') {
            Write-Host "  State in DB  : DOES NOT EXIST (Valid to create as a new table)" -ForegroundColor Green
        } else {
            Write-Host "  ❌ ERROR: Table [$targetSchema].[$targetTable] DOES NOT EXIST in database '$database'." -ForegroundColor Red
            Write-Host "     Any ALTER or DROP operation on this table will fail." -ForegroundColor Red
            $validationErrors++
        }
    }
    Write-Host ""
}

if ($inspectedTables.Count -eq 0) {
    Write-Host "No explicit tables detected in script (likely DML, indexes, SPs, or general queries)."
    Write-Host ""
}

Write-Host "Script preview (first 500 characters):"
Write-Host "--------------------------------------"
$preview = if ($content.Length -gt 500) { $content.Substring(0, 500) + "..." } else { $content }
Write-Host $preview
Write-Host "--------------------------------------"
Write-Host ""

if ($validationErrors -gt 0) {
    Write-Host "⚠️ ATTENTION: Detected $validationErrors validation error(s) during object pre-check." -ForegroundColor Red
}

$confirmation = 'yes'
if (-not $Force) {
    $confirmation = Read-Host "Do you want to execute this script against database '$database'? (yes/no)"
}
if ($confirmation -ne 'yes') {
    Write-Host "Execution cancelled by user."
    exit 0
}

Write-Host ""
Write-Host "Executing script..." -ForegroundColor Cyan

try {
    Invoke-DbaQuery -SqlInstance $server -Database $database -Query $content
    Write-Host "✓ Script executed successfully." -ForegroundColor Green
    if ($hasAlter -or $hasCreateTable -or $hasDropTable) {
        Write-Host ""
        Write-Host "ℹ️ Reminder: Structural table modifications were applied." -ForegroundColor Cyan
        Write-Host "  Run 'docker compose run --rm db export --force' to refresh local definitions in 'sql/tables/'." -ForegroundColor Cyan
    }
} catch {
    Write-Host "❌ Error executing script: $_" -ForegroundColor Red
    exit 1
}
