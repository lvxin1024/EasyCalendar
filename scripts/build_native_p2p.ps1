[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$manifest = Join-Path $root "native/easycalendar_p2p/Cargo.toml"
$outputDirectoryPath = [IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputDirectory))
$source = Join-Path $root "target/release/easycalendar_p2p.dll"
$output = Join-Path $outputDirectoryPath "easycalendar_p2p.dll"

if ($null -eq (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "cargo is required for Windows native builds"
}

& cargo build --release --manifest-path $manifest --target-dir (Join-Path $root "target")
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path $source)) {
    throw "Rust build did not produce $source"
}

New-Item -ItemType Directory -Force -Path $outputDirectoryPath | Out-Null
Copy-Item -Force $source $output
Write-Host "Built $output"
