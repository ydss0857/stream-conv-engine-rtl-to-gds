# Re-render the report PDFs from their HTML sources with Microsoft Edge (headless).
#
#   Right-click this file > "Run with PowerShell"
#   or, in a terminal:  powershell -ExecutionPolicy Bypass -File docs\report\build.ps1
#
# Edit the .html files (text between the tags), then run this script.

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $here "..\..")
$edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path $edge)) { $edge = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }

# The main report's PDF lives at the repository root (next to README and LICENSE);
# the help-request report stays here.
$targets = @{ "rtl_to_gds_report" = $root; "timing_help_report" = $here }

foreach ($name in $targets.Keys) {
    $html = Join-Path $here "$name.html"
    $pdf  = Join-Path $targets[$name] "$name.pdf"
    $url  = "file:///" + ($html -replace '\\', '/')
    Start-Process -FilePath $edge -Wait -WindowStyle Hidden -ArgumentList @(
        "--headless=new", "--disable-gpu", "--no-pdf-header-footer", "--print-to-pdf=$pdf", $url)
    Write-Host "wrote $pdf"
}
