$ErrorActionPreference = 'Stop'
$candidate = Split-Path $PSScriptRoot -Parent
$mirror = 'E:/Gowin/workspace/v3_hdmi_stage67_20261025'
$netlist = Join-Path $mirror 'impl/gwsynthesis/project.vg'
$archive = Join-Path (Split-Path (Split-Path $candidate -Parent) -Parent) 'artifacts/v3_hdmi_stage67_20261025'
if (!(Test-Path -LiteralPath $netlist)) { throw 'Run successful HDMI synthesis first' }
New-Item -ItemType Directory -Path $archive -Force | Out-Null
& python "$PSScriptRoot/audit_half_rate.py" --netlist $netlist --contest-strings --omit-patterns "$PSScriptRoot/retained_constraint_omissions.json" --output "$archive/half_rate_audit.json" --sdc "$candidate/constraints/half_rate_enumerated.sdc"
if ($LASTEXITCODE -ne 0) { throw 'Fresh-netlist CE proof failed' }
& python "$PSScriptRoot/compact_queries.py"
if ($LASTEXITCODE -ne 0) { throw 'SDC compression failed' }
& python "$PSScriptRoot/compact_queries.py" --verify-netlist $netlist
if ($LASTEXITCODE -ne 0) { throw 'Compressed endpoint equivalence failed' }
& python "$PSScriptRoot/test_compact_queries.py"
if ($LASTEXITCODE -ne 0) { throw 'Compression negative controls failed' }
& python "$PSScriptRoot/test_half_tick_hierarchy.py" --netlist $netlist
if ($LASTEXITCODE -ne 0) { throw 'Cross-hierarchy half-tick proof controls failed' }
Copy-Item -LiteralPath "$candidate/constraints/v3_hdmi.sdc" -Destination "$mirror/constraints/v3_hdmi.sdc" -Force
Copy-Item -LiteralPath "$candidate/constraints/v3_hdmi.sdc" -Destination "$archive/applied.sdc" -Force
Copy-Item -LiteralPath "$candidate/constraints/v3_hdmi.cst" -Destination "$archive/applied.cst" -Force
Write-Output 'Fresh HDMI constraints prepared; no P&R started.'
