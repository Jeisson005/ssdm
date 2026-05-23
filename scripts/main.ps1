param(
    [Parameter(Position=0, Mandatory=$false)]
    [ValidateSet('export', 'sync', 'execute', 'clean')]
    [string]$Action = $null
,
    [Parameter(Position=1, ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'

$force = $false
if ($Args -contains '-Force' -or $Args -contains '--force' -or $Args -contains '-f') {
    $force = $true
    $Args = $Args | Where-Object { $_ -notin @('-Force', '--force', '-f') }
}

if (-not $Action) {
    Write-Host "Usage: docker compose run --rm db <action> [options]"
    Write-Host ""
    Write-Host "Actions:"
    Write-Host "  export          Export database DDL to sql/ folder (cleans first)"
    Write-Host "  sync [file]     Sync DDL to database (shows diff, prompts confirmation)"
    Write-Host "  execute <path>  Execute custom SQL script (prompts confirmation)"
    Write-Host "  clean           Delete all SQL files from sql/ folder"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Force, -f      Skip confirmation prompts"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  docker compose run --rm db export"
    Write-Host "  docker compose run --rm db sync"
    Write-Host "  docker compose run --rm db sync sql/tables/dbo.Activity.sql"
    Write-Host "  docker compose run --rm db execute ./temp/migration.sql"
    Write-Host "  docker compose run --rm db clean"
    exit 1
}

switch ($Action) {
    'export' {
        if ($force) { & "/app/scripts/export-ddl.ps1" -Force } else { & "/app/scripts/export-ddl.ps1" }
    }
    'sync' {
        $file = if ($Args.Count -gt 0) { $Args[0] } else { $null }
        if ($file) {
            if ($force) { & "/app/scripts/sync-ddl.ps1" -FilePath $file -Force } else { & "/app/scripts/sync-ddl.ps1" -FilePath $file }
        } else {
            if ($force) { & "/app/scripts/sync-ddl.ps1" -Force } else { & "/app/scripts/sync-ddl.ps1" }
        }
    }
    'execute' {
        $path = if ($Args.Count -gt 0) { $Args[0] } else { $null }
        if ($force) { & "/app/scripts/execute-script.ps1" -FilePath $path -Force } else { & "/app/scripts/execute-script.ps1" -FilePath $path }
    }
    'clean' {
        & "/app/scripts/clean.ps1"
    }
}