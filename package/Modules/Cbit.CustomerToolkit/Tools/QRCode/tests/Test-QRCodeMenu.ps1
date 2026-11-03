#Requires -Version 5.1
# Scripted menu inputs and mocked clipboard/file boundaries. Never touches real credentials.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'QRCodeUtility.psm1') -Force
$module = Get-Module QRCodeUtility
$sample = [pscustomobject]@{
    Type = 'totp'; Issuer = 'Example'; Account = 'test@example.com'
    Secret = 'JBSWY3DPEHPK3PXP'; Algorithm = 'SHA1'; Digits = 6; Period = 30; Counter = $null
    Uri = 'otpauth://totp/Example:test%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example'
}

function Test-MenuScenario {
    param([string[]]$Choices, [object[]]$Reads, [int]$CopyFailures = 0)
    & $module {
        param($Choices, $Reads, $CopyFailures)
        $state = [pscustomobject]@{
            Choices = [Collections.Generic.Queue[string]]::new()
            Reads = [Collections.Generic.Queue[object]]::new()
            Sources = [Collections.Generic.List[string]]::new()
            Copies = [Collections.Generic.List[string]]::new()
            Messages = [Collections.Generic.List[string]]::new()
            CopyFailures = $CopyFailures
        }
        foreach ($choice in $Choices) { $state.Choices.Enqueue($choice) }
        foreach ($read in $Reads) { $state.Reads.Enqueue($read) }
        # These overrides exist only inside this module invocation's child scope.
        function Initialize-QrDecoder { }
        function Initialize-QrClipboard { }
        function Read-Host {
            param($Prompt)
            if ($state.Choices.Count -eq 0) { throw 'The menu requested unexpected input.' }
            $state.Choices.Dequeue()
        }
        function Write-Host {
            param($Object, $ForegroundColor)
            $state.Messages.Add([string]$Object)
        }
        function Read-QRCode {
            param([switch]$Clipboard, [string]$Output)
            if ($Output -ne 'Object') { throw 'The menu must retain the parsed object.' }
            if ($Clipboard) { $state.Sources.Add('Clipboard') } else { $state.Sources.Add('File') }
            if ($state.Reads.Count -eq 0) { throw 'Unexpected extra image read.' }
            $response = $state.Reads.Dequeue()
            if ($response -is [string] -and $response -eq 'error') { throw 'Synthetic image read failure.' }
            if ($response -is [string] -and $response -eq 'cancel') { return }
            return $response
        }
        function Set-QrClipboardText {
            param([string]$Text)
            if ($state.CopyFailures -gt 0) { $state.CopyFailures--; throw 'Synthetic clipboard lock.' }
            $state.Copies.Add($Text)
        }
        $unexpectedOutput = @(Show-QRCodeMenu)
        if ($unexpectedOutput.Count -ne 0) { throw 'The menu leaked pipeline output.' }
        if ($state.Choices.Count -ne 0) { throw 'The menu exited before consuming expected choices.' }
        return $state
    } $Choices $Reads $CopyFailures
}

$passed = 0
$state = Test-MenuScenario -Choices @('1', '1', '2', '0') -Reads @($sample)
if ($state.Sources.Count -ne 1 -or $state.Sources[0] -ne 'Clipboard') { throw 'Clipboard scan must occur exactly once.' }
if ($state.Copies.Count -ne 2 -or $state.Copies[0] -cne $sample.Secret -or $state.Copies[1] -cne $sample.Uri) { throw 'Both formats must be copied from one scan.' }
if (($state.Messages -join "`n").Contains($sample.Secret)) { throw 'Secret was printed by the menu.' }
$passed++

$state = Test-MenuScenario -Choices @('2', '2', '3', '0') -Reads @($sample)
if ($state.Sources[0] -ne 'File' -or $state.Copies[0] -cne $sample.Uri) { throw 'File source or URI action failed.' }
$passed++

$state = Test-MenuScenario -Choices @('2', '0') -Reads @('cancel')
if ($state.Copies.Count -ne 0 -or -not ($state.Messages -match 'selection canceled')) { throw 'Cancel did not return to source menu.' }
$passed++

$state = Test-MenuScenario -Choices @('1', '2', '1', '0') -Reads @('error', $sample)
if ($state.Sources.Count -ne 2 -or $state.Copies.Count -ne 1) { throw 'Image read error recovery failed.' }
$passed++

$state = Test-MenuScenario -Choices @('invalid', '1', 'invalid', '1', '0') -Reads @($sample)
if ($state.Copies.Count -ne 1 -or $state.Sources.Count -ne 1) { throw 'Invalid choices changed state.' }
$passed++

$state = Test-MenuScenario -Choices @('1', '1', '2', '0') -Reads @($sample) -CopyFailures 1
if ($state.Copies.Count -ne 1 -or $state.Copies[0] -cne $sample.Uri -or -not ($state.Messages -match 'Could not copy')) { throw 'Clipboard retry failed.' }
$passed++

$state = Test-MenuScenario -Choices @('1', '3', '2', '0') -Reads @($sample, 'cancel')
if ($state.Copies.Count -ne 0 -or $state.Sources.Count -ne 2) { throw 'Previous account was retained after starting another scan.' }
$passed++

$state = Test-MenuScenario -Choices @('0') -Reads @()
if ($state.Copies.Count -ne 0 -or $state.Sources.Count -ne 0) { throw 'Exit performed unexpected work.' }
$passed++

$custom = $sample.PSObject.Copy()
$custom.Period = 60
$state = Test-MenuScenario -Choices @('1', '0') -Reads @($custom)
if (-not ($state.Messages -match 'non-default OTP') -or -not ($state.Messages -match 'period: 60')) { throw 'Non-default OTP settings were hidden.' }
$passed++

Write-Output "$passed menu scenarios passed on PowerShell $($PSVersionTable.PSVersion)."
