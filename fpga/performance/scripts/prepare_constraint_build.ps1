$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$baseline='E:/Gowin/workspace/v3_full_stage54h_20261016'
$target='E:/Gowin/workspace/v3_full_stage54i_20261017'
if(Test-Path "$target/impl/pnr"){throw 'Candidate P&R evidence already exists; do not overwrite'}
$checked=@()
foreach($folder in @('rtl','src','sim')){
    foreach($file in Get-ChildItem (Join-Path $source $folder) -Recurse -File){
        if($file.Extension -notin '.v','.sv','.vh','.hex','.mem'){continue}
        $relative=[IO.Path]::GetRelativePath($source,$file.FullName)
        $old=Join-Path $baseline $relative
        $hash=(Get-FileHash -LiteralPath $file.FullName).Hash
        if(!(Test-Path $old) -or $hash -ne (Get-FileHash $old).Hash){throw "RTL/test changed: $relative"}
        $checked += [pscustomobject]@{path=$relative;sha256=$hash}
    }
}
foreach($name in @('v3_hardware_top.gprj','constraints/v3_hardware.cst')){
    if((Get-FileHash (Join-Path $source $name)).Hash -ne (Get-FileHash (Join-Path $baseline $name)).Hash){throw "Baseline differs: $name"}
}
$netlist="$baseline/impl/gwsynthesis/project.vg"
if((Get-FileHash $netlist).Hash -ne 'A24FB4B08FA5169696CC034CFDD2BAD2A52F2FC5D2F8D485E00C17108296615D'){throw 'Frozen synthesis netlist differs'}
& "$PSScriptRoot/sync_and_test.ps1" -SyncOnly
New-Item -ItemType Directory -Path "$target/impl" -Force | Out-Null
Copy-Item -LiteralPath "$baseline/impl/gwsynthesis" -Destination "$target/impl/gwsynthesis" -Recurse
$archive=Join-Path (Split-Path (Split-Path $source -Parent) -Parent) 'artifacts/v3_full_stage54i_20261017'
New-Item -ItemType Directory -Path $archive -Force | Out-Null
$checked | ConvertTo-Json -Depth 4 | Set-Content "$archive/unchanged_rtl_test_hashes.json" -Encoding utf8
Write-Output "Verified $($checked.Count) RTL/test/memory inputs identical to 54h; reusing synthesis and 119 regression results. P&R is fresh, no .pr reused."
