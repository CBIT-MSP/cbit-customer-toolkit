#Requires -Version 5.1
param([Parameter(Mandatory)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$module = Import-Module (Join-Path $PackageRoot 'Modules\Cbit.CustomerToolkit\Cbit.CustomerToolkit.psd1') -PassThru -DisableNameChecking -Force
$config = & $module { Get-ToolkitQrLaunchConfiguration }
Assert-True ($config.Engine -like '*\WindowsPowerShell\v1.0\powershell.exe') 'QR adapter did not select Windows PowerShell.'
Assert-True ($null -eq (Get-Module QRCodeUtility)) 'QR payload was imported before the technician selected it.'
Assert-True ($null -eq ('ZXing.BarcodeReaderGeneric' -as [type])) 'Decoder assembly was loaded during toolkit import.'
$payloadRoot = Split-Path $config.Entry
foreach ($required in 'QRCodeUtility.psm1','README.md','lib\ZXing.Net-LICENSE.txt','lib\THIRD-PARTY.txt','tests\Test-QRCodeUtility.ps1','tests\Test-QRCodeMenu.ps1') {
    Assert-True (Test-Path -LiteralPath (Join-Path $payloadRoot $required)) "Missing QR package file: $required"
}
$hashes = @{
    'lib\net40\zxing.dll'='643A5A3DB0AE02998B507BEB82DBC362A2D5593B429963DB17EB78089AABB95A'
    'lib\netstandard2.0\zxing.dll'='F3B823B6FD6492525A7547989056883DEF5D43BE1E12C4F63FA54DF73E3C5CFC'
}
foreach ($path in $hashes.Keys) {
    Assert-True ((Get-FileHash (Join-Path $payloadRoot $path)).Hash -eq $hashes[$path]) "QR decoder integrity mismatch: $path"
}

$result = & $module {
    $script:QrTestExit = 0
    $script:QrTestThrow = $false
    $script:QrTestCalls = 0
    $script:QrOriginalMenuValidator = (Get-Command Assert-ToolkitMenuConfiguration).ScriptBlock
    function script:Assert-ToolkitMenuConfiguration {
        param($Items)
        & $script:QrOriginalMenuValidator -Items $Items
        $script:QrTestMenuItems = $Items
    }
    function script:Start-Process {
        param($FilePath,$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru,$ErrorAction)
        $script:QrTestCalls++
        if ($env:PSModulePath) { throw 'Child inherited the caller module path.' }
        if ($script:QrTestThrow) { throw 'Synthetic launch failure.' }
        $script:QrTestInvocation = @{ Engine=$FilePath; Arguments=$ArgumentList; SameConsole=[bool]$NoNewWindow }
        $script:QrTestChild = [pscustomobject]@{
            Id=99999999; Handle=1; StartTime=(Get-Date); HasExited=$false; ExitCode=$script:QrTestExit
            Waited=$false; Disposed=$false; LeaseDir=(Join-Path (Get-ToolkitQrLaunchConfiguration).PackageRoot '.maintenance-workers')
        }
        $script:QrTestChild | Add-Member ScriptMethod WaitForExit {
            $leases = @(Get-ChildItem -LiteralPath $this.LeaseDir -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object Tool -eq 'QR Code Utility')
            if ($leases.Count -ne 1 -or $leases[0].State -ne 'Running' -or $leases[0].Pid -ne $this.Id) { throw 'QR files were not protected while the child was running.' }
            $this.Waited=$true; $this.HasExited=$true
        }
        $script:QrTestChild | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
        return $script:QrTestChild
    }
    $null = Show-TechMenu -ValidateOnly
    $item = $script:QrTestMenuItems[13]
    $originalPath = $env:PSModulePath
    & $item.Command
    $success = $script:QrTestChild.Waited -and $script:QrTestChild.Disposed -and ($env:PSModulePath -ceq $originalPath)
    $invocation = $script:QrTestInvocation
    $script:QrTestExit = 1
    $failedExitReported = $false
    try { Start-CBITQRCodeUtility } catch { $failedExitReported = $_.Exception.Message -like '*exited with an error*' }
    $script:QrTestThrow = $true
    $failedLaunchReported = $false
    try { Start-CBITQRCodeUtility } catch { $failedLaunchReported = $_.Exception.Message -eq 'Synthetic launch failure.' }
    $restored = $env:PSModulePath -ceq $originalPath
    $remaining = @(Get-ChildItem -LiteralPath (Join-Path (Get-ToolkitQrLaunchConfiguration).PackageRoot '.maintenance-workers') -Filter '*.json' |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object Tool -eq 'QR Code Utility')
    [pscustomobject]@{
        Success=$success; Invocation=$invocation; FailedExitReported=$failedExitReported; FailedLaunchReported=$failedLaunchReported
        ModulePathRestored=$restored; LeasesRemoved=($remaining.Count -eq 0)
        MenuName=$item.Name; DirectMenu=$item.SkipActionMenu; CommandName=$item.CommandName
    }
}
Assert-True ($result.Success -and $result.FailedExitReported -and $result.FailedLaunchReported -and $result.ModulePathRestored -and $result.LeasesRemoved) 'QR adapter lifecycle/failure checks failed.'
Assert-True ($result.MenuName -eq 'QR Code Utility' -and $result.DirectMenu -and $result.CommandName -eq 'Start-CBITQRCodeUtility') 'Shortcut N does not open the QR menu directly.'
Assert-True ($result.Invocation.SameConsole -and $result.Invocation.Engine -eq $config.Engine) 'QR menu opened in the wrong host or console.'
Assert-True ($result.Invocation.Arguments -ceq ('"-NoLogo" "-NoProfile" "-STA" "-File" "' + $config.Entry + '" "-Menu"')) 'QR menu flags/path were not forwarded correctly.'
Remove-Module Cbit.CustomerToolkit
Assert-True ($null -eq (Get-Command Start-CBITQRCodeUtility -ErrorAction SilentlyContinue)) 'QR adapter remained after toolkit unload.'
[pscustomobject]@{ PowerShell=$PSVersionTable.PSVersion.ToString(); MenuShortcut='N'; LazyLoading='Passed'; BundledDecoderIntegrity='Passed'; LaunchAndReturn='Passed'; ModulePathRestoration='Passed'; WorkerCleanup='Passed'; ClipboardAccessed=$false } | ConvertTo-Json
