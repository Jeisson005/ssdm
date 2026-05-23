param(
    [Parameter()]
    [string]$FilePath = $null
,
    [Parameter()]
    [switch]$Force = $false
)

$ErrorActionPreference = 'Stop'

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

$server = Connect-DbaInstance @connectParams

$sqlDir = '/app/sql'

if ($FilePath) {
    $resolvedPath = if ([System.IO.Path]::IsPathRooted($FilePath)) {
        $FilePath
    } else {
        Join-Path (Get-Location) $FilePath
    }
    if (-not (Test-Path $resolvedPath)) {
        Write-Host "File not found: $resolvedPath"
        exit 1
    }
    if ($resolvedPath -match '/sql/tables/') {
        Write-Host "Tables cannot be synced via this command. Use 'execute' with ALTER scripts instead."
        exit 1
    }
    $changedFiles = @($resolvedPath)
} else {
    Write-Host "Getting changed files from git..."
    $gitResult = git diff --cached --name-only HEAD
    if (-not $gitResult) {
        Write-Host "No changes detected in git diff"
        exit 0
    }
    $changedFiles = $gitResult | Where-Object { $_ -match '\.(sql)$' } | ForEach-Object {
        $fullPath = Join-Path (Get-Location) $_
        if (Test-Path $fullPath) { $fullPath }
    } | Where-Object { $_ -notmatch '/sql/tables/' }
}

if ($changedFiles.Count -eq 0) {
    Write-Host "No SQL files to sync."
    exit 0
}

$typeOrder = @{
    'sql/tables' = 1
    'sql/storedprocedures' = 2
    'sql/functions' = 3
    'sql/views' = 4
    'default' = 5
}

$sortedFiles = $changedFiles | Sort-Object {
    $dir = Split-Path -Parent $_
    $typeOrder[$dir] ?? $typeOrder['default']
}

$summary = @{}
foreach ($file in $sortedFiles) {
    $relativePath = $file.Replace((Get-Location).Path + '/', '').Replace((Get-Location).Path + '\', '')
    $dir = Split-Path -Parent $relativePath
    $fileName = Split-Path -Leaf $relativePath
    $typeLabel = switch ($dir) {
        'sql/tables' { 'Tables' }
        'sql/views' { 'Views' }
        'sql/storedprocedures' { 'Stored Procedures' }
        'sql/functions' { 'Functions' }
        default { 'Other' }
    }
    if (-not $summary[$typeLabel]) {
        $summary[$typeLabel] = @()
    }
    $summary[$typeLabel] += $fileName
}

Write-Host ""
Write-Host "========================================="
Write-Host "SYNC SUMMARY"
Write-Host "========================================="
Write-Host ""
Write-Host "Total files: $($sortedFiles.Count)"
Write-Host ""
foreach ($type in @('Tables', 'Views', 'Stored Procedures', 'Functions', 'Other')) {
    if ($summary[$type]) {
        Write-Host "$($type): $($summary[$type].Count)"
        $summary[$type] | ForEach-Object { Write-Host "  - $_" }
        Write-Host ""
    }
}

Write-Host "-----------------------------------------"
Write-Host ""
Write-Host "Files to sync:"
$sortedFiles | ForEach-Object {
    $relativePath = $_ -replace [regex]::Escape((Get-Location).Path), ''
    $relativePath = $relativePath -replace '^[/\\]', ''
    Write-Host "  $relativePath"
}
Write-Host ""

$confirmation = 'yes'
if (-not $Force) {
    $confirmation = Read-Host "Do you want to proceed with sync? (yes/no)"
}
if ($confirmation -ne 'yes') {
    Write-Host "Sync cancelled."
    exit 0
}

$successCount = 0
$errorCount = 0

foreach ($file in $sortedFiles) {
    $relativePath = $file.Replace((Get-Location).Path + '/', '').Replace((Get-Location).Path + '\', '')
    $content = Get-Content $file -Raw
    if (-not $content) {
        Write-Warning "Empty file: $file"
        continue
    }

    $dir = Split-Path -Parent $relativePath
    $fileName = Split-Path -Leaf $relativePath
    $objectType = switch ($dir) {
        'sql/tables' { 'table' }
        'sql/views' { 'view' }
        'sql/storedprocedures' { 'procedure' }
        'sql/functions' { 'function' }
        default { 'unknown' }
    }

    Write-Host ""
    Write-Host "Syncing: $relativePath"

    $fileSuccess = $true

    try {
        if ($objectType -eq 'table') {
            $tableName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $parts = $tableName -split '\.'
            if ($parts.Count -ne 2) {
                Write-Warning "  Invalid table file name format: $tableName (expected schema.tablename.sql)"
                continue
            }
            $schemaName = $parts[0]
            $tableNameOnly = $parts[1]

            $checkSql = "SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = '$schemaName' AND t.name = '$tableNameOnly'"
            $exists = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $checkSql

            if ($exists) {
                Write-Host "  Table '$schemaName.$tableNameOnly' exists - skipping (use 'execute' with ALTER script instead)"
                continue
            }

            Write-Host "  Creating table..."
            Invoke-DbaQuery -SqlInstance $server -Database $database -Query $content

        } elseif ($objectType -in @('view', 'procedure', 'function')) {
            $objName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $objTypeSql = switch ($objectType) {
                'view' { 'V' }
                'procedure' { 'P' }
                'function' { 'FN' }
            }
            $checkSql = "SELECT 1 FROM sys.objects WHERE name = '$objName' AND type = '$objTypeSql'"
            $exists = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $checkSql

            if ($exists) {
                Write-Host "  Object '$objName' exists - dropping and recreating..."
                $dropSql = "DROP $($objectType.ToUpper()) [$objName]"
                Invoke-DbaQuery -SqlInstance $server -Database $database -Query $dropSql
            }

            $createOrAlterSql = $content -replace '\bCREATE\b', 'CREATE OR ALTER'
            Invoke-DbaQuery -SqlInstance $server -Database $database -Query $createOrAlterSql
        } else {
            Write-Host "  Unknown object type, executing as-is..."
            Invoke-DbaQuery -SqlInstance $server -Database $database -Query $content
        }

        Write-Host "  Success: $relativePath"
        $successCount++

    } catch {
        Write-Host "  Error syncing $relativePath`: $_"
        $errorCount++
        $fileSuccess = $false
    }
}

Write-Host ""
Write-Host "========================================="
Write-Host "SYNC COMPLETED"
Write-Host "========================================="
Write-Host "Success: $successCount"
Write-Host "Errors: $errorCount"