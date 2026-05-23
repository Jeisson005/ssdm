$ErrorActionPreference = 'Stop'

$outDir = '/app/sql'

Write-Host "Cleaning output directory: $outDir"

if (Test-Path $outDir) {
    Get-ChildItem -Path $outDir -Recurse -Force | Remove-Item -Recurse -Force
    Write-Host "All contents deleted from: $outDir"
} else {
    Write-Host "Directory does not exist: $outDir"
}

Write-Host "Done."