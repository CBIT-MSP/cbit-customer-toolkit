#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = Join-Path $PSScriptRoot '..\package\Modules\Cbit.CustomerToolkit\Functions\Scan-Network.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Extract only discovery; never run the scanner or send network traffic.
$discovery = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ActiveInterfaces'}, $true)
. ([scriptblock]::Create($discovery.Extent.Text))
function Get-NetAdapter {
    @(
        [pscustomobject]@{Name='Guest'; InterfaceDescription='Microsoft Hyper-V Network Adapter'; ifIndex=1; Status='Up'}
        [pscustomobject]@{Name='VMware'; InterfaceDescription='VMware Virtual Ethernet Adapter'; ifIndex=2; Status='Up'}
        [pscustomobject]@{Name='Physical'; InterfaceDescription='Intel Ethernet'; ifIndex=3; Status='Up'}
        [pscustomobject]@{Name='Down'; InterfaceDescription='Intel Ethernet'; ifIndex=4; Status='Disconnected'}
        [pscustomobject]@{Name='Bluetooth'; InterfaceDescription='Bluetooth PAN'; ifIndex=5; Status='Up'}
        [pscustomobject]@{Name='Loopback'; InterfaceDescription='Loopback Adapter'; ifIndex=6; Status='Up'}
        [pscustomobject]@{Name='vEthernet'; InterfaceDescription='Hyper-V Virtual Ethernet Adapter'; ifIndex=7; Status='Up'}
        [pscustomobject]@{Name='Unaddressed'; InterfaceDescription='Virtual NIC'; ifIndex=8; Status='Up'}
    )
}
function Get-NetIPAddress {
    param($InterfaceIndex,$AddressFamily,$ErrorAction)
    if ($InterfaceIndex -in 4,5,6) { throw 'Excluded adapter was queried.' }
    $ips = switch ($InterfaceIndex) {
        1 { '10.70.70.2' }
        2 { '192.168.1.4' }
        3 { '10.0.0.2'; '10.0.1.2'; '169.254.1.2'; '127.2.3.4'; '0.0.0.0' }
        7 { '172.16.0.1' }
        8 { }
    }
    foreach ($ip in $ips) { [pscustomobject]@{IPAddress=$ip; PrefixLength=24} }
}
$results = @(Get-ActiveInterfaces)
if ($results.Count -ne 5) { throw "Expected 5 usable addresses, got $($results.Count)." }
if ($results.CIDR -notcontains '10.70.70.2/24') { throw 'Hyper-V guest adapter was lost.' }
if ($results.CIDR -notcontains '192.168.1.4/24') { throw 'VMware guest adapter was lost.' }
if ($results.CIDR -notcontains '172.16.0.1/24') { throw 'Host vEthernet adapter was lost.' }
if (@($results | Where-Object Name -eq Physical).Count -ne 2) { throw 'Multiple IP addresses were not kept as separate subnets.' }
if (@($results | Where-Object { $_.IPAddress -isnot [string] -or $_.PrefixLength -isnot [int] }).Count) { throw 'Interface row contains an array instead of one IP and prefix.' }
[pscustomobject]@{VirtualAndPhysicalAdapters='Passed'; MultipleAddresses='Passed'; InvalidAddressesExcluded='Passed'; NetworkScansRun=0} | ConvertTo-Json
