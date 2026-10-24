$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$target='E:/Gowin/workspace/v3_full_stage54j_20261017'
$baseline='E:/Gowin/workspace/v3_full_stage54i_20261017'
if(Test-Path "$target/impl/pnr"){throw 'Do not overwrite an existing P&R attempt'}
foreach($folder in @('rtl','src')){
    foreach($file in Get-ChildItem (Join-Path $source $folder) -Recurse -File){
        $rel=[IO.Path]::GetRelativePath($source,$file.FullName)
        if((Get-FileHash $file.FullName).Hash -ne (Get-FileHash (Join-Path $baseline $rel)).Hash){throw "RTL differs: $rel"}
    }
}
$log="$target/focused_stage54j.log"
$passes=@(Select-String $log -Pattern '^PASS tb_' )
if($passes.Count -ne 6 -or (Select-String $log -Pattern '^FAIL |# \*\* (Error|Fatal):')){throw 'Expected all six focused checks'}
if(!(Select-String "$target/sim/menu_delay_negative.log" -Pattern 'Fatal: MENU_DELAY_UNSAFE: receiver enable differs')){throw 'Missing negative control'}
$projectRoot=Split-Path (Split-Path $source -Parent) -Parent
$proof=Get-Content (Join-Path $projectRoot 'artifacts/v3_full_stage54j_20261017/netlist_menu_mask.json') -Raw | ConvertFrom-Json
if(!$proof.all_47_masked){throw 'Actual 47 CE pins not proven masked'}
& "$PSScriptRoot/sync_and_test.ps1" -SyncOnly
# Copy only synthesis evidence; never reuse .p/.pr or timing output. Gowin may
# rerun synthesis for the new project; verify the fresh netlist after completion.
New-Item -ItemType Directory "$target/impl" -Force | Out-Null
Copy-Item -LiteralPath "$baseline/impl/gwsynthesis" -Destination "$target/impl/gwsynthesis" -Recurse
'54j prepared: 47 exact max-delay endpoints, original RTL, six fresh checks and negative control passed.'
