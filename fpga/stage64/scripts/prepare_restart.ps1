$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$previous='E:/Gowin/workspace/v3_keyboard_stage59b_20261018'
$target='E:/Gowin/workspace/v3_keyboard_stage59b_rerun_20261019'
if(Test-Path -LiteralPath $target){throw 'Restart directory already exists; do not overwrite evidence'}
$receipt=Get-Content "$previous/.gowin-mcp/6a9606de29684a3189cec20ea1bf7e1b/receipt.json" -Raw | ConvertFrom-Json
if($receipt.state -notin 'completed','failed'){throw 'Previous worker has not recorded termination yet'}
if((Get-FileHash "$previous/impl/gwsynthesis/v3_hardware_top.vg").Hash -ne 'D172353318FF721FEEA548ACE44676D9FFC56385A8914A125D0692C2DA778736'){throw 'Verified netlist changed'}
# Only portable inputs and the verified synthesis output. No old placement,
# route checkpoint, bitstream or MCP receipt enters the fresh run.
New-Item -ItemType Directory -Path "$target/impl" -Force | Out-Null
foreach($folder in @('rtl','src','constraints','sim','scripts')){
    Copy-Item -LiteralPath "$source/$folder" -Destination $target -Recurse
}
Copy-Item -LiteralPath "$source/v3_hardware_top.gprj" -Destination $target
Copy-Item -LiteralPath "$previous/impl/gwsynthesis" -Destination "$target/impl" -Recurse
foreach($folder in @('rtl','src','constraints')){
    foreach($file in Get-ChildItem "$target/$folder" -Recurse -File){
        $relative=[IO.Path]::GetRelativePath($target,$file.FullName)
        if((Get-FileHash $file.FullName).Hash -ne (Get-FileHash (Join-Path $previous $relative)).Hash){throw "Restart input differs: $relative"}
    }
}
if((Get-FileHash "$target/impl/gwsynthesis/v3_hardware_top.vg").Hash -ne 'D172353318FF721FEEA548ACE44676D9FFC56385A8914A125D0692C2DA778736'){throw 'Copied netlist differs'}
Write-Output "Fresh P&R directory ready: $target"
