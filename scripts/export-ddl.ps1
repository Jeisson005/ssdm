param(
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

$outDir = '/app/sql'

Write-Host "Cleaning output directory: $outDir"
$dirs = @('tables', 'views', 'storedprocedures', 'functions')
foreach ($dir in $dirs) {
    $dirPath = Join-Path $outDir $dir
    if (Test-Path $dirPath) {
        Get-ChildItem -Path $dirPath -File | Remove-Item -Force
        Write-Host "  Cleaned: $dir"
    }
    New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
}

if (-not $Force) {
    $confirmation = Read-Host "Do you want to proceed with export? (yes/no)"
    if ($confirmation -ne 'yes') {
        Write-Host "Export cancelled."
        exit 0
    }
} else {
    Write-Host "Proceeding with export..."
}

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

Write-Host "Exporting DDL for database '$database' on '$instance'"
Write-Host "Output directory: $outDir"

$server = Connect-DbaInstance @connectParams

Write-Host "Exporting views via T-SQL..."
Invoke-DbaQuery -SqlInstance $server -Database $database -Query @"
SELECT OBJECT_SCHEMA_NAME(m.object_id) AS SchemaName, o.name AS ObjectName, m.definition
FROM sys.sql_modules m JOIN sys.objects o ON m.object_id = o.object_id
WHERE o.is_ms_shipped = 0 AND o.type = 'V'
ORDER BY OBJECT_SCHEMA_NAME(m.object_id), o.name
"@ | ForEach-Object {
    $def = $_.definition
    if ($def) { $def | Out-File -FilePath (Join-Path (Join-Path $outDir 'views') "$($_.SchemaName).$($_.ObjectName).sql") -Encoding UTF8 }
}

Write-Host "Exporting stored procedures via T-SQL..."
Invoke-DbaQuery -SqlInstance $server -Database $database -Query @"
SELECT OBJECT_SCHEMA_NAME(m.object_id) AS SchemaName, o.name AS ObjectName, m.definition
FROM sys.sql_modules m JOIN sys.objects o ON m.object_id = o.object_id
WHERE o.is_ms_shipped = 0 AND o.type = 'P'
ORDER BY OBJECT_SCHEMA_NAME(m.object_id), o.name
"@ | ForEach-Object {
    $def = $_.definition
    if ($def) { $def | Out-File -FilePath (Join-Path (Join-Path $outDir 'storedprocedures') "$($_.SchemaName).$($_.ObjectName).sql") -Encoding UTF8 }
}

Write-Host "Exporting functions via T-SQL..."
Invoke-DbaQuery -SqlInstance $server -Database $database -Query @"
SELECT OBJECT_SCHEMA_NAME(m.object_id) AS SchemaName, o.name AS ObjectName, m.definition
FROM sys.sql_modules m JOIN sys.objects o ON m.object_id = o.object_id
WHERE o.is_ms_shipped = 0 AND o.type IN ('FN', 'IF', 'TF', 'FS', 'FT')
ORDER BY OBJECT_SCHEMA_NAME(m.object_id), o.name
"@ | ForEach-Object {
    $def = $_.definition
    if ($def) { $def | Out-File -FilePath (Join-Path (Join-Path $outDir 'functions') "$($_.SchemaName).$($_.ObjectName).sql") -Encoding UTF8 }
}

Write-Host "Exporting tables via T-SQL..."
$tablesDDL = Invoke-DbaQuery -SqlInstance $server -Database $database -Query @"
SET NOCOUNT ON
SELECT
    s.name AS SchemaName,
    t.name AS TableName,
    'CREATE TABLE [' + s.name + '].[' + t.name + '] (' AS Header,
    STUFF((
        SELECT ', [' + c.name + '] ' +
            CASE WHEN c.system_type_id <> c.user_type_id THEN TYPE_NAME(c.user_type_id) ELSE TYPE_NAME(c.system_type_id) END +
            CASE WHEN c.max_length > 0 AND c.max_length <> -1 THEN
                CASE WHEN TYPE_NAME(c.system_type_id) IN ('nvarchar','nchar') THEN '(' + CAST(c.max_length/2 AS varchar) + ')'
                     WHEN TYPE_NAME(c.system_type_id) IN ('varchar','char','varbinary','binary') THEN '(' + CAST(c.max_length AS varchar) + ')'
                     ELSE ''
                END
            WHEN c.max_length = -1 THEN '(max)'
            WHEN TYPE_NAME(c.system_type_id) IN ('decimal','numeric') THEN '(' + CAST(c.precision AS varchar) + ',' + CAST(c.scale AS varchar) + ')'
            ELSE ''
            END +
            CASE WHEN c.is_nullable = 0 THEN ' NOT NULL' ELSE ' NULL' END +
            ISNULL(' DEFAULT ' + dc.definition, '') +
            CASE WHEN c.is_identity = 1 THEN ' IDENTITY(' + CAST(IDENT_SEED(QUOTENAME(s.name) + '.' + QUOTENAME(t.name)) AS varchar) + ',' + CAST(IDENT_INCR(QUOTENAME(s.name) + '.' + QUOTENAME(t.name)) AS varchar) + ')' ELSE '' END
        FROM sys.columns c
        LEFT JOIN sys.default_constraints dc ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
        WHERE c.object_id = t.object_id
        ORDER BY c.column_id
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 1, '') AS ColumnsDef,
    ')' AS Footer,
    ISNULL((
        SELECT ',' + CHAR(13) + CHAR(10) + 'ALTER TABLE [' + s.name + '].[' + t.name + '] ADD ' +
            CASE WHEN i.is_primary_key = 1 THEN 'PRIMARY KEY ' +
                CASE WHEN i.type_desc = 'CLUSTERED' THEN 'CLUSTERED' ELSE 'NONCLUSTERED' END +
                ' (' + STUFF((
                    SELECT ', [' + c.name + ']'
                    FROM sys.index_columns ic
                    JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                    ORDER BY ic.key_ordinal
                    FOR XML PATH(''), TYPE
                ).value('.', 'nvarchar(max)'), 1, 1, '') + ')'
            ELSE 'CREATE INDEX [' + i.name + '] ON [' + s.name + '].[' + t.name + '] (' +
                STUFF((
                    SELECT ', [' + c.name + ']'
                    FROM sys.index_columns ic
                    JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                    ORDER BY ic.key_ordinal
                    FOR XML PATH(''), TYPE
                ).value('.', 'nvarchar(max)'), 1, 1, '') + ')' +
                ISNULL(' INCLUDE (' + STUFF((
                    SELECT ', [' + c.name + ']'
                    FROM sys.index_columns ic
                    JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
                    ORDER BY ic.key_ordinal
                    FOR XML PATH(''), TYPE
                ).value('.', 'nvarchar(max)'), 1, 1, '') + ')', '')
            END
        FROM sys.indexes i
        WHERE i.object_id = t.object_id AND i.is_disabled = 0 AND i.is_hypothetical = 0
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), '') AS Indexes,
    ISNULL((
        SELECT CHAR(13) + CHAR(10) + 'ALTER TABLE [' + s.name + '].[' + t.name + '] ADD CONSTRAINT [' + fk.name + '] FOREIGN KEY (' +
            STUFF((
                SELECT ', [' + c.name + ']'
                FROM sys.foreign_key_columns fkc
                JOIN sys.columns c ON fkc.parent_object_id = c.object_id AND fkc.parent_column_id = c.column_id
                WHERE fkc.constraint_object_id = fk.object_id
                ORDER BY fkc.constraint_column_id
                FOR XML PATH(''), TYPE
            ).value('.', 'nvarchar(max)'), 1, 1, '') + ') REFERENCES [' + OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '].[' + OBJECT_NAME(fk.referenced_object_id) + '] (' +
            STUFF((
                SELECT ', [' + c.name + ']'
                FROM sys.foreign_key_columns fkc
                JOIN sys.columns c ON fkc.referenced_object_id = c.object_id AND fkc.referenced_column_id = c.column_id
                WHERE fkc.constraint_object_id = fk.object_id
                ORDER BY fkc.constraint_column_id
                FOR XML PATH(''), TYPE
            ).value('.', 'nvarchar(max)'), 1, 1, '') + ')'
        FROM sys.foreign_keys fk
        WHERE fk.parent_object_id = t.object_id
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), '') AS ForeignKeys
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE t.is_ms_shipped = 0 AND t.name <> 'sysdiagrams'
ORDER BY s.name, t.name
"@

foreach ($row in $tablesDDL) {
    $defs = $row.Header + $row.ColumnsDef + $row.Footer
    if ($row.Indexes) { $defs += $row.Indexes }
    if ($row.ForeignKeys) { $defs += $row.ForeignKeys }
    $defs | Out-File -FilePath (Join-Path (Join-Path $outDir 'tables') "$($row.SchemaName).$($row.TableName).sql") -Encoding UTF8
}

Write-Host "Done - Exported to: $outDir"