param(
    [Parameter(Position=0, Mandatory=$false)]
    [ValidateSet('export', 'sync', 'execute', 'clean', 'migrate')]
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
    Write-Host "Usage: docker compose run --rm db <action> [targets...] [options]"
    Write-Host ""
    Write-Host "Actions:"
    Write-Host "  export                 Export database DDL to sql/ folder (cleans first)"
    Write-Host "  sync [targets...]      Sync DDL to database with object pre-validation"
    Write-Host "                         Targets supported:"
    Write-Host "                           - Staged git files (default if no target provided)"
    Write-Host "                           - Single object: 'dbo.sp_MyProc' or 'sp_MyProc'"
    Write-Host "                           - Single file  : 'sql/storedprocedures/dbo.sp_MyProc.sql'"
    Write-Host "                           - Groups       : 'views', 'storedprocedures', 'functions'"
    Write-Host "                           - Wildcards    : 'sp_user*', 'sql/views/v_*'"
    Write-Host "                           - Multiple     : 'obj1 obj2 obj3' or list of files"
    Write-Host "                           - All non-table: '--all'"
    Write-Host "  execute <file>         Execute custom SQL script (from migrations/ or temp/) with pre-validation"
    Write-Host "  migrate <file>         Alias for 'execute migrations/<file>'"
    Write-Host "  clean                  Delete all SQL files from sql/ folder"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Force, -f             Skip confirmation prompts"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  docker compose run --rm db export"
    Write-Host "  docker compose run --rm db sync                                 # Sync staged changes"
    Write-Host "  docker compose run --rm db sync dbo.sp_GetUsers                 # Sync single object"
    Write-Host "  docker compose run --rm db sync views                           # Sync all views"
    Write-Host "  docker compose run --rm db sync storedprocedures                # Sync all stored procedures"
    Write-Host "  docker compose run --rm db sync 'sp_user*'                      # Sync by pattern"
    Write-Host "  docker compose run --rm db sync obj1 obj2                       # Sync multiple objects"
    Write-Host "  docker compose run --rm db execute ./migrations/001_alter.sql   # Execute migration (ALTER)"
    Write-Host "  docker compose run --rm db execute ./temp/query.sql             # Execute query/DML"
    Write-Host "  docker compose run --rm db clean"
    exit 1
}

switch ($Action) {
    'export' {
        if ($force) { & "/app/scripts/export-ddl.ps1" -Force } else { & "/app/scripts/export-ddl.ps1" }
    }
    'sync' {
        $params = @{}
        if ($force) { $params['Force'] = $true }
        if ($Args -and $Args.Count -gt 0) {
            $params['Targets'] = $Args
        }
        & "/app/scripts/sync-ddl.ps1" @params
    }
    'execute' {
        $path = if ($Args.Count -gt 0) { $Args[0] } else { $null }
        if ($force) { & "/app/scripts/execute-script.ps1" -FilePath $path -Force } else { & "/app/scripts/execute-script.ps1" -FilePath $path }
    }
    'migrate' {
        $path = if ($Args.Count -gt 0) { $Args[0] } else { $null }
        if ($force) { & "/app/scripts/execute-script.ps1" -FilePath $path -Force } else { & "/app/scripts/execute-script.ps1" -FilePath $path }
    }
    'clean' {
        & "/app/scripts/clean.ps1"
    }
}
