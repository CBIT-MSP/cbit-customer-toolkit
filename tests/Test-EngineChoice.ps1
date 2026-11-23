#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\package\Internal\EngineSelection.ps1')
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }

# Replace detection, the prompt, and installation. No installer or toolkit action runs.
$script:FoundPowerShell7 = $null
$script:PromptAnswer = 'n'
$script:FindCount = 0
$script:PromptCount = 0
$script:InstallCount = 0
function Find-PowerShell7 { $script:FindCount++; return $script:FoundPowerShell7 }
function Read-Host { param([string]$Prompt) $script:PromptCount++; return $script:PromptAnswer }
function Install-PowerShell7 { $script:InstallCount++; return 'C:\fixture\pwsh.exe' }

$windowsPowerShell = Get-WindowsPowerShellPath
$chosen = Select-ToolkitEngine -Engine Auto
Assert-True ($chosen -eq $windowsPowerShell) 'Declining installation did not select Windows PowerShell.'
Assert-True ($script:PromptCount -eq 1 -and $script:InstallCount -eq 0) 'Declining installation called the installer.'

$script:PromptAnswer = 'y'
$chosen = Select-ToolkitEngine -Engine Auto
Assert-True ($chosen -eq 'C:\fixture\pwsh.exe') 'Accepting installation did not select the installed engine.'
Assert-True ($script:PromptCount -eq 2 -and $script:InstallCount -eq 1) 'Acceptance did not call the installer exactly once.'

$chosen = Select-ToolkitEngine -Engine Auto -Verify
Assert-True ($chosen -eq $windowsPowerShell) 'Auto verification did not use Windows PowerShell when PowerShell 7 is absent.'
Assert-True ($script:PromptCount -eq 2 -and $script:InstallCount -eq 1) 'Verification prompted or installed software.'

$declined = $false
$script:PromptAnswer = 'n'
try { $null = Select-ToolkitEngine -Engine PowerShell7 } catch { $declined = $_.Exception.Message -like '*installation was declined*' }
Assert-True $declined 'Explicit PowerShell 7 request did not stop when installation was declined.'
Assert-True ($script:InstallCount -eq 1) 'Explicit PowerShell 7 decline called the installer.'

$missing = $false
try { $null = Select-ToolkitEngine -Engine PowerShell7 -Verify } catch { $missing = $_.Exception.Message -like '*Nothing was installed*' }
Assert-True $missing 'Explicit PowerShell 7 verification did not report the missing engine.'
Assert-True ($script:PromptCount -eq 3 -and $script:InstallCount -eq 1) 'Explicit verification prompted or installed software.'

$script:FoundPowerShell7 = 'C:\fixture\existing-pwsh.exe'
$chosen = Select-ToolkitEngine -Engine Auto
Assert-True ($chosen -eq $script:FoundPowerShell7) 'Auto did not select installed PowerShell 7.'
Assert-True ($script:PromptCount -eq 3 -and $script:InstallCount -eq 1) 'Installed PowerShell 7 prompted or installed software.'

$findBefore = $script:FindCount
$chosen = Select-ToolkitEngine -Engine WindowsPowerShell
Assert-True ($chosen -eq $windowsPowerShell) 'Explicit Windows PowerShell did not select Windows PowerShell.'
Assert-True ($script:FindCount -eq $findBefore -and $script:PromptCount -eq 3 -and $script:InstallCount -eq 1) 'Explicit Windows PowerShell probed or installed PowerShell 7.'

[pscustomobject]@{
    PowerShell = $PSVersionTable.PSVersion.ToString()
    DeclineFallsBackWithoutInstall = 'Passed'
    AcceptanceCallsInstallerOnce = 'Passed (mocked)'
    VerifyNeverPromptsOrInstalls = 'Passed'
    ExplicitEngineChoices = 'Passed'
    RealInstallations = 0
} | ConvertTo-Json
