param([Parameter(Mandatory=$true)][int]$BuildProcessId,
      [Parameter(Mandatory=$true)][long]$BuildStartTicks)
$ErrorActionPreference='Stop'
$candidate=Split-Path $PSScriptRoot -Parent
$archive=Join-Path (Split-Path (Split-Path $candidate -Parent) -Parent) ('artifacts/'+(Split-Path $candidate -Leaf))
# Read-only process identity checks. Never kill, restart, change settings or
# accept a different process that happens to reuse the same PID.
while($true){
    $running=Get-Process -Id $BuildProcessId -ErrorAction SilentlyContinue
    if(!$running -or $running.StartTime.Ticks -ne $BuildStartTicks){break}
    Start-Sleep -Seconds 10
}
& "$PSScriptRoot/archive_hdmi_results.ps1" *> "$archive/final_archive.log"
& python "$PSScriptRoot/collect_acceptance.py" *> "$archive/final_audits.log"
if($LASTEXITCODE -ne 0){throw 'Final read-only audit collection failed; inspect final_audits.log'}
Write-Output 'Build process ended; reports archived and read-only audits collected. No automatic acceptance or programming.'
