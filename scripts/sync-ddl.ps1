param(
    [Parameter()]
    [string[]]$Targets = @(),

    [Parameter()]
    [string]$FilePath = $null,

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

$sqlDir = if (Test-Path '/app/sql') { '/app/sql' } else { Join-Path (Get-Location) 'sql' }
$allNonTableDirs = @('storedprocedures', 'views', 'functions')

# Consolidate target parameters
if ($FilePath -and $Targets.Count -eq 0) {
    $Targets = @($FilePath)
}

$resolvedFiles = [System.Collections.Generic.List[string]]::new()

function Resolve-Target {
    param([string]$target)

    if (-not $target) { return }

    if ($target -eq '--all') {
        foreach ($sub in $allNonTableDirs) {
            $path = Join-Path $sqlDir $sub
            if (Test-Path $path) {
                Get-ChildItem -Path $path -Filter "*.sql" -File | ForEach-Object { $resolvedFiles.Add($_.FullName) }
            }
        }
        return
    }

    # Clean target string
    $cleanTarget = $target.Trim().Trim('"', "'")
    $lower = $cleanTarget.ToLowerInvariant().TrimEnd('/', '\')

    # Group keywords
    if ($lower -in @('views', 'sql/views', '/app/sql/views')) {
        $path = Join-Path $sqlDir 'views'
        if (Test-Path $path) {
            Get-ChildItem -Path $path -Filter "*.sql" -File | ForEach-Object { $resolvedFiles.Add($_.FullName) }
        }
        return
    }

    if ($lower -in @('storedprocedures', 'procs', 'procedures', 'sql/storedprocedures', '/app/sql/storedprocedures')) {
        $path = Join-Path $sqlDir 'storedprocedures'
        if (Test-Path $path) {
            Get-ChildItem -Path $path -Filter "*.sql" -File | ForEach-Object { $resolvedFiles.Add($_.FullName) }
        }
        return
    }

    if ($lower -in @('functions', 'funcs', 'sql/functions', '/app/sql/functions')) {
        $path = Join-Path $sqlDir 'functions'
        if (Test-Path $path) {
            Get-ChildItem -Path $path -Filter "*.sql" -File | ForEach-Object { $resolvedFiles.Add($_.FullName) }
        }
        return
    }

    # Direct existing path
    $checkPath = if ([System.IO.Path]::IsPathRooted($cleanTarget)) { $cleanTarget } else { Join-Path (Get-Location) $cleanTarget }
    if (Test-Path $checkPath -PathType Leaf) {
        $resolvedFiles.Add((Resolve-Path $checkPath).Path)
        return
    }
    if (Test-Path $checkPath -PathType Container) {
        Get-ChildItem -Path $checkPath -Filter "*.sql" -File | ForEach-Object { $resolvedFiles.Add($_.FullName) }
        return
    }

    # Wildcard search (e.g. "sp_user*" or "dbo.sp_*")
    if ($cleanTarget -match '[\*\?]') {
        $found = @()
        foreach ($sub in $allNonTableDirs) {
            $dirPath = Join-Path $sqlDir $sub
            if (Test-Path $dirPath) {
                $pattern = if ($cleanTarget.EndsWith('.sql')) { $cleanTarget } else { "$cleanTarget.sql" }
                $m = Get-ChildItem -Path $dirPath -Filter $pattern -File -ErrorAction SilentlyContinue
                if (-not $m) {
                    $m = Get-ChildItem -Path $dirPath -Filter "*$cleanTarget*.sql" -File -ErrorAction SilentlyContinue
                }
                if ($m) { $found += $m }
            }
        }
        if ($found.Count -gt 0) {
            $found | ForEach-Object { $resolvedFiles.Add($_.FullName) }
            return
        }
    }

    # Search by Object Name (e.g. "dbo.sp_my_proc" or "sp_my_proc")
    $searchName = $cleanTarget
    if ($searchName.EndsWith('.sql', [System.StringComparison]::OrdinalIgnoreCase)) {
        $searchName = $searchName.Substring(0, $searchName.Length - 4)
    }

    $foundObj = @()
    foreach ($sub in $allNonTableDirs) {
        $dirPath = Join-Path $sqlDir $sub
        if (Test-Path $dirPath) {
            $f1 = Join-Path $dirPath "$searchName.sql"
            if (Test-Path $f1) { $foundObj += $f1 }

            $f2 = Get-ChildItem -Path $dirPath -Filter "*.$searchName.sql" -File -ErrorAction SilentlyContinue
            if ($f2) { $foundObj += ($f2 | ForEach-Object { $_.FullName }) }
        }
    }

    if ($foundObj.Count -gt 0) {
        $foundObj | Select-Object -Unique | ForEach-Object { $resolvedFiles.Add($_) }
        return
    }

    Write-Warning "Could not find any SQL file matching '$cleanTarget'"
}

if ($Targets.Count -gt 0) {
    foreach ($t in $Targets) {
        Resolve-Target -target $t
    }
} else {
    Write-Host "Getting changed files from git diff (--cached HEAD)..."
    $gitResult = git diff --cached --name-only HEAD
    if (-not $gitResult) {
        Write-Host "No staged changes detected in git."
        Write-Host "Tips:"
        Write-Host "  - Stage files with: git add <file>"
        Write-Host "  - Or sync directly: docker compose run --rm db sync <object|group|pattern>"
        exit 0
    }
    $gitResult | Where-Object { $_ -match '\.sql$' } | ForEach-Object {
        $fullPath = Join-Path (Get-Location) $_
        if (Test-Path $fullPath -PathType Leaf) {
            $resolvedFiles.Add((Resolve-Path $fullPath).Path)
        }
    }
}

# Filter out tables and remove duplicates
$changedFiles = $resolvedFiles | Select-Object -Unique | Where-Object {
    if ($_ -match '[/\\\\]sql[/\\\\]tables[/\\\\]') {
        Write-Warning "Skipping table file: $_"
        Write-Warning "Tables cannot be synced via 'sync'. Use 'execute' with an ALTER script in 'migrations/'."
        $false
    } else {
        $true
    }
}

if ($changedFiles.Count -eq 0) {
    Write-Host "No eligible SQL files found to sync."
    exit 0
}

$typeOrder = @{
    'sql/views' = 1
    'sql/functions' = 2
    'sql/storedprocedures' = 3
    'default' = 4
}

$sortedFiles = $changedFiles | Sort-Object {
    $parent = Split-Path -Parent $_
    $normParent = $parent.Replace('\', '/').ToLowerInvariant()
    if ($normParent -match 'sql/views') { 1 }
    elseif ($normParent -match 'sql/functions') { 2 }
    elseif ($normParent -match 'sql/storedprocedures') { 3 }
    else { 4 }
}

Write-Host "Connecting to SQL Server instance '$sqlInstance' (Database: '$database')..."
$server = Connect-DbaInstance @connectParams

Write-Host ""
Write-Host "========================================="
Write-Host "OBJECT PRE-VALIDATION IN DATABASE"
Write-Host "========================================="

$validationDetails = @()
$hasWarnings = $false

foreach ($file in $sortedFiles) {
    $fileName = Split-Path -Leaf $file
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $dotIndex = $baseName.IndexOf('.')
    if ($dotIndex -gt 0) {
        $schemaName = $baseName.Substring(0, $dotIndex)
        $objName = $baseName.Substring($dotIndex + 1)
    } else {
        $schemaName = 'dbo'
        $objName = $baseName
    }

    $parentDir = Split-Path -Parent $file
    $normParent = $parentDir.Replace('\', '/').ToLowerInvariant()
    $typeLabel = if ($normParent -match 'sql/views') { 'VIEW' }
                 elseif ($normParent -match 'sql/storedprocedures') { 'PROCEDURE' }
                 elseif ($normParent -match 'sql/functions') { 'FUNCTION' }
                 else { 'OBJECT' }

    $checkSql = @"
SELECT 
    o.object_id,
    s.name AS SchemaName,
    o.name AS ObjectName,
    o.type,
    o.type_desc,
    o.create_date,
    o.modify_date
FROM sys.objects o
JOIN sys.schemas s ON o.schema_id = s.schema_id
WHERE s.name = '$schemaName' AND o.name = '$objName'
"@

    $dbObj = $null
    try {
        $dbObj = Invoke-DbaQuery -SqlInstance $server -Database $database -Query $checkSql
    } catch {
        Write-Warning "Error checking object in DB: $_"
    }

    $localTime = (Get-Item $file).LastWriteTime
    $statusText = ""
    $warningText = ""

    if ($dbObj) {
        $statusText = "EXISTS IN DB (Type: $($dbObj.type_desc), Created: $($dbObj.create_date), Modified in DB: $($dbObj.modify_date))"
        if ($dbObj.modify_date -and ($dbObj.modify_date -gt $localTime.AddMinutes(1))) {
            $warningText = "⚠️ WARNING: Database version was modified after local file ($($dbObj.modify_date) vs $localTime). You might overwrite external changes."
            $hasWarnings = $true
        }
    } else {
        $statusText = "DOES NOT EXIST IN DB (Will be created as a new object)"
    }

    $validationDetails += [PSCustomObject]@{
        File = $file
        RelativePath = ($file -replace [regex]::Escape((Get-Location).Path), '').TrimStart('/\')
        Schema = $schemaName
        Name = $objName
        Type = $typeLabel
        ExistsInDb = [bool]$dbObj
        Status = $statusText
        Warning = $warningText
    }

    Write-Host ""
    Write-Host "Object: [$schemaName].[$objName] ($typeLabel)" -ForegroundColor Cyan
    Write-Host "  Local file : $($file -replace [regex]::Escape((Get-Location).Path), '').TrimStart('/\')"
    if ($dbObj) {
        Write-Host "  State in DB: $statusText" -ForegroundColor Green
    } else {
        Write-Host "  State in DB: $statusText" -ForegroundColor Yellow
    }
    if ($warningText) {
        Write-Host "  $warningText" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "-----------------------------------------"
Write-Host "OBJECTS TO SYNC SUMMARY ($($validationDetails.Count)):"
$validationDetails | Group-Object Type | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count)"
}
Write-Host "-----------------------------------------"
Write-Host ""

if ($hasWarnings) {
    Write-Host "⚠️ WARNING: Warnings detected regarding newer versions in the database." -ForegroundColor Yellow
}

$confirmation = 'yes'
if (-not $Force) {
    $confirmation = Read-Host "Do you want to proceed with sync to database '$database'? (yes/no)"
}
if ($confirmation -ne 'yes') {
    Write-Host "Sync cancelled by user."
    exit 0
}

Write-Host ""
Write-Host "Applying changes..." -ForegroundColor Cyan

$successCount = 0
$errorCount = 0

foreach ($item in $validationDetails) {
    $file = $item.File
    $content = Get-Content $file -Raw
    if (-not $content) {
        Write-Warning "Empty file: $file"
        continue
    }

    Write-Host ""
    Write-Host "Syncing: $($item.RelativePath) ..." -NoNewline

    try {
        # Transform CREATE to CREATE OR ALTER safely for SPs, Views, Functions, Triggers
        $executableSql = $content
        if ($executableSql -match '(?i)\bCREATE\s+(PROCEDURE|PROC|VIEW|FUNCTION|TRIGGER)\b') {
            $executableSql = $executableSql -replace '(?i)\bCREATE\s+(PROCEDURE|PROC|VIEW|FUNCTION|TRIGGER)\b', 'CREATE OR ALTER $1'
        }

        Invoke-DbaQuery -SqlInstance $server -Database $database -Query $executableSql
        Write-Host " [OK]" -ForegroundColor Green
        $successCount++
    } catch {
        Write-Host " [ERROR]" -ForegroundColor Red
        Write-Host "  Error detail: $_" -ForegroundColor Red
        $errorCount++
    }
}

Write-Host ""
Write-Host "========================================="
Write-Host "SYNC COMPLETED"
Write-Host "========================================="
Write-Host "Success: $successCount" -ForegroundColor Green
Write-Host "Errors : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
