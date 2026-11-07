param([Parameter(Mandatory=$true)][string]$Netlist)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$netlist=(Resolve-Path -LiteralPath $Netlist).Path
# Require the exact artifact named by the successful synthesis log. Gowin
# may switch between project.vg and v3_hdmi_top.vg on consecutive runs.
if(!([IO.Path]::GetFullPath($netlist).StartsWith([IO.Path]::GetFullPath((Join-Path $root 'impl/gwsynthesis'))+[IO.Path]::DirectorySeparatorChar))){throw 'Netlist must belong to this candidate'}
$audit=Join-Path $root 'audit'
New-Item -ItemType Directory -Path $audit -Force | Out-Null
& python "$PSScriptRoot/audit_half_rate.py" --netlist $netlist --contest-strings --omit-patterns "$PSScriptRoot/retained_constraint_omissions.json" --output "$audit/half_rate_audit.json" --sdc "$root/constraints/half_rate_enumerated.sdc"
if($LASTEXITCODE -ne 0){throw 'Common CE proof failed'}
& python "$PSScriptRoot/compact_queries.py" --netlist $netlist
if($LASTEXITCODE -ne 0){throw 'Endpoint compression failed'}
& python "$PSScriptRoot/compact_queries.py" --verify-netlist $netlist
if($LASTEXITCODE -ne 0){throw 'Fresh endpoint equivalence failed'}
& python "$PSScriptRoot/test_compact_queries.py"
if($LASTEXITCODE -ne 0){throw 'Compression negative controls failed'}
& python "$PSScriptRoot/test_half_tick_hierarchy.py" --netlist $netlist
if($LASTEXITCODE -ne 0){throw 'Hierarchy CE proof failed'}
Get-FileHash -LiteralPath "$root/constraints/v3_hdmi.sdc" -Algorithm SHA256
