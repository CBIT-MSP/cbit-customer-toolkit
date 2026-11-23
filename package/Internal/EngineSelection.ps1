#Requires -Version 5.1
function Test-PowerShell7Executable {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $result = & $Path -NoLogo -NoProfile -NonInteractive -Command 'if ($PSVersionTable.PSVersion.Major -ge 7) { "CBIT-PowerShell7-OK"; exit 0 }; exit 1' 2>$null
        return ($LASTEXITCODE -eq 0 -and $result -contains 'CBIT-PowerShell7-OK')
    } catch { return $false }
}
function Find-PowerShell7 {
    # The machine install is discoverable even with this process's old PATH.
    $candidates = @(
        foreach ($root in @($env:ProgramW6432, $env:ProgramFiles)) {
            if ($root) { Join-Path $root 'PowerShell\7\pwsh.exe' }
        }
        Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source
        if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe' }
    )
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-PowerShell7Executable -Path $candidate) { return $candidate }
    }
    return $null
}
function Get-PowerShell7InstallMethod {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ($os.ProductType -ne 1) { return 'MSI' }
    if (Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue) { return 'WinGet' }
    return 'MSI'
}
function Install-PowerShell7Msi {
    # Pinned supported LTS; update this version when servicing the toolkit.
    $version = '7.6.6'
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $assetArchitecture = switch ($architecture) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        default { throw "PowerShell MSI installation is not configured for architecture '$architecture'." }
    }
    $folder = Join-Path ([IO.Path]::GetTempPath()) ('CBIT-PowerShell7-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $folder -ErrorAction Stop
    $installer = Join-Path $folder "PowerShell-$version-win-$assetArchitecture.msi"
    $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12
        $uri = "https://github.com/PowerShell/PowerShell/releases/download/v$version/PowerShell-$version-win-$assetArchitecture.msi"
        Invoke-WebRequest -Uri $uri -OutFile $installer -UseBasicParsing -ErrorAction Stop
        $signature = Get-AuthenticodeSignature -LiteralPath $installer -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
            throw 'PowerShell MSI signature verification failed. The installer was not run.'
        }
        $arguments = '/i "{0}" /passive /norestart ADD_PATH=1' -f $installer
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -notin @(0,3010)) { throw "PowerShell MSI installation failed (exit code $($process.ExitCode))." }
        if ($process.ExitCode -eq 3010) { Write-Warning 'The PowerShell installer reports that a restart is required. No restart was initiated.' }
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
        if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $folder -ErrorAction SilentlyContinue
    }
}
function Install-PowerShell7 {
    $existing = Find-PowerShell7
    if ($existing) { return $existing }
    if ((Get-PowerShell7InstallMethod) -eq 'MSI') {
        Write-Host 'Installing PowerShell 7 with the Microsoft MSI installer...' -ForegroundColor Yellow
        Install-PowerShell7Msi
    } else {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) { throw 'PowerShell 7 is not installed and Windows Package Manager (winget) is unavailable. Nothing was installed.' }
    Write-Host 'Installing PowerShell 7 with Windows Package Manager...' -ForegroundColor Yellow
    $arguments = @('install','--id','Microsoft.PowerShell','--exact','--source','winget',
        '--silent','--disable-interactivity','--accept-package-agreements','--accept-source-agreements')
    & $winget.Source @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "PowerShell 7 installation failed (winget exit code $LASTEXITCODE)." }
    }
    $installed = Find-PowerShell7
    if (-not $installed) { throw 'The installer completed, but no working PowerShell 7 executable was found. Check the installation or any restart requirement; toolkit startup cannot continue in PowerShell 7.' }
    return $installed
}
function Get-WindowsPowerShellPath {
    $path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Windows PowerShell was not found.' }
    return $path
}
function Select-ToolkitEngine {
    param(
        [ValidateSet('Auto','PowerShell7','WindowsPowerShell')][string]$Engine = 'Auto',
        [switch]$Verify
    )
    if ($Engine -eq 'WindowsPowerShell') { return Get-WindowsPowerShellPath }
    $powerShell7 = Find-PowerShell7
    if ($powerShell7) { return $powerShell7 }
    if ($Verify) {
        if ($Engine -eq 'PowerShell7') { throw 'PowerShell 7 is not installed or not available. Nothing was installed.' }
        return Get-WindowsPowerShellPath
    }
    Write-Host 'A working PowerShell 7 installation was not found.' -ForegroundColor Yellow
    Write-Host 'Windows PowerShell 5.1 can run most toolkit tools. Network scanning and email authentication require PowerShell 7.'
    $answer = [string](Read-Host 'Install PowerShell 7 now (MSI on Windows Server; elevation may be required)? [y/N]')
    if ($answer.Trim() -ieq 'y') { return Install-PowerShell7 }
    if ($Engine -eq 'PowerShell7') { throw 'PowerShell 7 was requested, but installation was declined. Nothing was installed.' }
    Write-Host 'Continuing with Windows PowerShell 5.1. Nothing was installed.'
    return Get-WindowsPowerShellPath
}
