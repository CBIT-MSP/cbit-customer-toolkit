#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot '..\package\Internal\EngineSelection.ps1'
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }

# Each scope isolates mocks. No download, elevation, or installation occurs.
& {
    . $engine
    $script:GoodPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    function Get-Command { param($Name,$CommandType,$ErrorAction) return $null }
    function Test-PowerShell7Executable { param($Path) return ($Path -eq $script:GoodPath) }
    Assert-True ((Find-PowerShell7) -eq $script:GoodPath) 'MSI detection must work with no pwsh on PATH.'
    $script:GoodPath = 'missing'
    Assert-True ($null -eq (Find-PowerShell7)) 'Unusable executable must be rejected.'
}
& {
    . $engine
    $script:ProductType = 3
    $script:HasWinget = $true
    function Get-CimInstance { param($ClassName,$ErrorAction) [pscustomobject]@{ProductType=$script:ProductType} }
    function Get-Command { param($Name,$CommandType,$ErrorAction) if ($script:HasWinget) { [pscustomobject]@{Source='fixture'} } }
    Assert-True ((Get-PowerShell7InstallMethod) -eq 'MSI') 'Member server must use MSI even when WinGet exists.'
    $script:ProductType = 2
    Assert-True ((Get-PowerShell7InstallMethod) -eq 'MSI') 'Domain controller must use MSI.'
    $script:ProductType = 1
    Assert-True ((Get-PowerShell7InstallMethod) -eq 'WinGet') 'Client WinGet routing changed.'
    $script:HasWinget = $false
    Assert-True ((Get-PowerShell7InstallMethod) -eq 'MSI') 'Client without WinGet must use MSI.'
}
& {
    . $engine
    $script:FindCalls = 0
    $script:InstallCalls = 0
    $script:Working = $true
    function Find-PowerShell7 { $script:FindCalls++; if ($script:Working -and $script:FindCalls -gt 1) { 'C:\fixture\pwsh.exe' } }
    function Get-PowerShell7InstallMethod { 'MSI' }
    function Install-PowerShell7Msi { $script:InstallCalls++ }
    Assert-True ((Install-PowerShell7) -eq 'C:\fixture\pwsh.exe') 'Post-install detection failed.'
    Assert-True ($script:InstallCalls -eq 1) 'Installer was not called exactly once.'
    $script:Working = $false
    $failed = $false
    try { Install-PowerShell7 } catch { $failed = $_.Exception.Message -like '*no working PowerShell 7*' }
    Assert-True $failed 'Installer success must not imply executable success.'
}
& {
    . $engine
    $script:SignatureStatus = 'Valid'
    $script:Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US'
    $script:ExitCode = 0
    $script:Starts = 0
    function New-Item { param($ItemType,$Path,$ErrorAction) }
    function Invoke-WebRequest { param($Uri,$OutFile,[switch]$UseBasicParsing,$ErrorAction) }
    function Get-AuthenticodeSignature { param($LiteralPath,$ErrorAction) [pscustomobject]@{Status=$script:SignatureStatus; SignerCertificate=[pscustomobject]@{Subject=$script:Signer}} }
    function Start-Process {
        param($FilePath,$ArgumentList,$Verb,[switch]$Wait,[switch]$PassThru,$ErrorAction)
        $script:Starts++
        Assert-True ($ArgumentList -like '*/norestart*' -and $ArgumentList -like '*ADD_PATH=1*' -and $Verb -eq 'RunAs') 'Installer options are incorrect.'
        [pscustomobject]@{ExitCode=$script:ExitCode}
    }
    function Test-Path { param($LiteralPath) $false }
    function Remove-Item { param($LiteralPath,[switch]$Force,$ErrorAction) }
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    Install-PowerShell7Msi
    Assert-True ($script:Starts -eq 1) 'Signed MSI was not launched.'
    $script:ExitCode = 3010
    Install-PowerShell7Msi
    $script:ExitCode = 1603
    $failed = $false
    try { Install-PowerShell7Msi } catch { $failed = $_.Exception.Message -like '*1603*' }
    Assert-True $failed 'MSI failure exit was ignored.'
    $before = $script:Starts
    $script:SignatureStatus = 'NotSigned'
    $failed = $false
    try { Install-PowerShell7Msi } catch { $failed = $_.Exception.Message -like '*signature verification failed*' }
    Assert-True ($failed -and $script:Starts -eq $before) 'Unsigned MSI reached execution.'
    $script:SignatureStatus = 'Valid'
    $script:Signer = 'CN=Other Publisher, O=Other Publisher, C=US'
    $failed = $false
    try { Install-PowerShell7Msi } catch { $failed = $_.Exception.Message -like '*signature verification failed*' }
    Assert-True ($failed -and $script:Starts -eq $before) 'Wrong publisher reached execution.'
    Assert-True ([Net.ServicePointManager]::SecurityProtocol -eq $protocol) 'TLS settings were not restored.'
}
& {
    . $engine
    $current = (Get-Process -Id $PID).Path
    Assert-True ((Test-PowerShell7Executable $current) -eq ($PSVersionTable.PSVersion.Major -ge 7)) 'Executable version probe returned the wrong result.'
    Assert-True (-not (Test-PowerShell7Executable 'C:\CBIT-nonexistent\pwsh.exe')) 'Missing executable passed validation.'
}
[pscustomobject]@{PowerShell=$PSVersionTable.PSVersion.ToString(); InstallationRegressionTests='Passed'; RealInstallations=0} | ConvertTo-Json
