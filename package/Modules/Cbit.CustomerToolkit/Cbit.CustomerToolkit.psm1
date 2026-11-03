$script:ToolkitBinRoot = Join-Path $PSScriptRoot 'bin'
$script:CbitUseAnsi = ($PSVersionTable.PSVersion.Major -ge 7) -or [bool]$env:WT_SESSION
$script:CbitPalette = @{
    Good = @{ Rgb = '143;168;128'; Fallback = 'DarkGreen' }
    Bad = @{ Rgb = '150;60;60'; Fallback = 'DarkRed' }
    Detail = @{ Rgb = '128;128;120'; Fallback = 'DarkGray' }
    Warn = @{ Rgb = '176;137;70'; Fallback = 'DarkYellow' }
    Header = @{ Rgb = '178;178;170'; Fallback = 'Gray' }
}
$script:CbitCheck = [char]0x2713
$script:CbitCross = [char]0x2717
$script:CbitWarnGlyph = [char]0x26A0

function Write-Color {
    param([string]$Text, [string]$Color = '', [switch]$NoNewline)
    if (-not $Color) { Write-Host $Text -NoNewline:$NoNewline }
    elseif ($script:CbitUseAnsi) {
        Write-Host ('{0}[38;2;{1}m{2}{0}[0m' -f [char]27, $script:CbitPalette[$Color].Rgb, $Text) -NoNewline:$NoNewline
    }
    else { Write-Host $Text -ForegroundColor $script:CbitPalette[$Color].Fallback -NoNewline:$NoNewline }
}

$legacy = $PSVersionTable.PSVersion.Major -lt 7
$files = @(
    'Get-BitLockerInformation.ps1', 'Get-ClipLength.ps1', 'Get-SystemDetails.ps1',
    'Invoke-InternetSpeedTest.ps1', 'Invoke-ServerInventory.ps1', 'Menu-Options.ps1', 'npp.ps1',
    'renew-safe.ps1', 'Repair-Winget.ps1', 'Show-TechMenu.ps1', 'Start-Pulse.ps1',
    'Test-Internet.ps1', 'Test-Network.ps1', 'test-site.ps1', 'Maintenance-Commands.ps1', 'GPO-Deployment.ps1', 'QR-Code-Utility.ps1'
)
if (-not $legacy) { $files += 'Scan-Network.ps1', 'Test-EmailAuthentication.ps1' }
foreach ($file in $files) { . (Join-Path $PSScriptRoot "Functions\$file") }
if ($legacy) {
    function Scan-Network { throw 'Scan-Network requires PowerShell 7. Reopen the toolkit with -Engine PowerShell7 on a machine where it is installed.' }
    function Test-EmailAuthentication { throw 'Test-EmailAuthentication requires PowerShell 7. Reopen the toolkit with -Engine PowerShell7 on a machine where it is installed.' }
    Set-Alias -Name Test-EmailDNS -Value Test-EmailAuthentication -Scope Script
    Set-Alias -Name Check-EmailDNS -Value Test-EmailAuthentication -Scope Script
    Set-Alias -Name Test-DMARC -Value Test-EmailAuthentication -Scope Script
}

function Get-ToolkitStatus {
    [pscustomobject]@{
        ToolkitVersion = '0.3.4-preview'
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        ModuleRoot = $PSScriptRoot
        BinaryDirectory = $script:ToolkitBinRoot
        PowerShell7OnlyTools = @('Scan-Network', 'Test-EmailAuthentication')
        PowerShell7ToolsAvailable = ($PSVersionTable.PSVersion.Major -ge 7)
    }
}
# Exports are explicitly limited by the manifest. Formatting helpers stay private.
