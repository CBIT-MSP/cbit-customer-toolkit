#Requires -Version 5.1
param([Parameter(Mandatory)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$module = Import-Module (Join-Path $PackageRoot 'Modules\Cbit.CustomerToolkit\Cbit.CustomerToolkit.psd1') -PassThru -DisableNameChecking -Force
$config = & $module { Get-ToolkitGpoLaunchConfiguration }
$expectedHash = '126207DA34D152CFB5272A88026A63BC91AF8F615FCA71FE566B9B57248247D8'
Assert-True ((Get-FileHash -LiteralPath $config.Entry -Algorithm SHA256).Hash -eq $expectedHash) 'The packaged deployment script differs from the SentinelOne MSI diagnostics revision.'
Assert-True ($config.Engine -like '*\WindowsPowerShell\v1.0\powershell.exe') 'Deployment did not select native Windows PowerShell.'
Assert-True ($config.ReportRoot -eq 'C:\CBIT\Reports\GPO' -and $config.LogRoot -eq 'C:\CBIT\Logs\GPO') 'Reports/state would not survive session cleanup.'
Assert-True ($null -eq (Get-Command Invoke-CBITAxisDeployment -ErrorAction SilentlyContinue)) 'The deployment payload was loaded into the toolkit process.'

# Mock only the adapter boundary. Never execute the deployment payload or AD commands.
$result = & $module {
    $script:GpoTestAdmin = $true
    $script:GpoTestExit = 0
    $script:GpoTestLaunchFailure = $false
    $script:GpoTestCalls = 0
    function script:Assert-ToolkitGpoAdministrator { if (-not $script:GpoTestAdmin) { throw 'Test: not elevated' } }
    function script:Start-Process {
        param($FilePath,$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru,$ErrorAction)
        $script:GpoTestCalls++
        if ($script:GpoTestLaunchFailure) { throw 'Test: process launch failed' }
        $script:GpoTestInvocation = @{ FilePath=$FilePath; Arguments=$ArgumentList; SameConsole=[bool]$NoNewWindow }
        $script:GpoTestChild = [pscustomobject]@{
            Handle=1; Id=99999999; StartTime=(Get-Date); HasExited=$false; ExitCode=$script:GpoTestExit
            Waited=$false; Disposed=$false; LeaseDir=(Join-Path (Get-ToolkitGpoLaunchConfiguration).PackageRoot '.maintenance-workers')
        }
        $script:GpoTestChild | Add-Member ScriptMethod WaitForExit {
            $leases = @(Get-ChildItem -LiteralPath $this.LeaseDir -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object Tool -eq 'GPO Deployment')
            if ($leases.Count -ne 1 -or $leases[0].State -ne 'Running' -or $leases[0].Pid -ne $this.Id) { throw 'Worker was not protected during execution.' }
            $this.Waited=$true; $this.HasExited=$true
        }
        $script:GpoTestChild | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
        return $script:GpoTestChild
    }
    Start-CBITGPODeployment 6>$null
    $success = $script:GpoTestChild.Waited -and $script:GpoTestChild.Disposed
    $invocation = $script:GpoTestInvocation
    $script:GpoTestExit = 1
    $failureReported = $false
    try { Start-CBITGPODeployment 6>$null } catch { $failureReported = $_.Exception.Message -like '*exited with an error*' }
    $script:GpoTestLaunchFailure = $true
    $launchFailureReported = $false
    try { Start-CBITGPODeployment 6>$null } catch { $launchFailureReported = $_.Exception.Message -eq 'Test: process launch failed' }
    $callsBefore = $script:GpoTestCalls
    $script:GpoTestAdmin = $false
    $elevationBlocked = $false
    try { Start-CBITGPODeployment 6>$null } catch { $elevationBlocked = $_.Exception.Message -eq 'Test: not elevated' }
    $remaining = @(Get-ChildItem -LiteralPath (Join-Path (Get-ToolkitGpoLaunchConfiguration).PackageRoot '.maintenance-workers') -Filter '*.json' |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object Tool -eq 'GPO Deployment')
    [pscustomobject]@{
        Success=$success; Invocation=$invocation; FailureReported=$failureReported; LaunchFailureReported=$launchFailureReported
        ElevationBlocked=($elevationBlocked -and $callsBefore -eq $script:GpoTestCalls); LeasesRemoved=($remaining.Count -eq 0)
    }
}
Assert-True ($result.Success -and $result.FailureReported -and $result.LaunchFailureReported -and $result.ElevationBlocked -and $result.LeasesRemoved) 'Adapter lifecycle/failure checks failed.'
Assert-True ($result.Invocation.SameConsole -and $result.Invocation.FilePath -eq $config.Engine) 'Wrong deployment process/console.'
Assert-True ($result.Invocation.Arguments.Contains('"-File" "' + $config.Entry + '"')) 'Deployment path was not quoted as one argument.'
Assert-True ($result.Invocation.Arguments.Contains('"-ReportRoot" "C:\CBIT\Reports\GPO" "-LogRoot" "C:\CBIT\Logs\GPO"')) 'Persistent paths were not passed to the payload.'
Remove-Module Cbit.CustomerToolkit
[pscustomobject]@{ PowerShell=$PSVersionTable.PSVersion.ToString(); PayloadRevision='Passed'; NativeEngine='Passed'; PersistentReportsAndState='Passed'; MockedLaunchAndReturn='Passed'; FailureAndElevationHandling='Passed'; WorkerLeaseCleanup='Passed'; DeploymentExecuted=$false } | ConvertTo-Json
