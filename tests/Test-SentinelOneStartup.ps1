#Requires -Version 5.1
param([Parameter(Mandatory)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$source = Join-Path $PackageRoot 'Modules\Cbit.CustomerToolkit\Deployment\Deploy-CBITStandardGPO.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $source).Path, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'Deployment source does not parse.'
$assignment = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:CBITEndpointTemplate'
}, $true)
Assert-True ($assignment.Right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) 'Endpoint template is not a literal string.'
$template = $assignment.Right.Expression.Value
$null = [System.Management.Automation.Language.Parser]::ParseInput($template, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'Generated startup script does not parse.'

$testsRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$runRoot = Join-Path $testsRoot ('s1-startup-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $runRoot
$harnessPath = Join-Path $runRoot 'Run-MockedStartup.ps1'
$harness = @'
param([string]$CaseRoot, [string]$CaseName)
$ErrorActionPreference = 'Stop'
$global:Scenario = $CaseName
$global:Starts = 0
$global:ProtectedPath = $null
$global:AclValid = $false
$global:Clock = [datetime]'2026-11-26T01:00:00'
$global:FakeToken = 'SYNTHETIC_TEST_TOKEN_ONLY_0123456789'
$env:TEMP = Join-Path $CaseRoot 'Temp'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:PROCESSOR_ARCHITEW6432 = ''
$global:CaseLog = $null
$global:ArgumentsValid = $false

function global:Get-Service {
    param($Name, $ErrorAction)
    if ($Name -ne 'SentinelAgent') { throw 'Unexpected service query in endpoint script.' }
    if ($global:Scenario -eq 'AlreadyInstalled' -or ($global:Starts -gt 0 -and $global:Scenario -in 'Success', 'RestartRequired')) {
        [pscustomobject]@{ Name = 'SentinelAgent'; Status = 'Running' }
    }
}
function global:Get-Date {
    param([string]$Format)
    if ($Format) { $global:Clock.ToString($Format) } else { $global:Clock }
}
function global:Start-Sleep {
    param([int]$Seconds)
    $global:Clock = $global:Clock.AddSeconds($Seconds)
}
function global:Set-Acl {
    param($LiteralPath, $AclObject)
    if ($global:Scenario -eq 'LogAclFailure') { throw 'Synthetic access denied while protecting MSI logs.' }
    $rules = @($AclObject.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $allowed = @($rules | Where-Object {
        $_.IdentityReference.Value -in 'S-1-5-18', 'S-1-5-32-544' -and
        $_.AccessControlType -eq 'Allow' -and
        $_.FileSystemRights -eq [Security.AccessControl.FileSystemRights]::FullControl -and
        $_.InheritanceFlags -eq ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit)
    })
    $global:AclValid = $AclObject.AreAccessRulesProtected -and $rules.Count -eq 2 -and $allowed.Count -eq 2
    if (-not $global:AclValid) { throw 'Verbose logs would not be private to SYSTEM/Administrators.' }
    $global:ProtectedPath = $LiteralPath
}
function global:Start-Process {
    param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
    $global:Starts++
    if ($FilePath -ne 'msiexec.exe') { throw 'Unexpected process launch.' }
    $logMatch = [regex]::Match($ArgumentList, '/L\*V! "([^"]+)"')
    $inputMatch = [regex]::Match($ArgumentList, '^/i "([^"]+)"')
    $global:ArgumentsValid = $Wait -and $PassThru -and $logMatch.Success -and $inputMatch.Success -and
        $ArgumentList.Contains(' /qn /norestart ') -and $ArgumentList.Contains('SITE_TOKEN="' + $global:FakeToken + '"')
    if (-not $global:ArgumentsValid) { throw 'MSI arguments lost logging, quoting, token, waiting, or no-restart settings.' }
    $global:CaseLog = $logMatch.Groups[1].Value
    if (-not $global:AclValid -or (Split-Path $global:CaseLog) -ne $global:ProtectedPath) {
        throw 'MSI launched before log-folder protection or outside its protected folder.'
    }
    if (-not (Test-Path -LiteralPath $inputMatch.Groups[1].Value)) { throw 'MSI input was not staged locally.' }
    if ($global:Scenario -eq 'ProcessStartFailure') { throw ('Synthetic process failure with token ' + $global:FakeToken) }
    $code = switch ($global:Scenario) { 'Installer1603' { 1603 }; 'RestartRequired' { 3010 }; default { 0 } }
    [IO.File]::WriteAllText($global:CaseLog, ('Synthetic MSI log; SITE_TOKEN=' + $global:FakeToken + "`r`nReturn value 3.`r`n"))
    [pscustomobject]@{ ExitCode = $code }
}

if ((Get-Command Start-Process).CommandType -ne 'Function' -or (Get-Command Get-Service).CommandType -ne 'Function') {
    throw 'Mocks are missing; refusing to run endpoint code.'
}
$global:LASTEXITCODE = 0
$caseExit = 99
try {
    & (Join-Path $CaseRoot 'Install-S1.ps1')
    $caseExit = $global:LASTEXITCODE
} finally {
    [pscustomobject]@{
        Starts = $global:Starts
        AclValid = $global:AclValid
        ArgumentsValid = $global:ArgumentsValid
        MsiLog = $global:CaseLog
        ExitCode = $caseExit
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $CaseRoot 'result.json') -Encoding UTF8
}
exit $caseExit
'@
Set-Content -LiteralPath $harnessPath -Value $harness -Encoding UTF8
$engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cases = @(
    @{ Name = 'AlreadyInstalled'; Exit = 0; Starts = 0 }
    @{ Name = 'Installer1603'; Exit = 1603; Starts = 1 }
    @{ Name = 'Success'; Exit = 0; Starts = 1 }
    @{ Name = 'RestartRequired'; Exit = 0; Starts = 1 }
    @{ Name = 'ServiceMissing'; Exit = 1; Starts = 1 }
    @{ Name = 'HashMismatch'; Exit = 1; Starts = 0 }
    @{ Name = 'LogAclFailure'; Exit = 1; Starts = 0 }
    @{ Name = 'ProcessStartFailure'; Exit = 1; Starts = 1 }
)
$results = @()
foreach ($case in $cases) {
    $caseRoot = Join-Path $runRoot $case.Name
    $share = Join-Path $caseRoot 'Share'
    $temp = Join-Path $caseRoot 'Temp'
    $logs = Join-Path $caseRoot 'Logs'
    foreach ($dir in $share, $temp, $logs) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $fixtureMsi = Join-Path $share 'fixture.msi'
    [IO.File]::WriteAllText($fixtureMsi, 'Synthetic data only. This is not an installable MSI package.')
    $sha1 = (Get-FileHash -LiteralPath $fixtureMsi -Algorithm SHA1).Hash
    if ($case.Name -eq 'HashMismatch') { $sha1 = '0000000000000000000000000000000000000000' }
    @{ fileName = 'fixture.msi'; version = 'TEST'; sha1 = $sha1 } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $share 'manifest.json') -Encoding UTF8
    $statusLog = Join-Path $logs 'S1-Install.log'
    $privateDir = Join-Path $logs 'SentinelOne-Installer'
    $scriptText = $template.Replace('__SITE_TOKEN__', 'SYNTHETIC_TEST_TOKEN_ONLY_0123456789').
        Replace('__SHARE_UNC__', $share.Replace("'", "''")).
        Replace('C:\CBIT\Logs\S1-Install.log', $statusLog.Replace("'", "''")).
        Replace('C:\CBIT\Logs\SentinelOne-Installer', $privateDir.Replace("'", "''"))
    Set-Content -LiteralPath (Join-Path $caseRoot 'Install-S1.ps1') -Value $scriptText -Encoding UTF8
    $output = @(& $engine -NoLogo -NoProfile -File $harnessPath -CaseRoot $caseRoot -CaseName $case.Name 2>&1)
    $actualExit = $LASTEXITCODE
    Assert-True ($actualExit -eq $case.Exit) "$($case.Name): expected exit $($case.Exit), got $actualExit. Fixtures retained at $caseRoot."
    $result = Get-Content -LiteralPath (Join-Path $caseRoot 'result.json') -Raw | ConvertFrom-Json
    Assert-True ($result.Starts -eq $case.Starts) "$($case.Name): wrong number of installer starts."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $temp 'fixture.msi'))) "$($case.Name): staged MSI was not cleaned up."
    if ($case.Starts -gt 0) {
        Assert-True ($result.AclValid -and $result.ArgumentsValid) "$($case.Name): logging protection or MSI invocation invalid."
    }
    if ($case.Name -in 'Installer1603', 'Success', 'RestartRequired', 'ServiceMissing') {
        Assert-True (Test-Path -LiteralPath $result.MsiLog) "$($case.Name): detailed installer log was lost."
    }
    if ($case.Name -eq 'AlreadyInstalled') {
        Assert-True (-not (Test-Path -LiteralPath $statusLog)) 'Already installed: unexpected logging or installation work.'
    } else {
        $status = Get-Content -LiteralPath $statusLog -Raw
        Assert-True (-not $status.Contains('SYNTHETIC_TEST_TOKEN_ONLY_0123456789')) "$($case.Name): site token leaked to ordinary status log."
        if ($case.Name -eq 'Installer1603') {
            Assert-True ($status.Contains('1603') -and $status.Contains($result.MsiLog)) 'Installer failure did not point to the preserved MSI log.'
        }
        if ($case.Name -eq 'ServiceMissing') { Assert-True ($status.Contains('service never appeared')) 'Missing-service failure was not reported.' }
    }
    $results += [pscustomobject]@{ Scenario = $case.Name; ExitCode = $actualExit; Passed = $true }
}

# Delete only this test invocation's verified, uniquely owned directory.
$resolvedRun = (Resolve-Path -LiteralPath $runRoot).Path
Assert-True ($resolvedRun.StartsWith($testsRoot + '\s1-startup-', [StringComparison]::OrdinalIgnoreCase)) 'Unsafe test cleanup path.'
Remove-Item -LiteralPath $resolvedRun -Recurse -Force
[pscustomobject]@{ Engine = 'Windows PowerShell 5.1'; DeploymentExecuted = $false; InstallerExecuted = $false; Cases = $results } | ConvertTo-Json -Depth 4
