function Get-ToolkitQrLaunchConfiguration {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $packageRoot = Split-Path -Parent (Split-Path -Parent $moduleRoot)
    $entry = Join-Path $moduleRoot 'Tools\QRCode\Decode-QRCode.ps1'
    $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not [Environment]::Is64BitProcess -and $env:PROCESSOR_ARCHITEW6432) {
        $engine = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    }
    if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'The QR utility is missing. Reopen the toolkit from the complete package.' }
    [pscustomobject]@{ Engine = $engine; Entry = $entry; PackageRoot = $packageRoot }
}

function Start-CBITQRCodeUtility {
    <#
    .SYNOPSIS
        Opens the offline QR decoder's source and copy menus.
    .DESCRIPTION
        Select a clipboard image or browse for an image, then copy the Base32
        secret or the full otpauth URI. Both can be copied from the same scan.
        Uses bundled ZXing.Net files; no network, installation, or elevation is
        required. Runs in Windows PowerShell 5.1 STA in this console. Select 0
        to return to the toolkit. The QR utility creates no credential files
        and does not print secret values. Clipboard history/system logging may
        retain credentials. Proprietary and migration QR payloads are unsupported.
    #>
    [CmdletBinding()]
    param()
    $config = Get-ToolkitQrLaunchConfiguration
    . (Join-Path $config.PackageRoot 'Internal\Lifecycle.ps1')
    # Keep the staged payload alive until the interactive child finishes.
    $leases = Join-Path $config.PackageRoot '.maintenance-workers'
    New-Item -ItemType Directory -Path $leases -Force -ErrorAction Stop | Out-Null
    $lease = Join-Path $leases ([guid]::NewGuid().ToString('N') + '.json')
    @{ State='Starting'; Tool='QR Code Utility' } | ConvertTo-Json | Set-Content -LiteralPath $lease -Encoding UTF8 -ErrorAction Stop
    $child = $null
    try {
        $arguments = @('-NoLogo','-NoProfile','-STA','-File',$config.Entry,'-Menu')
        # PowerShell 7 module paths can prevent Windows PowerShell's built-in
        # modules from loading. Reset only the child environment and restore
        # the caller immediately, including when process creation fails.
        $previousModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = $null
            $child = Start-Process -FilePath $config.Engine -ArgumentList ((ConvertTo-ToolkitProcessArguments $arguments) -join ' ') -NoNewWindow -PassThru -ErrorAction Stop
        }
        finally { $env:PSModulePath = $previousModulePath }
        $null = $child.Handle
        @{ State='Running'; Pid=$child.Id; StartedUtc=$child.StartTime.ToUniversalTime().ToString('o'); Tool='QR Code Utility' } |
            ConvertTo-Json | Set-Content -LiteralPath $lease -Encoding UTF8 -ErrorAction Stop
        $child.WaitForExit()
        if ($child.ExitCode -ne 0) { throw 'QR Code Utility exited with an error. Review the message above and try again.' }
    }
    finally {
        if (-not $child -or $child.HasExited) { Remove-Item -LiteralPath $lease -Force -ErrorAction SilentlyContinue }
        if ($child) { $child.Dispose() }
    }
}
