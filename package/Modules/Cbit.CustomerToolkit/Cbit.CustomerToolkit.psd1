@{
    RootModule = 'Cbit.CustomerToolkit.psm1'
    ModuleVersion = '0.3.4'
    GUID = 'a0fcff91-f9ac-4927-a57b-02854b7a6e94'
    Author = 'CBIT'
    Description = 'Temporary customer-session packaging of the roaming technician tools.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Get-BitLockerInformation', 'Get-ClipLength', 'Get-SystemDetails',
        'Invoke-InternetSpeedTest', 'Invoke-ServerInventory', 'npp', 'FlushMe',
        'Repair-Winget', 'Scan-Network', 'Show-TechMenu', 'Start-Pulse',
        'Test-EmailAuthentication', 'Test-Internet', 'Test-Network', 'Test-Site',
        'Get-ToolkitStatus', 'Remove-OEMBloatware', 'Configure-DellPower', 'Optimize-Windows11',
        'Start-CBITGPODeployment', 'Start-CBITQRCodeUtility'
    )
    AliasesToExport = @(
        'sysinfo', 'sys', 'speedtest', 'inventory', 'serverinv', 'np', 'Renew-Safe',
        'tech', 'techmenu', 'pulse', 'Test-EmailDNS', 'Check-EmailDNS', 'Test-DMARC',
        'net-test', 'Invoke-NetTest'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
}
