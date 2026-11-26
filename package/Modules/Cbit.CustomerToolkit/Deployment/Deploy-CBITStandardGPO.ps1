#requires -Version 5.1
<#
.SYNOPSIS
Interactive CBIT GPO deployment, with independently callable functions.
.DESCRIPTION
Dot-source with -FunctionsOnly, then call Invoke-CBITAxisDeployment,
Invoke-CBITEndpointDeployment, Invoke-CBITSentinelOneDeployment, or Invoke-CBITAction1Deployment.
Existing settings require -ApproveChanges; compliant reruns need no approval.
No production-style GPO is removed or imported over. Changes are backed up.
The optional privileged access runbook retains its original operator gates.
#>
[CmdletBinding()]
param([switch]$FunctionsOnly,[switch]$Resume,
    [string]$ReportRoot,
    [string]$LogRoot)

function Initialize-CBITRuntime {
    # Import the native engine's module explicitly: do not depend on command
    # auto-discovery or an inherited PSModulePath for script-based utilities.
    $utility = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'
    try {
        Import-Module -Name $utility -Scope Global -Force -ErrorAction Stop
        $hashCommand = Get-Command -Name Get-FileHash -Module Microsoft.PowerShell.Utility -ErrorAction Stop
        if (-not $hashCommand) { throw 'Get-FileHash was not exported.' }
    } catch {
        throw ("Required Windows PowerShell utility Get-FileHash is unavailable after loading {0}. No deployment was started. {1}" -f $utility, $_.Exception.Message)
    }
}
Initialize-CBITRuntime
# CBIT presentation only: standard ConsoleColor fallback palette.
$Host.UI.RawUI.ForegroundColor = 'Gray'
$Host.PrivateData.ErrorForegroundColor = 'DarkRed'
$Host.PrivateData.WarningForegroundColor = 'DarkYellow'
$Host.PrivateData.VerboseForegroundColor = 'DarkGray'
$Host.PrivateData.DebugForegroundColor = 'DarkGray'
$Host.PrivateData.ProgressForegroundColor = 'DarkGray'
$Host.PrivateData.ProgressBackgroundColor = 'Black'

if (-not $ReportRoot) { $ReportRoot=Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path)) 'reports' }
if (-not $LogRoot) { $LogRoot=Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path)) 'logs' }
$script:CBITReportRoot = $ReportRoot
$script:CBITLogRoot = $LogRoot
$script:CBITRunId = [guid]::NewGuid().ToString('N')
$script:CBITCurrentScriptPath = $MyInvocation.MyCommand.Path

# The release contains only an encrypted API credential; unlock it when SentinelOne is selected.
. (Join-Path $PSScriptRoot 'CBITCredential.ps1')
$script:CBITCredentialPath = Join-Path $PSScriptRoot 'SentinelOneCredential.json'
$script:CBITDefaultApiToken = $null

$script:CBITLastConsoleColor = $null
function Write-CBITConsole {
    param([Parameter(Position=0,ValueFromRemainingArguments=$true)][object[]]$Object,
        [ConsoleColor]$ForegroundColor='Gray',[ConsoleColor]$BackgroundColor,
        [object]$Separator=' ',[switch]$NoNewline)
    if($script:CBITLastConsoleColor -and $script:CBITLastConsoleColor -ne $ForegroundColor.ToString()){
        Microsoft.PowerShell.Utility\Write-Host ''
    }
    $script:CBITLastConsoleColor=$ForegroundColor.ToString()
    $options=@{Object=$Object;ForegroundColor=$ForegroundColor;Separator=$Separator;NoNewline=$NoNewline}
    if($PSBoundParameters.ContainsKey('BackgroundColor')){$options.BackgroundColor=$BackgroundColor}
    Microsoft.PowerShell.Utility\Write-Host @options
}

function Read-CBITMenuKey {
    $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Select-CBITDeploymentMenu {
    $entries=@(
        @{Key='1';Label='Action1'},
        @{Key='2';Label='Axis'},
        @{Key='3';Label='CyberQP'},
        @{Key='4';Label='SentinelOne'},
        @{Key='5';Label='Complete CBIT Stack'},
        @{Key='6';Label='Resume'},
        @{Key='7';Label='Export CBIT GPO status to C:\CBIT\Logs\GPO (.md)'},
        @{Key='8';Label='Action1 resume / audit / disable link'},
        @{Key='9';Label='CyberQP resume / rollback / dry run'},
        @{Key='0';Label='Exit'}
    )
    $interactive=$Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    if(-not $interactive){
        foreach($entry in $entries){Write-CBITConsole ('  {0}. {1}' -f $entry.Key,$entry.Label) -ForegroundColor Gray}
        return (Read-Host 'Selection').Trim()
    }
    Write-CBITConsole 'Use Up/Down and Enter, or press a number. Option 6 resumes; Esc exits.' -ForegroundColor DarkGray
    Write-CBITConsole '' -ForegroundColor Gray
    $selected=0
    $origin=$Host.UI.RawUI.CursorPosition
    # Reserve rows before capturing the origin, so scrolling cannot invalidate it.
    for($row=0;$row -lt $entries.Count;$row++){Microsoft.PowerShell.Utility\Write-Host ''}
    $bottom=$Host.UI.RawUI.CursorPosition
    $origin.Y=$bottom.Y-$entries.Count
    while($true){
        $Host.UI.RawUI.CursorPosition=$origin
        for($index=0;$index -lt $entries.Count;$index++){
            $marker=if($index -eq $selected){'>'}else{' '}
            $color=if($index -eq $selected){'Gray'}else{'DarkGray'}
            Microsoft.PowerShell.Utility\Write-Host ('{0} {1}. {2}' -f $marker,$entries[$index].Key,$entries[$index].Label) -ForegroundColor $color
        }
        $key=Read-CBITMenuKey
        if($key.VirtualKeyCode -eq 38){$selected=($selected+$entries.Count-1)%$entries.Count;continue}
        if($key.VirtualKeyCode -eq 40){$selected=($selected+1)%$entries.Count;continue}
        if($key.VirtualKeyCode -eq 13){$choice=$entries[$selected].Key;break}
        if($key.VirtualKeyCode -eq 27){$choice='0';break}
        $digit=[string]$key.Character
        if($digit -match '^[0-9rR]$'){$choice=$digit;break}
    }
    $Host.UI.RawUI.CursorPosition=$bottom
    $script:CBITLastConsoleColor='DarkGray'
    Write-CBITConsole ('Selected: '+$choice) -ForegroundColor Gray
    return $choice
}

function Write-CBITStatus {
    param([string]$Message,[ConsoleColor]$Color = 'DarkGray')
    Write-CBITConsole ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
    try {
        New-Item -ItemType Directory -Path $script:CBITLogRoot -Force -ErrorAction Stop | Out-Null
        Add-Content -LiteralPath (Join-Path $script:CBITLogRoot ($script:CBITRunId+'.log')) -Value ((Get-Date -Format s)+' '+$Message) -ErrorAction Stop
    } catch { Write-Warning 'File logging unavailable; console output remains available.' }
}
function Get-CBITEnvironment {
    Write-CBITStatus 'Checking prerequisites and discovering domain/PDC.'
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Use native Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 or a compatibility session.'}
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated with delegated AD/GPO write permissions.' }
    foreach ($m in 'ActiveDirectory','GroupPolicy') {
        if (-not (Get-Module -ListAvailable $m)) { throw "Required module $m missing. Install the appropriate AD/GPMC administration tools." }
        Import-Module $m -ErrorAction Stop
    }
    $d = Get-ADDomain -ErrorAction Stop
    $null = Get-ADRootDSE -Server $d.PDCEmulator -ErrorAction Stop
    $null = Get-GPO -All -Domain $d.DNSRoot -Server $d.PDCEmulator -ErrorAction Stop
    [pscustomobject]@{ Domain=$d.DNSRoot; DN=$d.DistinguishedName; Server=$d.PDCEmulator; NetBIOS=$d.NetBIOSName; SID=$d.DomainSID.Value; UsersPath=$d.UsersContainer }
}
function Get-CBITGpoPath {
    param($Environment,$Gpo)
    '\\{0}\SYSVOL\{1}\Policies\{{{2}}}' -f $Environment.Server,$Environment.Domain,$Gpo.Id
}
function Get-CBITGpoAD {
    param($Environment,$Gpo)
    Get-ADObject -Server $Environment.Server -Identity ('CN={'+$Gpo.Id+'},CN=Policies,CN=System,'+$Environment.DN) -Properties versionNumber,gPCMachineExtensionNames -ErrorAction Stop
}
function Get-CBITGpo {
    param($Environment,[string]$Name)
    $found = @(Get-GPO -All -Domain $Environment.Domain -Server $Environment.Server -ErrorAction Stop | Where-Object DisplayName -eq $Name)
    if ($found.Count -gt 1) { throw "Ambiguous GPO name '$Name': $($found.Count) matches. Resolve manually." }
    if ($found.Count) { Write-CBITStatus "Existing object detected: $Name [$($found[0].Id)]."; return $found[0] }
    Write-CBITStatus "Creating unlinked GPO: $Name."
    New-GPO -Name $Name -Domain $Environment.Domain -Server $Environment.Server -ErrorAction Stop
}
function Assert-CBITChange {
    param($Context,[string]$Description)
    Write-CBITStatus "Planned change: $Description" -Color DarkYellow
    if ($Context.Existing -and -not $Context.ApproveChanges) { throw "Existing GPO requires review. Rerun with -ApproveChanges to authorize: $Description" }
    if (-not $Context.BackedUp) {
        $dir = Join-Path $script:CBITReportRoot ('backups\'+$script:CBITRunId+'\'+$Context.Gpo.Id)
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        Backup-GPO -Guid $Context.Gpo.Id -Domain $Context.Env.Domain -Server $Context.Env.Server -Path $dir -ErrorAction Stop | Out-Null
        $Context.BackedUp = $true
    }
    $Context.Changed = $true
}
function New-CBITContext {
    param([string]$Name,[bool]$ApproveChanges)
    $e = Get-CBITEnvironment
    $found = @(Get-GPO -All -Domain $e.Domain -Server $e.Server -ErrorAction Stop | Where-Object DisplayName -eq $Name)
    @{ Env=$e; Gpo=(Get-CBITGpo $e $Name); Existing=($found.Count -gt 0); Changed=$false; BackedUp=$false; ApproveChanges=$ApproveChanges; Checks=[ordered]@{} }
}
function Set-CBITFile {
    param($Context,[string]$Path,[string]$Text,[string]$Encoding='UTF8')
    if ((Test-Path -LiteralPath $Path) -and ((Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) -ceq $Text)) { return $false }
    Assert-CBITChange $Context "Write managed content in $Path (preserving other items)."
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force -ErrorAction Stop | Out-Null
    Set-Content -LiteralPath $Path -Value $Text -Encoding $Encoding -NoNewline -ErrorAction Stop
    return $true
}
function Get-CBITXmlSignature {
    param([System.Xml.XmlNode]$Node)
    $copy=$Node.CloneNode($true)
    foreach($empty in $copy.SelectNodes('.//*[not(node())]')) { $empty.IsEmpty=$true }
    $copy.OuterXml
}
function Update-CBITMachineMetadata {
    # Preserve all existing CSE pairs and the user version (high 16 bits).
    param($Context,[string[]]$Pairs,[bool]$ContentChanged)
    $o = Get-CBITGpoAD $Context.Env $Context.Gpo
    $old = [string]$o.gPCMachineExtensionNames
    $entries = @([regex]::Matches($old,'\[\{[^}]+\}\{[^}]+\}\]') | ForEach-Object Value)
    if (($entries -join '') -cne $old) { throw "Unexpected CSE metadata on $($Context.Gpo.Id); refusing to replace it." }
    $merged = (@($entries + $Pairs) | Sort-Object -Unique) -join ''
    if (-not $ContentChanged -and $merged -ceq $old) { return }
    Assert-CBITChange $Context "Register required machine extensions and increment computer version on $($Context.Gpo.DisplayName)."
    $v = [uint32]([int64]$o.versionNumber -band 4294967295L)
    $next = ([int64]$v -band 4294901760L) -bor ((($v -band 65535)+1) -band 65535)
    $signed = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$next),0)
    $ini = Join-Path (Get-CBITGpoPath $Context.Env $Context.Gpo) 'GPT.INI'
    $text = Get-Content -LiteralPath $ini -Raw -ErrorAction Stop
    if ($text -notmatch '(?im)^Version=\d+') { throw "GPT.INI has no Version: $ini" }
    $text = [regex]::Replace($text,'(?im)^Version=\d+',('Version='+$next))
    Set-Content -LiteralPath $ini -Value $text -Encoding ASCII -NoNewline -ErrorAction Stop
    Set-ADObject -Identity $o -Server $Context.Env.Server -Replace @{gPCMachineExtensionNames=$merged;versionNumber=$signed} -ErrorAction Stop
}
function Assert-CBITTargets {
    param($Environment,[string[]]$TargetDn,[switch]$WorkstationsOnly)
    foreach ($t in $TargetDn) {
        if ($t -ieq $Environment.DN) { if ($WorkstationsOnly) { throw 'Endpoint administrator GPO requires a workstation OU, not domain root.' }; continue }
        $ou = Get-ADOrganizationalUnit -Identity $t -Server $Environment.Server -ErrorAction Stop
        if (-not $ou.DistinguishedName.EndsWith(','+$Environment.DN,[StringComparison]::OrdinalIgnoreCase)) { throw "Target outside current domain: $t" }
        if ($WorkstationsOnly) {
            $unsafe = @(Get-ADComputer -SearchBase $t -SearchScope Subtree -Filter * -Server $Environment.Server -Properties OperatingSystem,PrimaryGroupID | Where-Object { $_.PrimaryGroupID -in 516,521 -or $_.OperatingSystem -notlike 'Windows*' -or $_.OperatingSystem -like '*Server*' })
            if ($unsafe.Count) { throw "Workstation scope $t contains server/DC/unknown OS: $(($unsafe.Name) -join ', '). Review placement first." }
        }
    }
}
function Set-CBITLinks {
    param($Context,[string[]]$TargetDn,[bool]$Enforced)
    $current=Get-GPO -Guid $Context.Gpo.Id -Domain $Context.Env.Domain -Server $Context.Env.Server -ErrorAction Stop
    if($current.GpoStatus -notin 'AllSettingsEnabled','UserSettingsDisabled'){throw "Computer settings disabled on $($current.DisplayName); review status manually before linking."}
    $ad=Get-CBITGpoAD $Context.Env $current
    $ini=Get-Content (Join-Path (Get-CBITGpoPath $Context.Env $current) 'GPT.INI') -Raw
    $v=[regex]::Match($ini,'(?im)^Version=(\d+)').Groups[1].Value
    if(-not $v -or [int64]$v -ne ([int64]$ad.versionNumber -band 4294967295L)){throw "AD/SYSVOL version mismatch on $($current.Id); refusing links."}
    foreach ($t in @($TargetDn | Select-Object -Unique)) {
        $l = @((Get-GPInheritance -Target $t -Domain $Context.Env.Domain -Server $Context.Env.Server -ErrorAction Stop).GpoLinks | Where-Object GpoId -eq $Context.Gpo.Id)
        if ($l.Count -gt 1) { throw "Duplicate links to $t; resolve manually." }
        if (-not $l.Count -or -not $l[0].Enabled -or $l[0].Enforced -ne $Enforced) {
            Assert-CBITChange $Context "Link $($Context.Gpo.DisplayName) at $t, enabled, enforced=$Enforced."
            $args = @{Guid=$Context.Gpo.Id;Target=$t;Domain=$Context.Env.Domain;Server=$Context.Env.Server;LinkEnabled='Yes';Enforced=$(if($Enforced){'Yes'}else{'No'});ErrorAction='Stop'}
            if ($l.Count) { Set-GPLink @args | Out-Null } else { New-GPLink @args | Out-Null }
        }
        $read = @((Get-GPInheritance -Target $t -Domain $Context.Env.Domain -Server $Context.Env.Server -ErrorAction Stop).GpoLinks | Where-Object GpoId -eq $Context.Gpo.Id)
        $Context.Checks['Link '+$t] = ($read.Count -eq 1 -and $read[0].Enabled -and $read[0].Enforced -eq $Enforced)
    }
}
function Complete-CBITDeployment {
    param($Context,[string]$Policy)
    Write-CBITStatus "Verifying $Policy by reading AD, SYSVOL and GPO report."
    $g = Get-GPO -Guid $Context.Gpo.Id -Domain $Context.Env.Domain -Server $Context.Env.Server -ErrorAction Stop
    $o = Get-CBITGpoAD $Context.Env $g
    $ini = Get-Content -LiteralPath (Join-Path (Get-CBITGpoPath $Context.Env $g) 'GPT.INI') -Raw -ErrorAction Stop
    $version = [regex]::Match($ini,'(?im)^Version=(\d+)').Groups[1].Value
    $Context.Checks['AD/SYSVOL version agreement'] = ([int64]$version -eq ([int64]$o.versionNumber -band 4294967295L))
    $Context.Checks['Computer settings enabled'] = ($g.GpoStatus -in 'AllSettingsEnabled','UserSettingsDisabled')
    New-Item -ItemType Directory -Path $script:CBITReportRoot -Force | Out-Null
    $stem = Join-Path $script:CBITReportRoot ($script:CBITRunId+'-'+$g.Id)
    Get-GPOReport -Guid $g.Id -Domain $Context.Env.Domain -Server $Context.Env.Server -ReportType Xml -Path ($stem+'.xml') -ErrorAction Stop
    $bad = @($Context.Checks.Keys | Where-Object { -not $Context.Checks[$_] })
    $status = if($bad.Count){'Unable to verify'}elseif(-not $Context.Existing){'Successfully configured and verified'}elseif($Context.Changed){'Changed and successfully verified'}else{'Already correctly configured'}
    $result = [pscustomobject]@{Policy=$Policy;Name=$g.DisplayName;Id=$g.Id;Status=$status;Checks=$Context.Checks;Time=(Get-Date -Format s)}
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath ($stem+'.json') -Encoding UTF8
    Write-CBITStatus "$Policy : $status." -Color $(if($bad.Count){'DarkYellow'}else{'DarkGreen'})
    if ($bad.Count) { throw "Unable to verify $Policy [$($g.Id)]: $($bad -join '; '). GPO retained for inspection." }
    $result
}
function Save-CBITFailure {
    param([string]$Policy,$ErrorRecord)
    Write-CBITStatus "Failure in $Policy : $($ErrorRecord.Exception.Message). Partial changes, if any, are retained; review backup and logs." -Color DarkRed
    try {
        New-Item -ItemType Directory -Path $script:CBITReportRoot -Force | Out-Null
        [pscustomobject]@{Policy=$Policy;Status='Failed';Detail=$ErrorRecord.Exception.Message;Time=(Get-Date -Format s)} | ConvertTo-Json | Set-Content (Join-Path $script:CBITReportRoot ($script:CBITRunId+'-failure-'+$Policy+'.json'))
    } catch { Write-Warning 'Could not save failure report.' }
}

function Show-CBITPreamble {
    Write-CBITConsole "`nCBIT deployment - installer staging" -ForegroundColor Gray
    Write-CBITConsole 'Run as Administrator in Windows PowerShell 5.1 on the customer DC/package host.' -ForegroundColor DarkGray
    Write-CBITConsole '' -ForegroundColor DarkGray
    Write-CBITConsole 'AXIS: drop the extracted installer folder here:' -ForegroundColor Gray
    Write-CBITConsole '  C:\CBIT\CBITAgent-<Customer>-Setup\' -ForegroundColor Gray
    Write-CBITConsole '  Folder contents: CBITAgentInstaller.exe, customer.ini, pkg\<customer MSI>, pkg\vc_redist.x64.exe.' -ForegroundColor Gray
    Write-CBITConsole '' -ForegroundColor Gray
    Write-CBITConsole 'ACTION1: drop the MSI here:' -ForegroundColor Gray
    Write-CBITConsole '  C:\CBIT\<installer filename>.msi' -ForegroundColor Gray
    Write-CBITConsole '  Enter C:\CBIT (or the full MSI path) when prompted; matching action1_agent*.msi files are detected.' -ForegroundColor Gray
    Write-CBITConsole '' -ForegroundColor Gray
    Write-CBITConsole 'SENTINELONE: no installer staging needed; the script downloads the package automatically.' -ForegroundColor Gray
    Write-CBITConsole '' -ForegroundColor Gray
    Write-CBITConsole 'CYBERQP: no installer staging needed. Have the CBIT-DA and CBIT elevation credentials ready in IT Glue.' -ForegroundColor Gray
    Write-CBITConsole '' -ForegroundColor Gray
}
function Assert-CBITAxisPath {
    param([string]$Path)
    $absolute=[IO.Path]::GetFullPath($Path)
    $cursor=$absolute
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Axis paths cannot contain junctions/symlinks: $cursor"}
        }
        $parent=Split-Path $cursor -Parent
        if($parent -eq $cursor){break};$cursor=$parent
    }
    $absolute.TrimEnd('\')
}
function Get-CBITAxisManifest {
    # Never read or display customer.ini contents. Only inspect metadata and SHA256.
    param([Parameter(Mandatory)][string]$Path)
    $absolute=Assert-CBITAxisPath $Path
    if(-not(Test-Path -LiteralPath $absolute -PathType Container)){throw "Axis payload folder missing: $absolute"}
    $entries=@(Get-ChildItem -LiteralPath $absolute -Force -ErrorAction Stop)
    if(@($entries | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw "Reparse point in Axis kit: $absolute"}
    $roots=@($entries | Where-Object {-not $_.PSIsContainer})
    $dirs=@($entries | Where-Object PSIsContainer)
    if($roots.Count -ne 2 -or @($roots | Where-Object Name -eq 'CBITAgentInstaller.exe').Count -ne 1 -or @($roots | Where-Object Name -eq 'customer.ini').Count -ne 1 -or $dirs.Count -ne 1 -or $dirs[0].Name -ne 'pkg'){
        throw "Axis kit must contain only CBITAgentInstaller.exe, customer.ini and pkg\ at root: $absolute"
    }
    $pkg=@(Get-ChildItem -LiteralPath (Join-Path $absolute 'pkg') -Force -ErrorAction Stop)
    if(@($pkg | Where-Object {$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count -or $pkg.Count -ne 2 -or @($pkg | Where-Object Extension -eq '.msi').Count -ne 1 -or @($pkg | Where-Object Name -eq 'vc_redist.x64.exe').Count -ne 1){
        throw "Axis pkg\ must contain exactly one tenant MSI and vc_redist.x64.exe, with no other entries: $absolute"
    }
    foreach($file in @($roots)+@($pkg)){
        if($file.Length -le 0){throw "Axis payload file is empty: $($file.FullName)"}
        [pscustomobject]@{RelativePath=$file.FullName.Substring($absolute.Length).TrimStart('\');Length=$file.Length;SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash}
    }
}
function Test-CBITAxisNtfs {
    param([string]$Path,$Environment)
    $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
    $expected=@{'S-1-5-18'=[int][Security.AccessControl.FileSystemRights]::FullControl;'S-1-5-32-544'=[int][Security.AccessControl.FileSystemRights]::FullControl}
    $expected[$Environment.SID+'-515']=[int][Security.AccessControl.FileSystemRights]::ReadAndExecute
    $expected[$Environment.SID+'-516']=[int][Security.AccessControl.FileSystemRights]::ReadAndExecute
    if(-not $acl.AreAccessRulesProtected -or $acl.Access.Count -ne 4){return $false}
    foreach($ace in $acl.Access){
        $sid=$ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        # FileSystemAccessRule adds Synchronize to allowed ReadAndExecute rules.
        $rights=[int]$ace.FileSystemRights -band (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize)
        $wanted=if($expected.ContainsKey($sid)){$expected[$sid] -band (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize)}else{-1}
        if($ace.IsInherited -or $ace.AccessControlType -ne 'Allow' -or $rights -ne $wanted){return $false}
        $expected.Remove($sid)
    }
    return $expected.Count -eq 0
}
function Set-CBITAxisNtfs {
    param([string]$Path,$Environment)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Refusing to set ACL on reparse point: $Path"}
    $acl=if($item.PSIsContainer){New-Object Security.AccessControl.DirectorySecurity}else{New-Object Security.AccessControl.FileSecurity}
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach($sid in @('S-1-5-18','S-1-5-32-544',($Environment.SID+'-515'),($Environment.SID+'-516'))){
        $rights=if($sid -in 'S-1-5-18','S-1-5-32-544'){'FullControl'}else{'ReadAndExecute'}
        $identity=New-Object Security.Principal.SecurityIdentifier($sid)
        $rule=if($item.PSIsContainer){New-Object Security.AccessControl.FileSystemAccessRule($identity,$rights,'ContainerInherit,ObjectInherit','None','Allow')}else{New-Object Security.AccessControl.FileSystemAccessRule($identity,$rights,'Allow')}
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    if(-not(Test-CBITAxisNtfs $Path $Environment)){throw "Axis NTFS ACL failed readback: $Path"}
}
function Test-CBITAxisShare {
    param([string]$ShareName,[string]$DeploymentRoot,$Environment)
    $share=Get-SmbShare -Name $ShareName -ErrorAction Stop
    if([IO.Path]::GetFullPath($share.Path).TrimEnd('\') -ine $DeploymentRoot -or $share.FolderEnumerationMode -ne 'AccessBased'){return $false}
    $expected=@(($Environment.SID+'-515'),($Environment.SID+'-516'))
    $access=@(Get-SmbShareAccess -Name $ShareName -ErrorAction Stop)
    if($access.Count -ne 2){return $false}
    foreach($ace in $access){
        $sid=(New-Object Security.Principal.NTAccount($ace.AccountName)).Translate([Security.Principal.SecurityIdentifier]).Value
        if($ace.AccessControlType -ne 'Allow' -or $ace.AccessRight -ne 'Read' -or $sid -notin $expected){return $false}
        $expected=@($expected | Where-Object {$_ -ne $sid})
    }
    return $expected.Count -eq 0
}
function Initialize-CBITAxisPayload {
    [CmdletBinding()]
    param([string]$StagingPath,[string]$StagingRoot='C:\CBIT',[string]$DeploymentRoot='C:\CBIT\AXISdeploy',[string]$ShareName='AXISdeploy$',
        [switch]$ApproveChanges,$Environment)
    $ErrorActionPreference='Stop'
    if(-not $Environment){$Environment=Get-CBITEnvironment}
    foreach($cmd in 'Get-SmbShare','New-SmbShare','Get-SmbShareAccess','Grant-SmbShareAccess','Revoke-SmbShareAccess','Unblock-SmbShareAccess','Set-SmbShare'){if(-not(Get-Command $cmd -ErrorAction SilentlyContinue)){throw "Axis preparation requires $cmd on the package host."}}
    $base=Assert-CBITAxisPath $StagingRoot
    $destination=Assert-CBITAxisPath $DeploymentRoot
    if($destination -eq [IO.Path]::GetPathRoot($destination).TrimEnd('\')){throw 'Axis deployment folder cannot be a drive root.'}
    if($ShareName -notmatch '^[a-zA-Z0-9_-]+\$$'){throw 'Axis requires a valid hidden share name.'}
    if(-not $StagingPath -and (Test-Path -LiteralPath $base)){
        $kits=@(Get-ChildItem -LiteralPath $base -Directory -Force | Where-Object Name -like 'CBITAgent-*-Setup')
        if($kits.Count -gt 1){throw "Multiple staged Axis kits found under $base; choose -StagingPath explicitly."}
        if($kits.Count -eq 1){$StagingPath=$kits[0].FullName}
    }
    $sourceManifest=@()
    if($StagingPath){
        $StagingPath=Assert-CBITAxisPath $StagingPath
        if((Split-Path $StagingPath -Parent) -ine $base -or (Split-Path $StagingPath -Leaf) -notlike 'CBITAgent-*-Setup' -or $StagingPath -ieq $destination -or $destination.StartsWith($StagingPath+'\',[StringComparison]::OrdinalIgnoreCase) -or $StagingPath.StartsWith($destination+'\',[StringComparison]::OrdinalIgnoreCase)){
            throw 'Source cleanup is limited to one named CBITAgent-<Customer>-Setup folder directly under the approved staging root, separate from the deployment folder.'
        }
        $scriptLocation=Assert-CBITAxisPath $script:CBITCurrentScriptPath
        if($scriptLocation.StartsWith($StagingPath+'\',[StringComparison]::OrdinalIgnoreCase) -or $scriptLocation.StartsWith($destination+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Move the unified script outside staging and deployment folders before continuing.'}
        $sourceManifest=@(Get-CBITAxisManifest $StagingPath)
        Write-CBITStatus "Axis staged kit verified: $StagingPath; four nonempty files, exactly one tenant MSI."
    }
    $share=Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if($share -and [IO.Path]::GetFullPath($share.Path).TrimEnd('\') -ine $destination){throw "Existing Axis share $ShareName points to $($share.Path), expected $destination. Nothing replaced."}
    if(-not $StagingPath -and -not(Test-Path -LiteralPath $destination)){throw "No Axis kit or deployed payload. Stage the tenant kit at $base\CBITAgent-<Customer>-Setup\, then rerun."}
    if(Test-Path -LiteralPath $destination){
        $existingEntries=@(Get-ChildItem -LiteralPath $destination -Force)
        if($existingEntries.Count){
            $oldManifest=@(Get-CBITAxisManifest $destination)
            if($sourceManifest.Count -and @(Compare-Object @($sourceManifest.RelativePath) @($oldManifest.RelativePath)).Count){throw "Existing Axis payload filenames differ from staged kit (stale/foreign MSI). Review and remove the old payload explicitly; source retained: $StagingPath"}
        } elseif(-not $StagingPath){throw "Axis deployment folder is empty; stage the tenant kit under $base."}
    }
    $changed=$false
    $needsPermissions=-not $share -or -not(Test-Path -LiteralPath $destination)
    if($share -and -not(Test-CBITAxisShare $ShareName $destination $Environment)){$needsPermissions=$true}
    if(Test-Path -LiteralPath $destination){
        foreach($entry in @((Get-Item $destination))+@(Get-ChildItem -LiteralPath $destination -Recurse -Force)){
            if(-not(Test-CBITAxisNtfs $entry.FullName $Environment)){$needsPermissions=$true;break}
        }
    }
    if(($needsPermissions -or $StagingPath) -and -not $ApproveChanges){throw 'Axis share/payload preparation and hash-verified source cleanup require -ApproveChanges.'}
    New-Item -ItemType Directory -Path $script:CBITReportRoot -Force | Out-Null
    $report=Join-Path $script:CBITReportRoot ($script:CBITRunId+'-AxisPayload.json')
    if($needsPermissions){
        Write-CBITStatus "Hardening Axis folder $destination and share $ShareName BEFORE copying payload." -Color DarkYellow
        $before=[ordered]@{Path=$destination;Share=$ShareName;ShareAccess=@();NTFS=$null}
        if(Test-Path $destination){$before.NTFS=(Get-Acl $destination).Sddl}
        if($share){$before.ShareAccess=@(Get-SmbShareAccess -Name $ShareName | Select-Object AccountName,AccessControlType,AccessRight)}
        $before | ConvertTo-Json -Depth 4 | Set-Content ($report+'.before.json')
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Set-CBITAxisNtfs $destination $Environment
        foreach($entry in @(Get-ChildItem -LiteralPath $destination -Recurse -Force)){Set-CBITAxisNtfs $entry.FullName $Environment}
        $machineNames=@(foreach($sid in @(($Environment.SID+'-515'),($Environment.SID+'-516'))){(New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value})
        if(-not $share){New-SmbShare -Name $ShareName -Path $destination -ReadAccess $machineNames -FolderEnumerationMode AccessBased | Out-Null}
        else{
            foreach($ace in @(Get-SmbShareAccess -Name $ShareName)){
                if($ace.AccessControlType -eq 'Deny'){Unblock-SmbShareAccess -Name $ShareName -AccountName $ace.AccountName -Force | Out-Null}else{Revoke-SmbShareAccess -Name $ShareName -AccountName $ace.AccountName -Force | Out-Null}
            }
            foreach($name in $machineNames){Grant-SmbShareAccess -Name $ShareName -AccountName $name -AccessRight Read -Force | Out-Null}
            Set-SmbShare -Name $ShareName -FolderEnumerationMode AccessBased -Force
        }
        $changed=$true
    }
    if(-not(Test-CBITAxisShare $ShareName $destination $Environment) -or -not(Test-CBITAxisNtfs $destination $Environment)){throw 'Axis folder/share permissions failed verification; no staged payload copied or deleted.'}
    if($StagingPath){
        Write-CBITStatus 'Copying Axis payload into the protected share; retaining pkg structure.'
        New-Item -ItemType Directory -Path (Join-Path $destination 'pkg') -Force | Out-Null
        Set-CBITAxisNtfs (Join-Path $destination 'pkg') $Environment
        foreach($file in $sourceManifest){
            $to=Join-Path $destination $file.RelativePath
            Copy-Item -LiteralPath (Join-Path $StagingPath $file.RelativePath) -Destination $to -Force -ErrorAction Stop
            Set-CBITAxisNtfs $to $Environment
        }
        $changed=$true
    }
    $deployed=@(Get-CBITAxisManifest $destination)
    foreach($entry in @((Get-Item $destination))+@(Get-ChildItem -LiteralPath $destination -Recurse -Force)){
        if(-not(Test-CBITAxisNtfs $entry.FullName $Environment)){throw "Axis deployed ACL verification failed: $($entry.FullName). Source retained."}
    }
    if(-not(Test-CBITAxisShare $ShareName $destination $Environment)){throw 'Axis share verification failed. Source retained.'}
    if($StagingPath){
        $currentSource=@(Get-CBITAxisManifest $StagingPath)
        if(@(Compare-Object $sourceManifest $currentSource -Property RelativePath,Length,SHA256).Count -or @(Compare-Object $sourceManifest $deployed -Property RelativePath,Length,SHA256).Count){throw "Axis SHA256/file-set mismatch. Source NOT deleted: $StagingPath"}
    }
    $result=[pscustomobject]@{Status='Verified';Changed=$changed;Path=$destination;Share=$ShareName;ShareUnc=('\\'+$env:COMPUTERNAME+'.'+$Environment.Domain+'\'+$ShareName);Files=$deployed;Source=$StagingPath;SourceDeleted=$false;MachineOnlyShare=$true;ProtectedNTFS=$true}
    $result | ConvertTo-Json -Depth 5 | Set-Content $report
    if($StagingPath){
        # Revalidate exact cleanup boundaries immediately before recursive deletion.
        $cleanup=Assert-CBITAxisPath $StagingPath
        if($cleanup -ine $StagingPath -or (Split-Path $cleanup -Parent) -ine $base -or (Split-Path $cleanup -Leaf) -notlike 'CBITAgent-*-Setup'){throw 'Cleanup path validation failed; source retained.'}
        Write-CBITStatus "Every destination SHA256 and ACL verified. Removing verified staging source: $cleanup" -Color DarkYellow
        Remove-Item -LiteralPath $cleanup -Recurse -Force -ErrorAction Stop
        if(Test-Path -LiteralPath $cleanup){throw "Verified staging source still exists: $cleanup"}
        $result.SourceDeleted=$true
        $result | ConvertTo-Json -Depth 5 | Set-Content $report
    }
    Write-CBITStatus 'Axis payload and machine-only share verified; tenant identity still requires confirmation against the AXIS portal.' -Color DarkGreen
    $result
}
function Import-CBITAxisGolden {
    param($Context,[string]$ScheduledTasksXml)
    # Only import into the brand-new empty GPO created by this operation.
    # Never Import-GPO over a preexisting standing CBIT policy container.
    if($Context.Existing){throw 'Golden import cannot target a preexisting GPO.'}
    $stage=Join-Path $script:CBITLogRoot ('axis-import-'+[guid]::NewGuid().ToString('N'))
    $id='1D9002E7-C43F-4F82-8C16-8647E033A20D'
    $instance=Join-Path $stage ('{'+$id+'}')
    $taskDir=Join-Path $instance 'DomainSysvol\GPO\Machine\Preferences\ScheduledTasks'
    New-Item -ItemType Directory -Path $taskDir,(Join-Path $instance 'DomainSysvol\GPO\User') -Force | Out-Null
    $utf8=New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $stage 'manifest.xml'),$script:CBITAxisBackupManifest,$utf8)
    [IO.File]::WriteAllText((Join-Path $instance 'bkupInfo.xml'),$script:CBITAxisBackupInfo,$utf8)
    [IO.File]::WriteAllText((Join-Path $instance 'Backup.xml'),$script:CBITAxisBackupXml,$utf8)
    [IO.File]::WriteAllText((Join-Path $taskDir 'ScheduledTasks.xml'),$ScheduledTasksXml,$utf8)
    try{
        Write-CBITStatus 'Importing the embedded golden Axis backup into the new, unlinked GPO.'
        Import-GPO -BackupId $id -Path $stage -TargetGuid $Context.Gpo.Id -Domain $Context.Env.Domain -Server $Context.Env.Server -ErrorAction Stop | Out-Null
        $Context.Changed=$true
    } finally {
        $absolute=[IO.Path]::GetFullPath($stage)
        $parent=[IO.Path]::GetFullPath($script:CBITLogRoot).TrimEnd('\')
        if((Split-Path $absolute -Parent) -ine $parent -or (Split-Path $absolute -Leaf) -notlike 'axis-import-*'){throw 'Unexpected import cleanup path; retained for inspection.'}
        Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction Stop
    }
}
function Invoke-CBITAxisDeployment {
    [CmdletBinding()]
    param([string]$GpoName='CBIT MSP - Axis',[string]$InstallerUnc,[string[]]$TargetDn=@(),[switch]$Enforced,[switch]$ApproveChanges,
        [string]$StagingPath,[string]$StagingRoot='C:\CBIT',[string]$DeploymentRoot='C:\CBIT\AXISdeploy',[string]$ShareName='AXISdeploy$')
    $ErrorActionPreference='Stop'
    try {
        $e=Get-CBITEnvironment
        if(-not $PSBoundParameters.ContainsKey('TargetDn')){$TargetDn=@($e.DN)}
        Assert-CBITTargets $e $TargetDn
        $payload=$null
        if(-not $InstallerUnc){
            $payload=Initialize-CBITAxisPayload -StagingPath $StagingPath -StagingRoot $StagingRoot -DeploymentRoot $DeploymentRoot -ShareName $ShareName -ApproveChanges:$ApproveChanges -Environment $e
            $InstallerUnc=$payload.ShareUnc+'\CBITAgentInstaller.exe'
        } elseif($StagingPath){throw 'Explicit remote InstallerUnc cannot be combined with local kit staging. Omit InstallerUnc for automatic preparation.'}
        if ($InstallerUnc -notmatch '^\\\\([^\\]+)\\([^\\]+)\\(.+\.exe)$') { throw "Invalid installer UNC: $InstallerUnc" }
        $uncHost=$Matches[1];$uncShare=$Matches[2];$uncFile=$Matches[3]
        # A computer-only share can intentionally deny the administering user.
        # On the share host inspect the local backing file instead of weakening its ACL.
        if ($uncHost -in $env:COMPUTERNAME,($env:COMPUTERNAME+'.'+$e.Domain)) {
            $backing=Get-SmbShare -Name $uncShare -ErrorAction Stop
            $exists=Test-Path -LiteralPath (Join-Path $backing.Path $uncFile) -PathType Leaf
            Write-CBITStatus 'Checking installer using local share backing path; endpoint SMB access requires workstation validation.'
        } else { $exists=Test-Path -LiteralPath $InstallerUnc -PathType Leaf -ErrorAction Stop }
        if (-not $exists) { throw "Installer missing: $InstallerUnc" }
        Assert-CBITTargets $e $TargetDn
        $c=New-CBITContext $GpoName $ApproveChanges.IsPresent
        $path=Join-Path (Get-CBITGpoPath $c.Env $c.Gpo) 'Machine\Preferences\ScheduledTasks\ScheduledTasks.xml'
        [xml]$template=$script:CBITAxisTemplate
        $p=$template.ScheduledTasks.ImmediateTaskV2.Properties
        $p.Task.Actions.Exec.Command=$InstallerUnc
        $p.Task.Actions.Exec.WorkingDirectory=[string](Split-Path $InstallerUnc)
        $p.Task.RegistrationInfo.Author='CBIT MSP Deployment'
        if(-not $c.Existing){Import-CBITAxisGolden $c $template.OuterXml}
        if($payload){$c.Changed=$c.Changed -or $payload.Changed;$c.Checks['Axis payload/share/security verified']=$payload.Status -eq 'Verified'}
        $node=$template.ScheduledTasks.ImmediateTaskV2
        if (Test-Path $path) { [xml]$doc=Get-Content $path -Raw } else { [xml]$doc='<ScheduledTasks clsid="{CC63F200-7309-4ba0-B154-A71CD118DBCC}" />' }
        $matches=@($doc.DocumentElement.ChildNodes | Where-Object { $_.name -eq 'CBIT-RMM-Agent-Install' -or $_.uid -eq $node.uid })
        if ($matches.Count -gt 1) { throw 'Multiple managed Axis task items; resolve manually.' }
        $changed=$false
        if (-not $matches.Count -or (Get-CBITXmlSignature $matches[0]) -cne (Get-CBITXmlSignature $node)) {
            if ($matches.Count) { $null=$doc.DocumentElement.ReplaceChild($doc.ImportNode($node,$true),$matches[0]) } else { $null=$doc.DocumentElement.AppendChild($doc.ImportNode($node,$true)) }
            $changed=Set-CBITFile $c $path $doc.OuterXml
        }
        Update-CBITMachineMetadata $c @('[{00000000-0000-0000-0000-000000000000}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]','[{AADCED64-746C-4633-A97C-D61349046527}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]') $changed
        [xml]$read=Get-Content $path -Raw
        $items=@($read.DocumentElement.ChildNodes | Where-Object name -eq 'CBIT-RMM-Agent-Install')
        $c.Checks['Exactly one golden Axis task'] = ($items.Count -eq 1 -and (Get-CBITXmlSignature $items[0]) -ceq (Get-CBITXmlSignature $node))
        $c.Checks['ScheduledTasks CSE'] = ((Get-CBITGpoAD $c.Env $c.Gpo).gPCMachineExtensionNames -like '*{AADCED64-746C-4633-A97C-D61349046527}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}*')
        if (@($c.Checks.Values | Where-Object { -not $_ }).Count) { throw 'Axis settings failed verification before linking.' }
        Set-CBITLinks $c $TargetDn $Enforced.IsPresent
        Complete-CBITDeployment $c 'Axis'
    } catch { Save-CBITFailure 'Axis' $_; throw }
}

function Invoke-CBITEndpointDeployment {
    [CmdletBinding()]
    param([string]$GpoName='CBIT MSP - Endpoint Admin',[string]$GroupName='CBIT-Endpoint-Admins',
        [string]$ElevationSam='CBIT',[Security.SecureString]$NewAccountPassword,[string]$AccountName='CBIT-Elevation',
        [string[]]$TargetDn=@(),[switch]$ApproveChanges,[switch]$AllowAdditionalMembers)
    $ErrorActionPreference='Stop'
    try {
        $e=Get-CBITEnvironment
        $adChanged=$false
        Assert-CBITTargets $e $TargetDn -WorkstationsOnly
        if ($GroupName -notmatch '^[a-zA-Z0-9 _-]{1,64}$' -or $ElevationSam -notmatch '^[a-zA-Z0-9_-]{1,20}$') { throw 'Invalid group name or account SAM.' }
        $u=Get-ADUser -Filter "SamAccountName -eq '$ElevationSam'" -Server $e.Server -Properties Enabled,PasswordNeverExpires,CannotChangePassword,PrimaryGroupID
        if (-not $u -and -not $NewAccountPassword) { throw "Missing $ElevationSam. Supply -NewAccountPassword (SecureString), or use the privileged access runbook." }
        if ($u -and ($u.Name -ne $AccountName -or -not $u.Enabled)) { throw "Existing $ElevationSam is not the enabled standard account $AccountName. Review collision/disabled account via runbook." }
        if ($u) {
            $priv=@(Get-ADGroup -Server $e.Server -LDAPFilter ('(member:1.2.840.113556.1.4.1941:='+($u.DistinguishedName -replace '\\','\5c' -replace '\(','\28' -replace '\)','\29')+')') | Where-Object { $_.SID.Value -match ('^('+[regex]::Escape($e.SID)+'|S-1-5-32)-(512|518|519|520|544|548|549|550|551)$') })
            if ($priv.Count -or $u.PrimaryGroupID -ne 513) { throw "Elevation account has privileged membership or nonstandard primary group: $ElevationSam" }
        }
        $g=Get-ADGroup -Filter "SamAccountName -eq '$GroupName'" -Server $e.Server -Properties Members,MemberOf
        if ($g -and ($g.GroupScope -ne 'Global' -or $g.GroupCategory -ne 'Security' -or @($g.MemberOf).Count)) { throw "Existing $GroupName must be Global/Security and not nested." }
        if ($g -and @($g.Members | Where-Object { -not $u -or $_ -ne $u.DistinguishedName }).Count -and -not $AllowAdditionalMembers) { throw 'Additional group members require explicit -AllowAdditionalMembers after review.' }
        # AD changes are separately gated even if the GPO is new.
        if ((-not $u -or -not $g -or -not $u.PasswordNeverExpires -or -not $u.CannotChangePassword -or $g.Members -notcontains $u.DistinguishedName) -and -not $ApproveChanges) { throw 'AD account/group creation or correction requires -ApproveChanges.' }
        if (-not $u) {
            $adChanged=$true
            Write-CBITStatus "Creating standard elevation account $ElevationSam."
            $u=New-ADUser -Name $AccountName -SamAccountName $ElevationSam -UserPrincipalName ($ElevationSam+'@'+$e.Domain) -Path $e.UsersPath -Enabled $true -PasswordNeverExpires $true -CannotChangePassword $true -AccountPassword $NewAccountPassword -Server $e.Server -PassThru
        } elseif (-not $u.PasswordNeverExpires -or -not $u.CannotChangePassword) {
            $adChanged=$true
            Write-CBITStatus "Setting standard password flags on $ElevationSam; retaining existing password."
            Set-ADUser -Identity $u -PasswordNeverExpires $true -CannotChangePassword $true -Server $e.Server
        }
        if (-not $g) { $adChanged=$true; Write-CBITStatus "Creating Global/Security group $GroupName."; $g=New-ADGroup -Name $GroupName -SamAccountName $GroupName -GroupScope Global -GroupCategory Security -Path $e.UsersPath -Server $e.Server -PassThru }
        if ($g.Members -notcontains $u.DistinguishedName) { $adChanged=$true; Write-CBITStatus "Ensuring $ElevationSam membership in $GroupName."; Add-ADGroupMember -Identity $g -Members $u -Server $e.Server }
        $c=New-CBITContext $GpoName $ApproveChanges.IsPresent
        $c.Changed=$c.Changed -or $adChanged
        $path=Join-Path (Get-CBITGpoPath $c.Env $c.Gpo) 'Machine\Preferences\Groups\Groups.xml'
        if(Test-Path $path){[xml]$doc=Get-Content $path -Raw}else{[xml]$doc='<Groups clsid="{3125E937-EB16-4b4c-9934-544FC6D24D26}" />'}
        $admin=@($doc.Groups.Group | Where-Object { $_ -and $_.Properties.groupSid -eq 'S-1-5-32-544' })
        $local=@($doc.Groups.User | Where-Object { $_ -and $_.Properties.userName -ieq $ElevationSam })
        if($admin.Count -gt 1 -or $local.Count -gt 1){throw 'Duplicate managed local group/user items. Resolve manually.'}
        if($admin.Count -and (@($admin[0].Properties.Members.Member | Where-Object name -ine ($e.NetBIOS+'\'+$GroupName)).Count)){throw 'Existing Administrators item has additional member operations; review manually rather than discard them.'}
        $groupXml='<Group clsid="{6D4A79E4-529C-4481-ABD0-F5BD7EA93BA7}" name="Administrators (built-in)" image="2" uid="{8E2F6B68-CC38-4C61-945B-D460451F7565}"><Properties action="U" newName="" description="" deleteAllUsers="0" deleteAllGroups="0" removeAccounts="0" groupSid="S-1-5-32-544" groupName="Administrators (built-in)"><Members><Member name="'+[Security.SecurityElement]::Escape($e.NetBIOS+'\'+$GroupName)+'" action="ADD" sid="'+$g.SID.Value+'" /></Members></Properties></Group>'
        $userXml='<User clsid="{DF5F1855-51E5-4d24-8B1A-D9BDE98BA1D1}" name="'+$ElevationSam+'" image="3" uid="{06981219-9B18-4565-88AF-619184BC877C}"><Properties action="D" userName="'+$ElevationSam+'" /></User>'
        $changed=$false
        foreach($pair in @(@($admin,$groupXml),@($local,$userXml))){
            $current=@($pair[0]); [xml]$part=$pair[1]; $node=$part.DocumentElement
            if(-not $current.Count -or (Get-CBITXmlSignature $current[0]) -cne (Get-CBITXmlSignature $node)){
                if($current.Count){$null=$doc.Groups.ReplaceChild($doc.ImportNode($node,$true),$current[0])}else{$null=$doc.Groups.AppendChild($doc.ImportNode($node,$true))}
                $changed=$true
            }
        }
        if($changed){$null=Set-CBITFile $c $path $doc.OuterXml}
        Update-CBITMachineMetadata $c @('[{00000000-0000-0000-0000-000000000000}{D34B2E5A-ED1F-4AF3-8DDB-7A8D48DC5FEC}]','[{17D89FEC-5C44-4972-B12D-241CAEF74509}{D34B2E5A-ED1F-4AF3-8DDB-7A8D48DC5FEC}]') $changed
        [xml]$read=Get-Content $path -Raw
        $p=@($read.Groups.Group | Where-Object { $_ -and $_.Properties.groupSid -eq 'S-1-5-32-544' })
        $del=@($read.Groups.User | Where-Object { $_ -and $_.Properties.userName -ieq $ElevationSam })
        $c.Checks['Update Administrators without clearing membership']=$p.Count -eq 1 -and $p[0].Properties.action -eq 'U' -and $p[0].Properties.deleteAllUsers -eq '0' -and $p[0].Properties.deleteAllGroups -eq '0'
        $c.Checks['Domain group ADD with correct SID']=@($p[0].Properties.Members.Member | Where-Object { $_.name -eq ($e.NetBIOS+'\'+$GroupName) -and $_.action -eq 'ADD' -and $_.sid -eq $g.SID.Value }).Count -eq 1
        $c.Checks['Delete legacy local account without password']=$del.Count -eq 1 -and $del[0].Properties.action -eq 'D' -and -not $del[0].Properties.cpassword
        $c.Checks['AD group membership']=@(Get-ADGroupMember -Identity $g -Server $e.Server | Where-Object SID -eq $u.SID).Count -eq 1
        $fresh=Get-ADUser $u -Server $e.Server -Properties Enabled,PasswordNeverExpires,CannotChangePassword
        $c.Checks['Elevation account flags']=$fresh.Enabled -and $fresh.PasswordNeverExpires -and $fresh.CannotChangePassword
        $c.Checks['LocalUsersAndGroups CSE']=(Get-CBITGpoAD $c.Env $c.Gpo).gPCMachineExtensionNames -like '*{17D89FEC-5C44-4972-B12D-241CAEF74509}{D34B2E5A-ED1F-4AF3-8DDB-7A8D48DC5FEC}*'
        if(@($c.Checks.Values | Where-Object {-not $_}).Count){throw 'Endpoint settings failed verification before linking.'}
        Set-CBITLinks $c $TargetDn $false
        Complete-CBITDeployment $c 'Endpoint'
    } catch { Save-CBITFailure 'Endpoint' $_; throw }
}

function Invoke-CBITSentinelOneDeployment {
    [CmdletBinding()]
    param([string]$GpoName='CBIT MSP - SentinelOne',[Parameter(Mandatory)][Security.SecureString]$SiteToken,
        [string]$ConsoleUrl,[Security.SecureString]$ApiToken = $script:CBITDefaultApiToken,
        [string]$BaseDir='C:\CBIT\S1deploy',[string]$ShareName='S1deploy$',
        [string]$TaskName='CBIT - SentinelOne Package Sync',[string[]]$TargetDn=@(),
        [switch]$Enforced=$true,[switch]$UseExistingPackage,[switch]$ApproveChanges)
    $ErrorActionPreference='Stop'
    try {
        $e=Get-CBITEnvironment
        if(-not $PSBoundParameters.ContainsKey('TargetDn')){$TargetDn=@($e.DN)}
        Assert-CBITTargets $e $TargetDn
        foreach($cmd in 'Get-SmbShare','New-SmbShare','Register-ScheduledTask'){if(-not(Get-Command $cmd -ErrorAction SilentlyContinue)){throw "Required command missing: $cmd"}}
        $site=[Net.NetworkCredential]::new('',$SiteToken).Password
        $b64=$site; switch($b64.Length % 4){2{$b64+='=='}3{$b64+='='}}
        $decoded=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
        if(-not $decoded.site_key -or -not $decoded.url){throw 'Site token must decode to url/site_key. No token override permitted.'}
        if(-not $ConsoleUrl){$ConsoleUrl=$decoded.url.TrimEnd('/')}
        if($ConsoleUrl -notmatch '^https://[a-zA-Z0-9.-]+$' -or $decoded.url.TrimEnd('/') -ne $ConsoleUrl){throw 'HTTPS console URL must match the site token.'}
        $shareDir=Join-Path $BaseDir 'Share'; $syncScript=Join-Path $BaseDir 'Sync-S1Package.ps1'
        $cs=Get-CimInstance Win32_ComputerSystem
        $shareUnc='\\'+$cs.DNSHostName+'.'+$cs.Domain+'\'+$ShareName
        if($ShareName -notmatch '^[a-zA-Z0-9_-]+\$$'){throw 'Use a valid hidden SMB share name.'}
        $existingShare=Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
        if($existingShare -and $existingShare.Path -ine $shareDir){throw "Existing share $ShareName points elsewhere: $($existingShare.Path)"}
        if(-not $UseExistingPackage -and -not $ApiToken){throw 'Supply -ApiToken for API synchronization, or explicitly use -UseExistingPackage with a verified cached package.'}
        if(-not $UseExistingPackage){
            if(-not $ApproveChanges){throw 'Package folder/share/sync task configuration requires -ApproveChanges.'}
            $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "'+$syncScript+'"')
            $task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if($task -and ($task.Actions.Count -ne 1 -or $task.Actions.Execute -ne 'powershell.exe' -or $task.Actions.Arguments -ne $action.Arguments)){throw "Existing task $TaskName has different actions; review manually."}
            Write-CBITStatus "Configuring private package folder $BaseDir, read-only share $ShareName, and daily SYSTEM task $TaskName."
            New-Item -ItemType Directory -Path $shareDir -Force | Out-Null
            # Exact ACLs remove inherited or explicit access to the private token folder.
            foreach($entry in @(@($BaseDir,$false),@($shareDir,$true))){
                $acl=New-Object Security.AccessControl.DirectorySecurity
                $acl.SetAccessRuleProtection($true,$false)
                foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
                if($entry[1]){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-11')),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))}
                Set-Acl -LiteralPath $entry[0] -AclObject $acl
            }
            $auth=(New-Object Security.Principal.SecurityIdentifier('S-1-5-11')).Translate([Security.Principal.NTAccount]).Value
            $admins=(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value
            if(-not $existingShare){New-SmbShare -Name $ShareName -Path $shareDir -ReadAccess $auth -FullAccess $admins | Out-Null}
            $api=[Net.NetworkCredential]::new('',$ApiToken).Password
            $sync=$script:CBITSyncTemplate.Replace('__API_TOKEN__',$api.Replace("'","''")).Replace('__CONSOLE_URL__',$ConsoleUrl).Replace('__SHARE_DIR__',$shareDir.Replace("'","''"))
            Set-Content -LiteralPath $syncScript -Value $sync -Encoding UTF8
            $secretAcl=New-Object Security.AccessControl.FileSecurity
            $secretAcl.SetAccessRuleProtection($true,$false)
            foreach($sid in 'S-1-5-18','S-1-5-32-544'){$secretAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','Allow')))}
            Set-Acl -LiteralPath $syncScript -AclObject $secretAcl
            $api=$null; $sync=$null
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript
            if($LASTEXITCODE){throw 'Initial package synchronization failed; review private Sync.log. No GPO configured.'}
            $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "'+$syncScript+'"')
            $trigger=New-ScheduledTaskTrigger -Daily -At 3am
            $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if($task -and ($task.Actions.Execute -ne 'powershell.exe' -or $task.Actions.Arguments -ne $action.Arguments)){throw "Existing task $TaskName has different actions; review manually."}
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        }
        $manifestPath=Join-Path $shareDir 'manifest.json'
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if($manifest.fileName -ne [IO.Path]::GetFileName($manifest.fileName) -or $manifest.fileName -notlike '*.msi'){throw 'Manifest must reference a plain MSI filename.'}
        $msi=Join-Path $shareDir $manifest.fileName
        if((Get-FileHash -LiteralPath $msi -Algorithm SHA1).Hash -ne $manifest.sha1){throw 'Cached MSI hash does not match manifest.'}
        $access=@(Get-SmbShareAccess -Name $ShareName)
        $authSid='S-1-5-11'
        $readAccess=@($access | Where-Object { try { (New-Object Security.Principal.NTAccount($_.AccountName)).Translate([Security.Principal.SecurityIdentifier]).Value -eq $authSid -and $_.AccessControlType -eq 'Allow' -and $_.AccessRight -eq 'Read' } catch { $false } })
        if($readAccess.Count -ne 1){throw 'Package share requires Authenticated Users Read access.'}
        $c=New-CBITContext $GpoName $ApproveChanges.IsPresent
        $c.Checks['Package manifest and SHA1']=$true
        $c.Checks['SMB authenticated read']=$true
        $privateAcl=Get-Acl $BaseDir
        $exposed=@($privateAcl.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin 'S-1-5-18','S-1-5-32-544' })
        $c.Checks['API folder restricted']=$privateAcl.AreAccessRulesProtected -and $exposed.Count -eq 0
        if(Test-Path $syncScript){
            $tokenAcl=Get-Acl $syncScript
            $c.Checks['API script restricted']=@($tokenAcl.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin 'S-1-5-18','S-1-5-32-544' }).Count -eq 0
        }
        $shareAcl=Get-Acl $shareDir
        $c.Checks['Package NTFS read']=@($shareAcl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-11' -and $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute }).Count -gt 0
        if(-not $UseExistingPackage){
            $t=Get-ScheduledTask -TaskName $TaskName
            $c.Checks['Daily SYSTEM synchronization']=$t.Principal.UserId -in 'SYSTEM','S-1-5-18' -and $t.Principal.RunLevel -eq 'Highest' -and $t.Actions.Arguments -eq $action.Arguments -and $t.Triggers[0].DaysInterval -eq 1 -and ([datetime]$t.Triggers[0].StartBoundary).Hour -eq 3
        }
        $key='HKLM\Software\Policies\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $reg=Get-GPRegistryValue -Guid $c.Gpo.Id -Domain $e.Domain -Server $e.Server -Key $key -ErrorAction SilentlyContinue | Where-Object ValueName -eq 'SyncForegroundPolicy'
        if(-not $reg -or $reg.Value -ne 1 -or $reg.Type -ne 'DWord'){Assert-CBITChange $c 'Set Always wait for the network at startup to DWORD 1.'; Set-GPRegistryValue -Guid $c.Gpo.Id -Domain $e.Domain -Server $e.Server -Key $key -ValueName SyncForegroundPolicy -Type DWord -Value 1 | Out-Null}
        $gpPath=Get-CBITGpoPath $e $c.Gpo
        $endpoint=$script:CBITEndpointTemplate.Replace('__SITE_TOKEN__',$site.Replace("'","''")).Replace('__SHARE_UNC__',$shareUnc.Replace("'","''"))
        $scriptPath=Join-Path $gpPath 'Machine\Scripts\Startup\Install-S1.ps1'
        $changed=Set-CBITFile $c $scriptPath $endpoint
        $client='\\'+$e.Domain+'\SYSVOL\'+$e.Domain+'\Policies\{'+$c.Gpo.Id+'}\Machine\Scripts\Startup\Install-S1.ps1'
        $parameters='-NoProfile -ExecutionPolicy Bypass -File "'+$client+'"'
        $iniPath=Join-Path $gpPath 'Machine\Scripts\scripts.ini'
        $ini=if(Test-Path $iniPath){Get-Content $iniPath -Raw}else{''}
        # Preserve unrelated sections and startup entries. Only adopt entries pointing at this managed script.
        $lines=New-Object 'System.Collections.Generic.List[string]'
        foreach($line in ($ini -split '\r?\n')){if($line -ne ''){$lines.Add($line)}}
        $start=-1;$end=$lines.Count
        for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -eq '[Startup]'){$start=$i;break}}
        if($start -ge 0){for($i=$start+1;$i -lt $lines.Count;$i++){if($lines[$i] -match '^\['){$end=$i;break}}}else{$start=$lines.Count;$lines.Add('[Startup]');$end=$lines.Count}
        $managed=@();$indexes=@()
        for($i=$start+1;$i -lt $end;$i++){if($lines[$i] -match '^(\d+)(CmdLine|Parameters)='){$indexes+=[int]$Matches[1]};if($lines[$i] -match '^(\d+)Parameters=.*Install-S1\.ps1'){$managed+=[int]$Matches[1]}}
        if($managed.Count -gt 1){throw 'Multiple SentinelOne startup registrations; resolve manually.'}
        $index=if($managed.Count){$managed[0]}elseif($indexes.Count){($indexes | Measure-Object -Maximum).Maximum+1}else{0}
        if($managed.Count){for($i=$end-1;$i -gt $start;$i--){if($lines[$i] -match ('^'+$index+'(CmdLine|Parameters)=')){$lines.RemoveAt($i);$end--}}}
        $lines.Insert($end,([string]$index+'Parameters='+$parameters));$lines.Insert($end,([string]$index+'CmdLine=powershell.exe'))
        $newIni=($lines -join "`r`n")+"`r`n"
        $iniChanged=Set-CBITFile $c $iniPath $newIni 'Unicode'
        Update-CBITMachineMetadata $c @('[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]') ($changed -or $iniChanged)
        $c.Checks['Startup script exact readback']=(Get-Content $scriptPath -Raw) -ceq $endpoint
        $c.Checks['Startup registration exact readback']=(Get-Content $iniPath -Raw) -ceq $newIni
        $r=Get-GPRegistryValue -Guid $c.Gpo.Id -Domain $e.Domain -Server $e.Server -Key $key -ValueName SyncForegroundPolicy
        $c.Checks['Wait for network DWORD']=$r.Value -eq 1 -and $r.Type -eq 'DWord'
        $c.Checks['Scripts CSE']=(Get-CBITGpoAD $e $c.Gpo).gPCMachineExtensionNames -like '*{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}*'
        if(@($c.Checks.Values | Where-Object {-not $_}).Count){throw 'SentinelOne settings/infrastructure failed verification before linking.'}
        Set-CBITLinks $c $TargetDn $Enforced.IsPresent
        Complete-CBITDeployment $c 'SentinelOne'
    } catch { Save-CBITFailure 'SentinelOne' $_; throw } finally { $site=$null;$endpoint=$null;$api=$null }
}

# Embedded templates and the original gated runbook are inserted by the build script.
$script:CBITAxisBackupManifest = @'
<Backups xmlns="http://www.microsoft.com/GroupPolicy/GPOOperations/Manifest" xmlns:mfst="http://www.microsoft.com/GroupPolicy/GPOOperations/Manifest" mfst:version="1.0"><BackupInst><GPOGuid><![CDATA[{588E783B-76E3-4305-B2E9-4F1B7B40220F}]]></GPOGuid><GPODomain><![CDATA[HTV.local]]></GPODomain><GPODomainGuid><![CDATA[{9736a1d9-3d18-4fa3-96c0-abb914245151}]]></GPODomainGuid><GPODomainController><![CDATA[HTVC-DC.HTV.local]]></GPODomainController><BackupTime><![CDATA[2026-07-18T15:43:37]]></BackupTime><ID><![CDATA[{1D9002E7-C43F-4F82-8C16-8647E033A20D}]]></ID><Comment><![CDATA[Golden backup - verified 2026-07-18 - Axis agent Immediate Task]]></Comment><GPODisplayName><![CDATA[CBIT MSP - Axis]]></GPODisplayName></BackupInst></Backups>
'@

$script:CBITAxisBackupInfo = @'
<BackupInst xmlns="http://www.microsoft.com/GroupPolicy/GPOOperations/Manifest"><GPOGuid><![CDATA[{588E783B-76E3-4305-B2E9-4F1B7B40220F}]]></GPOGuid><GPODomain><![CDATA[HTV.local]]></GPODomain><GPODomainGuid><![CDATA[{9736a1d9-3d18-4fa3-96c0-abb914245151}]]></GPODomainGuid><GPODomainController><![CDATA[HTVC-DC.HTV.local]]></GPODomainController><BackupTime><![CDATA[2026-07-18T15:43:37]]></BackupTime><ID><![CDATA[{1D9002E7-C43F-4F82-8C16-8647E033A20D}]]></ID><Comment><![CDATA[Golden backup - verified 2026-07-18 - Axis agent Immediate Task]]></Comment><GPODisplayName><![CDATA[CBIT MSP - Axis]]></GPODisplayName></BackupInst>
'@

$script:CBITAxisBackupXml = @'
<?xml version="1.0" encoding="utf-8"?><!-- Copyright (c) Microsoft Corporation.  All rights reserved. --><GroupPolicyBackupScheme bkp:version="2.0" bkp:type="GroupPolicyBackupTemplate" xmlns:bkp="http://www.microsoft.com/GroupPolicy/GPOOperations" xmlns="http://www.microsoft.com/GroupPolicy/GPOOperations">
    <GroupPolicyObject><SecurityGroups><Group bkp:Source="FromDACL"><Sid><![CDATA[S-1-5-21-3514889338-3028185134-1016208046-519]]></Sid><SamAccountName><![CDATA[Enterprise Admins]]></SamAccountName><Type><![CDATA[UniversalGroup]]></Type><NetBIOSDomainName><![CDATA[HTV]]></NetBIOSDomainName><DnsDomainName><![CDATA[HTV.local]]></DnsDomainName><UPN><![CDATA[Enterprise Admins@HTV.local]]></UPN></Group><Group bkp:Source="FromDACL"><Sid><![CDATA[S-1-5-21-3514889338-3028185134-1016208046-512]]></Sid><SamAccountName><![CDATA[Domain Admins]]></SamAccountName><Type><![CDATA[GlobalGroup]]></Type><NetBIOSDomainName><![CDATA[HTV]]></NetBIOSDomainName><DnsDomainName><![CDATA[HTV.local]]></DnsDomainName><UPN><![CDATA[Domain Admins@HTV.local]]></UPN></Group></SecurityGroups><FilePaths/><GroupPolicyCoreSettings><ID><![CDATA[{588E783B-76E3-4305-B2E9-4F1B7B40220F}]]></ID><Domain><![CDATA[HTV.local]]></Domain><SecurityDescriptor>01 00 04 9c 00 00 00 00 00 00 00 00 00 00 00 00 14 00 00 00 04 00 ec 00 08 00 00 00 05 02 28 00 00 01 00 00 01 00 00 00 8f fd ac ed b3 ff d1 11 b4 1d 00 a0 c9 68 f9 39 01 01 00 00 00 00 00 05 0b 00 00 00 00 00 24 00 ff 00 0f 00 01 05 00 00 00 00 00 05 15 00 00 00 7a f4 80 d1 2e 70 7e b4 ae 1a 92 3c 00 02 00 00 00 02 24 00 ff 00 0f 00 01 05 00 00 00 00 00 05 15 00 00 00 7a f4 80 d1 2e 70 7e b4 ae 1a 92 3c 00 02 00 00 00 02 24 00 ff 00 0f 00 01 05 00 00 00 00 00 05 15 00 00 00 7a f4 80 d1 2e 70 7e b4 ae 1a 92 3c 07 02 00 00 00 02 14 00 94 00 02 00 01 01 00 00 00 00 00 05 09 00 00 00 00 02 14 00 94 00 02 00 01 01 00 00 00 00 00 05 0b 00 00 00 00 02 14 00 ff 00 0f 00 01 01 00 00 00 00 00 05 12 00 00 00 00 0a 14 00 ff 00 0f 00 01 01 00 00 00 00 00 03 00 00 00 00</SecurityDescriptor><DisplayName><![CDATA[CBIT MSP - Axis]]></DisplayName><Options><![CDATA[0]]></Options><UserVersionNumber><![CDATA[0]]></UserVersionNumber><MachineVersionNumber><![CDATA[262148]]></MachineVersionNumber><MachineExtensionGuids><![CDATA[[{00000000-0000-0000-0000-000000000000}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}][{AADCED64-746C-4633-A97C-D61349046527}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]]]></MachineExtensionGuids><UserExtensionGuids/><WMIFilter/></GroupPolicyCoreSettings> 
        <GroupPolicyExtension bkp:ID="{35378EAC-683F-11D2-A89A-00C04FBBCFA2}" bkp:DescName="Registry">
            
            
            <FSObjectFile bkp:Path="%GPO_FSPATH%\Adm\*.*" bkp:SourceExpandedPath="\\HTVC-DC.HTV.local\sysvol\HTV.local\Policies\{588E783B-76E3-4305-B2E9-4F1B7B40220F}\Adm\*.*"/>
        </GroupPolicyExtension>
        
        
        
        
        
        
        
        
        
    <GroupPolicyExtension bkp:ID="{F15C46CD-82A0-4C2D-A210-5D0D3182A418}" bkp:DescName="Unknown Extension"><FSObjectDir bkp:Path="%GPO_MACH_FSPATH%\Preferences" bkp:SourceExpandedPath="\\HTVC-DC.HTV.local\sysvol\HTV.local\Policies\{588E783B-76E3-4305-B2E9-4F1B7B40220F}\Machine\Preferences" bkp:Location="DomainSysvol\GPO\Machine\Preferences"/><FSObjectDir bkp:Path="%GPO_MACH_FSPATH%\Preferences\ScheduledTasks" bkp:SourceExpandedPath="\\HTVC-DC.HTV.local\sysvol\HTV.local\Policies\{588E783B-76E3-4305-B2E9-4F1B7B40220F}\Machine\Preferences\ScheduledTasks" bkp:Location="DomainSysvol\GPO\Machine\Preferences\ScheduledTasks"/><FSObjectFile bkp:Path="%GPO_MACH_FSPATH%\Preferences\ScheduledTasks\ScheduledTasks.xml" bkp:SourceExpandedPath="\\HTVC-DC.HTV.local\sysvol\HTV.local\Policies\{588E783B-76E3-4305-B2E9-4F1B7B40220F}\Machine\Preferences\ScheduledTasks\ScheduledTasks.xml" bkp:Location="DomainSysvol\GPO\Machine\Preferences\ScheduledTasks\ScheduledTasks.xml"/></GroupPolicyExtension></GroupPolicyObject>
</GroupPolicyBackupScheme>
'@


$script:CBITAxisTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<ScheduledTasks clsid="{CC63F200-7309-4ba0-B154-A71CD118DBCC}"><ImmediateTaskV2 clsid="{9756B581-76EC-4169-9AFC-0CA8D43ADB5F}" name="CBIT-RMM-Agent-Install" image="0" changed="2026-06-26 13:57:00" uid="{474E9EED-0B8B-48AC-9B87-D85028664207}" userContext="0" removePolicy="0"><Properties action="C" name="CBIT-RMM-Agent-Install" runAs="NT AUTHORITY\System" logonType="S4U"><Task version="1.2"><RegistrationInfo><Author>HTV\administrator</Author><Description></Description></RegistrationInfo><Principals><Principal id="Author"><UserId>NT AUTHORITY\System</UserId><LogonType>S4U</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals><Settings><IdleSettings><Duration>PT5M</Duration><WaitTimeout>PT1H</WaitTimeout><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>false</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><AllowStartOnDemand>false</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority><DeleteExpiredTaskAfter>PT0S</DeleteExpiredTaskAfter></Settings><Triggers><TimeTrigger><StartBoundary>%LocalTimeXmlEx%</StartBoundary><EndBoundary>%LocalTimeXmlEx%</EndBoundary><Enabled>true</Enabled></TimeTrigger></Triggers><Actions Context="Author"><Exec><Command>\\__DC_FQDN__\AXISdeploy$\CBITAgentInstaller.exe</Command><WorkingDirectory>\\__DC_FQDN__\AXISdeploy$</WorkingDirectory></Exec>
				</Actions></Task></Properties></ImmediateTaskV2>
</ScheduledTasks>

'@
$script:CBITSyncTemplate = @'
function Initialize-CBITRuntime {
    # Import the native engine's module explicitly: do not depend on command
    # auto-discovery or an inherited PSModulePath for script-based utilities.
    $utility = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'
    try {
        Import-Module -Name $utility -Scope Global -Force -ErrorAction Stop
        $hashCommand = Get-Command -Name Get-FileHash -Module Microsoft.PowerShell.Utility -ErrorAction Stop
        if (-not $hashCommand) { throw 'Get-FileHash was not exported.' }
    } catch {
        throw ("Required Windows PowerShell utility Get-FileHash is unavailable after loading {0}. No deployment was started. {1}" -f $utility, $_.Exception.Message)
    }
}
Initialize-CBITRuntime
# CBIT presentation only: standard ConsoleColor fallback palette.
$Host.UI.RawUI.ForegroundColor = 'Gray'
$Host.PrivateData.ErrorForegroundColor = 'DarkRed'
$Host.PrivateData.WarningForegroundColor = 'DarkYellow'
$Host.PrivateData.VerboseForegroundColor = 'DarkGray'
$Host.PrivateData.DebugForegroundColor = 'DarkGray'
$Host.PrivateData.ProgressForegroundColor = 'DarkGray'
$Host.PrivateData.ProgressBackgroundColor = 'Black'
# Generated by the CBIT SentinelOne GPO wizard. Contains the API token - keep this folder restricted to SYSTEM/Administrators.
$ErrorActionPreference = 'Stop'
$ApiToken   = '__API_TOKEN__'
$ConsoleUrl = '__CONSOLE_URL__'
$ShareDir   = '__SHARE_DIR__'
$Manifest   = Join-Path $ShareDir 'manifest.json'
$LogFile    = Join-Path (Split-Path $ShareDir) 'Sync.log'
function Log([string]$m) { "$(Get-Date -Format s)  $m" | Add-Content -Path $LogFile }

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $headers = @{ Authorization = "ApiToken $ApiToken" }

    $query = @{ osTypes='windows'; osArches='64 bit'; fileExtension='.msi'; status='ga'; sortBy='version'; sortOrder='desc'; limit=1 }
    $pkg = (Invoke-RestMethod -Uri "$ConsoleUrl/web/api/v2.1/update/agent/packages" -Headers $headers -Body $query).data | Select-Object -First 1
    if (-not $pkg) { throw "No GA 64-bit Windows MSI returned by the API. Check the service-user role and query filters." }

    if (Test-Path $Manifest) {
        $cur = Get-Content -Path $Manifest -Raw | ConvertFrom-Json
        if ($cur.sha1 -eq $pkg.sha1 -and (Test-Path (Join-Path $ShareDir $cur.fileName))) { Log "Up to date: $($pkg.version)"; return }
    }

    # Download straight into the share folder (temp name) so the file inherits the share folder's read ACL.
    # A Move-Item from the private folder would carry the private ACL and endpoints couldn't read it.
    Get-ChildItem -Path $ShareDir -Filter '*.partial' | Remove-Item -Force
    $partial = Join-Path $ShareDir "$($pkg.fileName).partial"
    Invoke-WebRequest -Uri $pkg.link -Headers $headers -OutFile $partial -UseBasicParsing

    $hash = (Get-FileHash -Path $partial -Algorithm SHA1).Hash
    if ($hash -ne $pkg.sha1) { Remove-Item $partial -Force; throw "SHA1 mismatch on $($pkg.fileName): expected $($pkg.sha1), got $hash." }

    $final = Join-Path $ShareDir $pkg.fileName
    if (Test-Path $final) { Remove-Item $final -Force }
    Rename-Item -Path $partial -NewName $pkg.fileName

    # Manifest last, so endpoints never see a manifest pointing at a file that isn't there yet.
    [pscustomobject]@{ fileName = $pkg.fileName; version = $pkg.version; sha1 = $pkg.sha1 } |
        ConvertTo-Json | Set-Content -Path $Manifest -Encoding ASCII
    Get-ChildItem -Path $ShareDir -Filter '*.msi' | Where-Object Name -ne $pkg.fileName | Remove-Item -Force

    Log "Updated share to $($pkg.version) ($($pkg.fileName))"
}
catch { Log "ERROR: $($_.Exception.Message)"; throw }
'@
$script:CBITEndpointTemplate = @'
# CBIT MSP - SentinelOne startup script (GPO). Runs as SYSTEM at boot. Generated by the CBIT wizard.
$ErrorActionPreference = 'Stop'
$SiteToken = '__SITE_TOKEN__'
$ShareUnc  = '__SHARE_UNC__'
$LogFile   = 'C:\CBIT\Logs\S1-Install.log'
$PrivateLogDir = 'C:\CBIT\Logs\SentinelOne-Installer'

# Already protected: exit silently (no log spam every boot).
if (Get-Service -Name 'SentinelAgent' -ErrorAction SilentlyContinue) { return }

New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null
function Log([string]$m) {
    if ($SiteToken) { $m = $m.Replace($SiteToken, '[SITE TOKEN REDACTED]') }
    "$(Get-Date -Format s)  $m" | Add-Content -Path $LogFile
}

$msiPath = $null
$exitCode = 1
try {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($arch -ne 'AMD64') { Log "Architecture '$arch' not supported by the x64 MSI - skipping."; return }

    $m = Get-Content -Path "$ShareUnc\manifest.json" -Raw -ErrorAction Stop | ConvertFrom-Json
    $msiPath = Join-Path $env:TEMP $m.fileName
    Copy-Item -Path "$ShareUnc\$($m.fileName)" -Destination $msiPath -Force -ErrorAction Stop

    $hash = (Get-FileHash -Path $msiPath -Algorithm SHA1).Hash
    if ($hash -ne $m.sha1) { throw "SHA1 mismatch on $($m.fileName): expected $($m.sha1), got $hash." }

    # Verbose MSI logs can include the site token. Restrict their dedicated folder before launching MSI.
    New-Item -ItemType Directory -Path $PrivateLogDir -Force | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $PrivateLogDir -AclObject $acl
    $msiLog = Join-Path $PrivateLogDir ('MSI-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.log')
    Log "Installing SentinelOne $($m.version) from $($m.fileName); user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name); PowerShell=$($PSVersionTable.PSVersion); process64=$([Environment]::Is64BitProcess); MSI log: $msiLog"
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msiPath`" SITE_TOKEN=`"$SiteToken`" /qn /norestart /L*V! `"$msiLog`"" -Wait -PassThru
    if ($proc.ExitCode -notin 0, 3010) {
        $exitCode = [int]$proc.ExitCode
        throw "msiexec returned $($proc.ExitCode) installing $($m.fileName). Detailed MSI log: $msiLog"
    }

    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Get-Service -Name 'SentinelAgent' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
    if (-not (Get-Service -Name 'SentinelAgent' -ErrorAction SilentlyContinue)) {
        throw "msiexec succeeded (exit $($proc.ExitCode)) but the SentinelAgent service never appeared."
    }
    Log "Installed SentinelOne $($m.version) (msiexec exit $($proc.ExitCode))."
    $exitCode = 0
}
catch { Log "ERROR: $($_.Exception.Message)" }
finally { if ($msiPath -and (Test-Path $msiPath)) { Remove-Item $msiPath -Force -ErrorAction SilentlyContinue } }
exit $exitCode
'@
$script:CBITPrivilegedRunbook = {
#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    CBIT Customer Privileged Access Deployment - interactive, resumable, journaled.

.DESCRIPTION
    Single-file interactive deployment of the CBIT Privileged Access standard (runbook v5).
    Run elevated on the customer DC (PDC emulator preferred) with the ActiveDirectory
    and GroupPolicy modules present.

    Phases
      0  Preamble / ITG pre-stage confirmation
      1  Environment + JIT attestation
      2  Discovery (read-only, embedded)
      3  Workstation OU scope (offer OU create + redircmp)
      4  Legacy 'CBIT' collision (offer rename -> cbit-legacy)
      5  CBIT-DA recovery account + interactive login test
      6  RID-500 disable (DISABLE gate)
      7  CBIT-Elevation (login CBIT)
      8  CBIT-Endpoint-Admins group
      9  GPO create/verify + GPMC edit pause + Groups.xml verification
     10  GPO link
     11  Workstation validation hand-off
     12  Summary

    Every mutation is journaled (journal.jsonl) with a pre-change breadcrumb.
    -Rollback replays the journal in reverse. -Resume continues an incomplete run.
    -DryRun runs discovery and prints planned mutations without changing anything.

.PARAMETER LogRoot
    Root folder for run folders. Default C:\CBIT\Logs\GPO\CyberQP

.NOTES
    Passwords are read as SecureString at the prompt and are never written to
    state, journal, log or transcript.
    Author: CBIT, Inc.   Version: 1.2 (2026-10-06) - CBIT-DA WinRM validation; GPP Local User Delete of legacy local CBIT
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]      [switch]$DryRun,
    [Parameter(ParameterSetName = 'Resume')]   [switch]$Resume,
    [Parameter(ParameterSetName = 'Rollback')] [switch]$Rollback,
    [string]$RunId,
    [string]$LogRoot = 'C:\CBIT\Logs\GPO\CyberQP'
)

function Initialize-CBITRuntime {
    # Import the native engine's module explicitly: do not depend on command
    # auto-discovery or an inherited PSModulePath for script-based utilities.
    $utility = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'
    try {
        Import-Module -Name $utility -Scope Global -Force -ErrorAction Stop
        $hashCommand = Get-Command -Name Get-FileHash -Module Microsoft.PowerShell.Utility -ErrorAction Stop
        if (-not $hashCommand) { throw 'Get-FileHash was not exported.' }
    } catch {
        throw ("Required Windows PowerShell utility Get-FileHash is unavailable after loading {0}. No deployment was started. {1}" -f $utility, $_.Exception.Message)
    }
}
Initialize-CBITRuntime
# CBIT presentation only: standard ConsoleColor fallback palette.
$Host.UI.RawUI.ForegroundColor = 'Gray'
$Host.PrivateData.ErrorForegroundColor = 'DarkRed'
$Host.PrivateData.WarningForegroundColor = 'DarkYellow'
$Host.PrivateData.VerboseForegroundColor = 'DarkGray'
$Host.PrivateData.DebugForegroundColor = 'DarkGray'
$Host.PrivateData.ProgressForegroundColor = 'DarkGray'
$Host.PrivateData.ProgressBackgroundColor = 'Black'

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ===========================================================================
# Constants
# ===========================================================================
$Script:Const = [ordered]@{
    RecoveryAccount = 'CBIT-DA'
    ElevationSam    = 'CBIT'
    ElevationName   = 'CBIT-Elevation'
    LegacyRename    = 'cbit-legacy'
    GroupName       = 'CBIT-Endpoint-Admins'
    GpoName         = 'CBIT MSP - Endpoint Admin'
    WorkstationsOU  = 'Workstations'
    AdminSid        = 'S-1-5-32-544'
    ItgRecovery     = 'Domain Recovery - CBIT-DA'
    ItgElevation    = 'Workstation Admin - CBIT Elevation'
}
$Script:PrivRids = @{
    '512' = 'Domain Admins'; '518' = 'Schema Admins'; '519' = 'Enterprise Admins'
    '520' = 'Group Policy Creator Owners'; '544' = 'Administrators'; '548' = 'Account Operators'
    '549' = 'Server Operators'; '550' = 'Print Operators'; '551' = 'Backup Operators'
}
$Script:PhaseOrder = @('Preamble','Environment','Discovery','Scope','LegacyCBIT','RecoveryAccount',
                       'RID500','Elevation','EndpointGroup','GPO','GPOLink','WorkstationTest','Summary')

# Run-scoped state (populated by Initialize-Run / Restore-Run)
$Script:RunPath   = $null
$Script:State     = $null
$Script:Disc      = $null
$Script:Transcript = $false
$Script:JournalSeq = 0

# ===========================================================================
# Generic helpers
# ===========================================================================
function Write-Log {
    param([string]$Text = '', [ValidateSet('Info','Warn','Error','Change','Gate','Skip','Ok')][string]$Level = 'Info')
    $color = switch ($Level) { 'Warn' {'DarkYellow'} 'Error' {'DarkRed'} 'Change' {'DarkYellow'} 'Gate' {'Gray'} 'Skip' {'DarkGray'} 'Ok' {'DarkGreen'} default {'DarkGray'} }
    Write-CBITConsole $Text -ForegroundColor $color
    if ($Script:RunPath) {
        $line = '{0} [{1,-6}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Text
        Add-Content -Path (Join-Path $Script:RunPath 'run.log') -Value $line -Encoding UTF8
    }
}
function Write-Banner { param([string]$Text)
    Write-Log ''
    Write-Log ('=' * 78)
    Write-Log "  $Text"
    Write-Log ('=' * 78)
}
function ConvertTo-Hashtable {
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}; foreach ($k in $Object.Keys) { $h[$k] = ConvertTo-Hashtable $Object[$k] }; return $h
    }
    if ($Object -is [string] -or $Object -is [ValueType]) { return $Object }
    if ($Object -is [System.Collections.IEnumerable]) {
        $arr = @(foreach ($i in $Object) { ,(ConvertTo-Hashtable $i) })
        return ,$arr
    }
    if ($Object -is [pscustomobject]) {
        $h = [ordered]@{}; foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }; return $h
    }
    return $Object
}
function Save-State {
    if (-not $Script:RunPath -or -not $Script:State) { return }
    $Script:State.Saved = (Get-Date).ToString('s')
    $Script:State | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $Script:RunPath 'state.json') -Encoding UTF8
}
function Set-Phase { param([string]$Name, [string]$Status, [string]$Note = '')
    $Script:State.Phases[$Name] = [ordered]@{ Status = $Status; Time = (Get-Date).ToString('s'); Note = $Note }
    Save-State
}
function Test-PhaseDone { param([string]$Name)
    $p = $Script:State.Phases[$Name]
    return ($null -ne $p -and $p.Status -in @('done','skipped'))
}
function Get-StringList { param($Value) @(@($Value) | Where-Object { $_ -is [string] -and $_ -ne '' }) }
function Add-Exception { param([string]$Text) $Script:State.Exceptions = @(@(Get-StringList $Script:State.Exceptions) + $Text); Write-Log "EXCEPTION: $Text" 'Warn'; Save-State }
function Add-FollowUp  { param([string]$Text) $Script:State.FollowUps  = @(@(Get-StringList $Script:State.FollowUps) + $Text); Write-Log "FOLLOW-UP: $Text" 'Warn'; Save-State }

function Save-Breadcrumb {
    # Pre-change snapshot. Returns the file path.
    param([string]$Name, $Object)
    $dir = Join-Path $Script:RunPath 'breadcrumbs'
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $safe = ($Name -replace '[\\/:*?"<>|]', '_')
    $file = Join-Path $dir ("{0:D3}-{1}.json" -f (++$Script:JournalSeq), $safe)
    try {
        if ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
            # Flatten to name -> string. NEVER ConvertTo-Json a raw AD object: nTSecurityDescriptor and
            # friends are deep graphs and will exhaust memory on the DC.
            $full = Get-ADObject -Identity $Object.DistinguishedName -Server $Script:State.DC -Properties *
            $flat = [ordered]@{}
            foreach ($n in ($full.PropertyNames | Sort-Object)) {
                $v = $full.$n
                if ($null -eq $v) { $flat[$n] = $null }
                elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) { $flat[$n] = @($v | ForEach-Object { "$_" }) }
                else { $flat[$n] = "$v" }
            }
            $Object = $flat
        }
        $Object | ConvertTo-Json -Depth 3 | Set-Content -Path $file -Encoding UTF8
    } catch {
        ($Object | Out-String -Width 400) | Set-Content -Path $file -Encoding UTF8
    }
    Write-Log "Breadcrumb: $file" 'Info'
    return $file
}
function Add-Journal {
    param([string]$Action, [string]$Target, $Before = $null, $After = $null, [string]$Note = '', [string]$Breadcrumb = '')
    $entry = [ordered]@{
        Seq = ++$Script:State.JournalCount; Time = (Get-Date).ToString('s'); Action = $Action; Target = $Target
        Before = $Before; After = $After; Note = $Note; Breadcrumb = $Breadcrumb; Phase = $Script:State.CurrentPhase
    }
    ($entry | ConvertTo-Json -Compress -Depth 6) | Add-Content -Path (Join-Path $Script:RunPath 'journal.jsonl') -Encoding UTF8
    Save-State
    Write-Log "JOURNAL #$($entry.Seq) $Action -> $Target" 'Change'
}
function Get-Journal { param([string]$RunPath = $Script:RunPath)
    $f = Join-Path $RunPath 'journal.jsonl'
    if (-not (Test-Path $f)) { return @() }
    return @(Get-Content $f | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Stop-Run {
    param([string]$Reason, [string]$Phase = $Script:State.CurrentPhase)
    Write-Log '' ; Write-Log "STOP: $Reason" 'Error'
    if ($Script:State -and $Phase) { Set-Phase $Phase 'stopped' $Reason }
    Write-Log "State saved. Re-run with -Resume to continue, or -Rollback to reverse this run." 'Warn'
    Write-Log "Run folder: $($Script:RunPath)" 'Warn'
    if ($Script:Transcript) { try { Stop-Transcript | Out-Null } catch {} }
    exit 1
}
function Invoke-Gate {
    # Blocks until the technician types the keyword. 'abort' always stops the run.
    param([string]$Message, [string]$Keyword = 'done', [string[]]$AlsoAccept = @(), [switch]$CaseSensitive, [switch]$AllowEmpty)
    Write-Log '' ; Write-Log $Message 'Gate'
    $opts = "Type '$Keyword'" + $(if ($AlsoAccept.Count) { " or " + (($AlsoAccept | ForEach-Object { "'$_'" }) -join ' / ') } else { '' }) + " to continue, 'abort' to stop and save state"
    while ($true) {
        $r = (Read-Host $opts).Trim()
        if ($r -ceq 'abort') { Stop-Run 'Aborted by technician at gate.' }
        $ok = if ($CaseSensitive) { $r -ceq $Keyword } else { $r -ieq $Keyword }
        if (-not $ok -and $AlsoAccept.Count) { $ok = [bool]($AlsoAccept | Where-Object { $_ -ieq $r }) }
        if ($ok) { Write-Log "GATE [$Keyword]: technician entered '$r'" 'Gate'; return $r }
        if ($r -eq '' -and $AllowEmpty) { Write-Log "GATE [$Keyword]: Enter pressed - no action" 'Gate'; return '' }
    }
}
function Confirm-YesNo { param([string]$Message)
    while ($true) {
        $r = (Read-Host "$Message [y/n]").Trim().ToLower()
        if ($r -eq 'abort') { Stop-Run 'Aborted by technician.' }
        if ($r -in 'y','yes') { Write-Log "CONFIRM: '$Message' -> yes" 'Gate'; return $true }
        if ($r -in 'n','no')  { Write-Log "CONFIRM: '$Message' -> no"  'Gate'; return $false }
    }
}
function Read-PasswordTwice { param([string]$Label)
    while ($true) {
        $a = Read-Host "Enter $Label (paste from IT Glue)" -AsSecureString
        $b = Read-Host "Re-enter $Label" -AsSecureString
        $pa = [System.Net.NetworkCredential]::new('', $a).Password
        $pb = [System.Net.NetworkCredential]::new('', $b).Password
        $match = ($pa.Length -gt 0) -and ($pa -ceq $pb)
        $pa = $null; $pb = $null
        if ($match) { return $a }
        Write-Log 'Passwords did not match or were empty. Try again.' 'Warn'
    }
}
function Convert-FileTime { param($Value)
    if ($Value -and $Value -gt 0) { [DateTime]::FromFileTime([int64]$Value).ToString('yyyy-MM-dd HH:mm') } else { 'never' }
}
function Invoke-Phase {
    param([string]$Name, [scriptblock]$Body, [switch]$AlwaysRun)
    if ((Test-PhaseDone $Name) -and -not $AlwaysRun) {
        Write-Log "Phase $Name : already $($Script:State.Phases[$Name].Status) in a prior session - skipping" 'Skip'
        return
    }
    $Script:State.CurrentPhase = $Name
    Set-Phase $Name 'running'
    Write-Banner "PHASE: $Name"
    try {
        & $Body
        if ($Script:State.Phases[$Name].Status -eq 'running') { Set-Phase $Name 'done' }
    } catch {
        Set-Phase $Name 'error' $_.Exception.Message
        Write-Log "ERROR in phase $Name : $($_.Exception.Message)" 'Error'
        Write-Log ($_.ScriptStackTrace) 'Error'
        Stop-Run "Unhandled error in phase $Name."
    }
}

# ===========================================================================
# AD helpers
# ===========================================================================
function Get-RecursiveGroups { param([string]$DistinguishedName)
    $esc = $DistinguishedName -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29'
    @(Get-ADGroup -Server $Script:State.DC -LDAPFilter "(member:1.2.840.113556.1.4.1941:=$esc)" -Properties GroupScope,GroupCategory,Description)
}
function Test-PrivilegedGroup { param($Group)
    $sid = $Group.SID.Value; $rid = $sid.Split('-')[-1]
    if ($Script:PrivRids.ContainsKey($rid)) {
        if ($sid -like 'S-1-5-32-*' -or $sid -like "$($Script:State.DomainSid)-*") { return $Script:PrivRids[$rid] }
    }
    return $null
}
function Get-ADSafe {
    # AD -Identity lookups throw terminating errors on not-found even with -ErrorAction SilentlyContinue; wrap them.
    param([scriptblock]$Query)
    try { & $Query } catch { $null }
}
function Get-UserBySam { param([string]$Sam)
    $u = @(Get-ADUser -Server $Script:State.DC -Filter "SamAccountName -eq '$Sam'" -Properties Enabled,PasswordNeverExpires,CannotChangePassword,PasswordLastSet,LastLogonTimestamp,Description,MemberOf,PrimaryGroupID,adminCount,ServicePrincipalName,UserPrincipalName,whenCreated,LockedOut,DisplayName)
    if ($u.Count -gt 1) { throw "More than one user matched SamAccountName '$Sam' - not possible in a single domain; check -Server scope." }
    if ($u.Count -eq 1) { return $u[0] } else { return $null }
}
function Test-CreatedThisRun { param([string]$ObjectGuid)
    [bool](Get-Journal | Where-Object { $_.Action -like 'Create*' -and $_.After -and $_.After.ObjectGUID -eq $ObjectGuid })
}
function Test-RecycleBin {
    try { $f = Get-ADOptionalFeature -Server $Script:State.DC -Filter 'Name -like "Recycle Bin Feature"'; return ([bool]$f -and @($f.EnabledScopes).Count -gt 0) } catch { return $null }
}
function Get-OuCanonical { param([string]$DN)
    (Get-ADOrganizationalUnit -Identity $DN -Server $Script:State.DC -Properties CanonicalName).CanonicalName
}
function Test-RecoveryCredential {
    # Validates the CBIT-DA password and Domain Admins token via WinRM to the PDC. Credential is never persisted.
    $user = "$($Script:State.NetBIOS)\$($Script:Const.RecoveryAccount)"
    while($true){
        $cred = Get-Credential -UserName $user -Message "Paste the '$($Script:Const.ItgRecovery)' password from IT Glue"
        if (-not $cred) { return [pscustomobject]@{ Ok = $false; Detail = 'Credential prompt cancelled.' } }
        $entered=$cred.UserName
        if($entered -ine $user -and $entered -ine $Script:Const.RecoveryAccount -and $entered -ine ($Script:Const.RecoveryAccount+'@'+$Script:State.DomainDNS)){
            Write-Log 'Recovery username was not found or is not the required CBIT-DA account. Try again.' 'Warn'
            $cred=$null;continue
        }
        break
    }
    try {
        $r = Invoke-Command -ComputerName $Script:State.DC -Credential $cred -ErrorAction Stop -ScriptBlock {
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            [pscustomobject]@{
                Name    = $id.Name
                IsAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                Sids    = @($id.Groups | ForEach-Object { $_.Value })
            }
        }
        $isDA = $r.Sids -contains "$($Script:State.DomainSid)-512"
        $ok   = ($r.Name -ieq $user) -and $r.IsAdmin -and $isDA
        return [pscustomobject]@{ Ok = $ok; Detail = "Name=$($r.Name) LocalAdmin=$($r.IsAdmin) DomainAdmins=$isDA" }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    } finally { $cred = $null }
}
function Get-GpoSysvolPath { param($Gpo)
    "\\{0}\SYSVOL\{1}\Policies\{{{2}}}" -f $Script:State.DC, $Script:State.DomainDNS, $Gpo.Id.ToString().ToUpper()
}

# ===========================================================================
# GPP Groups.xml verification (runbook v6 gap: parse SYSVOL, not the report)
# ===========================================================================
function Test-EndpointGpoSettings {
    param($Gpo)
    $problems = New-Object System.Collections.Generic.List[string]
    $xmlPath  = Join-Path (Get-GpoSysvolPath $Gpo) 'Machine\Preferences\Groups\Groups.xml'
    $expectedMember = "$($Script:State.NetBIOS)\$($Script:Const.GroupName)"
    if (-not (Test-Path $xmlPath)) {
        $problems.Add("Groups.xml not found at $xmlPath - GPP Local Group item not saved, or GPMC was pointed at a different DC (use Change Domain Controller -> $($Script:State.DC)).")
        return [pscustomobject]@{ Valid = $false; Problems = $problems; Path = $xmlPath }
    }
    [xml]$x = Get-Content $xmlPath -Raw
    $groups = @($x.Groups.Group)
    $target = @($groups | Where-Object { $_.Properties.groupSid -eq $Script:Const.AdminSid })
    if ($target.Count -eq 0) { $problems.Add("No Local Group item targets $($Script:Const.AdminSid) (Administrators built-in).") }
    if ($target.Count -gt 1) { $problems.Add("$($target.Count) Local Group items target Administrators - expected exactly one; remove duplicates.") }
    foreach ($g in $groups) {
        $p = $g.Properties
        if ($p.deleteAllUsers  -eq '1') { $problems.Add("Item '$($g.name)': 'Delete all member users' is CHECKED - must be unchecked.") }
        if ($p.deleteAllGroups -eq '1') { $problems.Add("Item '$($g.name)': 'Delete all member groups' is CHECKED - must be unchecked.") }
        if ($p.action -and $p.action -ne 'U') { $problems.Add("Item '$($g.name)': action is '$($p.action)' - must be Update (U).") }
    }
    if ($target.Count -eq 1) {
        $members = @($target[0].Properties.Members.Member)
        $hit = @($members | Where-Object { $_.name -ieq $expectedMember })
        if ($hit.Count -eq 0)             { $problems.Add("Member '$expectedMember' not present in the Administrators item. Members found: $(($members | ForEach-Object { $_.name }) -join ', ')") }
        elseif ($hit[0].action -ne 'ADD') { $problems.Add("Member '$expectedMember' action is '$($hit[0].action)' - must be ADD.") }
        $extra = @($members | Where-Object { $_.name -ine $expectedMember })
        if ($extra.Count) { $problems.Add("Unexpected additional members in the Administrators item: $(($extra | ForEach-Object { "$($_.name)[$($_.action)]" }) -join ', ')") }
        if ($target[0].Properties.removeAccounts -eq '1') { $problems.Add("Administrators item has 'removeAccounts' set - not expected.") }
    }
    # Legacy local CBIT: exactly one Local User item, action Delete, no stored password
    $users = @($x.Groups.User | Where-Object { $_ })
    $del   = @($users | Where-Object { $_.Properties.userName -ieq $Script:Const.ElevationSam })
    if ($del.Count -eq 0)     { $problems.Add("No Local User item deleting local '$($Script:Const.ElevationSam)' (New -> Local User, Action Delete).") }
    elseif ($del.Count -gt 1) { $problems.Add("$($del.Count) Local User items for '$($Script:Const.ElevationSam)' - expected exactly one.") }
    elseif ($del[0].Properties.action -ne 'D') { $problems.Add("Local User '$($Script:Const.ElevationSam)' action is '$($del[0].Properties.action)' - must be Delete (D).") }
    foreach ($u in $users) {
        if ($u.Properties.userName -ine $Script:Const.ElevationSam) { $problems.Add("Unexpected Local User item '$($u.Properties.userName)'.") }
        if ($u.Properties.cpassword) { $problems.Add("Local User item '$($u.Properties.userName)' contains a password (cpassword). Never store passwords in GPP.") }
    }
    $gpoNow = Get-GPO -Guid $Gpo.Id -Domain $Script:State.DomainDNS -Server $Script:State.DC
    if ($gpoNow.Computer.DSVersion -lt 1) { $problems.Add("GPO computer version is $($gpoNow.Computer.DSVersion) - GPMC edit has not incremented the version.") }
    [pscustomobject]@{ Valid = ($problems.Count -eq 0); Problems = $problems; Path = $xmlPath }
}

# ===========================================================================
# Run lifecycle
# ===========================================================================
function Get-RunFolders {
    if (-not (Test-Path $LogRoot)) { return @() }
    @(Get-ChildItem $LogRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'state.json') } | Sort-Object Name)
}
function Get-RunState { param([string]$Path)
    ConvertTo-Hashtable (Get-Content (Join-Path $Path 'state.json') -Raw | ConvertFrom-Json)
}
function Resolve-RunFolder {
    # -RunId given: that folder. Otherwise latest.
    param([switch]$IncompleteOnly)
    $runs = Get-RunFolders
    if ($RunId) {
        $r = $runs | Where-Object { $_.Name -eq $RunId -or $_.FullName -eq $RunId }
        if (-not $r) { throw "Run '$RunId' not found under $LogRoot" }
        return $r.FullName
    }
    if ($IncompleteOnly) { $runs = @($runs | Where-Object { $st = Get-RunState $_.FullName; -not $st.Completed -and -not $st.DryRun }) }
    if ($runs.Count -eq 0) { return $null }
    return ($runs | Select-Object -Last 1).FullName
}
function Initialize-Domain {
    foreach ($m in 'ActiveDirectory','GroupPolicy') {
        if (-not (Get-Module -ListAvailable -Name $m)) { throw "PowerShell module '$m' is not installed. Install RSAT-AD-PowerShell / GPMC and re-run." }
        Import-Module $m -ErrorAction Stop
    }
    $d = Get-ADDomain -ErrorAction Stop
    $f = Get-ADForest -ErrorAction Stop
    return @{
        DomainDNS = $d.DNSRoot; NetBIOS = $d.NetBIOSName; DomainDN = $d.DistinguishedName; DomainSid = $d.DomainSID.Value
        DC = $d.PDCEmulator; DCs = @($d.ReplicaDirectoryServers); UsersContainer = $d.UsersContainer; ComputersContainer = $d.ComputersContainer
        DomainMode = "$($d.DomainMode)"; ForestMode = "$($f.ForestMode)"; ForestDomains = @($f.Domains)
    }
}
function Initialize-Run {
    $dom = Initialize-Domain
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Script:RunPath = Join-Path $LogRoot "$($dom.NetBIOS)-$stamp"
    foreach ($sub in '', 'breadcrumbs', 'discovery') { New-Item -Path (Join-Path $Script:RunPath $sub) -ItemType Directory -Force | Out-Null }
    $Script:State = [ordered]@{
        RunId = Split-Path $Script:RunPath -Leaf; Created = (Get-Date).ToString('s'); Saved = $null; Completed = $false; DryRun = [bool]$DryRun
        Host = $env:COMPUTERNAME; RunAs = "$env:USERDOMAIN\$env:USERNAME"; ScriptVersion = '1.2'
        DomainDNS = $dom.DomainDNS; NetBIOS = $dom.NetBIOS; DomainDN = $dom.DomainDN; DomainSid = $dom.DomainSid; DC = $dom.DC
        UsersContainer = $dom.UsersContainer; ComputersContainer = $dom.ComputersContainer
        UsersPath = $dom.UsersContainer; GroupsPath = $dom.UsersContainer
        WorkstationsOUs = @(); Phases = [ordered]@{}; CurrentPhase = ''
        Exceptions = @(); FollowUps = @(); JournalCount = 0
        Legacy = [ordered]@{}; GpoId = $null; ValidationStatus = 'pending'; RID500Disabled = $null
    }
    Save-State
    Start-Transcript -Path (Join-Path $Script:RunPath 'transcript.log') -Append | Out-Null
    $Script:Transcript = $true
    Write-Banner "CBIT Privileged Access Deployment  -  run $($Script:State.RunId)"
    Write-Log "Host $env:COMPUTERNAME   RunAs $($Script:State.RunAs)   PS $($PSVersionTable.PSVersion)   DryRun=$($DryRun.IsPresent)"
    Write-Log "Domain $($dom.DomainDNS) ($($dom.NetBIOS))   PDC $($dom.DC)   Mode $($dom.DomainMode)/$($dom.ForestMode)"
    Write-Log "Run folder: $($Script:RunPath)"
    if ($dom.ForestDomains.Count -gt 1) { Add-Exception "Multi-domain forest ($($dom.ForestDomains -join ', ')). Script scope is the current domain only." }
}
function Restore-Run { param([string]$Path)
    $Script:RunPath = $Path
    $Script:State   = Get-RunState $Path
    $Script:JournalSeq = $Script:State.JournalCount
    $dom = Initialize-Domain
    if ($dom.DomainDNS -ine $Script:State.DomainDNS) { throw "Run $($Script:State.RunId) belongs to $($Script:State.DomainDNS) but this host is in $($dom.DomainDNS)." }
    $Script:State.DC = $dom.DC   # PDC may have moved; everything else is stable
    foreach ($k in 'Exceptions','FollowUps','WorkstationsOUs') { $Script:State[$k] = Get-StringList $Script:State[$k] }
    Start-Transcript -Path (Join-Path $Path 'transcript.log') -Append | Out-Null
    $Script:Transcript = $true
    Write-Banner "RESUME  -  run $($Script:State.RunId)"
    Write-Log ("Phases: " + (($Script:State.Phases.Keys | ForEach-Object { "$_=$($Script:State.Phases[$_].Status)" }) -join '  '))
    Write-Log "Workstation OUs: $($Script:State.WorkstationsOUs -join ' | ')"
    Save-State
    # Reload discovery object if it was cached
    $dcache = Join-Path $Path 'discovery\discovery.json'
    if (Test-Path $dcache) { $Script:Disc = ConvertTo-Hashtable (Get-Content $dcache -Raw | ConvertFrom-Json) }
}

# ===========================================================================
# PHASE 0 - Preamble
# ===========================================================================
function Invoke-Preamble {
    $nb = $Script:State.NetBIOS
    $lines = @(
        "This script deploys the CBIT Privileged Access standard on $($Script:State.DomainDNS)."
        ''
        'REQUIREMENTS'
        "  - Elevated PowerShell on the customer DC (this host: $env:COMPUTERNAME, PDC: $($Script:State.DC))."
        '  - CyberQP JIT server/DC administration confirmed working (you will attest in the next step).'
        '  - Pre-staged in IT Glue BEFORE continuing:'
        "      1. '$($Script:Const.ItgRecovery)'   username $nb\CBIT-DA   - LastPass-generated 45-character password"
        "      2. '$($Script:Const.ItgElevation)'   username $nb\CBIT   - <city4>-<look2thestars base>"
        '    Both entries stay management-only. Never match CBIT-DA to CyberQP rotation.'
        ''
        'WHAT THE SCRIPT DOES'
        '  Discovery (read-only) -> workstation OU scope -> legacy CBIT check -> CBIT-DA -> RID-500 -> CBIT-Elevation'
        "  -> $($Script:Const.GroupName) -> GPO '$($Script:Const.GpoName)' -> link -> workstation validation -> summary."
        ''
        'WHERE IT PAUSES FOR YOU'
        '  - CBIT-DA credential/admin check via WinRM; separate interactive login if manual verification is needed'
        '  - Endpoint GPO preferences are configured automatically and verified; no manual GPMC edit is required'
        '  - gpupdate on a workstation'
        '  - Every deletion, rename, RID-500 disable, OU create, workstation move, redircmp and GPO link asks first.'
        ''
        'WHAT IT WILL NOT DO'
        "  Move servers, clean up AD, touch the 'CBIT MSP - Axis' RMM GPO, JIT identities, service accounts or Exchange groups."
        ''
        "Every change is journaled to $($Script:RunPath)\journal.jsonl with a pre-change breadcrumb."
        '  Resume an interrupted run:   unified menu option 5, then resume (use the same script/log location)'
        '  Reverse this run:            unified menu option 5, then rollback (review the run ID and plan)'
    )
    $lines | ForEach-Object { Write-Log $_ }
    if ($DryRun) { Write-Log 'DRY RUN - nothing will be changed.' 'Warn'; return }
    Write-Log ''
    Read-Host 'When both IT Glue entries are saved, press Enter to start' | Out-Null
    Write-Log 'GATE [Enter]: ITG pre-stage confirmed' 'Gate'
}

# ===========================================================================
# PHASE 1 - Environment
# ===========================================================================
function Invoke-Environment {
    $os = Get-CimInstance Win32_OperatingSystem
    $isDC = ($os.ProductType -eq 2)
    $build = [int]$os.BuildNumber
    Write-Log "OS: $($os.Caption) build $build   DomainController=$isDC"
    if ($build -lt 14393) { Add-Exception "Host build $build is older than Server 2016 - script floor is 2016; proceed at own risk." }
    if (-not $isDC) { Write-Log 'Not a domain controller. Supported, but redircmp and SYSVOL checks target the PDC over the network.' 'Warn' }
    if ($env:COMPUTERNAME -ine ($Script:State.DC -split '\.')[0]) { Write-Log "Note: this host is not the PDC emulator ($($Script:State.DC)); all AD/GPO calls are targeted at the PDC." 'Warn' }
    $rid500 = Get-ADUser -Identity "$($Script:State.DomainSid)-500" -Server $Script:State.DC -Properties Enabled
    if ($env:USERNAME -ieq $rid500.SamAccountName) { Add-Exception "Running as the built-in Administrator ($($rid500.SamAccountName)). Phase RID500 will refuse to disable it from this session." }
    if ($DryRun) { return }
    Invoke-Gate -Message 'Confirm CyberQP JIT server/DC administration is working for this customer (runbook guardrail 3.1).' -Keyword 'ready'
    $Script:State.JitAttested = (Get-Date).ToString('s'); Save-State
}

# ===========================================================================
# PHASE 2 - Discovery (embedded, read-only)
# ===========================================================================
function Invoke-Discovery {
    $DC = $Script:State.DC; $DomainDNS = $Script:State.DomainDNS; $DomainDN = $Script:State.DomainDN; $DomainSid = $Script:State.DomainSid
    $dir = Join-Path $Script:RunPath 'discovery'
    $Summary = New-Object System.Collections.Generic.List[string]
    $Detail  = New-Object System.Collections.Generic.List[string]
    $Findings = New-Object System.Collections.Generic.List[string]
    function Add-Line { param([string]$Text = '') $Summary.Add($Text); Write-CBITConsole $Text -ForegroundColor DarkGray }
    function Add-Header { param([string]$Text) Add-Line ''; Add-Line ('-' * 78); Add-Line "  $Text"; Add-Line ('-' * 78) }
    function Add-Finding { param([string]$Text) $Findings.Add($Text) }
    function Save-Report { param([string]$Name, $Object)
        $Detail.Add(''); $Detail.Add('#' * 78); $Detail.Add("# $Name"); $Detail.Add('#' * 78)
        if ($null -eq $Object) { $Detail.Add('<< no data >>'); return }
        try { $t = ($Object | Out-String -Width 400).TrimEnd(); if ([string]::IsNullOrWhiteSpace($t)) { $Detail.Add('<< no data >>') } else { $Detail.Add($t) } }
        catch { $Detail.Add("ERROR rendering section: $($_.Exception.Message)") }
    }
    function Get-OuGpoLinks { param([string]$Target)
        try {
            $inh = Get-GPInheritance -Target $Target -Domain $DomainDNS -Server $DC -ErrorAction Stop
            $links = @($inh.GpoLinks | ForEach-Object { '{0}{1}{2} [{3}]' -f $_.DisplayName, $(if (-not $_.Enabled) {' (DISABLED)'} else {''}), $(if ($_.Enforced) {' (ENFORCED)'} else {''}), $_.Order })
            [pscustomobject]@{ Target = $Target; BlocksInheritance = $inh.GpoInheritanceBlocked; Links = $links; Raw = $inh }
        } catch { [pscustomobject]@{ Target = $Target; BlocksInheritance = $null; Links = @("ERROR: $($_.Exception.Message)"); Raw = $null } }
    }

    Add-Header "DISCOVERY  $DomainDNS  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  (read-only)"
    Add-Line "DomainDN $DomainDN   PDC $DC   ComputersContainer $($Script:State.ComputersContainer)"

    # --- 2a. Existing CBIT* users ---------------------------------------------
    Add-Header 'CBIT* IDENTITIES'
    $cbitUsers = @(Get-ADUser -Server $DC -Filter 'SamAccountName -like "CBIT*" -or Name -like "CBIT*"' -Properties Enabled,PasswordNeverExpires,CannotChangePassword,PasswordLastSet,LastLogonTimestamp,Description,MemberOf,PrimaryGroupID,adminCount,ServicePrincipalName,UserPrincipalName,whenCreated,DisplayName)
    $userInfo = @()
    foreach ($u in $cbitUsers) {
        $groups = @(Get-RecursiveGroups -DistinguishedName $u.DistinguishedName | Sort-Object Name)
        $priv = @($groups | Where-Object { Test-PrivilegedGroup $_ } | ForEach-Object { $_.Name })
        $vpn  = @($groups | Where-Object { $_.Name -match 'vpn|remote|rdp|rds|dial|ras|nps|wifi|wireless' } | ForEach-Object { $_.Name })
        Add-Line ''
        Add-Line "User $($u.Name) (sAM=$($u.SamAccountName))  Enabled=$($u.Enabled)  Created=$($u.whenCreated.ToString('yyyy-MM-dd'))  LastLogon~$(Convert-FileTime $u.LastLogonTimestamp)"
        Add-Line "  DN $($u.DistinguishedName)"
        Add-Line "  PwdNeverExpires=$($u.PasswordNeverExpires) CannotChangePwd=$($u.CannotChangePassword) adminCount=$($u.adminCount) PrimaryGroupID=$($u.PrimaryGroupID) Desc='$($u.Description)'"
        if ($u.ServicePrincipalName) { Add-Line "  SPNs: $($u.ServicePrincipalName -join '; ')"; Add-Finding "$($u.SamAccountName) has SPNs - likely a service account. Not touched." }
        Add-Line "  Groups ($($groups.Count)): $(($groups | ForEach-Object { $_.Name + $(if (Test-PrivilegedGroup $_) {'***'} else {''}) }) -join ', ')"
        if ($priv.Count) { Add-Finding "$($u.SamAccountName) is in privileged group(s): $($priv -join ', ')." }
        if ($vpn.Count)  { Add-Finding "$($u.SamAccountName) is in possible VPN/remote group(s): $($vpn -join ', ')." }
        $userInfo += [ordered]@{ Name = $u.Name; Sam = $u.SamAccountName; DN = $u.DistinguishedName; Enabled = [bool]$u.Enabled; Guid = $u.ObjectGUID.ToString()
                                 Description = "$($u.Description)"; SPNs = @($u.ServicePrincipalName); Privileged = $priv; VPNish = $vpn; Groups = @($groups | ForEach-Object { $_.Name })
                                 PrimaryGroupID = $u.PrimaryGroupID; adminCount = $u.adminCount; Created = $u.whenCreated.ToString('s'); LastLogon = (Convert-FileTime $u.LastLogonTimestamp) }
    }
    if ($cbitUsers.Count -eq 0) { Add-Line 'None.' }
    Save-Report 'CBIT-Users' ($cbitUsers | Format-List Name,SamAccountName,UserPrincipalName,Enabled,Description,DistinguishedName,@{N='MemberOf';E={$_.MemberOf -join '; '}})
    $cbitGroups = @(Get-ADGroup -Server $DC -Filter 'SamAccountName -like "CBIT*" -or Name -like "CBIT*"' -Properties Description,Members,MemberOf)
    Add-Line ''
    Add-Line "CBIT* groups: $(if ($cbitGroups.Count) { ($cbitGroups | ForEach-Object { "$($_.Name) [$($_.GroupScope)/$($_.GroupCategory), $(@($_.Members).Count) members]" }) -join '; ' } else { 'none' })"

    # --- 2b. CBIT-DA / RID-500 -------------------------------------------------
    Add-Header "$($Script:Const.RecoveryAccount) / BUILT-IN ADMINISTRATOR"
    $da = Get-UserBySam $Script:Const.RecoveryAccount
    $daInfo = $null
    if ($da) {
        $isDA = [bool](Get-RecursiveGroups $da.DistinguishedName | Where-Object { $_.SID.Value -eq "$DomainSid-512" })
        Add-Line "$($Script:Const.RecoveryAccount): EXISTS Enabled=$($da.Enabled) LockedOut=$($da.LockedOut) DomainAdmin=$isDA PwdLastSet=$($da.PasswordLastSet) LastLogon~$(Convert-FileTime $da.LastLogonTimestamp)"
        $daInfo = [ordered]@{ Exists = $true; Enabled = [bool]$da.Enabled; DomainAdmin = $isDA; Guid = $da.ObjectGUID.ToString(); Created = $da.whenCreated.ToString('s') }
        if (-not $da.Enabled) { Add-Finding "$($Script:Const.RecoveryAccount) exists but is DISABLED." }
        if (-not $isDA)       { Add-Finding "$($Script:Const.RecoveryAccount) exists but is NOT a Domain Admin." }
    } else { Add-Line "$($Script:Const.RecoveryAccount): not present"; $daInfo = [ordered]@{ Exists = $false } }
    $rid500 = Get-ADUser -Identity "$DomainSid-500" -Server $DC -Properties Enabled,LastLogonTimestamp,PasswordLastSet,LastLogonDate
    $r500Info = [ordered]@{ Sam = $rid500.SamAccountName; Enabled = [bool]$rid500.Enabled; LastLogon = (Convert-FileTime $rid500.LastLogonTimestamp); PwdLastSet = "$($rid500.PasswordLastSet)"; AutomationHints = @() }
    if ($rid500.LastLogonDate -and $rid500.LastLogonDate -gt (Get-Date).AddDays(-30)) { $r500Info.AutomationHints += "LastLogon within 30 days ($($rid500.LastLogonDate))" }
    if ($rid500.LastLogonDate -and $rid500.LastLogonDate.Minute -eq 0 -and $rid500.LastLogonDate.Second -eq 0) { $r500Info.AutomationHints += 'LastLogon lands exactly on the hour (scheduled task / backup / rotation?)' }
    if ($rid500.PasswordLastSet -and $rid500.PasswordLastSet -gt (Get-Date).AddDays(-30)) { $r500Info.AutomationHints += "Password set within 30 days ($($rid500.PasswordLastSet)) - CyberQP rotation?" }
    Add-Line "Built-in Administrator (RID 500): $($rid500.SamAccountName) Enabled=$($rid500.Enabled) LastLogon~$($r500Info.LastLogon) PwdLastSet=$($rid500.PasswordLastSet)"
    foreach ($h in $r500Info.AutomationHints) { Add-Line "  automation hint: $h" }
    Add-Line "AD Recycle Bin: $(Test-RecycleBin)"

    # --- 2c. Standard objects --------------------------------------------------
    Add-Header 'STANDARD OBJECTS'
    $grp = Get-ADGroup -Server $DC -Filter "SamAccountName -eq '$($Script:Const.GroupName)'" -Properties Members,MemberOf,Description -ErrorAction SilentlyContinue
    $grpInfo = if ($grp) { [ordered]@{ Exists = $true; Scope = "$($grp.GroupScope)"; Category = "$($grp.GroupCategory)"; Members = @($grp.Members); MemberOf = @($grp.MemberOf); DN = $grp.DistinguishedName } } else { [ordered]@{ Exists = $false } }
    Add-Line "Group '$($Script:Const.GroupName)': $(if ($grp) { "EXISTS $($grp.GroupScope)/$($grp.GroupCategory) members=$(@($grp.Members).Count) memberOf=$(@($grp.MemberOf).Count)" } else { 'not present' })"
    $allGpos = @(Get-GPO -All -Domain $DomainDNS -Server $DC)
    $gpoMatches = @($allGpos | Where-Object { $_.DisplayName -eq $Script:Const.GpoName })
    Add-Line "GPO '$($Script:Const.GpoName)': $(if ($gpoMatches.Count) { "EXISTS x$($gpoMatches.Count) Id=$($gpoMatches[0].Id) CompVer=$($gpoMatches[0].Computer.DSVersion) Status=$($gpoMatches[0].GpoStatus)" } else { 'not present' })"
    Add-Line "All GPOs in domain: $($allGpos.Count)"
    $orphans = @()
    foreach ($g in $allGpos) {
        $p = "\\$DC\SYSVOL\$DomainDNS\Policies\{$($g.Id.ToString().ToUpper())}"
        if (-not (Test-Path $p)) { $orphans += $g.DisplayName }
    }
    if ($orphans.Count) { Add-Finding "$($orphans.Count) GPO(s) have no SYSVOL folder on $DC (orphaned): $($orphans -join '; ')." }
    $cbitGpos = @($allGpos | Where-Object { $_.DisplayName -like 'CBIT*' })
    $gpoInfo = @()
    foreach ($g in $cbitGpos) {
        [xml]$rep = Get-GPOReport -Guid $g.Id -Domain $DomainDNS -Server $DC -ReportType Xml
        $links = @($rep.GPO.LinksTo | ForEach-Object { "$($_.SOMPath)$(if ($_.Enforced -eq 'true') {' (ENFORCED)'})$(if ($_.Enabled -ne 'true') {' (DISABLED)'})" })
        Add-Line "  - $($g.DisplayName)  Status=$($g.GpoStatus) CompVer=$($g.Computer.DSVersion)  Links: $(if ($links.Count) { $links -join ' | ' } else { '<unlinked>' })"
        $safe = ($g.DisplayName -replace '[\\/:*?"<>|]', '_')
        try { Get-GPOReport -Guid $g.Id -Domain $DomainDNS -Server $DC -ReportType Xml -Path (Join-Path $dir "$safe.xml") } catch {}
        $gpoInfo += [ordered]@{ Name = $g.DisplayName; Id = $g.Id.ToString(); Links = $links; CompVer = $g.Computer.DSVersion }
    }
    Save-Report 'All-GPOs' ($allGpos | Select-Object DisplayName,GpoStatus,@{N='CompVer';E={$_.Computer.DSVersion}},@{N='UserVer';E={$_.User.DSVersion}},CreationTime,ModificationTime,Id | Sort-Object DisplayName | Format-Table -AutoSize)

    # --- 2d. Computers & OUs ---------------------------------------------------
    Add-Header 'COMPUTERS AND OU PLACEMENT'
    $computers = @(Get-ADComputer -Server $DC -Filter * -Properties OperatingSystem,Enabled,LastLogonTimestamp,PrimaryGroupID,Description)
    $compRows = @(foreach ($c in $computers) {
        $parent = ($c.DistinguishedName -replace '^CN=[^,]+,', '')
        $class = if ($c.PrimaryGroupID -in 516,521 -or $parent -like 'OU=Domain Controllers,*') { 'DC' }
                 elseif ($c.OperatingSystem -like '*Server*') { 'Server' }
                 elseif ($c.OperatingSystem -like 'Windows*') { 'Client' }
                 elseif ([string]::IsNullOrEmpty($c.OperatingSystem)) { 'Unknown' } else { 'Other' }
        if ($c.Name -like 'AZUREADSSO*' -or $c.Description -match 'cluster|CNO|VCO') { $class = 'Special' }
        [pscustomobject]@{ Name = $c.Name; Class = $class; OS = $c.OperatingSystem; Enabled = $c.Enabled; LastLogon = (Convert-FileTime $c.LastLogonTimestamp); Container = $parent; DN = $c.DistinguishedName }
    })
    Save-Report 'Computers' ($compRows | Sort-Object Container,Name | Format-Table Name,Class,OS,Enabled,LastLogon,Container -AutoSize)
    $byClass = $compRows | Group-Object Class | Sort-Object Name
    Add-Line "Total computers: $($compRows.Count)   $(($byClass | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '  ')"
    $stale = @($compRows | Where-Object { $_.Enabled -and $_.LastLogon -ne 'never' -and ([datetime]$_.LastLogon) -lt (Get-Date).AddDays(-90) })
    if ($stale.Count) { Add-Line "Stale (>90d): $($stale.Count) enabled computer(s) - see discovery detail"; Add-FollowUp "$($stale.Count) stale computer objects (>90d no logon) - see discovery detail." }
    $candidateOUs = @(); $mixedOUs = @(); $clientsInContainer = 0
    foreach ($grpC in ($compRows | Group-Object Container | Sort-Object Name)) {
        $cnt = $grpC.Group | Group-Object Class
        $desc = ($cnt | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
        $hasClient = [bool]($cnt | Where-Object { $_.Name -eq 'Client' })
        $hasServer = [bool]($cnt | Where-Object { $_.Name -in 'Server','DC' })
        $tag = ''
        if ($grpC.Name -like 'CN=*') { $tag = '  <-- CONTAINER (cannot link GPO)'; if ($hasClient) { $clientsInContainer += @($grpC.Group | Where-Object Class -eq 'Client').Count } }
        elseif ($grpC.Name -like 'OU=Domain Controllers,*') { $tag = '  (DCs)' }
        elseif ($hasClient -and $hasServer) { $tag = '  <-- MIXED'; $mixedOUs += $grpC.Name }
        elseif ($hasClient) { $tag = '  <-- workstation-only candidate'; $candidateOUs += $grpC.Name }
        Add-Line ("  {0}  [{1}]{2}" -f $grpC.Name, $desc, $tag)
        if ($hasClient -and $hasServer) { foreach ($s in ($grpC.Group | Where-Object { $_.Class -in 'Server','DC' })) { Add-Line "        server: $($s.Name)  $($s.OS)" } }
    }
    if ($clientsInContainer) { Add-Finding "$clientsInContainer client(s) sit in the default Computers container - GPO cannot apply there. The script will offer to move them (Client-class only) once a scope OU is set." }
    if ($mixedOUs.Count)     { Add-Finding "Mixed OU(s) hold servers and clients: $($mixedOUs -join '; '). Not selectable as workstation scope until servers are moved out (out of script scope)." }
    $ous = @(Get-ADOrganizationalUnit -Server $DC -Filter * -Properties ProtectedFromAccidentalDeletion,gPLink,gPOptions,CanonicalName | Sort-Object CanonicalName)
    Add-Line ''
    Add-Line "OU tree ($($ous.Count)):"
    foreach ($ou in $ous) {
        $depth = ($ou.DistinguishedName -split ',(?=OU=)').Count - 1
        $n = @($compRows | Where-Object { $_.Container -eq $ou.DistinguishedName }).Count
        $flags = ''
        if ($n) { $flags += "  [$n computers]" }
        if ($ou.gPLink -and $ou.gPLink.Trim()) { $flags += '  [GPO-linked]' }
        if ($ou.gPOptions -eq 1) { $flags += '  [BLOCKS INHERITANCE]' }
        Add-Line ("  {0}{1}{2}" -f (' ' * ($depth * 2)), $ou.Name, $flags)
    }
    $existingWsOu = @($ous | Where-Object { $_.Name -ieq $Script:Const.WorkstationsOU } | ForEach-Object { $_.DistinguishedName })
    $root = Get-OuGpoLinks -Target $DomainDN
    Add-Line ''
    Add-Line "Domain root links: $(if ($root.Links.Count) { $root.Links -join ' | ' } else { '<none>' })"
    $inh = @()
    foreach ($t in ($candidateOUs + $mixedOUs)) { $r = Get-OuGpoLinks -Target $t; $inh += "===== $t =====", ($r.Raw | Format-List * | Out-String) }
    Save-Report 'OU-Inheritance' $inh

    # --- 2e. Findings ------------------------------------------------------------
    Add-Header 'FINDINGS'
    if ($Findings.Count -eq 0) { Add-Line 'None.' } else { $i = 1; foreach ($f in $Findings) { Add-Line "  $i. $f"; $i++ } }
    Add-Line "Workstation OU candidates: $(if ($candidateOUs.Count) { $candidateOUs -join ' | ' } else { 'NONE' })"

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Summary | Out-File -FilePath (Join-Path $dir "Discovery-Summary-$stamp.txt") -Encoding UTF8
    (@("DISCOVERY DETAIL $DomainDNS $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") + $Detail) | Out-File -FilePath (Join-Path $dir "Discovery-Detail-$stamp.txt") -Encoding UTF8 -Width 400

    $Script:Disc = [ordered]@{
        Time = (Get-Date).ToString('s'); Users = $userInfo; Groups = @($cbitGroups | ForEach-Object { $_.Name }); RecoveryAccount = $daInfo; RID500 = $r500Info
        EndpointGroup = $grpInfo; GpoMatches = @($gpoMatches | ForEach-Object { $_.Id.ToString() }); CbitGpos = $gpoInfo; OrphanGpos = $orphans
        CandidateOUs = $candidateOUs; MixedOUs = $mixedOUs; ExistingWorkstationsOU = $existingWsOu; ClientsInContainer = $clientsInContainer
        Computers = @($compRows | ForEach-Object { [ordered]@{ Name = $_.Name; Class = $_.Class; DN = $_.DN } })
        RecycleBin = (Test-RecycleBin); Findings = @($Findings)
    }
    $Script:Disc | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir 'discovery.json') -Encoding UTF8
    Save-State
    Write-Log "Discovery written to $dir" 'Ok'
}

# ===========================================================================
# PHASE 3 - Workstation OU scope (+ optional OU create / redircmp)
# ===========================================================================
function Test-OuHoldsServers { param([string]$OU)
    @($Script:Disc.Computers | Where-Object { $_.Class -in 'Server','DC' -and ($_.DN -like "*,$OU") })
}
function Get-ProposedContainerPaths {
    $ous = @(Get-ADOrganizationalUnit -Server $Script:State.DC -Filter * | Sort-Object DistinguishedName)
    $u = $ous | Where-Object { $_.Name -match '^(Users|Domain Users|People|Staff|Employees|Accounts)$' } | Select-Object -First 1 -ExpandProperty DistinguishedName
    $g = $ous | Where-Object { $_.Name -match '^(Groups|Security Groups|Domain Groups)$' } | Select-Object -First 1 -ExpandProperty DistinguishedName
    [pscustomobject]@{
        Users  = $(if ($u) { $u } else { $Script:State.UsersContainer })
        Groups = $(if ($g) { $g } elseif ($u) { $u } else { $Script:State.UsersContainer })
    }
}
function Invoke-ClientMove {
    # Offer to move Client-class computers out of default containers into the (single) scope OU.
    param([string]$TargetOU)
    $inContainer = @($Script:Disc.Computers | Where-Object { $_.Class -eq 'Client' -and ($_.DN -replace '^CN=[^,]+,', '') -like 'CN=*' })
    if ($inContainer.Count -eq 0) { return }
    # Re-read live so a stale discovery cache cannot cause a wrong move
    $live = @()
    foreach ($c in $inContainer) {
        $obj = Get-ADSafe { Get-ADComputer -Identity $c.DN -Server $Script:State.DC -Properties OperatingSystem }
        if ($obj -and $obj.OperatingSystem -like 'Windows*' -and $obj.OperatingSystem -notlike '*Server*' -and ($obj.DistinguishedName -replace '^CN=[^,]+,', '') -like 'CN=*') { $live += $obj }
    }
    if ($live.Count -eq 0) { Write-Log 'Clients in the default container have already been moved.' 'Ok'; return }
    Write-Log ''
    Write-Log "$($live.Count) workstation(s) sit in the default Computers container; the GPO will not apply to them until they are in $TargetOU :" 'Warn'
    $live | ForEach-Object { Write-Log ("  {0,-20} {1}" -f $_.Name, $_.OperatingSystem) }
    if ($DryRun) { Write-Log "[DRYRUN] Would offer to move these $($live.Count) client(s) into $TargetOU." 'Warn'; return }
    if (-not (Confirm-YesNo "CyberQP workstation scope: move all $($live.Count) workstation computer objects into $TargetOU now so the local-admin policy can apply? (servers/DCs/unknown OS are never moved; each move is journaled and reversible)")) {
        Add-FollowUp "$($live.Count) client(s) left in CN=Computers - must be moved to $TargetOU manually for the GPO to apply."
        return
    }
    Save-Breadcrumb 'computers-before-move' ($live | Select-Object Name,OperatingSystem,DistinguishedName,ObjectGUID) | Out-Null
    foreach ($obj in $live) {
        $before = $obj.DistinguishedName
        Move-ADObject -Identity $obj.ObjectGUID -TargetPath $TargetOU -Server $Script:State.DC
        $after = (Get-ADComputer -Identity $obj.ObjectGUID -Server $Script:State.DC).DistinguishedName
        Add-Journal -Action 'MoveObject' -Target $obj.Name -Before @{ DN = $before; Parent = ($before -replace '^CN=[^,]+,', '') } -After @{ DN = $after; Parent = $TargetOU; ObjectGUID = $obj.ObjectGUID.ToString() }
        Write-Log "Moved $($obj.Name) -> $TargetOU" 'Ok'
    }
    $Script:Disc.ClientsInContainer = 0; $Script:Disc | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Script:RunPath 'discovery\discovery.json') -Encoding UTF8
    Write-Log 'Moved workstations will pick up the GPO at next policy refresh (or gpupdate /force in the validation step).'
}
function Read-DirectoryContainer {
    param([string]$Prompt,[string]$Default)
    while($true){
        $inputDn=(Read-Host ($Prompt+' [Enter = '+$Default+'; abort = pause]')).Trim()
        if($inputDn -ieq 'abort'){Stop-Run 'Paused at directory destination prompt.'}
        $dn=if($inputDn){$inputDn}else{$Default}
        if($dn -notmatch '^(?i)(OU|CN)=.+,DC='){
            Write-Log 'OU/container not found or invalid. Enter a distinguished name, or press Enter for the proposed destination. Try again.' 'Warn';continue
        }
        try{
            $object=Get-ADObject -Identity $dn -Server $Script:State.DC -ErrorAction Stop
            if($object.ObjectClass -notin 'organizationalUnit','container'){
                Write-Log 'The selected object is not an OU/container. Try again.' 'Warn';continue
            }
            if(-not $object.DistinguishedName.EndsWith(','+$Script:State.DomainDN,[StringComparison]::OrdinalIgnoreCase)){
                Write-Log 'OU/container is outside this domain. Try again.' 'Warn';continue
            }
            return $object.DistinguishedName
        }catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException]{
            Write-Log 'OU/container was not found. Try again.' 'Warn'
        }catch [ArgumentException]{Write-Log 'Invalid OU/container distinguished name. Try again.' 'Warn'}
    }
}

function Invoke-Scope {
    $cands = @($Script:Disc.CandidateOUs)
    $existing = @($Script:Disc.ExistingWorkstationsOU)
    $ouList = @()
    Write-Log "Candidate workstation-only OUs from discovery: $(if ($cands.Count) { $cands -join ' | ' } else { 'none' })"
    if ($existing.Count -and -not ($cands -contains $existing[0])) { Write-Log "An OU named '$($Script:Const.WorkstationsOU)' exists but holds no clients: $($existing -join ' | ')" }

    if ($DryRun) {
        $Script:State.WorkstationsOUs = @($(if ($cands.Count) { $cands } elseif ($existing.Count) { $existing } else { @() }))
        if ($Script:State.WorkstationsOUs.Count -eq 0) {
            $newDn = "OU=$($Script:Const.WorkstationsOU),$($Script:State.DomainDN)"
            Write-Log "[DRYRUN] No workstation OU. Would offer to create $newDn and then offer redircmp to it (current default: $($Script:State.ComputersContainer))." 'Warn'
            $Script:State.WorkstationsOUs = @($newDn)
        } else { Write-Log "[DRYRUN] Would propose scope: $($Script:State.WorkstationsOUs -join ' | ')" 'Warn' }
        if ($Script:State.WorkstationsOUs.Count -eq 1) { Invoke-ClientMove -TargetOU $Script:State.WorkstationsOUs[0] }
        $p = Get-ProposedContainerPaths
        Write-Log "[DRYRUN] Would propose users destination $($p.Users) and groups destination $($p.Groups)." 'Warn'
        $Script:State.UsersPath = $p.Users; $Script:State.GroupsPath = $p.Groups
        Save-State; return
    }

    $prior = @($Script:State.WorkstationsOUs)
    if ($prior.Count) { Write-Log "Scope saved by the previous session: $($prior -join ' | ')" }
    if ($prior.Count -gt 0 -or $cands.Count -gt 0 -or $existing.Count -gt 0) {
        $proposed = if ($prior.Count) { $prior } elseif ($cands.Count) { $cands } else { $existing }
        Write-Log 'Proposed scope:' ; $proposed | ForEach-Object { Write-Log "  $_" }
        $r = (Read-Host 'CyberQP local-admin policy: use the workstation OUs above? Enter = accept; edit = choose different OUs').Trim()
        if ($r -ieq 'edit') { $ouList = @() } else { $ouList = @($proposed) }
    }
    if ($ouList.Count -eq 0) {
        Write-Log 'Enter workstation-only OU DNs one per line (blank line to finish). Leave empty to create a new Workstations OU.'
        do {
            $ou = (Read-Host 'CyberQP local-admin policy: paste a workstation OU DN (blank = finish; none entered = offer new Workstations OU)').Trim()
            if ($ou) {
                try { $o = Get-ADOrganizationalUnit -Identity $ou -Server $Script:State.DC; $ouList += $o.DistinguishedName }
                catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] { Write-Log 'OU was not found. Try again.' 'Warn' } catch [ArgumentException] { Write-Log 'Invalid OU distinguished name. Try again.' 'Warn' }
            }
        } while ($ou)
    }
    if ($ouList.Count -eq 0) {
        $newDn = "OU=$($Script:Const.WorkstationsOU),$($Script:State.DomainDN)"
        $already = Get-ADSafe { Get-ADOrganizationalUnit -Identity $newDn -Server $Script:State.DC }
        if ($already) { Write-Log "$newDn already exists (created by an earlier session?) - using it." 'Ok'; $ouList = @($newDn) }
        elseif (Confirm-YesNo "No workstation OU selected. Create '$newDn' (protected from accidental deletion)?") {
            Save-Breadcrumb 'OU-tree-before-create' (Get-ADOrganizationalUnit -Server $Script:State.DC -Filter * | Select-Object Name,DistinguishedName) | Out-Null
            New-ADOrganizationalUnit -Server $Script:State.DC -Name $Script:Const.WorkstationsOU -Path $Script:State.DomainDN -ProtectedFromAccidentalDeletion $true -Description 'CBIT managed workstations'
            Add-Journal -Action 'CreateOU' -Target $newDn -After @{ DN = $newDn }
            $ouList = @($newDn)
        } else { Stop-Run 'No workstation OU scope. Cannot continue.' }
    }
    # Server safety check
    foreach ($ou in $ouList) {
        $srv = Test-OuHoldsServers $ou
        if ($srv.Count) {
            Write-Log "WARNING: $ou subtree contains server/DC objects: $(($srv | ForEach-Object { $_.Name }) -join ', ')" 'Warn'
            if (-not (Confirm-YesNo 'Linking the Endpoint Admin GPO here will grant CBIT local admin on those servers. Keep this OU in scope anyway?')) { Stop-Run "Scope rejected because $ou holds servers. Move servers out (manually) and re-run with -Resume." }
            Add-Exception "Scope OU $ou contains servers ($(($srv | ForEach-Object { $_.Name }) -join ', ')) - accepted by technician."
        }
    }
    $Script:State.WorkstationsOUs = @($ouList)
    Write-Log "Scope: $($ouList -join ' | ')" 'Ok'
    Save-State
    if ($ouList.Count -eq 1) { Invoke-ClientMove -TargetOU $ouList[0] }
    elseif ($Script:Disc.ClientsInContainer) { Add-FollowUp "$($Script:Disc.ClientsInContainer) client(s) in CN=Computers not moved (multiple scope OUs - ambiguous target). Move manually." }

    # Users / groups destination (proposed from OU names; Enter accepts)
    $prop = Get-ProposedContainerPaths
    $Script:State.UsersPath = Read-DirectoryContainer -Prompt 'CyberQP NEW user accounts: destination OU/container DN (not a username or password)' -Default $prop.Users
    $Script:State.GroupsPath = Read-DirectoryContainer -Prompt 'CyberQP NEW access group: destination OU/container DN' -Default $prop.Groups
    Write-Log "Users -> $($Script:State.UsersPath)   Groups -> $($Script:State.GroupsPath)" 'Ok'
    Save-State

    # redircmp offer
    $cur = (Get-ADDomain -Server $Script:State.DC).ComputersContainer
    $hasRedircmp = [bool](Get-Command redircmp.exe -ErrorAction SilentlyContinue)
    if ($ouList.Count -eq 1 -and $cur -like 'CN=Computers,*' -and -not $hasRedircmp) { Write-Log 'redircmp.exe not found on this host (not a DC / AD DS tools missing) - redircmp offer skipped.' 'Warn' }
    if ($ouList.Count -eq 1 -and $cur -like 'CN=Computers,*' -and $hasRedircmp) {
        Write-Log ''
        Write-Log "Default computer container is $cur." 'Warn'
        Write-Log "redircmp to $($ouList[0]) makes every future domain join land in the workstation OU."
        Write-Log "RISK: a server joined without an explicit OU target will also land there and inherit the Endpoint Admin GPO (CBIT gets local admin on it). This gets recorded for IT Glue." 'Warn'
        if (Confirm-YesNo "Future domain joins: make $($ouList[0]) the default computer destination? This also affects servers joined without an explicit OU") {
            Save-Breadcrumb 'redircmp-before' @{ ComputersContainer = $cur } | Out-Null
            $out = & redircmp.exe $ouList[0] 2>&1
            Write-Log ($out -join ' ')
            if ($LASTEXITCODE -ne 0) { throw "redircmp failed (exit $LASTEXITCODE): $out" }
            $now = (Get-ADDomain -Server $Script:State.DC).ComputersContainer
            Add-Journal -Action 'SetRedircmp' -Target $ouList[0] -Before @{ ComputersContainer = $cur } -After @{ ComputersContainer = $now }
            $Script:State.ComputersContainer = $now
            Add-FollowUp "ITG: redircmp set to $($ouList[0]). Servers must be joined with an explicit OU (or moved immediately) or they inherit the Endpoint Admin GPO."
        } else { Write-Log 'redircmp skipped.' 'Skip' }
    } elseif ($cur -notlike 'CN=Computers,*') { Write-Log "Default computer container already redirected: $cur" }
    Save-State
}

# ===========================================================================
# Legacy account dependency scan (read-only)
# ===========================================================================
function Find-AccountDependencies {
    param($User)
    $nb   = (Get-ADDomain -Server $Script:State.DC).NetBIOSName
    $sam  = $User.SamAccountName
    $pat  = '^(?:' + [regex]::Escape($nb) + '\\|\.\\)?' + [regex]::Escape($sam) + '$|^' + [regex]::Escape("$sam@") 
    $res  = [ordered]@{ NetBIOS = $nb; Hits = @(); Unreachable = @(); Scanned = @() }

    $u = Get-ADUser -Identity $User.ObjectGUID -Server $Script:State.DC -Properties LastLogonDate, pwdLastSet, PasswordLastSet
    Write-Log "  LastLogonDate (replicated, +/-14d): $($u.LastLogonDate)   PasswordLastSet: $($u.PasswordLastSet)"

    $servers = @(Get-ADComputer -Server $Script:State.DC -Filter "Enabled -eq 'True' -and OperatingSystem -like '*Server*'" -Properties DNSHostName |
                 ForEach-Object { if ($_.DNSHostName) { $_.DNSHostName } else { $_.Name } })
    Write-Log "  Scanning services and scheduled tasks on $($servers.Count) enabled server(s) via CIM/WinRM..."
    foreach ($h in $servers) {
        $cs = $null
        try {
            $opt = New-CimSessionOption -Protocol Wsman
            $cs  = New-CimSession -ComputerName $h -SessionOption $opt -OperationTimeoutSec 20 -ErrorAction Stop
        } catch {
            try { $cs = New-CimSession -ComputerName $h -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 20 -ErrorAction Stop }
            catch { $res.Unreachable += $h; continue }
        }
        try {
            Get-CimInstance -CimSession $cs -ClassName Win32_Service -ErrorAction Stop |
                Where-Object { $_.StartName -and $_.StartName -match $pat } |
                ForEach-Object { $res.Hits += [pscustomobject]@{ Host = $h; Type = 'Service'; Item = $_.Name; RunAs = $_.StartName; State = $_.State } }
            try {
                Get-ScheduledTask -CimSession $cs -ErrorAction Stop |
                    Where-Object { $_.Principal.UserId -and $_.Principal.UserId -match $pat } |
                    ForEach-Object { $res.Hits += [pscustomobject]@{ Host = $h; Type = 'SchedTask'; Item = "$($_.TaskPath)$($_.TaskName)"; RunAs = $_.Principal.UserId; State = "$($_.State)" } }
            } catch { $res.Hits += [pscustomobject]@{ Host = $h; Type = 'SchedTask'; Item = '(query failed - check manually)'; RunAs = ''; State = $_.Exception.Message } }
            $res.Scanned += $h
        } catch { $res.Unreachable += $h }
        finally { if ($cs) { Remove-CimSession $cs } }
    }
    Save-Breadcrumb "legacy-$sam-dependency-scan" $res | Out-Null
    $res
}

# ===========================================================================
# PHASE 4 - Legacy CBIT collision
# ===========================================================================
function Invoke-LegacyCBIT {
    $sam  = Get-UserBySam $Script:Const.ElevationSam
    $byName = @(Get-ADUser -Server $Script:State.DC -Filter "Name -eq '$($Script:Const.ElevationName)'" -Properties SamAccountName)
    if (-not $sam -and $byName.Count -eq 0) { Write-Log "No account with sAM '$($Script:Const.ElevationSam)' or Name '$($Script:Const.ElevationName)'. No collision." 'Ok'; $Script:State.Legacy = @{ Collision = $false }; Save-State; return }
    if ($byName.Count -gt 0 -and (-not $sam -or $byName[0].ObjectGUID -ne $sam.ObjectGUID)) {
        Stop-Run "An object named '$($Script:Const.ElevationName)' exists (sAM=$($byName[0].SamAccountName)) but is not sAM '$($Script:Const.ElevationSam)'. Resolve manually, then -Resume."
    }
    # sAM CBIT exists
    $std = ($sam.Name -eq $Script:Const.ElevationName)
    $info = $Script:Disc.Users | Where-Object { $_.Sam -ieq $Script:Const.ElevationSam } | Select-Object -First 1
    Write-Log "sAM '$($Script:Const.ElevationSam)' exists: Name='$($sam.Name)' Enabled=$($sam.Enabled) Created=$($sam.whenCreated.ToString('yyyy-MM-dd')) Desc='$($sam.Description)'"
    if ($info) { Write-Log "  Groups: $($info.Groups -join ', ')   Privileged: $(if ($info.Privileged.Count) { $info.Privileged -join ', ' } else { 'none' })   SPNs: $(if ($info.SPNs.Count) { $info.SPNs -join '; ' } else { 'none' })" }
    if ($std) {
        Write-Log "Name matches '$($Script:Const.ElevationName)' - treated as the existing standard elevation account. Phase Elevation will verify/reuse it." 'Ok'
        $Script:State.Legacy = @{ Collision = $false; ExistingStandard = $true; Guid = $sam.ObjectGUID.ToString() }; Save-State; return
    }
    if ($DryRun) { Write-Log "[DRYRUN] Would offer rename of '$($sam.Name)' (sAM CBIT) -> $($Script:Const.LegacyRename)." 'Warn'; return }
    $risky = [bool]($info -and ($info.SPNs.Count -or $info.Privileged.Count))
    if ($risky) {
        Write-Log ''
        Write-Log "Legacy '$($sam.Name)' is privileged ($(@($info.Privileged) -join ', '))$(if ($info.SPNs.Count) { " and has SPNs ($($info.SPNs -join '; '))" })." 'Warn'
        Write-Log "Renaming keeps memberships, SPNs, password and enabled state; anything that logs on by the '$($Script:Const.ElevationSam)' name will fail after the rename." 'Warn'
        Write-Log ''
        Write-Log 'Dependency scan (read-only):'
        $dep = Find-AccountDependencies $sam
        if ($dep.Hits.Count) {
            Write-Log "  FOUND $($dep.Hits.Count) item(s) running as $($dep.NetBIOS)\$($Script:Const.ElevationSam):" 'Warn'
            $dep.Hits | ForEach-Object { Write-Log ("    {0,-9} {1}  {2}  (RunAs {3}, {4})" -f $_.Type, $_.Host, $_.Item, $_.RunAs, $_.State) 'Warn' }
        } else { Write-Log "  No services or scheduled tasks found on $($dep.Scanned.Count) scanned server(s)." 'Ok' }
        if ($dep.Unreachable.Count) { Write-Log "  NOT SCANNED (unreachable): $($dep.Unreachable -join ', ')" 'Warn' }
        Write-Log '  Not checked: workstations, stored credentials (Credential Manager, mapped drives, app configs), RMM/backup agents, line-of-business apps.' 'Warn'
        Write-Log ''
        $q = if ($dep.Hits.Count -or $dep.Unreachable.Count) { "Dependencies found or hosts unscanned (above). Proceed to the rename offer anyway?" } else { "Proceed to the rename offer?" }
        if (-not (Confirm-YesNo $q)) {
            Stop-Run "Legacy '$($Script:Const.ElevationSam)' is privileged; technician declined remediation after dependency scan. Resolve manually, then -Resume."
        }
        if ($dep.Hits.Count) { Add-FollowUp "Rename of legacy $($Script:Const.ElevationSam) proceeded with $($dep.Hits.Count) known dependency(ies): $(($dep.Hits | ForEach-Object { "$($_.Host)/$($_.Item)" }) -join '; '). Re-point to new credentials." }
        if ($dep.Unreachable.Count) { Add-FollowUp "Legacy $($Script:Const.ElevationSam) dependency scan could not reach: $($dep.Unreachable -join ', '). Check manually." }
        Add-Exception "Legacy '$($Script:Const.ElevationSam)' was privileged ($(@($info.Privileged) -join ', '))$(if ($info.SPNs.Count) { ' with SPNs' }); rename approved after dependency scan ($($dep.Hits.Count) hit(s), $($dep.Unreachable.Count) unscanned)."
    }
    Write-Log ''
    Write-Log "This is a legacy account holding the sAM the standard needs. Option: rename it to '$($Script:Const.LegacyRename)' (Name, sAM, UPN, DisplayName). Group memberships, password and enabled state are untouched." 'Warn'
    Write-Log "AD Recycle Bin: $($Script:Disc.RecycleBin). Rename is fully reversible via -Rollback regardless."
    if (Get-UserBySam $Script:Const.LegacyRename) { Stop-Run "'$($Script:Const.LegacyRename)' already exists - cannot rename. Resolve manually, then -Resume." }
    if (-not (Confirm-YesNo "Rename '$($sam.Name)' (sAM $($Script:Const.ElevationSam)) to '$($Script:Const.LegacyRename)'?")) {
        Stop-Run 'Legacy CBIT left in place; the standard elevation account cannot be created. Resolve manually, then -Resume.'
    }
    $bc = Save-Breadcrumb "user-$($sam.SamAccountName)-before-rename" $sam
    $before = @{ Name = $sam.Name; Sam = $sam.SamAccountName; UPN = "$($sam.UserPrincipalName)"; DisplayName = "$($sam.DisplayName)"; DN = $sam.DistinguishedName; ObjectGUID = $sam.ObjectGUID.ToString() }
    Set-ADUser -Identity $sam.ObjectGUID -Server $Script:State.DC -SamAccountName $Script:Const.LegacyRename -UserPrincipalName "$($Script:Const.LegacyRename)@$($Script:State.DomainDNS)" -DisplayName $Script:Const.LegacyRename -Description "Legacy CBIT account renamed $(Get-Date -Format yyyy-MM-dd) by CBIT priv-access deployment (was $($sam.SamAccountName))"
    Rename-ADObject -Identity $sam.ObjectGUID -Server $Script:State.DC -NewName $Script:Const.LegacyRename
    $after = Get-ADUser -Identity $sam.ObjectGUID -Server $Script:State.DC -Properties DisplayName
    Add-Journal -Action 'RenameUser' -Target $before.DN -Before $before -After @{ Name = $after.Name; Sam = $after.SamAccountName; UPN = $after.UserPrincipalName; DisplayName = $after.DisplayName; DN = $after.DistinguishedName; ObjectGUID = $sam.ObjectGUID.ToString() } -Breadcrumb $bc
    $Script:State.Legacy = @{ Collision = $true; RenamedTo = $Script:Const.LegacyRename; Guid = $sam.ObjectGUID.ToString(); Enabled = [bool]$sam.Enabled }
    Add-FollowUp "Legacy account renamed to $($Script:Const.LegacyRename) (still Enabled=$($sam.Enabled), memberships untouched$(if ($risky) { ', STILL PRIVILEGED' })). Audit and retire once the domain path is proven."
    Save-State
    Write-Log "Renamed. New DN: $($after.DistinguishedName)" 'Ok'
}

# ===========================================================================
# Shared: create-or-verify a standard account
# ===========================================================================
function Invoke-StandardAccount {
    param([string]$Sam, [string]$Name, [string]$Description, [switch]$CannotChangePassword, [string]$PasswordLabel, [scriptblock]$PostEnable)
    $u = Get-UserBySam $Sam
    if ($u -and $u.Enabled) {
        Write-Log "$Sam exists and is enabled (Name='$($u.Name)', PwdNeverExpires=$($u.PasswordNeverExpires), Created=$($u.whenCreated.ToString('yyyy-MM-dd'))). Reusing." 'Ok'
        if ($u.Name -ne $Name) { Stop-Run "$Sam exists but Name is '$($u.Name)', expected '$Name'. Decide manually, then -Resume." }
        return $u
    }
    if ($u -and -not $u.Enabled) {
        if (-not (Test-CreatedThisRun $u.ObjectGUID.ToString())) { Stop-Run "$Sam exists but is DISABLED and was not created by this run. Decide manually, then -Resume." }
        Write-Log "$Sam was created by this run but never enabled (password step did not complete). Resuming at the password step." 'Warn'
    }
    if ($DryRun) { Write-Log "[DRYRUN] Would create $Name (sAM $Sam) in $($Script:State.UsersPath), set password, enable." 'Warn'; return $null }
    if (-not $u) {
        Get-ADObject -Identity $Script:State.UsersPath -Server $Script:State.DC | Out-Null
        $u = New-ADUser -Server $Script:State.DC -Name $Name -DisplayName $Name -SamAccountName $Sam -UserPrincipalName "$Sam@$($Script:State.DomainDNS)" `
                -Path $Script:State.UsersPath -Enabled $false -PasswordNeverExpires $true -CannotChangePassword ([bool]$CannotChangePassword) -Description $Description -PassThru
        Add-Journal -Action 'CreateUser' -Target $u.DistinguishedName -After @{ ObjectGUID = $u.ObjectGUID.ToString(); Sam = $Sam; DN = $u.DistinguishedName }
        Write-Log "Created $Name (disabled)." 'Ok'
    }
    # Password + enable (loop until AD accepts)
    while ($true) {
        $pw = Read-PasswordTwice $PasswordLabel
        try {
            Set-ADAccountPassword -Identity $u.ObjectGUID -Server $Script:State.DC -Reset -NewPassword $pw
            break
        } catch { Write-Log "Password rejected: $($_.Exception.Message)" 'Warn' }
        finally { $pw = $null }
    }
    Enable-ADAccount -Identity $u.ObjectGUID -Server $Script:State.DC
    Add-Journal -Action 'EnableUser' -Target $u.DistinguishedName -Before @{ Enabled = $false } -After @{ Enabled = $true; ObjectGUID = $u.ObjectGUID.ToString() }
    if ($PostEnable) { & $PostEnable $u }
    return (Get-UserBySam $Sam)
}

# ===========================================================================
# PHASE 5 - CBIT-DA
# ===========================================================================
function Invoke-RecoveryAccount {
    $daSid = "$($Script:State.DomainSid)-512"
    $u = Invoke-StandardAccount -Sam $Script:Const.RecoveryAccount -Name $Script:Const.RecoveryAccount -Description 'CBIT domain recovery account' `
            -PasswordLabel "$($Script:State.NetBIOS)\CBIT-DA password ($($Script:Const.ItgRecovery))" -PostEnable {
                param($acct)
                $sid = "$($Script:State.DomainSid)-512"
                Add-ADGroupMember -Server $Script:State.DC -Identity $sid -Members $acct.ObjectGUID
                Add-Journal -Action 'AddGroupMember' -Target $sid -After @{ Group = 'Domain Admins'; GroupSid = $sid; Member = $acct.DistinguishedName; MemberGuid = $acct.ObjectGUID.ToString() }
            }
    if ($DryRun) { return }
    $isDA = [bool](Get-RecursiveGroups $u.DistinguishedName | Where-Object { $_.SID.Value -eq $daSid })
    if (-not $isDA) {
        Write-Log "$($Script:Const.RecoveryAccount) is not a Domain Admin." 'Warn'
        if (Confirm-YesNo "Add $($Script:Const.RecoveryAccount) to Domain Admins now?") {
            Add-ADGroupMember -Server $Script:State.DC -Identity $daSid -Members $u.ObjectGUID
            Add-Journal -Action 'AddGroupMember' -Target $daSid -After @{ Group = 'Domain Admins'; GroupSid = $daSid; Member = $u.DistinguishedName; MemberGuid = $u.ObjectGUID.ToString() }
        } else { Stop-Run 'CBIT-DA recovery path incomplete (not DA). Guardrail 3.2.' }
    }
    $groups = @(Get-ADPrincipalGroupMembership $u.ObjectGUID -Server $Script:State.DC | ForEach-Object { $_.Name })
    Write-Log "$($Script:Const.RecoveryAccount): Enabled=$($u.Enabled) PwdNeverExpires=$($u.PasswordNeverExpires) Groups: $($groups -join ', ')" 'Ok'
    $extra = @($groups | Where-Object { $_ -notin 'Domain Users','Domain Admins' })
    if ($extra.Count) { Add-Exception "$($Script:Const.RecoveryAccount) has additional memberships not cleaned up: $($extra -join ', ')" }
    if (-not $Script:State.RecoveryLoginVerified) {
        while ($true) {
            Write-Log "Validating $($Script:State.NetBIOS)\CBIT-DA via WinRM to $($Script:State.DC) (network logon; does not test interactive/RDP logon rights)."
            $t = Test-RecoveryCredential
            if ($t.Ok) {
                Write-Log "CBIT-DA validated: $($t.Detail)" 'Ok'
                $Script:State.RecoveryLoginMethod = 'WinRM'; break
            }
            Write-Log "CBIT-DA validation failed: $($t.Detail)" 'Warn'
            $r = Invoke-Gate -Message "Type 'retry' to test again, or 'manual' to verify with a separate interactive DC logon instead." -Keyword 'retry' -AlsoAccept @('manual')
            if ($r -ieq 'manual') {
                Invoke-Gate -Message "In a SEPARATE session (keep this one open), log on to a DC as $($Script:State.NetBIOS)\CBIT-DA using the IT Glue entry '$($Script:Const.ItgRecovery)' and confirm administrative access. Do not use this password on a workstation." -Keyword 'done' | Out-Null
                $Script:State.RecoveryLoginMethod = 'interactive'; break
            }
        }
        $Script:State.RecoveryLoginVerified = (Get-Date).ToString('s'); Save-State
    }
}

# ===========================================================================
# PHASE 6 - RID-500
# ===========================================================================
function Invoke-RID500 {
    $rid = $Script:Disc.RID500
    $acct = Get-ADUser -Identity "$($Script:State.DomainSid)-500" -Server $Script:State.DC -Properties Enabled,LastLogonDate,PasswordLastSet
    Write-Log "Built-in Administrator: $($acct.SamAccountName) Enabled=$($acct.Enabled) LastLogon=$($acct.LastLogonDate) PwdLastSet=$($acct.PasswordLastSet)"
    if (-not $acct.Enabled) { Write-Log 'Already disabled. Nothing to do.' 'Ok'; $Script:State.RID500Disabled = 'pre-existing'; Save-State; return }
    if ($rid.AutomationHints.Count) { Write-Log 'Automation suspicion:' 'Warn'; $rid.AutomationHints | ForEach-Object { Write-Log "  - $_" 'Warn' } }
    else { Write-Log 'No automation hints from timestamps (does not prove nothing uses it).' }
    if ($DryRun) { Write-Log "[DRYRUN] Would offer DISABLE of $($acct.SamAccountName)." 'Warn'; return }
    if ($env:USERNAME -ieq $acct.SamAccountName) { Add-Exception 'Session is running as the built-in Administrator - not disabled. Re-run this phase from a CBIT-DA/JIT session (-Resume).'; $Script:State.RID500Disabled = $false; Save-State; return }
    Write-Log 'Ask the responsible operator about backups, scheduled tasks, services, tools or CyberQP rotation using this account. Record the answer in the ticket.'
    $r = Invoke-Gate -Message "Disable $($acct.SamAccountName)? Type DISABLE (case-sensitive) only with explicit operator approval; Enter leaves it unchanged." -Keyword 'DISABLE' -CaseSensitive -AllowEmpty
    if ($r -ceq 'DISABLE') {
        $bc = Save-Breadcrumb "rid500-$($acct.SamAccountName)-before-disable" $acct
        Disable-ADAccount -Identity $acct.ObjectGUID -Server $Script:State.DC
        Add-Journal -Action 'DisableUser' -Target $acct.DistinguishedName -Before @{ Enabled = $true } -After @{ Enabled = $false; ObjectGUID = $acct.ObjectGUID.ToString(); Sam = $acct.SamAccountName } -Breadcrumb $bc
        $Script:State.RID500Disabled = $true
        Write-Log "$($acct.SamAccountName) disabled. Remains in Builtin\Administrators by design." 'Ok'
        if ($rid.AutomationHints.Count) { Add-FollowUp "RID-500 disabled with automation hints present ($($rid.AutomationHints -join '; ')). First suspect if anything breaks." }
    } else {
        $Script:State.RID500Disabled = $false
        Add-Exception 'RID-500 left ENABLED (no operator approval or dependencies unclear).'
    }
    Save-State
}

# ===========================================================================
# PHASE 7 - CBIT-Elevation
# ===========================================================================
function Invoke-Elevation {
    $u = Invoke-StandardAccount -Sam $Script:Const.ElevationSam -Name $Script:Const.ElevationName -Description 'CBIT workstation elevation account' -CannotChangePassword `
            -PasswordLabel "$($Script:State.NetBIOS)\CBIT elevation password ($($Script:Const.ItgElevation))"
    if ($DryRun) { return }
    $groups = @(Get-ADPrincipalGroupMembership $u.ObjectGUID -Server $Script:State.DC)
    $priv = @($groups | Where-Object { Test-PrivilegedGroup $_ } | ForEach-Object { $_.Name })
    Write-Log "$($Script:Const.ElevationName): sAM=$($u.SamAccountName) Enabled=$($u.Enabled) PwdNeverExpires=$($u.PasswordNeverExpires) CannotChangePwd=$($u.CannotChangePassword) Groups: $(($groups | ForEach-Object { $_.Name }) -join ', ')" 'Ok'
    if ($priv.Count) { Stop-Run "$($Script:Const.ElevationSam) holds privileged membership: $($priv -join ', '). Not allowed for the elevation account. Resolve manually, then -Resume." }
    if (-not $u.PasswordNeverExpires -or -not $u.CannotChangePassword) {
        if (Confirm-YesNo 'CyberQP workstation account CBIT-Elevation (login CBIT): keep its password from expiring and prevent user password changes?') {
            Save-Breadcrumb "user-$($u.SamAccountName)-before-flags" $u | Out-Null
            Set-ADUser -Identity $u.ObjectGUID -Server $Script:State.DC -PasswordNeverExpires $true -CannotChangePassword $true
            Add-Journal -Action 'SetUserFlags' -Target $u.DistinguishedName -Before @{ PasswordNeverExpires = [bool]$u.PasswordNeverExpires; CannotChangePassword = [bool]$u.CannotChangePassword } -After @{ PasswordNeverExpires = $true; CannotChangePassword = $true; ObjectGUID = $u.ObjectGUID.ToString() }
        } else { Add-Exception "$($Script:Const.ElevationSam) flags not standard (PwdNeverExpires=$($u.PasswordNeverExpires), CannotChangePwd=$($u.CannotChangePassword))." }
    }
}

# ===========================================================================
# PHASE 8 - CBIT-Endpoint-Admins
# ===========================================================================
function Invoke-EndpointGroup {
    $g = Get-ADGroup -Server $Script:State.DC -Filter "SamAccountName -eq '$($Script:Const.GroupName)'" -Properties Members,MemberOf,Description
    $elev = Get-UserBySam $Script:Const.ElevationSam
    if ($DryRun) {
        Write-Log "[DRYRUN] Group: $(if ($g) { "exists, members=$(@($g.Members).Count)" } else { "would create in $($Script:State.GroupsPath)" }); would add $($Script:Const.ElevationSam) if missing." 'Warn'; return
    }
    if (-not $g) {
        Get-ADObject -Identity $Script:State.GroupsPath -Server $Script:State.DC | Out-Null
        $g = New-ADGroup -Server $Script:State.DC -Name $Script:Const.GroupName -SamAccountName $Script:Const.GroupName -GroupScope Global -GroupCategory Security -Path $Script:State.GroupsPath -Description 'CBIT workstation local administrator access via GPO' -PassThru
        Add-Journal -Action 'CreateGroup' -Target $g.DistinguishedName -After @{ ObjectGUID = $g.ObjectGUID.ToString(); DN = $g.DistinguishedName }
        $g = Get-ADGroup -Identity $g.ObjectGUID -Server $Script:State.DC -Properties Members,MemberOf
        Write-Log "Created $($Script:Const.GroupName) in $($Script:State.GroupsPath)." 'Ok'
    } else {
        Write-Log "$($Script:Const.GroupName) exists: $($g.GroupScope)/$($g.GroupCategory) DN=$($g.DistinguishedName)"
        if ($g.GroupScope -ne 'Global' -or $g.GroupCategory -ne 'Security') { Stop-Run "Existing group is $($g.GroupScope)/$($g.GroupCategory), not Global/Security. Decide manually, then -Resume." }
        if (@($g.MemberOf).Count) { Stop-Run "Existing group is nested in: $($g.MemberOf -join '; '). Not allowed. Decide manually, then -Resume." }
        $members = @($g.Members)
        Write-Log "  Members ($($members.Count)): $(if ($members.Count) { $members -join '; ' } else { 'none' })"
        $others = @($members | Where-Object { $_ -ne $elev.DistinguishedName })
        if ($others.Count -and -not (Confirm-YesNo 'CBIT-Endpoint-Admins has additional members; they will also receive workstation local-admin access. Keep those members and reuse the group?')) { Stop-Run 'Endpoint group membership needs a decision. Resolve manually, then -Resume.' }
        if ($others.Count) { Add-Exception "$($Script:Const.GroupName) has extra members left in place: $($others -join '; ')" }
    }
    if (@($g.Members) -contains $elev.DistinguishedName) { Write-Log "$($Script:Const.ElevationSam) already a member." 'Ok' }
    else {
        Save-Breadcrumb "group-$($Script:Const.GroupName)-before-add" $g | Out-Null
        Add-ADGroupMember -Server $Script:State.DC -Identity $g.ObjectGUID -Members $elev.ObjectGUID
        Add-Journal -Action 'AddGroupMember' -Target $g.DistinguishedName -After @{ Group = $Script:Const.GroupName; GroupGuid = $g.ObjectGUID.ToString(); Member = $elev.DistinguishedName; MemberGuid = $elev.ObjectGUID.ToString() }
        Write-Log "Added $($Script:Const.ElevationSam) to $($Script:Const.GroupName)." 'Ok'
    }
    $final = @(Get-ADGroupMember -Identity $g.ObjectGUID -Server $Script:State.DC | ForEach-Object { $_.SamAccountName })
    Write-Log "Final members: $($final -join ', ')" 'Ok'
    $Script:State.GroupGuid = $g.ObjectGUID.ToString(); Save-State
}

# ===========================================================================
# PHASE 9 - GPO
# ===========================================================================
function Show-GppInstructions { param($Gpo)
    $lines = @(
        "Open Group Policy Management. Right-click the domain -> Change Domain Controller -> $($Script:State.DC)."
        "Edit '$($Gpo.DisplayName)' (Id $($Gpo.Id)):"
        '  Computer Configuration -> Preferences -> Control Panel Settings -> Local Users and Groups'
        '  New -> Local Group'
        '    Action:                       Update'
        "    Group name:                   Administrators (built-in)   [$($Script:Const.AdminSid)]"
        '    Delete all member users:      UNCHECKED'
        '    Delete all member groups:     UNCHECKED'
        "    Members -> Add:               $($Script:State.NetBIOS)\$($Script:Const.GroupName)     action ADD"
        '    Common tab:                   defaults'
        '  The two delete-all checkboxes are hidden while the Member dialog is open - re-check both are clear before OK.'
        '  Never use Replace, delete-all, or passwords in GPP.'
        ''
        '  SECOND ITEM - delete the legacy LOCAL CBIT account on each workstation:'
        '  Local Users and Groups -> New -> Local User'
        '    Action:                       Delete'
        "    User name:                    $($Script:Const.ElevationSam)     (type it; Local User items only touch local accounts)"
        '    Common tab:                   defaults'
        '  Do NOT add CBIT to the Administrators item as a REMOVE member - extra members fail verification.'
        '  Deletion is permanent: unlinking/rollback does not recreate the account.'
        ''
        "Copy this member name exactly:   $($Script:State.NetBIOS)\$($Script:Const.GroupName)"
    )
    $lines | ForEach-Object { Write-Log $_ 'Gate' }
}
function Invoke-GPO {
    $DomainDNS = $Script:State.DomainDNS; $DC = $Script:State.DC
    $gpoMatches = @(Get-GPO -All -Domain $DomainDNS -Server $DC | Where-Object { $_.DisplayName -eq $Script:Const.GpoName })
    if ($gpoMatches.Count -gt 1) { Stop-Run "$($gpoMatches.Count) GPOs named '$($Script:Const.GpoName)'. Decide manually, then -Resume." }
    if ($DryRun) {
        if ($gpoMatches.Count) { $t = Test-EndpointGpoSettings $gpoMatches[0]; Write-Log "[DRYRUN] GPO exists Id=$($gpoMatches[0].Id). Settings valid=$($t.Valid). $(($t.Problems) -join ' | ')" 'Warn' }
        else { Write-Log "[DRYRUN] Would create GPO '$($Script:Const.GpoName)' then pause for the GPMC edit." 'Warn' }
        return
    }
    $gpo = $null
    if ($gpoMatches.Count -eq 0) {
        $gpo = New-GPO -Name $Script:Const.GpoName -Domain $DomainDNS -Server $DC -Comment "CBIT Privileged Access standard - created $(Get-Date -Format yyyy-MM-dd)"
        Add-Journal -Action 'CreateGPO' -Target $Script:Const.GpoName -After @{ Id = $gpo.Id.ToString(); Name = $gpo.DisplayName }
        Write-Log "Created GPO Id=$($gpo.Id)." 'Ok'
    } else {
        $gpo = $gpoMatches[0]
        Write-Log "GPO exists Id=$($gpo.Id) CompVer=$($gpo.Computer.DSVersion) Modified=$($gpo.ModificationTime) Status=$($gpo.GpoStatus)"
        $bdir = Join-Path $Script:RunPath 'breadcrumbs\gpo-backup'
        New-Item $bdir -ItemType Directory -Force | Out-Null
        $already = Get-Journal | Where-Object { $_.Action -eq 'BackupGPO' -and $_.Target -eq $gpo.Id.ToString() }
        if (-not $already) {
            $b = Backup-GPO -Guid $gpo.Id -Domain $DomainDNS -Server $DC -Path $bdir
            Add-Journal -Action 'BackupGPO' -Target $gpo.Id.ToString() -After @{ BackupId = $b.Id.ToString(); Path = $bdir; Name = $gpo.DisplayName } -Breadcrumb $bdir
            Write-Log "Existing GPO backed up to $bdir (BackupId $($b.Id))." 'Ok'
        }
        # Links outside scope?
        [xml]$rep = Get-GPOReport -Guid $gpo.Id -Domain $DomainDNS -Server $DC -ReportType Xml
        $scopeCanon = @($Script:State.WorkstationsOUs | ForEach-Object { Get-OuCanonical $_ })
        $links = @($rep.GPO.LinksTo | ForEach-Object { $_.SOMPath })
        $foreign = @($links | Where-Object { $l = $_; -not ($scopeCanon | Where-Object { $_ -ieq $l }) })
        if ($foreign.Count) { Stop-Run "Existing GPO is linked outside the workstation scope: $($foreign -join ' | '). Decide manually, then -Resume." }
        $ext = @($rep.GPO.Computer.ExtensionData.Extension | ForEach-Object { $_.type }) + @($rep.GPO.User.ExtensionData.Extension | ForEach-Object { $_.type })
        $unrelated = @($ext | Where-Object { $_ -and $_ -notmatch 'LocalUsersAndGroups' })
        if ($unrelated.Count) { Write-Log "Existing GPO carries other extensions: $($unrelated -join ', ')" 'Warn'; if (-not (Confirm-YesNo 'Continue and reuse this GPO anyway?')) { Stop-Run 'Existing GPO needs review.' } ; Add-Exception "GPO reused with unrelated extensions: $($unrelated -join ', ')" }
    }
    $Script:State.GpoId = $gpo.Id.ToString(); Save-State
    if ($gpo.GpoStatus -ne 'AllSettingsEnabled') {
        Write-Log "GPO status is $($gpo.GpoStatus)." 'Warn'
        if (Confirm-YesNo 'Set GPO status to AllSettingsEnabled?') {
            $before = "$($gpo.GpoStatus)"; $gpo.GpoStatus = 'AllSettingsEnabled'
            Add-Journal -Action 'SetGpoStatus' -Target $gpo.Id.ToString() -Before @{ Status = $before } -After @{ Status = 'AllSettingsEnabled' }
        }
    }
    # Verify / edit loop
    $test = Test-EndpointGpoSettings $gpo
    if ($test.Valid) { Write-Log 'GPP Local Group item already correct (Update / S-1-5-32-544 / ADD / delete-all off). No GPMC edit needed.' 'Ok' }
    while (-not $test.Valid) {
        Write-Log ''
        Write-Log 'GPP Local Group item is missing or incorrect:' 'Warn'
        $test.Problems | ForEach-Object { Write-Log "  - $_" 'Warn' }
        Show-GppInstructions $gpo
        Invoke-Gate -Message 'After saving the item in GPMC (and closing the editor), continue.' -Keyword 'done' | Out-Null
        Start-Sleep -Seconds 3
        $test = Test-EndpointGpoSettings $gpo
    }
    Write-Log "Groups.xml verified: $($test.Path)" 'Ok'
    Copy-Item $test.Path (Join-Path $Script:RunPath 'breadcrumbs\Groups.xml.verified') -Force
    Get-GPOReport -Guid $gpo.Id -Domain $DomainDNS -Server $DC -ReportType Xml -Path (Join-Path $Script:RunPath 'CBIT-MSP-Endpoint-Admin-PreLink.xml')
    Get-GPOReport -Guid $gpo.Id -Domain $DomainDNS -Server $DC -ReportType Html -Path (Join-Path $Script:RunPath 'CBIT-MSP-Endpoint-Admin-PreLink.html')
    Add-Journal -Action 'GppVerified' -Target $gpo.Id.ToString() -Note 'Manual GPMC edit verified against SYSVOL Groups.xml' -After @{ CompVer = (Get-GPO -Guid $gpo.Id -Domain $DomainDNS -Server $DC).Computer.DSVersion }
}

# ===========================================================================
# PHASE 10 - Link
# ===========================================================================
function Invoke-GPOLink {
    $DomainDNS = $Script:State.DomainDNS; $DC = $Script:State.DC
    $ous = @($Script:State.WorkstationsOUs)
    if ($DryRun -and -not $Script:State.GpoId) {
        Write-Log "[DRYRUN] Would link the new GPO (enabled, not enforced) to: $($ous -join ' | ')" 'Warn'; return
    }
    if (-not $Script:State.GpoId) { Stop-Run 'No GPO Id in state - phase GPO did not complete. Re-run with -Resume.' }
    $gpo = Get-GPO -Guid $Script:State.GpoId -Domain $DomainDNS -Server $DC
    $plan = @()
    foreach ($ou in $ous) {
        $l = (Get-GPInheritance -Target $ou -Domain $DomainDNS -Server $DC).GpoLinks | Where-Object { $_.GpoId -eq $gpo.Id }
        $plan += [pscustomobject]@{ OU = $ou; Existing = [bool]$l; Enabled = $(if ($l) { $l.Enabled } else { $null }); Enforced = $(if ($l) { $l.Enforced } else { $null }) }
    }
    Write-Log 'Link plan:'
    $plan | ForEach-Object { Write-Log "  $($_.OU)  ->  $(if ($_.Existing) { "already linked (Enabled=$($_.Enabled) Enforced=$($_.Enforced))" } else { 'NEW link, enabled, not enforced' })" }
    if ($DryRun) { return }
    $todo = @($plan | Where-Object { -not $_.Existing -or -not $_.Enabled -or $_.Enforced })
    if ($todo.Count -eq 0) { Write-Log 'All links already in place.' 'Ok' }
    else {
        Write-Log "Linking applies '$($gpo.DisplayName)' to every computer in those OUs and their sub-OUs - not just a test machine." 'Warn'
        if (-not (Confirm-YesNo "CyberQP local-admin policy: link/enable on the $($todo.Count) workstation OU(s) listed above, including their sub-OUs?")) { Stop-Run 'Link declined. Re-run with -Resume when ready.' }
        foreach ($p in $todo) {
            if ($p.Existing) {
                Set-GPLink -Guid $gpo.Id -Target $p.OU -LinkEnabled Yes -Enforced No -Domain $DomainDNS -Server $DC | Out-Null
                Add-Journal -Action 'SetGPLink' -Target $p.OU -Before @{ Enabled = $p.Enabled; Enforced = $p.Enforced; GpoId = $gpo.Id.ToString() } -After @{ Enabled = $true; Enforced = $false; GpoId = $gpo.Id.ToString() }
            } else {
                New-GPLink -Guid $gpo.Id -Target $p.OU -LinkEnabled Yes -Enforced No -Domain $DomainDNS -Server $DC | Out-Null
                Add-Journal -Action 'NewGPLink' -Target $p.OU -After @{ Enabled = $true; Enforced = $false; GpoId = $gpo.Id.ToString() }
            }
            Write-Log "Linked: $($p.OU)" 'Ok'
        }
    }
    # Verify
    Get-GPOReport -Guid $gpo.Id -Domain $DomainDNS -Server $DC -ReportType Xml -Path (Join-Path $Script:RunPath 'CBIT-MSP-Endpoint-Admin.xml')
    [xml]$rep = Get-Content (Join-Path $Script:RunPath 'CBIT-MSP-Endpoint-Admin.xml') -Raw
    $linksTo = @($rep.GPO.LinksTo)
    Write-Log "LinksTo after link: $($linksTo.Count) (expected $($ous.Count)): $(($linksTo | ForEach-Object { "$($_.SOMPath) Enabled=$($_.Enabled) Enforced=$($_.Enforced)" }) -join ' | ')"
    if ($linksTo.Count -ne $ous.Count) { Add-Exception "GPO LinksTo count $($linksTo.Count) != scope count $($ous.Count). Review." }
}

# ===========================================================================
# PHASE 11 - Workstation validation hand-off
# ===========================================================================
function Invoke-WorkstationTest {
    $nb = $Script:State.NetBIOS
    @(
        'On one workstation in scope, from an elevated prompt (ScreenConnect backstage is fine):'
        '    gpupdate /target:computer /force'
        "    Get-LocalGroup -SID '$($Script:Const.AdminSid)' | Get-LocalGroupMember"
        "Pass = '$nb\$($Script:Const.GroupName)' appears in local Administrators."
        "Note a LOCAL account named 'CBIT' is common on legacy endpoints; at UAC always use $nb\CBIT (bare CBIT resolves to the local account)."
        'Optional: trigger a UAC prompt from a standard-user session and elevate with the ITG elevation password.'
    ) | ForEach-Object { Write-Log $_ 'Gate' }
    if ($DryRun) { return }
    $r = Invoke-Gate -Message 'CyberQP workstation test: done = CBIT-Endpoint-Admins appears in local Administrators; pending = not tested; failed = tested but missing.' -Keyword 'done' -AlsoAccept @('pending','failed')
    $Script:State.ValidationStatus = switch ($r.ToLower()) { 'done' { 'passed' } 'pending' { 'pending' } 'failed' { 'failed' } }
    if ($r -ieq 'failed') { Add-Exception 'Workstation validation FAILED - investigate before closing the ticket.' }
    if ($r -ieq 'pending') { Add-FollowUp 'Workstation validation pending - assign an owner in the ticket.' }
    Save-State
}

# ===========================================================================
# PHASE 12 - Summary
# ===========================================================================
function Invoke-Summary {
    $s = $Script:State
    $j = Get-Journal
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("CBIT Privileged Access Deployment - $($s.DomainDNS) ($($s.NetBIOS)) - run $($s.RunId)")
    $out.Add("Completed $(Get-Date -Format 'yyyy-MM-dd HH:mm')  by $($s.RunAs) on $($s.Host)  DryRun=$($s.DryRun)")
    $out.Add('')
    $out.Add('CHECKLIST')
    $chk = @(
        [pscustomobject]@{ Item = "JIT server/DC administration attested";                              Ok = [bool]$s.JitAttested }
        [pscustomobject]@{ Item = "CBIT-DA present, enabled, Domain Admin, credential/admin access verified (WinRM or manual logon)";              Ok = ($s.Phases.RecoveryAccount.Status -eq 'done' -and [bool]$s.RecoveryLoginVerified) }
        [pscustomobject]@{ Item = "RID-500 disabled with approval";                                      Ok = ($s.RID500Disabled -eq $true -or $s.RID500Disabled -eq 'pre-existing') }
        [pscustomobject]@{ Item = "Workstation OU scope confirmed: $($s.WorkstationsOUs -join ' | ')";   Ok = (@($s.WorkstationsOUs).Count -gt 0) }
        [pscustomobject]@{ Item = "Legacy CBIT collision absent/resolved";                               Ok = ($s.Phases.LegacyCBIT.Status -eq 'done') }
        [pscustomobject]@{ Item = "CBIT-Elevation (login CBIT) + $($Script:Const.GroupName) correct";    Ok = ($s.Phases.EndpointGroup.Status -eq 'done') }
        [pscustomobject]@{ Item = "GPO GPP item verified from SYSVOL (Update/ADD/delete-all off)";       Ok = ($s.Phases.GPO.Status -eq 'done') }
        [pscustomobject]@{ Item = "GPO linked to every scope OU, enabled, not enforced";                 Ok = ($s.Phases.GPOLink.Status -eq 'done') }
        [pscustomobject]@{ Item = "Workstation validation: $($s.ValidationStatus)";                      Ok = ($s.ValidationStatus -eq 'passed') }
    )
    if ($s.DryRun) { $chk | ForEach-Object { $_.Ok = $false } }
    foreach ($c in $chk) { $out.Add("  [$(if ($c.Ok) {'x'} else {' '})] $($c.Item)") }
    $out.Add('')
    $out.Add('IT GLUE ENTRIES (verify)')
    $out.Add("  $($Script:Const.ItgRecovery)   username $($s.NetBIOS)\CBIT-DA   management-only, never matched to CyberQP rotation")
    $out.Add("  $($Script:Const.ItgElevation)   username $($s.NetBIOS)\CBIT")
    if ($s.ComputersContainer -notlike 'CN=Computers,*') { $out.Add("  Domain note: default computer container redirected to $($s.ComputersContainer) - servers must be joined with an explicit OU target.") }
    $out.Add('')
    $exc = Get-StringList $s.Exceptions; $fu = Get-StringList $s.FollowUps
    $out.Add("EXCEPTIONS ($($exc.Count))"); foreach ($e in $exc) { $out.Add("  - $e") }
    $out.Add("FOLLOW-UPS ($($fu.Count))");  foreach ($f in $fu)  { $out.Add("  - $f") }
    $out.Add('')
    $out.Add("DISCOVERY FINDINGS ($(@($Script:Disc.Findings).Count))"); foreach ($f in @($Script:Disc.Findings)) { $out.Add("  - $f") }
    $out.Add('')
    $out.Add("CHANGES JOURNALED ($($j.Count))")
    foreach ($e in $j) { $out.Add("  #$($e.Seq) $($e.Time) $($e.Action) $($e.Target)") }
    $out.Add('')
    $out.Add("Rollback: unified menu option 5, then rollback; confirm run $($s.RunId) before approving the plan")
    $out.Add("Run folder: $($Script:RunPath)")
    $file = Join-Path $Script:RunPath "Summary-$($s.RunId).txt"
    $out | Out-File $file -Encoding UTF8
    Write-Log ''
    $out | ForEach-Object { Write-Log $_ }
    Write-Log "Summary saved: $file" 'Ok'
    if (-not $DryRun) { $Script:State.Completed = $true }
    Save-State
}

# ===========================================================================
# DRY RUN plan (evaluates current state, no prompts, no changes)
# ===========================================================================
function Invoke-DryRunPlan {
    Write-Banner 'DRY RUN - PLANNED ACTIONS'
    Invoke-Phase 'Scope'           { Invoke-Scope }
    Invoke-Phase 'LegacyCBIT'      { Invoke-LegacyCBIT }
    Invoke-Phase 'RecoveryAccount' { Invoke-RecoveryAccount }
    Invoke-Phase 'RID500'          { Invoke-RID500 }
    Invoke-Phase 'Elevation'       { Invoke-Elevation }
    Invoke-Phase 'EndpointGroup'   { Invoke-EndpointGroup }
    Invoke-Phase 'GPO'             { Invoke-GPO }
    Invoke-Phase 'GPOLink'         { Invoke-GPOLink }
    Invoke-Phase 'WorkstationTest' { Invoke-WorkstationTest }
    Invoke-Phase 'Summary'         { Invoke-Summary }
    Write-Log 'Dry run complete. No changes were made; no journal was written.' 'Ok'
}

# ===========================================================================
# ROLLBACK
# ===========================================================================
function Invoke-Rollback { param([string]$Path)
    Restore-Run $Path
    $DC = $Script:State.DC; $DomainDNS = $Script:State.DomainDNS
    $entries = @(Get-Journal $Path | Sort-Object Seq -Descending)
    if ($entries.Count -eq 0) { Write-Log 'Journal is empty - nothing to roll back.' 'Ok'; Stop-Transcript | Out-Null; return }
    Write-Banner "ROLLBACK PLAN - run $($Script:State.RunId) ($($entries.Count) entries, newest first)"
    $plan = foreach ($e in $entries) {
        $desc = switch ($e.Action) {
            'NewGPLink'      { "Remove link of GPO $($e.After.GpoId) from $($e.Target)" }
            'SetGPLink'      { "Restore link on $($e.Target) to Enabled=$($e.Before.Enabled) Enforced=$($e.Before.Enforced)" }
            'GppVerified'    { "(no action - covered by GPO delete/restore)" }
            'SetGpoStatus'   { "Set GPO $($e.Target) status back to $($e.Before.Status)" }
            'BackupGPO'      { "RESTORE pre-existing GPO $($e.After.Name) from backup $($e.After.BackupId) (undoes the GPMC edit)  [gated]" }
            'CreateGPO'      { "DELETE GPO '$($e.After.Name)' $($e.After.Id)  [gated]" }
            'AddGroupMember' { "Remove $($e.After.Member) from $($e.After.Group)" }
            'CreateGroup'    { "DELETE group $($e.Target)  [gated]" }
            'SetUserFlags'   { "Restore flags on $($e.Target): PwdNeverExpires=$($e.Before.PasswordNeverExpires) CannotChangePwd=$($e.Before.CannotChangePassword)" }
            'EnableUser'     { "Disable $($e.Target)" }
            'CreateUser'     { "DELETE user $($e.Target)  [gated]" }
            'DisableUser'    { "Re-enable $($e.After.Sam) (RID-500)  [gated]" }
            'RenameUser'     { "Rename $($e.After.Sam) back to $($e.Before.Sam) / '$($e.Before.Name)'" }
            'SetRedircmp'    { "redircmp back to $($e.Before.ComputersContainer)" }
            'MoveObject'     { "Move $($e.Target) back to $($e.Before.Parent)" }
            'CreateOU'       { "DELETE OU $($e.Target) if empty  [gated]" }
            default          { "UNKNOWN action $($e.Action) - will be skipped" }
        }
        Write-Log "  #$($e.Seq) $desc"
        [pscustomobject]@{ Entry = $e; Desc = $desc }
    }
    Write-Log ''
    Write-Log 'Rollback does NOT restore passwords, and does not touch anything the script did not journal.' 'Warn'
    if (-not (Confirm-YesNo 'Execute this rollback plan (each deletion asks again)?')) { Write-Log 'Rollback cancelled.' 'Skip'; Stop-Transcript | Out-Null; return }
    $Script:State.CurrentPhase = 'Rollback'
    $rbLog = Join-Path $Path 'rollback.log'
    foreach ($p in $plan) {
        $e = $p.Entry
        try {
            $done = $false
            switch ($e.Action) {
                'NewGPLink'    { if ((Get-GPInheritance -Target $e.Target -Domain $DomainDNS -Server $DC).GpoLinks | Where-Object { $_.GpoId -eq $e.After.GpoId }) { Remove-GPLink -Guid $e.After.GpoId -Target $e.Target -Domain $DomainDNS -Server $DC | Out-Null }; $done = $true }
                'SetGPLink'    { Set-GPLink -Guid $e.After.GpoId -Target $e.Target -LinkEnabled $(if ($e.Before.Enabled) {'Yes'} else {'No'}) -Enforced $(if ($e.Before.Enforced) {'Yes'} else {'No'}) -Domain $DomainDNS -Server $DC | Out-Null; $done = $true }
                'GppVerified'  { $done = $true }
                'SetGpoStatus' { $g = (Get-ADSafe { Get-GPO -Guid $e.Target -Domain $DomainDNS -Server $DC }); if ($g) { $g.GpoStatus = $e.Before.Status }; $done = $true }
                'BackupGPO'    { if (Confirm-YesNo "Restore GPO '$($e.After.Name)' from backup (reverts the GPP edit)?") { Restore-GPO -BackupId $e.After.BackupId -Path $e.After.Path -Domain $DomainDNS -Server $DC | Out-Null; $done = $true } }
                'CreateGPO'    { if ((Get-ADSafe { Get-GPO -Guid $e.After.Id -Domain $DomainDNS -Server $DC })) { if (Confirm-YesNo "DELETE GPO '$($e.After.Name)'?") { Remove-GPO -Guid $e.After.Id -Domain $DomainDNS -Server $DC -Confirm:$false; $done = $true } } else { $done = $true } }
                'AddGroupMember' {
                    $gid = if ($e.After.GroupGuid) { $e.After.GroupGuid } else { $e.After.GroupSid }
                    $grpObj = Get-ADSafe { Get-ADGroup -Identity $gid -Server $DC }
                    $mem = Get-ADSafe { Get-ADObject -Identity $e.After.MemberGuid -Server $DC }
                    if ($grpObj -and $mem) { Remove-ADGroupMember -Identity $grpObj -Members $mem -Server $DC -Confirm:$false }
                    $done = $true }
                'CreateGroup'  { $g = Get-ADSafe { Get-ADGroup -Identity $e.After.ObjectGUID -Server $DC }; if ($g) { if (Confirm-YesNo "DELETE group $($g.Name)?") { Remove-ADGroup -Identity $g -Server $DC -Confirm:$false; $done = $true } } else { $done = $true } }
                'SetUserFlags' { Set-ADUser -Identity $e.After.ObjectGUID -Server $DC -PasswordNeverExpires $e.Before.PasswordNeverExpires -CannotChangePassword $e.Before.CannotChangePassword; $done = $true }
                'EnableUser'   { $u = Get-ADSafe { Get-ADUser -Identity $e.After.ObjectGUID -Server $DC }; if ($u) { Disable-ADAccount -Identity $u -Server $DC }; $done = $true }
                'CreateUser'   { $u = Get-ADSafe { Get-ADUser -Identity $e.After.ObjectGUID -Server $DC }; if ($u) { if (Confirm-YesNo "DELETE user $($u.SamAccountName)?") { Remove-ADUser -Identity $u -Server $DC -Confirm:$false; $done = $true } } else { $done = $true } }
                'DisableUser'  { if (Confirm-YesNo "Re-enable $($e.After.Sam) (built-in Administrator)?") { Enable-ADAccount -Identity $e.After.ObjectGUID -Server $DC; $done = $true } }
                'RenameUser'   {
                    $u = Get-ADSafe { Get-ADUser -Identity $e.After.ObjectGUID -Server $DC }
                    if ($u) {
                        if (Get-UserBySam $e.Before.Sam) { throw "sAM '$($e.Before.Sam)' is taken (probably by the new CBIT-Elevation) - delete that first or leave the legacy account renamed." }
                        Set-ADUser -Identity $u -Server $DC -SamAccountName $e.Before.Sam -UserPrincipalName $e.Before.UPN -DisplayName $e.Before.DisplayName
                        Rename-ADObject -Identity $u -Server $DC -NewName $e.Before.Name
                    }
                    $done = $true }
                'SetRedircmp'  { $o = & redircmp.exe $e.Before.ComputersContainer 2>&1; if ($LASTEXITCODE -ne 0) { throw "redircmp failed: $o" }; $done = $true }
                'MoveObject'   {
                    $obj = Get-ADSafe { Get-ADObject -Identity $e.After.ObjectGUID -Server $DC }
                    if ($obj) { Move-ADObject -Identity $obj -TargetPath $e.Before.Parent -Server $DC }
                    $done = $true }
                'CreateOU'     {
                    $ou = Get-ADSafe { Get-ADOrganizationalUnit -Identity $e.Target -Server $DC }
                    if ($ou) {
                        $kids = @(Get-ADObject -SearchBase $e.Target -SearchScope OneLevel -Filter * -Server $DC)
                        if ($kids.Count) { Write-Log "OU $($e.Target) is not empty ($($kids.Count) objects) - left in place." 'Warn' }
                        elseif (Confirm-YesNo "DELETE empty OU $($e.Target)?") { Set-ADOrganizationalUnit -Identity $ou -Server $DC -ProtectedFromAccidentalDeletion $false; Remove-ADOrganizationalUnit -Identity $ou -Server $DC -Confirm:$false; $done = $true }
                    } else { $done = $true } }
                default        { Write-Log "Skipping unknown action $($e.Action)" 'Warn' }
            }
            $msg = "#$($e.Seq) $($e.Action) $($e.Target) -> $(if ($done) {'reverted'} else {'SKIPPED by technician'})"
            Write-Log $msg $(if ($done) {'Ok'} else {'Skip'})
            Add-Content $rbLog "$(Get-Date -Format s) $msg"
        } catch {
            Write-Log "#$($e.Seq) $($e.Action) FAILED: $($_.Exception.Message)" 'Error'
            Add-Content $rbLog "$(Get-Date -Format s) #$($e.Seq) FAILED: $($_.Exception.Message)"
            if (-not (Confirm-YesNo 'Continue with the remaining rollback entries?')) { break }
        }
    }
    $Script:State.RolledBack = (Get-Date).ToString('s'); Save-State
    Write-Log "Rollback finished. Log: $rbLog" 'Ok'
    Stop-Transcript | Out-Null
}

# ===========================================================================
# MAIN
# ===========================================================================
try {
    New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null

    if ($Rollback) {
        $p = Resolve-RunFolder
        if (-not $p) { throw "No runs found under $LogRoot" }
        Invoke-Rollback -Path $p
        exit 0
    }

    if ($Resume) {
        $p = Resolve-RunFolder -IncompleteOnly
        if (-not $p) { throw "No incomplete run found under $LogRoot (use -RunId to pick one explicitly)." }
        Restore-Run $p
        if ($Script:State.DryRun) { throw 'That run was a dry run; start a new run instead.' }
    } else {
        $open = Resolve-RunFolder -IncompleteOnly
        if ($open -and -not $DryRun) {
            Write-CBITConsole "An incomplete run exists: $open" -ForegroundColor DarkYellow
            $r = (Read-Host "Type 'resume' to continue it, or Enter to start a NEW run (the old one stays on disk)").Trim()
            if ($r -ieq 'resume') { Restore-Run $open } else { Initialize-Run }
        } else { Initialize-Run }
    }

    Invoke-Phase 'Preamble'    { Invoke-Preamble }
    Invoke-Phase 'Environment' { Invoke-Environment } -AlwaysRun
    Invoke-Phase 'Discovery'   { Invoke-Discovery }
    if (-not $Script:Disc) { Invoke-Discovery }   # resumed before cache existed

    if ($DryRun) { Invoke-DryRunPlan; exit 0 }

    Invoke-Phase 'Scope'           { Invoke-Scope }
    Invoke-Phase 'LegacyCBIT'      { Invoke-LegacyCBIT }
    Invoke-Phase 'RecoveryAccount' { Invoke-RecoveryAccount }
    Invoke-Phase 'RID500'          { Invoke-RID500 }
    Invoke-Phase 'Elevation'       { Invoke-Elevation }
    Invoke-Phase 'EndpointGroup'   { Invoke-EndpointGroup }
    Invoke-Phase 'GPO'             { Invoke-GPO }
    Invoke-Phase 'GPOLink'         { Invoke-GPOLink }
    Invoke-Phase 'WorkstationTest' { Invoke-WorkstationTest }
    Invoke-Phase 'Summary'         { Invoke-Summary }

    Write-Log ''
    Write-Log "Deployment complete. Run folder: $($Script:RunPath)" 'Ok'
} catch {
    Write-CBITConsole "FATAL: $($_.Exception.Message)" -ForegroundColor DarkRed
    Write-CBITConsole $_.ScriptStackTrace -ForegroundColor DarkGray
    if ($Script:State) { Save-State }
    exit 1
} finally {
    if ($Script:Transcript) { try { Stop-Transcript | Out-Null } catch {} }
}

}

$script:CBITRunbookIntegration = {
    param([string]$UnifiedPath,[string]$ReportsRoot,[string]$LogsRoot)
    # Keep account/OU/recovery gates and the original rollback journal. Only the
    # manual GPMC phase is delegated to the unified, verified endpoint function.
    $oldGpo=${function:Invoke-GPO}
    $oldLink=${function:Invoke-GPOLink}
    $runbookLogRoot=$LogRoot
    $runbookResume=$Resume
    . $UnifiedPath -FunctionsOnly -ReportRoot $ReportsRoot -LogRoot $LogsRoot
    $Resume=$runbookResume
    $LogRoot=$runbookLogRoot
    $script:CBITOriginalRunbookGpo=$oldGpo
    $script:CBITOriginalRunbookLink=$oldLink
    function Invoke-GPO {
        if($DryRun){& $script:CBITOriginalRunbookGpo;return}
        $domain=$script:State.DomainDNS;$dc=$script:State.DC
        $existing=@(Get-GPO -All -Domain $domain -Server $dc | Where-Object DisplayName -eq $script:Const.GpoName)
        if($existing.Count -gt 1){throw 'Ambiguous endpoint GPO name; resolve manually.'}
        if($existing.Count){
            [xml]$report=Get-GPOReport -Guid $existing[0].Id -Domain $domain -Server $dc -ReportType Xml
            $allowed=@($script:State.WorkstationsOUs | ForEach-Object {Get-OuCanonical $_})
            $foreign=@($report.GPO.LinksTo | Where-Object {$_ -and $_.SOMPath -notin $allowed})
            if($foreign.Count){throw 'Existing endpoint GPO is linked outside the confirmed workstation scope. Review links before editing.'}
            $backupDir=Join-Path $script:RunPath 'breadcrumbs\gpo-backup'
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $backup=Backup-GPO -Guid $existing[0].Id -Domain $domain -Server $dc -Path $backupDir
            Add-Journal -Action BackupGPO -Target $existing[0].Id.ToString() -After @{BackupId=$backup.Id.ToString();Path=$backupDir;Name=$existing[0].DisplayName}
        }
        try{
            $result=Invoke-CBITEndpointDeployment -GpoName $script:Const.GpoName -GroupName $script:Const.GroupName -ElevationSam $script:Const.ElevationSam -AccountName $script:Const.ElevationName -TargetDn @() -ApproveChanges -AllowAdditionalMembers
            $script:State.GpoId=$result.Id.ToString();Save-State
            Add-Journal -Action GppVerified -Target $result.Id.ToString() -Note 'Unified endpoint function configured and independently verified GPP; no GPMC edit required.'
        } finally {
            if(-not $existing.Count){
                $created=@(Get-GPO -All -Domain $domain -Server $dc | Where-Object DisplayName -eq $script:Const.GpoName)
                if($created.Count -eq 1){
                    Add-Journal -Action CreateGPO -Target $script:Const.GpoName -After @{Id=$created[0].Id.ToString();Name=$created[0].DisplayName}
                    $script:State.GpoId=$created[0].Id.ToString();Save-State
                }
            }
        }
    }
    function Invoke-GPOLink {
        & $script:CBITOriginalRunbookLink
        if($DryRun){return}
        foreach($ou in $script:State.WorkstationsOUs){
            $links=@((Get-GPInheritance -Target $ou -Domain $script:State.DomainDNS -Server $script:State.DC).GpoLinks | Where-Object GpoId -eq $script:State.GpoId)
            if($links.Count -ne 1 -or -not $links[0].Enabled -or $links[0].Enforced){throw "Endpoint link readback failed for $ou; expected one enabled, non-enforced link."}
        }
    }
}
function Invoke-CBITPrivilegedAccessRunbook {
    [CmdletBinding()]
    param([switch]$DryRun,[switch]$Resume,[switch]$Rollback,[string]$RunId)
    $dir=Join-Path $script:CBITLogRoot 'CyberQP'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file=Join-Path $dir 'Deploy-CyberQPGPO-preserved.ps1'
    $runbook=$script:CBITPrivilegedRunbook.ToString()
    $main=[regex]::Matches($runbook,'(?m)^try \{')
    if($main.Count -ne 1){throw 'Cannot locate preserved runbook main entry point.'}
    $integration=". {`r`n"+$script:CBITRunbookIntegration.ToString()+"`r`n} -UnifiedPath '"+$script:CBITCurrentScriptPath.Replace("'","''")+"' -ReportsRoot '"+$script:CBITReportRoot.Replace("'","''")+"' -LogsRoot '"+$script:CBITLogRoot.Replace("'","''")+"'`r`n`r`n"
    $runbook=$runbook.Insert($main[0].Index,$integration)
    [IO.File]::WriteAllText($file,$runbook,(New-Object Text.UTF8Encoding($false)))
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$file,'-LogRoot',$dir)
    if($DryRun){$args+='-DryRun'};if($Resume){$args+='-Resume'};if($Rollback){$args+='-Rollback'};if($RunId){$args+=@('-RunId',$RunId)}
    $beforeStates=@{}
    foreach($stateFile in @(Get-ChildItem -LiteralPath $dir -Filter state.json -Recurse -File)){
        $beforeStates[$stateFile.FullName]=(Get-FileHash -LiteralPath $stateFile.FullName -Algorithm SHA256).Hash
    }
    & powershell.exe @args | Out-Host
    $runExit=$LASTEXITCODE
    # The preserved runbook owns its journal/state layout. Export its readable
    # verification artifacts to the requested report root after the child exits.
    foreach($artifact in @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Extension -in '.xml','.html','.txt' })){
        $relative=$artifact.FullName.Substring($dir.Length).TrimStart('\')
        $destination=Join-Path (Join-Path $script:CBITReportRoot 'CyberQP') $relative
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath $artifact.FullName -Destination $destination -Force
    }
    if($runExit){throw "Privileged access runbook failed; inspect $dir."}
    $changedStates=@(Get-ChildItem -LiteralPath $dir -Filter state.json -Recurse -File | Where-Object {
        -not $beforeStates.ContainsKey($_.FullName) -or $beforeStates[$_.FullName] -ne (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    } | Sort-Object LastWriteTime -Descending)
    $state=$null
    if($changedStates.Count -eq 1){$state=Get-Content -LiteralPath $changedStates[0].FullName -Raw | ConvertFrom-Json}
    $status='Returned; review guided summary'
    $detail='No single updated run state identified; completion is not confirmed.'
    $notes=@()
    if($Rollback){$status='Rollback review finished';$detail='Review the rollback log for applied, skipped or declined reversals.'}
    elseif($DryRun){$status='Dry run finished';$detail='Inspection only; no deployment changes.'}
    elseif($state){
        $status=if($state.Completed -and $state.ValidationStatus -eq 'passed'){'Completed; workstation test attested'}elseif($state.Completed){'Configured; workstation validation '+$state.ValidationStatus}else{'Incomplete; review guided summary'}
        $detail='Workstation scope: '+(@($state.WorkstationsOUs) -join '; ')
        $notes=@(@($state.FollowUps)+@($state.Exceptions) | Where-Object {$_ -is [string] -and $_})
    }
    [pscustomobject]@{Policy='CyberQP';Status=$status;Detail=$detail;FollowUps=$notes;RunId=$(if($state){$state.RunId});LogPath=$dir}
}
function Show-CBITCompletion {
    param([object[]]$Outcomes,[string]$Domain,[string]$SummaryPath)
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('============================================================')
    $lines.Add('DEPLOYMENT RUN FINISHED - '+$Domain)
    $lines.Add('============================================================')
    foreach($outcome in $Outcomes){
        $lines.Add($outcome.Policy+': '+$outcome.Status)
        if($outcome.Detail){$lines.Add('  '+$outcome.Detail)}
    }
    $lines.Add('')
    $lines.Add('FOLLOW-UP')
    $notes=@($Outcomes | ForEach-Object {if($_.PSObject.Properties['FollowUps']){$_.FollowUps}} | Where-Object {$_} | Select-Object -Unique)
    foreach($note in $notes){$lines.Add('  - '+$note)}
    if(@($Outcomes | Where-Object Status -eq 'Failed').Count){$lines.Add('  - Resolve failed items using the saved reports before retrying.')}
    if(@($Outcomes | Where-Object Policy -in 'Axis','SentinelOne').Count){$lines.Add('  - Confirm agent installation on pilot endpoints and in the tenant portals.')}
    if(-not $notes.Count -and -not @($Outcomes | Where-Object { $_.Status -eq 'Failed' -or $_.Policy -in 'Axis','SentinelOne' }).Count){$lines.Add('  - Review any pending validation shown above.')}
    $lines.Add('')
    $lines.Add('SAVED REFERENCE')
    $lines.Add('  Run summary: '+$SummaryPath)
    $lines.Add('  Reports: '+$script:CBITReportRoot)
    $lines.Add('  Logs: '+$script:CBITLogRoot)
    $lines.Add('============================================================')
    $lines | Set-Content -LiteralPath ([IO.Path]::ChangeExtension($SummaryPath,'.txt')) -Encoding UTF8
    Write-CBITConsole ''
    foreach($line in $lines){Write-CBITConsole $line -ForegroundColor Gray}
    do{$answer=(Read-Host 'Press Enter for deployment options, or q to quit').Trim()}while($answer -and $answer -ine 'q')
    return ($answer -ieq 'q')
}

function Invoke-CBITS1Read {
    param([Parameter(Mandatory)][string]$Path,[string]$ConsoleUrl='https://usea1-pax8-03.sentinelone.net',[Security.SecureString]$ApiToken=$script:CBITDefaultApiToken)
    if($ConsoleUrl -notmatch '^https://[a-zA-Z0-9.-]+$' -or $Path -notmatch '^/web/api/v2\.1/'){throw 'Invalid SentinelOne API address.'}
    $secret=[Net.NetworkCredential]::new('',$ApiToken).Password
    try {
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Method Get -Uri ($ConsoleUrl+$Path) -Headers @{Authorization=('ApiToken '+$secret)} -TimeoutSec 30 -ErrorAction Stop
    } catch {
        $http=if($_.Exception.Response){[int]$_.Exception.Response.StatusCode}else{'network error'}
        throw "SentinelOne lookup failed ($http). Search again, use manual entry, or quit."
    } finally {$secret=$null}
}
function Get-CBITS1Sites {
    param([string]$ConsoleUrl='https://usea1-pax8-03.sentinelone.net',[Security.SecureString]$ApiToken=$script:CBITDefaultApiToken)
    $sites=New-Object 'System.Collections.Generic.List[object]'
    $seen=New-Object 'System.Collections.Generic.HashSet[string]'
    $cursor=$null
    do {
        $path='/web/api/v2.1/sites?limit=100'
        if($cursor){$path+='&cursor='+[Uri]::EscapeDataString($cursor)}
        $response=Invoke-CBITS1Read -Path $path -ConsoleUrl $ConsoleUrl -ApiToken $ApiToken
        foreach($site in @($response.data.sites)){
            if($site -and $site.state -eq 'active'){$sites.Add([pscustomobject]@{Name=[string]$site.name;Id=[string]$site.id;AccountName=[string]$site.accountName;State=[string]$site.state})}
        }
        $cursor=[string]$response.pagination.nextCursor
        if($cursor -and -not $seen.Add($cursor)){throw 'SentinelOne returned a repeated page cursor; lookup stopped.'}
    }while($cursor)
    $sites.ToArray() | Sort-Object Id -Unique
}
function ConvertTo-CBITCustomerName {
    param([string]$Name)
    $value=$Name.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $value=[regex]::Replace($value,'\p{Mn}','')
    $value=[regex]::Replace($value,'[^\p{L}\p{Nd}]+',' ').Trim()
    # Remove only trailing legal suffixes; keep meaningful customer words.
    $value=[regex]::Replace($value,'(?:\s+|^)(?:incorporated|inc|llc|ltd|limited|corp|corporation|co|company)(?:\s+(?:incorporated|inc|llc|ltd|limited|corp|corporation|co|company))*$','').Trim()
    return $value
}
function Get-CBITNameSimilarity {
    param([string]$Left,[string]$Right)
    if(-not $Left -or -not $Right){return 0.0}
    $previous=New-Object 'int[]' ($Right.Length+1)
    for($j=0;$j -le $Right.Length;$j++){$previous[$j]=$j}
    for($i=1;$i -le $Left.Length;$i++){
        $current=New-Object 'int[]' ($Right.Length+1);$current[0]=$i
        for($j=1;$j -le $Right.Length;$j++){
            $cost=if($Left[$i-1] -eq $Right[$j-1]){0}else{1}
            $current[$j]=[Math]::Min([Math]::Min($previous[$j]+1,$current[$j-1]+1),$previous[$j-1]+$cost)
        }
        $previous=$current
    }
    return 1.0-($previous[$Right.Length]/[double][Math]::Max($Left.Length,$Right.Length))
}
function Find-CBITS1Site {
    param([object[]]$Sites,[string]$Customer)
    $query=ConvertTo-CBITCustomerName $Customer
    if(-not $query){return}
    foreach($site in $Sites){
        $name=ConvertTo-CBITCustomerName $site.Name
        $score=0.0
        if($name -eq $query){$score=100}
        elseif((' '+$name+' ').Contains(' '+$query+' ')){$score=90}
        elseif($query.Length -ge 3 -and $name.Contains($query)){$score=80}
        else {
            $similarity=Get-CBITNameSimilarity $query $name
            foreach($word in ($name -split ' ')){
                if($query.Length -ge 4 -and $word.Length -ge 4){$similarity=[Math]::Max($similarity,(Get-CBITNameSimilarity $query $word))}
            }
            if($similarity -ge 0.72){$score=60*$similarity}
        }
        if($score){[pscustomobject]@{Name=$site.Name;Id=[string]$site.Id;AccountName=$site.AccountName;Score=$score}}
    }
}
function Test-CBITS1SiteToken {
    param([Security.SecureString]$Token,[string]$ExpectedConsole)
    try {
        $raw=[Net.NetworkCredential]::new('',$Token).Password
        switch($raw.Length % 4){2{$raw+='=='}3{$raw+='='}}
        $decoded=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw)) | ConvertFrom-Json
        if(-not $decoded.site_key -or $decoded.url -notmatch '^https://[a-zA-Z0-9.-]+/?$'){throw 'Invalid'}
        $url=$decoded.url.TrimEnd('/')
        if($ExpectedConsole -and $url -ine $ExpectedConsole.TrimEnd('/')){throw 'Wrong console'}
        return $url
    }catch{throw 'Invalid site token or unexpected console URL. No deployments started.'}
    finally{$raw=$null;$decoded=$null}
}
function Select-CBITS1Customer {
    param([Parameter(Mandatory)][string]$Domain,[string]$ConsoleUrl='https://usea1-pax8-03.sentinelone.net',[Security.SecureString]$ApiToken=$script:CBITDefaultApiToken)
    $sites=$null
    $manual=$false
    while($true){
        if(-not $manual){
            $customer=(Read-Host 'SentinelOne customer name (loose match); m for manual token entry, q to quit').Trim()
            if($customer -ieq 'q'){return $null}
            if($customer -ieq 'm'){$manual=$true}
            elseif(-not $customer){continue}
            else {
                try {
                    if($null -eq $sites){$sites=@(Get-CBITS1Sites -ConsoleUrl $ConsoleUrl -ApiToken $ApiToken)}
                    $matches=@(Find-CBITS1Site -Sites $sites -Customer $customer | Sort-Object @{Expression='Score';Descending=$true},Name)
                    if(-not $matches.Count){Write-CBITConsole 'No active customer sites matched. Try a shorter name or different spelling.' -ForegroundColor DarkYellow}
                    else {
                        Write-CBITConsole 'Active SentinelOne customer sites - select the correct full name:' -ForegroundColor Gray
                        for($i=0;$i -lt $matches.Count;$i++){Write-CBITConsole ('{0}. {1}' -f ($i+1),$matches[$i].Name) -ForegroundColor Gray}
                        $selection=(Read-Host 'Site number; Enter to search again, m for manual entry, q to quit').Trim()
                        if($selection -ieq 'q'){return $null}
                        if($selection -ieq 'm'){$manual=$true;continue}
                        if(-not $selection){continue}
                        $number=0
                        if(-not [int]::TryParse($selection,[ref]$number) -or $number -lt 1 -or $number -gt $matches.Count){Write-CBITConsole 'Choose a number from the displayed list.' -ForegroundColor DarkYellow}
                        else {
                            $chosen=$matches[$number-1]
                            if((Read-Host ('Deploy SentinelOne for '+$chosen.Name+' to domain '+$Domain+'? [y/N]')) -match '^(y|yes)$'){
                                $response=Invoke-CBITS1Read -Path ('/web/api/v2.1/sites/'+[Uri]::EscapeDataString($chosen.Id)) -ConsoleUrl $ConsoleUrl -ApiToken $ApiToken
                                if([string]$response.data.id -ne $chosen.Id -or $response.data.state -ne 'active' -or $response.data.name -cne $chosen.Name){throw 'Selected site changed or is inactive; search again to confirm its identity.'}
                                if(-not $response.data.registrationToken){throw 'Selected site did not return an installation token; use manual entry or quit.'}
                                $token=ConvertTo-SecureString $response.data.registrationToken -AsPlainText -Force
                                $response=$null
                                $null=Test-CBITS1SiteToken -Token $token -ExpectedConsole $ConsoleUrl
                                return [pscustomobject]@{Token=$token;Name=$chosen.Name;Id=$chosen.Id;Source='API';ConsoleUrl=$ConsoleUrl}
                            }
                        }
                    }
                }catch{Write-CBITConsole $_.Exception.Message -ForegroundColor DarkYellow;$sites=$null}
                do{$navigation=(Read-Host 'Press Enter to search again, m for manual entry, or q to quit').Trim()}while($navigation -and $navigation -inotcontains 'm' -and $navigation -inotcontains 'q')
                if($navigation -ieq 'q'){return $null}
                $manual=($navigation -ieq 'm')
                continue
            }
        }
        if($manual){
            try {
                $token=Read-Host 'Customer SentinelOne SITE token (secure manual entry)' -AsSecureString
                $url=Test-CBITS1SiteToken -Token $token
                if((Read-Host ('Use manually supplied SentinelOne token for domain '+$Domain+' on '+$url+'? Customer identity is not API-verified [y/N]')) -match '^(y|yes)$'){
                    return [pscustomobject]@{Token=$token;Name='Manual token (customer not API-verified)';Id=$null;Source='Manual';ConsoleUrl=$url}
                }
            }catch{Write-CBITConsole $_.Exception.Message -ForegroundColor DarkYellow}
            $token=$null
            do{$navigation=(Read-Host 'Press Enter to search again, m for manual entry, or q to quit').Trim()}while($navigation -and $navigation -inotcontains 'm' -and $navigation -inotcontains 'q')
            if($navigation -ieq 'q'){return $null}
            $manual=($navigation -ieq 'm')
        }
    }
}

# Exact original bytes; child process isolates Action1 variables and exit handling.
$script:CBITAction1SourceBase64='77u/I3JlcXVpcmVzIC1WZXJzaW9uIDUuMQ0KPCMNCi5TWU5PUFNJUw0KICAgIFN0YXJ0LXRvLWZpbmlzaCBDQklUIE1TUCBBY3Rpb24xIEdQTyBkZXBsb3ltZW50IHdpemFyZCB3aXRoIHJlc3VtYWJsZSBjaGVja3BvaW50cy4NCi5ERVNDUklQVElPTg0KICAgIFVzZXMgQWN0aW9uMSdzIHN1cHBvcnRlZCBHcm91cCBQb2xpY3kgU29mdHdhcmUgSW5zdGFsbGF0aW9uIChBc3NpZ25lZCBNU0kpIG1ldGhvZC4NCiAgICBMYXVuY2hpbmcgdGhlIHNjcmlwdCBpbW1lZGlhdGVseSBjaGVja3MgdGhlIGRvbWFpbiwgc3RhZ2VzIGEgcHJvdGVjdGVkIFNNQiBkaXN0cmlidXRpb24gcG9pbnQsIGNyZWF0ZXMgYW4NCiAgICB1bmxpbmtlZCBHUE8sIHBhdXNlcyBvbmx5IGZvciBHUE1DIEFzc2lnbmVkIE1TSSBwYWNrYWdlIHNldHVwLCB0aGVuIHZlcmlmaWVzIGFuZA0KICAgIGVuYWJsZXMgdGhlIGRvbWFpbi1yb290IGxpbmsgYWZ0ZXIgZXhwbGljaXQgY29uZmlybWF0aW9uLiBSZXJ1biB3aXRoIC1SZXN1bWUuDQogICAgRG9lcyBub3QgbW9kaWZ5IG90aGVyIENCSVQgTVNQIC0gKiBHUE9zLg0KLlBBUkFNRVRFUiBBdWRpdE9ubHkNCiAgICBSZWFkLW9ubHkgQUQgYXNzZXNzbWVudCAod3JpdGVzIG9ubHkgYSBsb2NhbCBhdWRpdCBsb2cpLg0KLlBBUkFNRVRFUiBSZXN1bWUNCiAgICBSZXN1bWUgZnJvbSBhIGxvY2FsbHkgcGVyc2lzdGVkLCBkb21haW4tIGFuZCBob3N0LWJvdW5kIGNoZWNrcG9pbnQuDQouUEFSQU1FVEVSIERpc2FibGVSb290TGluaw0KICAgIERpc2FibGUgdGhlIENCSVQgTVNQIC0gQWN0aW9uMSBkb21haW4tcm9vdCBsaW5rIChleHBsaWNpdCBjb25maXJtYXRpb24gcmVxdWlyZWQpOyBkb2VzIG5vdCB1bmluc3RhbGwgYWdlbnRzLg0KLk5PVEVTDQogICAgV2luZG93cyBQb3dlclNoZWxsIDUuMSBvciBQb3dlclNoZWxsIDcgb24gV2luZG93cyB3aXRoIEFEIFJTQVQgLyBHcm91cFBvbGljeSBtb2R1bGVzLg0KICAgIFJ1biB1c2luZyBhbiBhY2NvdW50IGF1dGhvcml6ZWQgdG8gY3JlYXRlIEdQT3MgYW5kIGxpbmsgR1BPcyBhdCB0aGUgZG9tYWluIHJvb3QuDQogICAgTVNJIGZpbGVzIGFyZSB0ZW5hbnQtc3BlY2lmaWMuIERvd25sb2FkIHRoZSBNU0kgZnJvbSB0aGUgQ09SUkVDVCBBY3Rpb24xIG9yZ2FuaXphdGlvbi4NCiAgICBTb3VyY2U6IGh0dHBzOi8vd3d3LmFjdGlvbjEuY29tL2RvY3VtZW50YXRpb24vZ3BvLXNvZnR3YXJlLWluc3RhbGxhdGlvbi8NCiM+DQpbQ21kbGV0QmluZGluZygpXQ0KcGFyYW0oW3N3aXRjaF0kQXVkaXRPbmx5LCBbc3dpdGNoXSRSZXN1bWUsIFtzd2l0Y2hdJERpc2FibGVSb290TGluaykNCg0KU2V0LVN0cmljdE1vZGUgLVZlcnNpb24gTGF0ZXN0DQokRXJyb3JBY3Rpb25QcmVmZXJlbmNlID0gJ1N0b3AnDQoNCiRzY3JpcHQ6TmFtZSA9ICdDQklUIE1TUCAtIEFjdGlvbjEnDQokc2NyaXB0OkRvbWFpbiA9ICRudWxsDQokc2NyaXB0OkRvbWFpbkROID0gJG51bGwNCiRzY3JpcHQ6R3BvID0gJG51bGwNCiRzY3JpcHQ6SW5zdGFsbGVyVU5DID0gJG51bGwNCiRzY3JpcHQ6SW5zdGFsbGVySGFzaCA9ICRudWxsDQokc2NyaXB0OkF1ZGl0RGlyID0gJG51bGwNCiRzY3JpcHQ6VHJhbnNjcmlwdFN0YXJ0ZWQgPSAkZmFsc2UNCiRzY3JpcHQ6U3RhdGVGaWxlID0gJG51bGwNCiRzY3JpcHQ6U3RhdGUgPSAkbnVsbA0KJHNjcmlwdDpTdGFnZUZvbGRlciA9ICRudWxsDQokc2NyaXB0OlNoYXJlTmFtZSA9ICRudWxsDQokc2NyaXB0OlByaW5jaXBhbHMgPSAkbnVsbA0KJHNjcmlwdDpDb21wdXRlcklzREMgPSAkZmFsc2UNCiRzY3JpcHQ6UGFsZXR0ZSA9IEB7DQogICAgR29vZCAgID0gQHsgSGV4ID0gJyM4RkE4ODAnOyBDb25zb2xlID0gJ0RhcmtHcmVlbicgfQ0KICAgIEJhZCAgICA9IEB7IEhleCA9ICcjOTYzQzNDJzsgQ29uc29sZSA9ICdEYXJrUmVkJyB9DQogICAgRGV0YWlsID0gQHsgSGV4ID0gJyM4MDgwNzgnOyBDb25zb2xlID0gJ0RhcmtHcmF5JyB9DQogICAgV2FybiAgID0gQHsgSGV4ID0gJyNCMDg5NDYnOyBDb25zb2xlID0gJ0RhcmtZZWxsb3cnIH0NCiAgICBIZWFkZXIgPSBAeyBIZXggPSAnI0IyQjJBQSc7IENvbnNvbGUgPSAnR3JheScgfQ0KfQ0KDQpmdW5jdGlvbiBXcml0ZS1DQklUIHsNCiAgICBwYXJhbShbc3RyaW5nXSRUZXh0LCBbVmFsaWRhdGVTZXQoJ0dvb2QnLCdCYWQnLCdEZXRhaWwnLCdXYXJuJywnSGVhZGVyJyldW3N0cmluZ10kVG9uZSA9ICdEZXRhaWwnKQ0KICAgICRjb2xvciA9ICRzY3JpcHQ6UGFsZXR0ZVskVG9uZV0NCiAgICAkc3VwcG9ydHNSZ2IgPSAkZmFsc2UNCiAgICBpZiAoJFBTVmVyc2lvblRhYmxlLlBTVmVyc2lvbi5NYWpvciAtZ2UgNykgew0KICAgICAgICB0cnkgeyAkc3VwcG9ydHNSZ2IgPSBbYm9vbF0kSG9zdC5VSS5TdXBwb3J0c1ZpcnR1YWxUZXJtaW5hbCB9IGNhdGNoIHsgJHN1cHBvcnRzUmdiID0gJGZhbHNlIH0NCiAgICB9DQogICAgaWYgKCRzdXBwb3J0c1JnYikgew0KICAgICAgICAkaGV4ID0gJGNvbG9yLkhleC5UcmltU3RhcnQoJyMnKQ0KICAgICAgICAkciA9IFtDb252ZXJ0XTo6VG9JbnQzMigkaGV4LlN1YnN0cmluZygwLCAyKSwgMTYpDQogICAgICAgICRnID0gW0NvbnZlcnRdOjpUb0ludDMyKCRoZXguU3Vic3RyaW5nKDIsIDIpLCAxNikNCiAgICAgICAgJGIgPSBbQ29udmVydF06OlRvSW50MzIoJGhleC5TdWJzdHJpbmcoNCwgMiksIDE2KQ0KICAgICAgICAkZXNjID0gW2NoYXJdMjcNCiAgICAgICAgV3JpdGUtSG9zdCAoInswfVszODsyO3sxfTt7Mn07ezN9bXs0fXswfVswbSIgLWYgJGVzYywgJHIsICRnLCAkYiwgJFRleHQpDQogICAgfSBlbHNlIHsNCiAgICAgICAgV3JpdGUtSG9zdCAkVGV4dCAtRm9yZWdyb3VuZENvbG9yICRjb2xvci5Db25zb2xlDQogICAgfQ0KfQ0KDQpmdW5jdGlvbiBTaG93LUJhbm5lciB7DQogICAgV3JpdGUtSG9zdCAnJw0KICAgIFdyaXRlLUNCSVQgJz09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScgSGVhZGVyDQogICAgV3JpdGUtQ0JJVCAnICAgQ0JJVCBNU1AgIHwgIEFDVElPTjEgR1BPIERFUExPWU1FTlQgV0laQVJEJyBIZWFkZXINCiAgICBXcml0ZS1DQklUICc9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nIEhlYWRlcg0KICAgIFdyaXRlLUNCSVQgKCdQb2xpY3k6IHswfScgLWYgJHNjcmlwdDpOYW1lKSBEZXRhaWwNCiAgICBpZiAoJHNjcmlwdDpEb21haW4pIHsgV3JpdGUtQ0JJVCAoJ0RvbWFpbjogezB9JyAtZiAkc2NyaXB0OkRvbWFpbikgRGV0YWlsIH0NCiAgICBXcml0ZS1Ib3N0ICcnDQp9DQoNCmZ1bmN0aW9uIENvbmZpcm0tRXhhY3Qgew0KICAgIHBhcmFtKFtzdHJpbmddJFByb21wdCwgW3N0cmluZ10kUGhyYXNlKQ0KICAgIFdyaXRlLUhvc3QgJycNCiAgICBXcml0ZS1DQklUICRQcm9tcHQgV2Fybg0KICAgIHdoaWxlICgkdHJ1ZSkgew0KICAgICAgICAkYW5zd2VyID0gKFJlYWQtSG9zdCAoIlR5cGUgezB9IHRvIHByb2NlZWQgKG9yIENBTkNFTCB0byBnbyBiYWNrKSIgLWYgJFBocmFzZSkpLlRyaW0oKQ0KICAgICAgICBpZiAoJGFuc3dlciAtaWVxICRQaHJhc2UpIHsgcmV0dXJuICR0cnVlIH0NCiAgICAgICAgaWYgKCRhbnN3ZXIgLWllcSAnQ0FOQ0VMJykgeyByZXR1cm4gJGZhbHNlIH0NCiAgICAgICAgV3JpdGUtQ0JJVCAiTm90IHJlY29nbml6ZWQuIFR5cGUgJFBocmFzZSBvciBDQU5DRUw7IGNhcGl0YWxpemF0aW9uIGRvZXMgbm90IG1hdHRlci4iIFdhcm4NCiAgICB9DQp9DQoNCmZ1bmN0aW9uIEFzc2VydC1VTkNGaWxlIHsNCiAgICBwYXJhbShbc3RyaW5nXSRQYXRoKQ0KICAgIGlmICgkUGF0aCAtbm90bWF0Y2ggJ15cXFxcW15cXF0rXFxbXlxcXStcXC4rXC5tc2kkJykgew0KICAgICAgICB0aHJvdyAnUHJvdmlkZSBhIGNvbXBsZXRlIFVOQyBwYXRoIHRvIGFuIE1TSSwgZm9yIGV4YW1wbGUgXFxmaWxlc2VydmVyXHNvZnR3YXJlXEFjdGlvbjFcYWN0aW9uMV9hZ2VudC5tc2kuJw0KICAgIH0NCiAgICBpZiAoLW5vdCAoVGVzdC1QYXRoIC1MaXRlcmFsUGF0aCAkUGF0aCAtUGF0aFR5cGUgTGVhZikpIHsgdGhyb3cgIkNhbm5vdCByZWFkIE1TSTogJFBhdGgiIH0NCiAgICAkZmlsZSA9IEdldC1JdGVtIC1MaXRlcmFsUGF0aCAkUGF0aA0KICAgIGlmICgkZmlsZS5MZW5ndGggLWxlIDApIHsgdGhyb3cgJ01TSSBpcyBlbXB0eS4nIH0NCiAgICByZXR1cm4gJGZpbGUNCn0NCg0KZnVuY3Rpb24gR2V0LUNCSVRHUE8gew0KICAgICRpdGVtcyA9IEAoR2V0LUdQTyAtQWxsIC1Eb21haW4gJHNjcmlwdDpEb21haW4gfCBXaGVyZS1PYmplY3QgeyAkXy5EaXNwbGF5TmFtZSAtZXEgJHNjcmlwdDpOYW1lIH0pDQogICAgaWYgKCRpdGVtcy5Db3VudCAtZ3QgMSkgeyB0aHJvdyAiTXVsdGlwbGUgR1BPcyBuYW1lZCAnJCgkc2NyaXB0Ok5hbWUpJyBleGlzdC4gUmVzb2x2ZSB0aGUgZHVwbGljYXRlIG5hbWVzIGluIEdQTUMgYmVmb3JlIHByb2NlZWRpbmcuIiB9DQogICAgaWYgKCRpdGVtcy5Db3VudCAtZXEgMSkgeyByZXR1cm4gJGl0ZW1zWzBdIH0NCiAgICByZXR1cm4gJG51bGwNCn0NCg0KZnVuY3Rpb24gR2V0LVJvb3RMaW5rIHsNCiAgICAkaW5oZXJpdGFuY2UgPSBHZXQtR1BJbmhlcml0YW5jZSAtVGFyZ2V0ICRzY3JpcHQ6RG9tYWluRE4gLURvbWFpbiAkc2NyaXB0OkRvbWFpbg0KICAgIHJldHVybiBAKCRpbmhlcml0YW5jZS5HcG9MaW5rcyB8IFdoZXJlLU9iamVjdCB7ICRfLkRpc3BsYXlOYW1lIC1lcSAkc2NyaXB0Ok5hbWUgfSkNCn0NCg0KZnVuY3Rpb24gR2V0LURlcGxveW1lbnRMaW5rIHsNCiAgICAkdGFyZ2V0ID0gaWYgKCRzY3JpcHQ6U3RhdGUgLWFuZCAkc2NyaXB0OlN0YXRlLkxpbmtUYXJnZXRETikgeyBbc3RyaW5nXSRzY3JpcHQ6U3RhdGUuTGlua1RhcmdldEROIH0gZWxzZSB7ICRzY3JpcHQ6RG9tYWluRE4gfQ0KICAgICRpbmhlcml0YW5jZSA9IEdldC1HUEluaGVyaXRhbmNlIC1UYXJnZXQgJHRhcmdldCAtRG9tYWluICRzY3JpcHQ6RG9tYWluDQogICAgcmV0dXJuIEAoJGluaGVyaXRhbmNlLkdwb0xpbmtzIHwgV2hlcmUtT2JqZWN0IHsgJF8uRGlzcGxheU5hbWUgLWVxICRzY3JpcHQ6TmFtZSB9KQ0KfQ0KDQpmdW5jdGlvbiBUZXN0LUJsb2NrZWRJbmhlcml0YW5jZSB7DQogICAgdHJ5IHsNCiAgICAgICAgJGJsb2NrZWQgPSBAKEdldC1BRE9yZ2FuaXphdGlvbmFsVW5pdCAtRmlsdGVyICogLVByb3BlcnRpZXMgZ1BPcHRpb25zIHwgV2hlcmUtT2JqZWN0IHsgKCgkXy5nUE9wdGlvbnMgLWFzIFtpbnRdKSAtYmFuZCAxKSAtbmUgMCB9KQ0KICAgICAgICBpZiAoJGJsb2NrZWQuQ291bnQgLWd0IDApIHsNCiAgICAgICAgICAgIFdyaXRlLUNCSVQgIldBUk5JTkc6ICQoJGJsb2NrZWQuQ291bnQpIE9VKHMpIGJsb2NrIGluaGVyaXRlZCBHUE9zLiBBIG5vbi1lbmZvcmNlZCBkb21haW4tcm9vdCBsaW5rIG1heSBub3QgcmVhY2ggY29tcHV0ZXJzIGluIHRob3NlIE9Vcy4iIFdhcm4NCiAgICAgICAgICAgICRibG9ja2VkIHwgU2VsZWN0LU9iamVjdCAtRmlyc3QgMTIgLUV4cGFuZFByb3BlcnR5IERpc3Rpbmd1aXNoZWROYW1lIHwgRm9yRWFjaC1PYmplY3QgeyBXcml0ZS1DQklUICIgICRfIiBXYXJuIH0NCiAgICAgICAgICAgIGlmICgkYmxvY2tlZC5Db3VudCAtZ3QgMTIpIHsgV3JpdGUtQ0JJVCAnICAoYWRkaXRpb25hbCBPVXMgb21pdHRlZCknIFdhcm4gfQ0KICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAgV3JpdGUtQ0JJVCAnTm8gT1VzIHdpdGggYmxvY2tlZCBpbmhlcml0YW5jZSBkZXRlY3RlZC4nIEdvb2QNCiAgICAgICAgfQ0KICAgIH0gY2F0Y2ggew0KICAgICAgICBXcml0ZS1DQklUICgiQ291bGQgbm90IGluc3BlY3QgYmxvY2tlZCBpbmhlcml0YW5jZTogezB9IiAtZiAkXy5FeGNlcHRpb24uTWVzc2FnZSkgV2Fybg0KICAgIH0NCn0NCg0KZnVuY3Rpb24gSW5pdGlhbGl6ZS1DQklUIHsNCiAgICBpZiAoLW5vdCAoR2V0LU1vZHVsZSAtTGlzdEF2YWlsYWJsZSAtTmFtZSBBY3RpdmVEaXJlY3RvcnkpKSB7IHRocm93ICdBY3RpdmVEaXJlY3RvcnkgUlNBVCBtb2R1bGUgbm90IGluc3RhbGxlZC4nIH0NCiAgICBpZiAoLW5vdCAoR2V0LU1vZHVsZSAtTGlzdEF2YWlsYWJsZSAtTmFtZSBHcm91cFBvbGljeSkpIHsgdGhyb3cgJ0dyb3VwUG9saWN5IFJTQVQgbW9kdWxlIG5vdCBpbnN0YWxsZWQuJyB9DQogICAgSW1wb3J0LU1vZHVsZSBBY3RpdmVEaXJlY3RvcnkgLUVycm9yQWN0aW9uIFN0b3ANCiAgICBJbXBvcnQtTW9kdWxlIEdyb3VwUG9saWN5IC1FcnJvckFjdGlvbiBTdG9wDQogICAgJGFkID0gR2V0LUFERG9tYWluIC1FcnJvckFjdGlvbiBTdG9wDQogICAgJHNjcmlwdDpEb21haW4gPSAkYWQuRE5TUm9vdA0KICAgICRzY3JpcHQ6RG9tYWluRE4gPSAkYWQuRGlzdGluZ3Vpc2hlZE5hbWUNCiAgICBpZiAoLW5vdCAkc2NyaXB0OkRvbWFpbiAtb3IgLW5vdCAkc2NyaXB0OkRvbWFpbkROKSB7IHRocm93ICdDb3VsZCBub3QgcmVzb2x2ZSB0aGUgY3VycmVudCBBRCBkb21haW4uJyB9DQogICAgJHNjcmlwdDpHcG8gPSBHZXQtQ0JJVEdQTw0KfQ0KDQpmdW5jdGlvbiBHZXQtUHJpbmNpcGFsTmFtZUZyb21TaWQgew0KICAgIHBhcmFtKFtzdHJpbmddJFNpZCkNCiAgICByZXR1cm4gKFtTZWN1cml0eS5QcmluY2lwYWwuU2VjdXJpdHlJZGVudGlmaWVyXTo6bmV3KCRTaWQpKS5UcmFuc2xhdGUoW1N5c3RlbS5TZWN1cml0eS5QcmluY2lwYWwuTlRBY2NvdW50XSkuVmFsdWUNCn0NCg0KZnVuY3Rpb24gSW5pdGlhbGl6ZS1QcmluY2lwYWxzIHsNCiAgICAkYWQgPSBHZXQtQUREb21haW4gLUVycm9yQWN0aW9uIFN0b3ANCiAgICAkc2lkID0gJGFkLkRvbWFpblNJRC5WYWx1ZQ0KICAgICRjb21wdXRlcnMgPSBHZXQtUHJpbmNpcGFsTmFtZUZyb21TaWQgLVNpZCAoIiRzaWQtNTE1IikNCiAgICAkY29udHJvbGxlcnMgPSBHZXQtUHJpbmNpcGFsTmFtZUZyb21TaWQgLVNpZCAoIiRzaWQtNTE2IikNCiAgICAkcmVhZGVycyA9IEAoJGNvbXB1dGVycywgJGNvbnRyb2xsZXJzKQ0KICAgICMgSWYgdGhlIGRvbWFpbiBoYXMgUk9EQ3MsIHBlcm1pdCB0aGVpciBjb21wdXRlciBhY2NvdW50cyB0b28uDQogICAgdHJ5IHsNCiAgICAgICAgJHJvZGMgPSBHZXQtQURHcm91cCAtSWRlbnRpdHkgKCIkc2lkLTUyMSIpIC1FcnJvckFjdGlvbiBTdG9wDQogICAgICAgIGlmICgkcm9kYykgeyAkcmVhZGVycyArPSAoR2V0LVByaW5jaXBhbE5hbWVGcm9tU2lkIC1TaWQgKCIkc2lkLTUyMSIpKSB9DQogICAgfSBjYXRjaCB7IH0NCiAgICAkc2NyaXB0OlByaW5jaXBhbHMgPSBAew0KICAgICAgICBBZG1pbiA9IEdldC1QcmluY2lwYWxOYW1lRnJvbVNpZCAtU2lkICdTLTEtNS0zMi01NDQnDQogICAgICAgIFN5c3RlbSA9IEdldC1QcmluY2lwYWxOYW1lRnJvbVNpZCAtU2lkICdTLTEtNS0xOCcNCiAgICAgICAgUmVhZGVycyA9IEAoJHJlYWRlcnMpDQogICAgICAgIEFkbWluU2lkID0gJ1MtMS01LTMyLTU0NCcNCiAgICAgICAgU3lzdGVtU2lkID0gJ1MtMS01LTE4Jw0KICAgICAgICBSZWFkZXJTaWRzID0gQCgkcmVhZGVycyB8IEZvckVhY2gtT2JqZWN0IHsgKFtTZWN1cml0eS5QcmluY2lwYWwuTlRBY2NvdW50XTo6bmV3KCRfKSkuVHJhbnNsYXRlKFtTeXN0ZW0uU2VjdXJpdHkuUHJpbmNpcGFsLlNlY3VyaXR5SWRlbnRpZmllcl0pLlZhbHVlIH0pDQogICAgfQ0KICAgICRyb2xlID0gKEdldC1DaW1JbnN0YW5jZSBXaW4zMl9Db21wdXRlclN5c3RlbSAtRXJyb3JBY3Rpb24gU3RvcCkuRG9tYWluUm9sZQ0KICAgICRzY3JpcHQ6Q29tcHV0ZXJJc0RDID0gKCRyb2xlIC1nZSA0KQ0KICAgIGlmICgkc2NyaXB0OkNvbXB1dGVySXNEQykgew0KICAgICAgICAkZGMgPSBHZXQtQUREb21haW5Db250cm9sbGVyIC1JZGVudGl0eSAkZW52OkNPTVBVVEVSTkFNRSAtRXJyb3JBY3Rpb24gU3RvcA0KICAgICAgICAkc2NyaXB0OkNvbXB1dGVySXNEQyA9ICgtbm90ICRkYy5Jc1JlYWRPbmx5KQ0KICAgIH0NCn0NCg0KZnVuY3Rpb24gQXNzZXJ0LUVsZXZhdGlvbiB7DQogICAgJGlkZW50aXR5ID0gW1NlY3VyaXR5LlByaW5jaXBhbC5XaW5kb3dzSWRlbnRpdHldOjpHZXRDdXJyZW50KCkNCiAgICAkcHJpbmNpcGFsID0gW1NlY3VyaXR5LlByaW5jaXBhbC5XaW5kb3dzUHJpbmNpcGFsXTo6bmV3KCRpZGVudGl0eSkNCiAgICBpZiAoLW5vdCAkcHJpbmNpcGFsLklzSW5Sb2xlKFtTZWN1cml0eS5QcmluY2lwYWwuV2luZG93c0J1aWx0SW5Sb2xlXTo6QWRtaW5pc3RyYXRvcikpIHsNCiAgICAgICAgdGhyb3cgJ1J1biBQb3dlclNoZWxsIGVsZXZhdGVkIGFzIGFuIGFjY291bnQgd2l0aCBhZG1pbmlzdHJhdGl2ZSBhbmQgR1BPIG1hbmFnZW1lbnQgcmlnaHRzLicNCiAgICB9DQp9DQoNCmZ1bmN0aW9uIFRlc3QtQWNsUmlnaHRzIHsNCiAgICBwYXJhbShbc3RyaW5nXSRQYXRoLCBbc3dpdGNoXSRGb2xkZXIpDQogICAgJGFjbCA9IEdldC1BY2wgLUxpdGVyYWxQYXRoICRQYXRoIC1FcnJvckFjdGlvbiBTdG9wDQogICAgaWYgKCRGb2xkZXIgLWFuZCAtbm90ICRhY2wuQXJlQWNjZXNzUnVsZXNQcm90ZWN0ZWQpIHsNCiAgICAgICAgdGhyb3cgIkRpcmVjdG9yeSBpbmhlcml0cyBwb3RlbnRpYWxseSB1bnNhZmUgcGVybWlzc2lvbnM6ICRQYXRoIg0KICAgIH0NCiAgICAkYWxsb3dlZCA9IEAoJHNjcmlwdDpQcmluY2lwYWxzLkFkbWluU2lkLCAkc2NyaXB0OlByaW5jaXBhbHMuU3lzdGVtU2lkKSArIEAoJHNjcmlwdDpQcmluY2lwYWxzLlJlYWRlclNpZHMpDQogICAgJGZvdW5kID0gQHt9DQogICAgZm9yZWFjaCAoJGVudHJ5IGluIEAoJGFjbC5BY2Nlc3MpKSB7DQogICAgICAgICRzaWQgPSAkZW50cnkuSWRlbnRpdHlSZWZlcmVuY2UuVHJhbnNsYXRlKFtTZWN1cml0eS5QcmluY2lwYWwuU2VjdXJpdHlJZGVudGlmaWVyXSkuVmFsdWUNCiAgICAgICAgaWYgKCRlbnRyeS5BY2Nlc3NDb250cm9sVHlwZSAtbmUgJ0FsbG93JykgeyB0aHJvdyAiVW5leHBlY3RlZCBERU5ZIEFDTCBvbiAkUGF0aCAoJHNpZCkuIFJlc29sdmUgbWFudWFsbHkuIiB9DQogICAgICAgIGlmICgkc2lkIC1ub3RpbiAkYWxsb3dlZCkgeyB0aHJvdyAiVW5leHBlY3RlZCBOVEZTIHBlcm1pc3Npb24gZm9yIFNJRCAkc2lkIG9uICRQYXRoOyByZXNvbHZlIG1hbnVhbGx5LiIgfQ0KICAgICAgICAkcmlnaHRzID0gW2ludDY0XSRlbnRyeS5GaWxlU3lzdGVtUmlnaHRzDQogICAgICAgIGlmICgtbm90ICRmb3VuZC5Db250YWluc0tleSgkc2lkKSkgeyAkZm91bmRbJHNpZF0gPSBbaW50NjRdMCB9DQogICAgICAgICRmb3VuZFskc2lkXSA9IFtpbnQ2NF0oJGZvdW5kWyRzaWRdIC1ib3IgJHJpZ2h0cykNCiAgICB9DQogICAgJGZ1bGwgPSBbaW50NjRdW1NlY3VyaXR5LkFjY2Vzc0NvbnRyb2wuRmlsZVN5c3RlbVJpZ2h0c106OkZ1bGxDb250cm9sDQogICAgJHJlYWQgPSBbaW50NjRdW1NlY3VyaXR5LkFjY2Vzc0NvbnRyb2wuRmlsZVN5c3RlbVJpZ2h0c106OlJlYWRBbmRFeGVjdXRlDQogICAgJHdyaXRlID0gW2ludDY0XVtTZWN1cml0eS5BY2Nlc3NDb250cm9sLkZpbGVTeXN0ZW1SaWdodHNdOjpXcml0ZQ0KICAgIGZvcmVhY2ggKCRzaWQgaW4gQCgkc2NyaXB0OlByaW5jaXBhbHMuQWRtaW5TaWQsICRzY3JpcHQ6UHJpbmNpcGFscy5TeXN0ZW1TaWQpKSB7DQogICAgICAgIGlmICgtbm90ICRmb3VuZC5Db250YWluc0tleSgkc2lkKSAtb3IgKCgkZm91bmRbJHNpZF0gLWJhbmQgJGZ1bGwpIC1uZSAkZnVsbCkpIHsNCiAgICAgICAgICAgIHRocm93ICJNaXNzaW5nIGFkbWluaXN0cmF0b3JzIG9yIFNZU1RFTSBOVEZTIEZ1bGxDb250cm9sIG9uICRQYXRoICgkc2lkKSINCiAgICAgICAgfQ0KICAgIH0NCiAgICBmb3JlYWNoICgkc2lkIGluIEAoJHNjcmlwdDpQcmluY2lwYWxzLlJlYWRlclNpZHMpKSB7DQogICAgICAgIGlmICgtbm90ICRmb3VuZC5Db250YWluc0tleSgkc2lkKSAtb3IgKCgkZm91bmRbJHNpZF0gLWJhbmQgJHJlYWQpIC1uZSAkcmVhZCkpIHsNCiAgICAgICAgICAgIHRocm93ICJNaXNzaW5nIGNvbXB1dGVyLWFjY291bnQgcmVhZC9leGVjdXRlIE5URlMgcmlnaHRzIG9uICRQYXRoICgkc2lkKSINCiAgICAgICAgfQ0KICAgICAgICBpZiAoKCRmb3VuZFskc2lkXSAtYmFuZCAkd3JpdGUpIC1uZSAwKSB7IHRocm93ICJBIGNvbXB1dGVyLWFjY291bnQgZ3JvdXAgaGFzIE5URlMgd3JpdGUgcmlnaHRzIG9uICRQYXRoICgkc2lkKSIgfQ0KICAgIH0NCn0NCg0KZnVuY3Rpb24gTmV3LVNlY3VyZVN0YWdlRGlyZWN0b3J5IHsNCiAgICBwYXJhbShbc3RyaW5nXSRQYXRoKQ0KICAgIGlmIChUZXN0LVBhdGggLUxpdGVyYWxQYXRoICRQYXRoIC1QYXRoVHlwZSBMZWFmKSB7IHRocm93ICJTdGFnZSBwYXRoIGlzIGEgZmlsZTogJFBhdGgiIH0NCiAgICAkY3JlYXRlZCA9IC1ub3QgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJFBhdGggLVBhdGhUeXBlIENvbnRhaW5lcikNCiAgICBpZiAoJGNyZWF0ZWQpIHsNCiAgICAgICAgJG51bGwgPSBOZXctSXRlbSAtSXRlbVR5cGUgRGlyZWN0b3J5IC1QYXRoICRQYXRoIC1Gb3JjZSAtRXJyb3JBY3Rpb24gU3RvcA0KICAgICAgICAkYWNsID0gR2V0LUFjbCAtTGl0ZXJhbFBhdGggJFBhdGgNCiAgICAgICAgJGFjbC5TZXRBY2Nlc3NSdWxlUHJvdGVjdGlvbigkdHJ1ZSwgJGZhbHNlKQ0KICAgICAgICBmb3JlYWNoICgkcnVsZSBpbiBAKCRhY2wuQWNjZXNzKSkgeyBbdm9pZF0kYWNsLlJlbW92ZUFjY2Vzc1J1bGVBbGwoJHJ1bGUpIH0NCiAgICAgICAgJGluaGVyaXQgPSBbU2VjdXJpdHkuQWNjZXNzQ29udHJvbC5Jbmhlcml0YW5jZUZsYWdzXSdDb250YWluZXJJbmhlcml0LE9iamVjdEluaGVyaXQnDQogICAgICAgICRwcm9wYWdhdGUgPSBbU2VjdXJpdHkuQWNjZXNzQ29udHJvbC5Qcm9wYWdhdGlvbkZsYWdzXTo6Tm9uZQ0KICAgICAgICAkYWxsb3cgPSBbU2VjdXJpdHkuQWNjZXNzQ29udHJvbC5BY2Nlc3NDb250cm9sVHlwZV06OkFsbG93DQogICAgICAgICRhZG1pbiA9IFtTZWN1cml0eS5QcmluY2lwYWwuU2VjdXJpdHlJZGVudGlmaWVyXTo6bmV3KCRzY3JpcHQ6UHJpbmNpcGFscy5BZG1pblNpZCkNCiAgICAgICAgJHN5c3RlbSA9IFtTZWN1cml0eS5QcmluY2lwYWwuU2VjdXJpdHlJZGVudGlmaWVyXTo6bmV3KCRzY3JpcHQ6UHJpbmNpcGFscy5TeXN0ZW1TaWQpDQogICAgICAgIGZvcmVhY2ggKCRzaWQgaW4gQCgkYWRtaW4sICRzeXN0ZW0pKSB7DQogICAgICAgICAgICAkYWNsLkFkZEFjY2Vzc1J1bGUoKFtTZWN1cml0eS5BY2Nlc3NDb250cm9sLkZpbGVTeXN0ZW1BY2Nlc3NSdWxlXTo6bmV3KCRzaWQsIFtTZWN1cml0eS5BY2Nlc3NDb250cm9sLkZpbGVTeXN0ZW1SaWdodHNdOjpGdWxsQ29udHJvbCwgJGluaGVyaXQsICRwcm9wYWdhdGUsICRhbGxvdykpKQ0KICAgICAgICB9DQogICAgICAgIGZvcmVhY2ggKCRzIGluICRzY3JpcHQ6UHJpbmNpcGFscy5SZWFkZXJTaWRzKSB7DQogICAgICAgICAgICAkcHJpbmNpcGFsID0gW1NlY3VyaXR5LlByaW5jaXBhbC5TZWN1cml0eUlkZW50aWZpZXJdOjpuZXcoJHMpDQogICAgICAgICAgICAkYWNsLkFkZEFjY2Vzc1J1bGUoKFtTZWN1cml0eS5BY2Nlc3NDb250cm9sLkZpbGVTeXN0ZW1BY2Nlc3NSdWxlXTo6bmV3KCRwcmluY2lwYWwsIFtTZWN1cml0eS5BY2Nlc3NDb250cm9sLkZpbGVTeXN0ZW1SaWdodHNdOjpSZWFkQW5kRXhlY3V0ZSwgJGluaGVyaXQsICRwcm9wYWdhdGUsICRhbGxvdykpKQ0KICAgICAgICB9DQogICAgICAgIFNldC1BY2wgLUxpdGVyYWxQYXRoICRQYXRoIC1BY2xPYmplY3QgJGFjbCAtRXJyb3JBY3Rpb24gU3RvcA0KICAgICAgICBXcml0ZS1DQklUICJDcmVhdGVkIHByb3RlY3RlZCBOVEZTIGZvbGRlcjogJFBhdGgiIEdvb2QNCiAgICB9IGVsc2Ugew0KICAgICAgICBXcml0ZS1DQklUICJFeGlzdGluZyBzdGFnZSBmb2xkZXIgZGV0ZWN0ZWQ7IHZlcmlmeWluZyB3aXRob3V0IGNoYW5naW5nIGl0cyBBQ0xzOiAkUGF0aCIgV2Fybg0KICAgIH0NCiAgICBUZXN0LUFjbFJpZ2h0cyAtUGF0aCAkUGF0aCAtRm9sZGVyDQp9DQoNCmZ1bmN0aW9uIFRlc3QtU2hhcmVBY2Nlc3Mgew0KICAgIHBhcmFtKFtzdHJpbmddJE5hbWUsIFtzdHJpbmddJExvY2FsRm9sZGVyKQ0KICAgICRzaGFyZSA9IEdldC1TbWJTaGFyZSAtTmFtZSAkTmFtZSAtRXJyb3JBY3Rpb24gU3RvcA0KICAgICRyZXNvbHZlZCA9IFtJTy5QYXRoXTo6R2V0RnVsbFBhdGgoJHNoYXJlLlBhdGgpLlRyaW1FbmQoJ1wnKQ0KICAgICRleHBlY3RlZCA9IFtJTy5QYXRoXTo6R2V0RnVsbFBhdGgoJExvY2FsRm9sZGVyKS5UcmltRW5kKCdcJykNCiAgICBpZiAoJHJlc29sdmVkIC1pbmUgJGV4cGVjdGVkKSB7IHRocm93ICJFeGlzdGluZyBTTUIgc2hhcmUgJyROYW1lJyBwb2ludHMgdG8gJyQoJHNoYXJlLlBhdGgpJyByYXRoZXIgdGhhbiAnJExvY2FsRm9sZGVyJy4iIH0NCiAgICAkYWNjZXNzID0gQChHZXQtU21iU2hhcmVBY2Nlc3MgLU5hbWUgJE5hbWUgLUVycm9yQWN0aW9uIFN0b3ApDQogICAgJGFjY2VwdGVkID0gQCgkc2NyaXB0OlByaW5jaXBhbHMuQWRtaW4pICsgQCgkc2NyaXB0OlByaW5jaXBhbHMuUmVhZGVycykNCiAgICBmb3JlYWNoICgkYSBpbiAkYWNjZXNzKSB7DQogICAgICAgIGlmICgkYS5BY2Nlc3NDb250cm9sVHlwZSAtbmUgJ0FsbG93JyAtb3IgJGEuQWNjb3VudE5hbWUgLW5vdGluICRhY2NlcHRlZCkgew0KICAgICAgICAgICAgdGhyb3cgIlNoYXJlICckTmFtZScgaGFzIGFuIHVuZXhwZWN0ZWQgcGVybWlzc2lvbjogJCgkYS5BY2NvdW50TmFtZSkgJCgkYS5BY2Nlc3NDb250cm9sVHlwZSkgJCgkYS5BY2Nlc3NSaWdodCkuIg0KICAgICAgICB9DQogICAgICAgIGlmICgkYS5BY2NvdW50TmFtZSAtaW4gJHNjcmlwdDpQcmluY2lwYWxzLlJlYWRlcnMgLWFuZCAkYS5BY2Nlc3NSaWdodCAtbmUgJ1JlYWQnKSB7DQogICAgICAgICAgICB0aHJvdyAiQ29tcHV0ZXIgcHJpbmNpcGFscyBtdXN0IGhhdmUgU01CIFJlYWQgT05MWTogJCgkYS5BY2NvdW50TmFtZSkiDQogICAgICAgIH0NCiAgICB9DQogICAgZm9yZWFjaCAoJHAgaW4gJHNjcmlwdDpQcmluY2lwYWxzLlJlYWRlcnMpIHsNCiAgICAgICAgaWYgKEAoJGFjY2VzcyB8IFdoZXJlLU9iamVjdCB7ICRfLkFjY291bnROYW1lIC1pZXEgJHAgLWFuZCAkXy5BY2Nlc3NSaWdodCAtZXEgJ1JlYWQnIH0pLkNvdW50IC1uZSAxKSB7DQogICAgICAgICAgICB0aHJvdyAiTWlzc2luZyBTTUIgUmVhZCBmb3IgJHAgb24gJE5hbWUiDQogICAgICAgIH0NCiAgICB9DQogICAgaWYgKEAoJGFjY2VzcyB8IFdoZXJlLU9iamVjdCB7ICRfLkFjY291bnROYW1lIC1pZXEgJHNjcmlwdDpQcmluY2lwYWxzLkFkbWluIC1hbmQgJF8uQWNjZXNzUmlnaHQgLWVxICdGdWxsJyB9KS5Db3VudCAtbmUgMSkgew0KICAgICAgICB0aHJvdyAiTWlzc2luZyBTTUIgRnVsbCBmb3IgbG9jYWwgQWRtaW5pc3RyYXRvcnMgb24gJE5hbWUiDQogICAgfQ0KICAgIFRlc3QtQWNsUmlnaHRzIC1QYXRoICRMb2NhbEZvbGRlciAtRm9sZGVyDQogICAgV3JpdGUtQ0JJVCAoJ1NoYXJlICsgTlRGUyBBQ0wgdmFsaWRhdGlvbiBwYXNzZWQ6IHswfScgLWYgJE5hbWUpIEdvb2QNCn0NCg0KZnVuY3Rpb24gTmV3LU9yVmVyaWZ5U2hhcmUgew0KICAgIHBhcmFtKFtzdHJpbmddJE5hbWUsIFtzdHJpbmddJExvY2FsRm9sZGVyKQ0KICAgICRleGlzdGluZyA9IEdldC1TbWJTaGFyZSAtTmFtZSAkTmFtZSAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZQ0KICAgIGlmICgtbm90ICRleGlzdGluZykgew0KICAgICAgICAkcGFyYW1zID0gQHsNCiAgICAgICAgICAgIE5hbWUgPSAkTmFtZTsgUGF0aCA9ICRMb2NhbEZvbGRlcg0KICAgICAgICAgICAgRnVsbEFjY2VzcyA9IEAoJHNjcmlwdDpQcmluY2lwYWxzLkFkbWluKQ0KICAgICAgICAgICAgUmVhZEFjY2VzcyA9IEAoJHNjcmlwdDpQcmluY2lwYWxzLlJlYWRlcnMpDQogICAgICAgICAgICBEZXNjcmlwdGlvbiA9ICdDQklUIEFjdGlvbjEgLSBwcm90ZWN0ZWQsIGNvbXB1dGVyLXJlYWRhYmxlIGRpc3RyaWJ1dGlvbiBwb2ludCcNCiAgICAgICAgICAgIENhY2hpbmdNb2RlID0gJ05vbmUnDQogICAgICAgICAgICBGb2xkZXJFbnVtZXJhdGlvbk1vZGUgPSAnQWNjZXNzQmFzZWQnDQogICAgICAgICAgICBFcnJvckFjdGlvbiA9ICdTdG9wJw0KICAgICAgICB9DQogICAgICAgIE5ldy1TbWJTaGFyZSBAcGFyYW1zIHwgT3V0LU51bGwNCiAgICAgICAgV3JpdGUtQ0JJVCAiQ3JlYXRlZCBoaWRkZW4gU01CIHNoYXJlOiAkTmFtZSIgR29vZA0KICAgIH0gZWxzZSB7DQogICAgICAgIFdyaXRlLUNCSVQgIlNNQiBzaGFyZSAnJE5hbWUnIGFscmVhZHkgZXhpc3RzOyBjaGVja2luZyBpdCB3aXRob3V0IGNoYW5naW5nIHBlcm1pc3Npb25zLiIgV2Fybg0KICAgIH0NCiAgICBUZXN0LVNoYXJlQWNjZXNzIC1OYW1lICROYW1lIC1Mb2NhbEZvbGRlciAkTG9jYWxGb2xkZXINCn0NCg0KZnVuY3Rpb24gVGVzdC1JbnN0YWxsZXJTdGFnZSB7DQogICAgaWYgKC1ub3QgJHNjcmlwdDpTdGFnZUZvbGRlciAtb3IgLW5vdCAkc2NyaXB0OlNoYXJlTmFtZSAtb3IgLW5vdCAkc2NyaXB0Okluc3RhbGxlclVOQyAtb3IgLW5vdCAkc2NyaXB0Okluc3RhbGxlckhhc2gpIHsNCiAgICAgICAgdGhyb3cgJ01pc3Npbmcgc2F2ZWQgc3RhZ2luZyBkZXRhaWxzOyBjYW5ub3QgcHJvY2VlZC4nDQogICAgfQ0KICAgIFRlc3QtU2hhcmVBY2Nlc3MgLU5hbWUgJHNjcmlwdDpTaGFyZU5hbWUgLUxvY2FsRm9sZGVyICRzY3JpcHQ6U3RhZ2VGb2xkZXINCiAgICAkZmlsZSA9IEFzc2VydC1VTkNGaWxlIC1QYXRoICRzY3JpcHQ6SW5zdGFsbGVyVU5DDQogICAgJGV4cGVjdGVkUHJlZml4ID0gIlxcJCgkZW52OkNPTVBVVEVSTkFNRSkuJCgkc2NyaXB0OkRvbWFpbilcJCgkc2NyaXB0OlNoYXJlTmFtZSlcIg0KICAgIGlmICgtbm90ICRzY3JpcHQ6SW5zdGFsbGVyVU5DLlN0YXJ0c1dpdGgoJGV4cGVjdGVkUHJlZml4LCBbU3RyaW5nQ29tcGFyaXNvbl06Ok9yZGluYWxJZ25vcmVDYXNlKSkgew0KICAgICAgICB0aHJvdyAiU3RvcmVkIE1TSSBVTkMgZG9lcyBub3QgbWF0Y2ggdGhpcyBzZXJ2ZXIncyBzdGFnZWQgc2hhcmU6ICQoJHNjcmlwdDpJbnN0YWxsZXJVTkMpIg0KICAgIH0NCiAgICAkbG9jYWxGaWxlID0gSm9pbi1QYXRoICRzY3JpcHQ6U3RhZ2VGb2xkZXIgJGZpbGUuTmFtZQ0KICAgIFRlc3QtQWNsUmlnaHRzIC1QYXRoICRsb2NhbEZpbGUNCiAgICAkdW5jSGFzaCA9IChHZXQtRmlsZUhhc2ggLUxpdGVyYWxQYXRoICRzY3JpcHQ6SW5zdGFsbGVyVU5DIC1BbGdvcml0aG0gU0hBMjU2KS5IYXNoDQogICAgJGxvY2FsSGFzaCA9IChHZXQtRmlsZUhhc2ggLUxpdGVyYWxQYXRoICRsb2NhbEZpbGUgLUFsZ29yaXRobSBTSEEyNTYpLkhhc2gNCiAgICBpZiAoJHVuY0hhc2ggLW5lICRzY3JpcHQ6SW5zdGFsbGVySGFzaCAtb3IgJGxvY2FsSGFzaCAtbmUgJHNjcmlwdDpJbnN0YWxsZXJIYXNoKSB7DQogICAgICAgIHRocm93ICdTdGFnZWQgTVNJIFNIQTI1NiBkcmlmdCBkZXRlY3RlZDogU1RPUC4gRG8gbm90IHJlcGxhY2UgYSBkZXBsb3llZCBNU0kgaW4gcGxhY2UuJw0KICAgIH0NCiAgICBXcml0ZS1DQklUICdTdGFnaW5nIHJldmFsaWRhdGlvbiBwYXNzZWQ6IFVOQywgc2hhcmUsIEFDTHMgYW5kIFNIQTI1Ni4nIEdvb2QNCn0NCg0KZnVuY3Rpb24gU2F2ZS1DaGVja3BvaW50IHsNCiAgICBwYXJhbShbaW50XSRTdGVwKQ0KICAgIGlmICgkU3RlcCAtbHQgW2ludF0kc2NyaXB0OlN0YXRlLlN0ZXApIHsgdGhyb3cgJ0NoZWNrcG9pbnQgbXVzdCBub3QgbW92ZSBiYWNrd2FyZHMuJyB9DQogICAgJHNjcmlwdDpTdGF0ZS5TdGVwID0gJFN0ZXANCiAgICAkc2NyaXB0OlN0YXRlLkluc3RhbGxlclVOQyA9ICRzY3JpcHQ6SW5zdGFsbGVyVU5DDQogICAgJHNjcmlwdDpTdGF0ZS5JbnN0YWxsZXJIYXNoID0gJHNjcmlwdDpJbnN0YWxsZXJIYXNoDQogICAgJHNjcmlwdDpTdGF0ZS5TdGFnZUZvbGRlciA9ICRzY3JpcHQ6U3RhZ2VGb2xkZXINCiAgICAkc2NyaXB0OlN0YXRlLlNoYXJlTmFtZSA9ICRzY3JpcHQ6U2hhcmVOYW1lDQogICAgaWYgKCRzY3JpcHQ6R3BvKSB7ICRzY3JpcHQ6U3RhdGUuR3BvR3VpZCA9ICRzY3JpcHQ6R3BvLklkLlRvU3RyaW5nKCkgfQ0KICAgICRzY3JpcHQ6U3RhdGUuTGFzdFVwZGF0ZWQgPSAoR2V0LURhdGUpLlRvU3RyaW5nKCdvJykNCiAgICAkanNvbiA9ICRzY3JpcHQ6U3RhdGUgfCBDb252ZXJ0VG8tSnNvbiAtRGVwdGggNQ0KICAgICR0ZW1wID0gIiQoJHNjcmlwdDpTdGF0ZUZpbGUpLnRtcCINCiAgICAkanNvbiB8IFNldC1Db250ZW50IC1MaXRlcmFsUGF0aCAkdGVtcCAtRW5jb2RpbmcgVVRGOCAtRXJyb3JBY3Rpb24gU3RvcA0KICAgIE1vdmUtSXRlbSAtTGl0ZXJhbFBhdGggJHRlbXAgLURlc3RpbmF0aW9uICRzY3JpcHQ6U3RhdGVGaWxlIC1Gb3JjZSAtRXJyb3JBY3Rpb24gU3RvcA0KfQ0KDQpmdW5jdGlvbiBJbml0aWFsaXplLUNoZWNrcG9pbnQgew0KICAgICRzY3JpcHQ6U3RhdGVGaWxlID0gSm9pbi1QYXRoICRzY3JpcHQ6QXVkaXREaXIgKCdjaGVja3BvaW50LScgKyAkc2NyaXB0OkRvbWFpbiArICcuanNvbicpDQogICAgaWYgKCRSZXN1bWUpIHsNCiAgICAgICAgaWYgKC1ub3QgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJHNjcmlwdDpTdGF0ZUZpbGUgLVBhdGhUeXBlIExlYWYpKSB7IHRocm93ICJObyBjaGVja3BvaW50IGV4aXN0cyBhdCAkKCRzY3JpcHQ6U3RhdGVGaWxlKTsgc3RhcnQgbm9ybWFsbHkuIiB9DQogICAgICAgICRzY3JpcHQ6U3RhdGUgPSBHZXQtQ29udGVudCAtTGl0ZXJhbFBhdGggJHNjcmlwdDpTdGF0ZUZpbGUgLVJhdyB8IENvbnZlcnRGcm9tLUpzb24NCiAgICAgICAgaWYgKC1ub3QgKCRzY3JpcHQ6U3RhdGUuUFNPYmplY3QuUHJvcGVydGllcy5OYW1lIC1jb250YWlucyAnTGlua1RhcmdldEROJykpIHsNCiAgICAgICAgICAgICRzY3JpcHQ6U3RhdGUgfCBBZGQtTWVtYmVyIC1Ob3RlUHJvcGVydHlOYW1lIExpbmtUYXJnZXRETiAtTm90ZVByb3BlcnR5VmFsdWUgJG51bGwNCiAgICAgICAgfQ0KICAgICAgICBpZiAoJHNjcmlwdDpTdGF0ZS5WZXJzaW9uIC1uZSAyIC1vciAkc2NyaXB0OlN0YXRlLkRvbWFpbiAtaW5lICRzY3JpcHQ6RG9tYWluIC1vciAkc2NyaXB0OlN0YXRlLkhvc3QgLWluZSAkZW52OkNPTVBVVEVSTkFNRSkgew0KICAgICAgICAgICAgdGhyb3cgJ0NoZWNrcG9pbnQgYmVsb25ncyB0byBhbm90aGVyIHZlcnNpb24sIGRvbWFpbiwgb3IgaG9zdC4gQ2Fubm90IHJlc3VtZS4nDQogICAgICAgIH0NCiAgICAgICAgaWYgKCRzY3JpcHQ6U3RhdGUuU3RlcCAtbHQgMCAtb3IgJHNjcmlwdDpTdGF0ZS5TdGVwIC1ndCA2KSB7IHRocm93ICdJbnZhbGlkIGNoZWNrcG9pbnQgc3RlcC4nIH0NCiAgICAgICAgJHNjcmlwdDpJbnN0YWxsZXJVTkMgPSAkc2NyaXB0OlN0YXRlLkluc3RhbGxlclVOQw0KICAgICAgICAkc2NyaXB0Okluc3RhbGxlckhhc2ggPSAkc2NyaXB0OlN0YXRlLkluc3RhbGxlckhhc2gNCiAgICAgICAgJHNjcmlwdDpTdGFnZUZvbGRlciA9ICRzY3JpcHQ6U3RhdGUuU3RhZ2VGb2xkZXINCiAgICAgICAgJHNjcmlwdDpTaGFyZU5hbWUgPSAkc2NyaXB0OlN0YXRlLlNoYXJlTmFtZQ0KICAgICAgICBXcml0ZS1DQklUICJSZXN1bWluZyB2ZXJpZmllZCBkb21haW4tYm91bmQgY2hlY2twb2ludCBhdCBzdGFnZSAkKCRzY3JpcHQ6U3RhdGUuU3RlcCkuIiBHb29kDQogICAgfSBlbHNlIHsNCiAgICAgICAgaWYgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJHNjcmlwdDpTdGF0ZUZpbGUgLVBhdGhUeXBlIExlYWYpIHsNCiAgICAgICAgICAgIHRocm93ICJQcmV2aW91cyBkZXBsb3ltZW50IGNoZWNrcG9pbnQgZXhpc3RzLiBVc2UgLVJlc3VtZSBvciByZXZpZXc6ICQoJHNjcmlwdDpTdGF0ZUZpbGUpIg0KICAgICAgICB9DQogICAgICAgICRzY3JpcHQ6U3RhdGUgPSBbb3JkZXJlZF1Aew0KICAgICAgICAgICAgVmVyc2lvbiA9IDI7IERvbWFpbiA9ICRzY3JpcHQ6RG9tYWluOyBIb3N0ID0gJGVudjpDT01QVVRFUk5BTUU7IFN0ZXAgPSAwDQogICAgICAgICAgICBJbnN0YWxsZXJVTkMgPSAkbnVsbDsgSW5zdGFsbGVySGFzaCA9ICRudWxsOyBTdGFnZUZvbGRlciA9ICRudWxsDQogICAgICAgICAgICBTaGFyZU5hbWUgPSAkbnVsbDsgR3BvR3VpZCA9ICRudWxsOyBMaW5rVGFyZ2V0RE4gPSAkbnVsbDsgTGFzdFVwZGF0ZWQgPSAkbnVsbA0KICAgICAgICB9DQogICAgICAgIFNhdmUtQ2hlY2twb2ludCAtU3RlcCAwDQogICAgfQ0KfQ0KDQpmdW5jdGlvbiBTaG93LVByZWZsaWdodCB7DQogICAgU2hvdy1CYW5uZXINCiAgICBXcml0ZS1DQklUICdTVEVQIDEgIC8gIFJFQUQtT05MWSBET01BSU4gUFJFRkxJR0hUJyBIZWFkZXINCiAgICBXcml0ZS1DQklUICgiUm9vdDogezB9IiAtZiAkc2NyaXB0OkRvbWFpbkROKSBEZXRhaWwNCiAgICBXcml0ZS1DQklUICgiT3BlcmF0b3I6IHswfSIgLWYgW1NlY3VyaXR5LlByaW5jaXBhbC5XaW5kb3dzSWRlbnRpdHldOjpHZXRDdXJyZW50KCkuTmFtZSkgRGV0YWlsDQogICAgJGFsbCA9IEAoR2V0LUdQTyAtQWxsIC1Eb21haW4gJHNjcmlwdDpEb21haW4pDQogICAgJG90aGVyID0gQCgkYWxsIHwgV2hlcmUtT2JqZWN0IHsgJF8uRGlzcGxheU5hbWUgLWxpa2UgJ0NCSVQgTVNQIC0gKicgLWFuZCAkXy5EaXNwbGF5TmFtZSAtbmUgJHNjcmlwdDpOYW1lIH0gfCBTb3J0LU9iamVjdCBEaXNwbGF5TmFtZSkNCiAgICBXcml0ZS1DQklUICgiT3RoZXIgQ0JJVCBNU1AgLSAqIHBvbGljaWVzIGZvdW5kOiB7MH0gKHJlYWQtb25seTsgbmV2ZXIgbW9kaWZpZWQpIiAtZiAkb3RoZXIuQ291bnQpIERldGFpbA0KICAgIGZvcmVhY2ggKCRpdGVtIGluICRvdGhlcikgeyBXcml0ZS1DQklUICgiICAtIHswfSIgLWYgJGl0ZW0uRGlzcGxheU5hbWUpIERldGFpbCB9DQogICAgJHNjcmlwdDpHcG8gPSBHZXQtQ0JJVEdQTw0KICAgIGlmICgkc2NyaXB0Okdwbykgew0KICAgICAgICBXcml0ZS1DQklUICgiR1BPIGFscmVhZHkgZXhpc3RzOiB7MH0gIFt7MX1dIiAtZiAkc2NyaXB0Okdwby5EaXNwbGF5TmFtZSwgJHNjcmlwdDpHcG8uSWQpIFdhcm4NCiAgICAgICAgV3JpdGUtQ0JJVCAnVGhlIHdpemFyZCB3aWxsIG5vdCBvdmVyd3JpdGUgb3IgcmVjb25maWd1cmUgYW4gZXhpc3RpbmcgR1BPLicgV2Fybg0KICAgIH0gZWxzZSB7DQogICAgICAgIFdyaXRlLUNCSVQgJ1RoZSBuYW1lZCBHUE8gZG9lcyBub3QgZXhpc3QgeWV0LicgR29vZA0KICAgIH0NCiAgICAkbGlua3MgPSBAKEdldC1Sb290TGluaykNCiAgICBpZiAoJGxpbmtzLkNvdW50IC1lcSAwKSB7IFdyaXRlLUNCSVQgJ05vIGRvbWFpbi1yb290IGxpbmsgZXhpc3RzIGZvciB0aGlzIHBvbGljeS4nIERldGFpbCB9DQogICAgZWxzZSB7DQogICAgICAgIGZvcmVhY2ggKCRsIGluICRsaW5rcykgew0KICAgICAgICAgICAgV3JpdGUtQ0JJVCAoIkRvbWFpbi1yb290IGxpbms6IEVuYWJsZWQ9ezB9IEVuZm9yY2VkPXsxfSBPcmRlcj17Mn0iIC1mICRsLkVuYWJsZWQsICRsLkVuZm9yY2VkLCAkbC5PcmRlcikgV2Fybg0KICAgICAgICB9DQogICAgfQ0KICAgIFRlc3QtQmxvY2tlZEluaGVyaXRhbmNlDQogICAgV3JpdGUtSG9zdCAnJw0KICAgIFdyaXRlLUNCSVQgJ1Njb3BlOiBkb21haW4tam9pbmVkIGNvbXB1dGVycyBpbmNsdWRpbmcgd29ya3N0YXRpb24sIG1lbWJlci1zZXJ2ZXIgYW5kIERDIE9Vcywgc3ViamVjdCB0byBpbmhlcml0YW5jZSwgZmlsdGVyaW5nLCBjb25uZWN0aXZpdHkgYW5kIE9TIHN1cHBvcnQuJyBEZXRhaWwNCiAgICBXcml0ZS1DQklUICdOT1RFOiBUaGUgTVNJIGFuZCBTTUIgc2hhcmUgbXVzdCBiZSByZWFjaGFibGUgYnkgQ09NUFVURVIgYWNjb3VudHMgYXQgYm9vdCAobm90IG9ubHkgeW91ciBhZG1pbiBhY2NvdW50KS4nIFdhcm4NCiAgICBXcml0ZS1DQklUICdOT1RFOiBDaGVjayB0aGUgdGVuYW50LXNwZWNpZmljIE1TSSBiZWZvcmUgZXhwb3NpbmcgaXQgdG8gdGhlIGRvbWFpbi4nIFdhcm4NCiAgICBXcml0ZS1Ib3N0ICcnDQp9DQoNCmZ1bmN0aW9uIFJlc29sdmUtQWN0aW9uMUluc3RhbGxlciB7DQogICAgcGFyYW0oW1BhcmFtZXRlcihNYW5kYXRvcnkpXVtzdHJpbmddJFBhdGgpDQogICAgJGl0ZW0gPSBHZXQtSXRlbSAtTGl0ZXJhbFBhdGggJFBhdGggLUVycm9yQWN0aW9uIFN0b3ANCiAgICBpZiAoJGl0ZW0uUFNJc0NvbnRhaW5lcikgew0KICAgICAgICAkbWF0Y2hlcyA9IEAoR2V0LUNoaWxkSXRlbSAtTGl0ZXJhbFBhdGggJGl0ZW0uRnVsbE5hbWUgLUZpbGUgLUZpbHRlciAnYWN0aW9uMV9hZ2VudCoubXNpJyAtRXJyb3JBY3Rpb24gU3RvcCB8IFNvcnQtT2JqZWN0IE5hbWUpDQogICAgICAgIGlmICgtbm90ICRtYXRjaGVzLkNvdW50KSB7IHRocm93ICJObyBhY3Rpb24xX2FnZW50Ki5tc2kgZmlsZXMgZm91bmQgaW4gJyRQYXRoJy4iIH0NCiAgICAgICAgaWYgKCRtYXRjaGVzLkNvdW50IC1lcSAxKSB7ICRpdGVtID0gJG1hdGNoZXNbMF0gfQ0KICAgICAgICBlbHNlIHsNCiAgICAgICAgICAgIFdyaXRlLUNCSVQgJ011bHRpcGxlIEFjdGlvbjEgaW5zdGFsbGVycyBmb3VuZC4gU2VsZWN0IHRoZSBjb3JyZWN0IGN1c3RvbWVyIG9yZ2FuaXphdGlvbjonIFdhcm4NCiAgICAgICAgICAgIGZvciAoJGkgPSAwOyAkaSAtbHQgJG1hdGNoZXMuQ291bnQ7ICRpKyspIHsgV3JpdGUtQ0JJVCAoJ3swfS4gezF9JyAtZiAoJGkgKyAxKSwgJG1hdGNoZXNbJGldLk5hbWUpIERldGFpbCB9DQogICAgICAgICAgICAkbnVtYmVyID0gMA0KICAgICAgICAgICAgJGFuc3dlciA9IFJlYWQtSG9zdCAnSW5zdGFsbGVyIG51bWJlciAoRW50ZXIgY2FuY2VscyknDQogICAgICAgICAgICBpZiAoLW5vdCBbaW50XTo6VHJ5UGFyc2UoJGFuc3dlciwgW3JlZl0kbnVtYmVyKSAtb3IgJG51bWJlciAtbHQgMSAtb3IgJG51bWJlciAtZ3QgJG1hdGNoZXMuQ291bnQpIHsNCiAgICAgICAgICAgICAgICB0aHJvdyAnSW5zdGFsbGVyIHNlbGVjdGlvbiBjYW5jZWxsZWQgb3IgaW52YWxpZC4gTm8gaW5zdGFsbGVyIHdhcyBzdGFnZWQuJw0KICAgICAgICAgICAgfQ0KICAgICAgICAgICAgJGl0ZW0gPSAkbWF0Y2hlc1skbnVtYmVyIC0gMV0NCiAgICAgICAgfQ0KICAgIH0NCiAgICBpZiAoJGl0ZW0uUFNJc0NvbnRhaW5lciAtb3IgJGl0ZW0uRXh0ZW5zaW9uIC1pbmUgJy5tc2knIC1vciAkaXRlbS5MZW5ndGggLWxlIDApIHsgdGhyb3cgJ1NvdXJjZSBtdXN0IGJlIGEgbm9uZW1wdHkgLm1zaSBmaWxlLicgfQ0KICAgIFdyaXRlLUNCSVQgKCdTZWxlY3RlZCBBY3Rpb24xIGluc3RhbGxlcjogJyArICRpdGVtLkZ1bGxOYW1lKSBEZXRhaWwNCiAgICByZXR1cm4gJGl0ZW0NCn0NCg0KZnVuY3Rpb24gUmVtb3ZlLUFjdGlvbjFTb3VyY2VJbnN0YWxsZXIgew0KICAgIHBhcmFtKFtzdHJpbmddJFNvdXJjZSwgW3N0cmluZ10kRGVzdGluYXRpb24sIFtzdHJpbmddJEV4cGVjdGVkSGFzaCkNCiAgICAjIE5ldmVyIGRlbGV0ZSBmcm9tIGEgVU5DIGRpc3RyaWJ1dGlvbiBwb2ludCBvciB0aHJvdWdoIGEgZmlsZXN5c3RlbSBhbGlhcy4NCiAgICAkc291cmNlUGF0aCA9IFtJTy5QYXRoXTo6R2V0RnVsbFBhdGgoJFNvdXJjZSkNCiAgICAkZGVzdGluYXRpb25QYXRoID0gW0lPLlBhdGhdOjpHZXRGdWxsUGF0aCgkRGVzdGluYXRpb24pDQogICAgJHN0YWdlUGF0aCA9IFtJTy5QYXRoXTo6R2V0RGlyZWN0b3J5TmFtZSgkZGVzdGluYXRpb25QYXRoKS5UcmltRW5kKCdcJykgKyAnXCcNCiAgICBpZiAoJHNvdXJjZVBhdGggLWllcSAkZGVzdGluYXRpb25QYXRoIC1vciAkc291cmNlUGF0aC5TdGFydHNXaXRoKCRzdGFnZVBhdGgsIFtTdHJpbmdDb21wYXJpc29uXTo6T3JkaW5hbElnbm9yZUNhc2UpKSB7IHJldHVybiB9DQogICAgaWYgKCRzb3VyY2VQYXRoIC1ub3RtYXRjaCAnXltBLVphLXpdOlxcJykgew0KICAgICAgICBXcml0ZS1DQklUICdTb3VyY2UgcmV0YWluZWQ6IGF1dG9tYXRpYyBjbGVhbnVwIGFwcGxpZXMgb25seSB0byBhIGxvY2FsIGRvd25sb2FkZWQgTVNJLicgV2Fybg0KICAgICAgICByZXR1cm4NCiAgICB9DQogICAgZm9yZWFjaCAoJHBhdGggaW4gQCgkc291cmNlUGF0aCwgJGRlc3RpbmF0aW9uUGF0aCkpIHsNCiAgICAgICAgJG5vZGUgPSBHZXQtSXRlbSAtTGl0ZXJhbFBhdGggJHBhdGggLUZvcmNlIC1FcnJvckFjdGlvbiBTdG9wDQogICAgICAgIHdoaWxlICgkbm9kZSkgew0KICAgICAgICAgICAgaWYgKCRub2RlLkF0dHJpYnV0ZXMgLWJhbmQgW0lPLkZpbGVBdHRyaWJ1dGVzXTo6UmVwYXJzZVBvaW50KSB7DQogICAgICAgICAgICAgICAgV3JpdGUtQ0JJVCAnU291cmNlIHJldGFpbmVkOiBhIHN0YWdpbmcvc291cmNlIHBhdGggY29udGFpbnMgYSBmaWxlc3lzdGVtIGxpbmsuJyBXYXJuDQogICAgICAgICAgICAgICAgcmV0dXJuDQogICAgICAgICAgICB9DQogICAgICAgICAgICAkbm9kZSA9IGlmICgkbm9kZSAtaXMgW0lPLkRpcmVjdG9yeUluZm9dKSB7ICRub2RlLlBhcmVudCB9IGVsc2UgeyAkbm9kZS5EaXJlY3RvcnkgfQ0KICAgICAgICB9DQogICAgfQ0KICAgIGlmICgoR2V0LUZpbGVIYXNoIC1MaXRlcmFsUGF0aCAkc291cmNlUGF0aCAtQWxnb3JpdGhtIFNIQTI1NiAtRXJyb3JBY3Rpb24gU3RvcCkuSGFzaCAtbmUgJEV4cGVjdGVkSGFzaCAtb3INCiAgICAgICAgKEdldC1GaWxlSGFzaCAtTGl0ZXJhbFBhdGggJGRlc3RpbmF0aW9uUGF0aCAtQWxnb3JpdGhtIFNIQTI1NiAtRXJyb3JBY3Rpb24gU3RvcCkuSGFzaCAtbmUgJEV4cGVjdGVkSGFzaCkgew0KICAgICAgICB0aHJvdyAnU291cmNlIG9yIHN0YWdlZCBNU0kgY2hhbmdlZCBhZnRlciB2ZXJpZmljYXRpb247IHNvdXJjZSByZXRhaW5lZC4nDQogICAgfQ0KICAgIFJlbW92ZS1JdGVtIC1MaXRlcmFsUGF0aCAkc291cmNlUGF0aCAtRXJyb3JBY3Rpb24gU3RvcA0KICAgIFdyaXRlLUNCSVQgKCdSZW1vdmVkIHZlcmlmaWVkIHNvdXJjZSBpbnN0YWxsZXI6ICcgKyAkc291cmNlUGF0aCkgR29vZA0KfQ0KDQpmdW5jdGlvbiBTZXQtSW5zdGFsbGVyIHsNCiAgICBTaG93LUJhbm5lcg0KICAgIFdyaXRlLUNCSVQgJ1NURVAgMiAgLyAgU0VDVVJFIEFDVElPTjEgSU5TVEFMTEVSIFNUQUdJTkcnIEhlYWRlcg0KICAgIFdyaXRlLUNCSVQgJ0FjdGlvbjEgY29uc29sZSA+IGNvcnJlY3QgY3VzdG9tZXIgb3JnYW5pemF0aW9uID4gRW5kcG9pbnRzID4gSW5zdGFsbCBBZ2VudHMgPiBkb3dubG9hZCBXaW5kb3dzIE1TSS4nIERldGFpbA0KICAgIFdyaXRlLUNCSVQgJ1RoZSBpbnN0YWxsZXIgaXMgb3JnYW5pemF0aW9uLXNwZWNpZmljLiBWZXJpZnkgdGhlIHNlbGVjdGVkIHRlbmFudCBiZWZvcmUgZW50ZXJpbmcgdGhlIHNvdXJjZSBwYXRoLicgV2Fybg0KICAgIFdyaXRlLUhvc3QgJycNCiAgICAkc291cmNlID0gKFJlYWQtSG9zdCAnQWN0aW9uMSBNU0kgZmlsZSBvciBmb2xkZXIgKEVudGVyID0gQzpcQ0JJVCknKS5UcmltKCkuVHJpbSgnIicpDQogICAgaWYgKC1ub3QgJHNvdXJjZSkgeyAkc291cmNlID0gJ0M6XENCSVQnIH0NCiAgICAkaW5wdXRGaWxlID0gUmVzb2x2ZS1BY3Rpb24xSW5zdGFsbGVyIC1QYXRoICRzb3VyY2UNCiAgICBXcml0ZS1DQklUICdBZnRlciBzaGFyZSwgcGVybWlzc2lvbnMgYW5kIGhhc2hlcyBhcmUgdmVyaWZpZWQsIHRoZSBvcmlnaW5hbCBsb2NhbCBNU0kgd2lsbCBiZSByZW1vdmVkOyB0aGUgc3RhZ2VkIGNvcHkgcmVtYWlucy4nIERldGFpbA0KICAgICMgQ2hlY2sgdGhlIGNvbXBvdW5kLWZpbGUgc2lnbmF0dXJlOiBjYXRjaGVzIG9idmlvdXMgcmVuYW1lZCBFWEUvWklQIGZpbGVzLg0KICAgICRzdHJlYW0gPSBbSU8uRmlsZV06Ok9wZW5SZWFkKCRpbnB1dEZpbGUuRnVsbE5hbWUpDQogICAgdHJ5IHsNCiAgICAgICAgJGhlYWRlciA9IE5ldy1PYmplY3QgYnl0ZVtdIDgNCiAgICAgICAgaWYgKCRzdHJlYW0uUmVhZCgkaGVhZGVyLCAwLCA4KSAtbmUgOCAtb3IgKFtCaXRDb252ZXJ0ZXJdOjpUb1N0cmluZygkaGVhZGVyKSAtbmUgJ0QwLUNGLTExLUUwLUExLUIxLTFBLUUxJykpIHsNCiAgICAgICAgICAgIHRocm93ICdJbnB1dCBmaWxlIGlzIG5vdCBhIHN0YW5kYXJkIE1TSS9PTEUgY29tcG91bmQgZG9jdW1lbnQuJw0KICAgICAgICB9DQogICAgfSBmaW5hbGx5IHsgJHN0cmVhbS5EaXNwb3NlKCkgfQ0KICAgICRzaWduYXR1cmUgPSBHZXQtQXV0aGVudGljb2RlU2lnbmF0dXJlIC1MaXRlcmFsUGF0aCAkaW5wdXRGaWxlLkZ1bGxOYW1lDQogICAgaWYgKCRzaWduYXR1cmUuU3RhdHVzIC1lcSAnVmFsaWQnKSB7IFdyaXRlLUNCSVQgKCJNU0kgc2lnbmF0dXJlOiBWQUxJRCAoJCgkc2lnbmF0dXJlLlNpZ25lckNlcnRpZmljYXRlLlN1YmplY3QpKSIpIEdvb2QgfQ0KICAgIGVsc2VpZiAoJHNpZ25hdHVyZS5TdGF0dXMgLWVxICdOb3RTaWduZWQnKSB7IFdyaXRlLUNCSVQgJ01TSSBpcyBub3QgQXV0aGVudGljb2RlLXNpZ25lZC4gSW5kZXBlbmRlbnRseSBjb25maXJtIGl0IGNhbWUgZnJvbSBBY3Rpb24xLicgV2FybiB9DQogICAgZWxzZSB7IHRocm93ICJNU0kgc2lnbmF0dXJlIHN0YXR1cyBpcyAkKCRzaWduYXR1cmUuU3RhdHVzKS4gUmVmdXNpbmcgdG8gc3RhZ2UgYSBwb3RlbnRpYWxseSB0YW1wZXJlZCBNU0kuIiB9DQoNCiAgICBXcml0ZS1Ib3N0ICcnDQogICAgJGRlZmF1bHRGb2xkZXIgPSAnQzpcQ0JJVFxBQ1RJT04xZGVwbG95Jw0KICAgICRkZWZhdWx0U2hhcmUgPSAnQUNUSU9OMWRlcGxveSQnDQogICAgV3JpdGUtQ0JJVCAnUmVjb21tZW5kZWQgZGlzdHJpYnV0aW9uIHBvaW50IG9uIFRISVMgZG9tYWluIGNvbnRyb2xsZXI6JyBIZWFkZXINCiAgICBXcml0ZS1DQklUICIgIExvY2FsIGZvbGRlcjogJGRlZmF1bHRGb2xkZXIiIERldGFpbA0KICAgIFdyaXRlLUNCSVQgIiAgU01CIHNoYXJlOiAgICAkZGVmYXVsdFNoYXJlIChoaWRkZW4pIiBEZXRhaWwNCiAgICBXcml0ZS1DQklUICgiICBNU0kgVU5DOiAgICAgIFxcJCgkZW52OkNPTVBVVEVSTkFNRSkuJCgkc2NyaXB0OkRvbWFpbilcJGRlZmF1bHRTaGFyZVwkKCRpbnB1dEZpbGUuTmFtZSkiKSBHb29kDQogICAgV3JpdGUtSG9zdCAnJw0KICAgIHdoaWxlICgkdHJ1ZSkgew0KICAgICAgICAkY2hvaWNlID0gKFJlYWQtSG9zdCAnVXNlIHJlY29tbWVuZGVkIHByb3RlY3RlZCBmb2xkZXIgKyBzaGFyZT8gW1kvbl0nKS5UcmltKCkNCiAgICAgICAgaWYgKCRjaG9pY2UgLWVxICcnIC1vciAkY2hvaWNlIC1tYXRjaCAnXig/aTp5fHllc3xufG5vKSQnKSB7IGJyZWFrIH0NCiAgICAgICAgV3JpdGUtQ0JJVCAnUGxlYXNlIGVudGVyIFksIE4sIG9yIHByZXNzIEVudGVyIGZvciB0aGUgcmVjb21tZW5kYXRpb24uJyBXYXJuDQogICAgfQ0KICAgIGlmICgkY2hvaWNlIC1tYXRjaCAnXig/aTpufG5vKSQnKSB7DQogICAgICAgIFdyaXRlLUNCSVQgJ0FEVkFOQ0VEIE9WRVJSSURFLiBBIG5ldyBsb2NhbCBmb2xkZXIgYW5kIHNoYXJlIHdpbGwgYmUgY3JlYXRlZCBvbiB0aGlzIERDLicgV2Fybg0KICAgICAgICAkZm9sZGVyID0gKFJlYWQtSG9zdCAnRnVsbCBMT0NBTCBkaXJlY3RvcnkgcGF0aCBmb3IgZGlzdHJpYnV0aW9uIGZpbGVzJykuVHJpbSgpLlRyaW0oJyInKS5UcmltRW5kKCdcJykNCiAgICAgICAgJHNoYXJlID0gKFJlYWQtSG9zdCAnU01CIHNoYXJlIG5hbWUgKGVuZGluZyBpbiAkIHJlY29tbWVuZGVkKScpLlRyaW0oKQ0KICAgICAgICBpZiAoLW5vdCAoQ29uZmlybS1FeGFjdCAtUHJvbXB0ICJPdmVycmlkZSBkZWZhdWx0IHBhdGgvc2hhcmUgdG8gJGZvbGRlciBhbmQgJHtzaGFyZX0/IiAtUGhyYXNlICdPVkVSUklERScpKSB7DQogICAgICAgICAgICB0aHJvdyAnQ3VzdG9tIGRpc3RyaWJ1dGlvbiBsb2NhdGlvbiBub3QgYXBwcm92ZWQuJw0KICAgICAgICB9DQogICAgfSBlbHNlaWYgKCRjaG9pY2UgLWVxICcnIC1vciAkY2hvaWNlIC1tYXRjaCAnXig/aTp5fHllcykkJykgew0KICAgICAgICAkZm9sZGVyID0gJGRlZmF1bHRGb2xkZXINCiAgICAgICAgJHNoYXJlID0gJGRlZmF1bHRTaGFyZQ0KICAgIH0NCiAgICBpZiAoLW5vdCBbSU8uUGF0aF06OklzUGF0aFJvb3RlZCgkZm9sZGVyKSAtb3IgJGZvbGRlciAtbm90bWF0Y2ggJ15bQS1aYS16XTpcXC4rJykgew0KICAgICAgICB0aHJvdyAnQSBmdWxsIGxvY2FsIGRyaXZlIHBhdGggKGZvciBleGFtcGxlIEM6XENCSVRcQUNUSU9OMWRlcGxveSkgaXMgcmVxdWlyZWQuJw0KICAgIH0NCiAgICAkZm9sZGVyID0gW0lPLlBhdGhdOjpHZXRGdWxsUGF0aCgkZm9sZGVyKS5UcmltRW5kKCdcJykNCiAgICBpZiAoJGZvbGRlciAtbWF0Y2ggJ14oP2k6W0EtWl06XFwoPzpXaW5kb3dzfFVzZXJzfFByb2dyYW0gRmlsZXMoPzogXCh4ODZcKSk/KSg/OlxcfCQpKScgLW9yICRmb2xkZXIgLW1hdGNoICdeW0EtWmEtel06JCcpIHsNCiAgICAgICAgdGhyb3cgJ0RvIG5vdCBzdGFnZSBkZXBsb3ltZW50IGZpbGVzIGluc2lkZSBzeXN0ZW0vdXNlci9hcHBsaWNhdGlvbiBkaXJlY3RvcmllcyBvciBhIGRyaXZlIHJvb3QuJw0KICAgIH0NCiAgICBpZiAoJHNoYXJlIC1ub3RtYXRjaCAnXltBLVphLXowLTlfLV0rXCQkJykgeyB0aHJvdyAnUmVxdWlyZSBhIGhpZGRlbiBTTUIgc2hhcmUgbmFtZSBlbmRpbmcgaW4gJCAobGV0dGVycywgbnVtYmVycywgdW5kZXJzY29yZXMgb3IgaHlwaGVucykuJyB9DQogICAgaWYgKC1ub3QgJHNjcmlwdDpDb21wdXRlcklzREMpIHsNCiAgICAgICAgdGhyb3cgJ0F1dG9tYXRpYyBzZWN1cmVkLXNoYXJlIHN0YWdpbmcgcmVxdWlyZXMgcnVubmluZyBsb2NhbGx5IG9uIGEgd3JpdGFibGUgZG9tYWluIGNvbnRyb2xsZXIuIFVzZSBhIGN1c3RvbWVyIERDLicNCiAgICB9DQogICAgQXNzZXJ0LUVsZXZhdGlvbg0KICAgICRzcmNIYXNoID0gKEdldC1GaWxlSGFzaCAtTGl0ZXJhbFBhdGggJGlucHV0RmlsZS5GdWxsTmFtZSAtQWxnb3JpdGhtIFNIQTI1NikuSGFzaA0KICAgICRzY3JpcHQ6U3RhZ2VGb2xkZXIgPSAkZm9sZGVyDQogICAgJHNjcmlwdDpTaGFyZU5hbWUgPSAkc2hhcmUNCiAgICBOZXctU2VjdXJlU3RhZ2VEaXJlY3RvcnkgLVBhdGggJGZvbGRlcg0KICAgIE5ldy1PclZlcmlmeVNoYXJlIC1OYW1lICRzaGFyZSAtTG9jYWxGb2xkZXIgJGZvbGRlcg0KICAgICRkZXN0aW5hdGlvbiA9IEpvaW4tUGF0aCAkZm9sZGVyICRpbnB1dEZpbGUuTmFtZQ0KICAgIGlmIChUZXN0LVBhdGggLUxpdGVyYWxQYXRoICRkZXN0aW5hdGlvbikgew0KICAgICAgICAkb2xkSGFzaCA9IChHZXQtRmlsZUhhc2ggLUxpdGVyYWxQYXRoICRkZXN0aW5hdGlvbiAtQWxnb3JpdGhtIFNIQTI1NikuSGFzaA0KICAgICAgICBpZiAoJG9sZEhhc2ggLW5lICRzcmNIYXNoKSB7IHRocm93ICJEaWZmZXJlbnQgTVNJIGFscmVhZHkgZXhpc3RzIGF0ICckZGVzdGluYXRpb24nLiBOZXZlciBvdmVyd3JpdGUgYSBwdWJsaXNoZWQgTVNJLiIgfQ0KICAgICAgICBXcml0ZS1DQklUICdJZGVudGljYWwgc3RhZ2VkIE1TSSBhbHJlYWR5IGV4aXN0cy4gUmV1c2luZyB3aXRob3V0IG92ZXJ3cml0aW5nLicgR29vZA0KICAgIH0gZWxzZSB7DQogICAgICAgIENvcHktSXRlbSAtTGl0ZXJhbFBhdGggJGlucHV0RmlsZS5GdWxsTmFtZSAtRGVzdGluYXRpb24gJGRlc3RpbmF0aW9uIC1FcnJvckFjdGlvbiBTdG9wDQogICAgICAgIFdyaXRlLUNCSVQgJ0NvcGllZCBNU0kgaW50byB0aGUgc2VjdXJlZCBkaXN0cmlidXRpb24gZm9sZGVyLicgR29vZA0KICAgIH0NCiAgICAkc2NyaXB0Okluc3RhbGxlclVOQyA9ICJcXCQoJGVudjpDT01QVVRFUk5BTUUpLiQoJHNjcmlwdDpEb21haW4pXCRzaGFyZVwkKCRpbnB1dEZpbGUuTmFtZSkiDQogICAgJHNjcmlwdDpJbnN0YWxsZXJIYXNoID0gJHNyY0hhc2gNCiAgICBUZXN0LUluc3RhbGxlclN0YWdlDQogICAgUmVtb3ZlLUFjdGlvbjFTb3VyY2VJbnN0YWxsZXIgLVNvdXJjZSAkaW5wdXRGaWxlLkZ1bGxOYW1lIC1EZXN0aW5hdGlvbiAkZGVzdGluYXRpb24gLUV4cGVjdGVkSGFzaCAkc3JjSGFzaA0KICAgIFdyaXRlLUhvc3QgJycNCiAgICBXcml0ZS1DQklUICJWZXJpZmllZCBNU0kgVU5DOiAkKCRzY3JpcHQ6SW5zdGFsbGVyVU5DKSIgR29vZA0KICAgIFdyaXRlLUNCSVQgIk1TSSBTSEEyNTY6ICQoJHNjcmlwdDpJbnN0YWxsZXJIYXNoKSIgRGV0YWlsDQogICAgV3JpdGUtQ0JJVCAnQW4gYWRtaW5pc3RyYXRvciByZWFkaW5nIHRoaXMgc2hhcmUgZG9lcyBub3QgcHJvdmUgcmVtb3RlIGNvbXB1dGVyIGFjY291bnRzIGNhbiByZWFkIGl0LiBUZXN0IGZyb20gZW5kcG9pbnQgZHVyaW5nIHJvbGxvdXQuJyBXYXJuDQogICAgV3JpdGUtSG9zdCAnJw0KfQ0KDQpmdW5jdGlvbiBOZXctU3RhZ2VkR3BvIHsNCiAgICBTaG93LUJhbm5lcg0KICAgIFdyaXRlLUNCSVQgJ1NURVAgMyAgLyAgQ1JFQVRFIE9SIFZFUklGWSBVTkxJTktFRCBQT0xJQ1knIEhlYWRlcg0KICAgICRzY3JpcHQ6R3BvID0gR2V0LUNCSVRHUE8NCiAgICBpZiAoJHNjcmlwdDpHcG8pIHsNCiAgICAgICAgaWYgKC1ub3QgJHNjcmlwdDpTdGF0ZS5HcG9HdWlkIC1vciAkc2NyaXB0Okdwby5JZC5Ub1N0cmluZygpIC1pbmUgW3N0cmluZ10kc2NyaXB0OlN0YXRlLkdwb0d1aWQpIHsNCiAgICAgICAgICAgIHRocm93ICdBIENCSVQgTVNQIC0gQWN0aW9uMSBHUE8gYWxyZWFkeSBleGlzdHMgYnV0IGlzIE5PVCByZWNvcmRlZCBpbiB0aGlzIHdpemFyZCBjaGVja3BvaW50OyB3aWxsIG5vdCBhZG9wdCBvciBjaGFuZ2UgaXQuJw0KICAgICAgICB9DQogICAgICAgIFdyaXRlLUNCSVQgIlJldXNpbmcgY2hlY2twb2ludC1vd25lZCBHUE86ICQoJHNjcmlwdDpHcG8uSWQpIiBHb29kDQogICAgfSBlbHNlIHsNCiAgICAgICAgaWYgKC1ub3QgJHNjcmlwdDpJbnN0YWxsZXJVTkMpIHsgdGhyb3cgJ0luc3RhbGxlciBtdXN0IGJlIHN0YWdlZCBmaXJzdC4nIH0NCiAgICAgICAgQXNzZXJ0LUVsZXZhdGlvbg0KICAgICAgICBXcml0ZS1DQklUICdQcm9wb3NlZDogY3JlYXRlIE5FVywgVU5MSU5LRUQgQ0JJVCBNU1AgLSBBY3Rpb24xOyB1c2VyIGNvbmZpZ3VyYXRpb24gZGlzYWJsZWQ7IEF1dGhlbnRpY2F0ZWQgVXNlcnMgYXBwbGllcy4nIERldGFpbA0KICAgICAgICAkbmV3ID0gTmV3LUdQTyAtTmFtZSAkc2NyaXB0Ok5hbWUgLURvbWFpbiAkc2NyaXB0OkRvbWFpbiAtQ29tbWVudCAnQ0JJVCBBY3Rpb24xIC0gQXNzaWduZWQgTVNJLCBjb21wdXRlciBzY29wZSwgZG9tYWluIHJvb3QgYWZ0ZXIgdmFsaWRhdGlvbi4nDQogICAgICAgICRzY3JpcHQ6R3BvID0gJG5ldw0KICAgICAgICAjIFJlY29yZCBvd25lcnNoaXAgYXMgc29vbiBhcyB0aGUgR1BPIGlzIGNyZWF0ZWQsIGJlZm9yZSBjaGFuZ2luZyBzZXR0aW5ncy4NCiAgICAgICAgU2F2ZS1DaGVja3BvaW50IC1TdGVwIDINCiAgICB9DQogICAgdHJ5IHsNCiAgICAgICAgJHNjcmlwdDpHcG8uR3BvU3RhdHVzID0gJ1VzZXJTZXR0aW5nc0Rpc2FibGVkJw0KICAgICAgICBTZXQtR1BQZXJtaXNzaW9uIC1HdWlkICRzY3JpcHQ6R3BvLklkIC1Eb21haW5OYW1lICRzY3JpcHQ6RG9tYWluIC1UYXJnZXROYW1lICdBdXRoZW50aWNhdGVkIFVzZXJzJyAtVGFyZ2V0VHlwZSBHcm91cCAtUGVybWlzc2lvbkxldmVsIEdwb0FwcGx5IC1SZXBsYWNlIHwgT3V0LU51bGwNCiAgICAgICAgU2V0LUdQUmVnaXN0cnlWYWx1ZSAtR3VpZCAkc2NyaXB0Okdwby5JZCAtRG9tYWluICRzY3JpcHQ6RG9tYWluIC1LZXkgJ0hLTE1cU29mdHdhcmVcUG9saWNpZXNcTWljcm9zb2Z0XFdpbmRvd3MgTlRcQ3VycmVudFZlcnNpb25cV2lubG9nb24nIC1WYWx1ZU5hbWUgU3luY0ZvcmVncm91bmRQb2xpY3kgLVR5cGUgRFdvcmQgLVZhbHVlIDEgfCBPdXQtTnVsbA0KICAgIH0gY2F0Y2ggew0KICAgICAgICB0aHJvdyAnR1BPIHdhcyBjcmVhdGVkIGJ1dCBiYXNlbGluZSBwb2xpY3kgc2V0dGluZ3MgZmFpbGVkLiBJdCByZW1haW5zIFVOTElOS0VEOyByZXJ1biB3aXRoIC1SZXN1bWUuICcgKyAkXy5FeGNlcHRpb24uTWVzc2FnZQ0KICAgIH0NCiAgICBXcml0ZS1DQklUICJDcmVhdGVkL3ZlcmlmaWVkIEdQTyAodW5saW5rZWQpOiAkKCRzY3JpcHQ6R3BvLklkKSIgR29vZA0KICAgIFdyaXRlLUhvc3QgJycNCn0NCg0KZnVuY3Rpb24gT3Blbi1HcG1jR3VpZGUgew0KICAgIFNob3ctQmFubmVyDQogICAgV3JpdGUtQ0JJVCAnU1RFUCA0ICAvICBBQ1RJT04xIEFTU0lHTkVEIE1TSSBJTiBHUE1DIChPTkUgTUFOVUFMIFNURVApJyBIZWFkZXINCiAgICAkc2NyaXB0OkdwbyA9IEdldC1DQklUR1BPDQogICAgaWYgKC1ub3QgJHNjcmlwdDpHcG8pIHsgdGhyb3cgJ0dQTyBub3QgZm91bmQuJyB9DQogICAgV3JpdGUtQ0JJVCAiR1BPOiAkKCRzY3JpcHQ6TmFtZSkiIEhlYWRlcg0KICAgIFdyaXRlLUhvc3QgJycNCiAgICBXcml0ZS1DQklUICdHUE1DIG5hdmlnYXRpb246JyBEZXRhaWwNCiAgICBXcml0ZS1DQklUICJGb3Jlc3Q6ICQoJHNjcmlwdDpEb21haW4pIiBEZXRhaWwNCiAgICBXcml0ZS1DQklUICcgICstLSBEb21haW5zJyBEZXRhaWwNCiAgICBXcml0ZS1DQklUICIgICAgICArLS0gJCgkc2NyaXB0OkRvbWFpbikiIERldGFpbA0KICAgIFdyaXRlLUNCSVQgJyAgICAgICAgICArLS0gR3JvdXAgUG9saWN5IE9iamVjdHMnIERldGFpbA0KICAgIFdyaXRlLUNCSVQgIiAgICAgICAgICAgICAgKy0tICQoJHNjcmlwdDpOYW1lKSAocmlnaHQtY2xpY2sgPiBFZGl0KSIgRGV0YWlsDQogICAgV3JpdGUtSG9zdCAnJw0KICAgIFdyaXRlLUNCSVQgJ0NvbXB1dGVyIENvbmZpZ3VyYXRpb24nIERldGFpbA0KICAgIFdyaXRlLUNCSVQgJyAgKy0tIFBvbGljaWVzJyBEZXRhaWwNCiAgICBXcml0ZS1DQklUICcgICAgICArLS0gU29mdHdhcmUgU2V0dGluZ3MnIERldGFpbA0KICAgIFdyaXRlLUNCSVQgJyAgICAgICAgICArLS0gU29mdHdhcmUgaW5zdGFsbGF0aW9uIChyaWdodC1jbGljayA+IE5ldyA+IFBhY2thZ2UpJyBEZXRhaWwNCiAgICBXcml0ZS1Ib3N0ICcnDQogICAgV3JpdGUtQ0JJVCAiRW50ZXIgdGhpcyBmdWxsIFVOQyBwYXRoIChkbyBOT1QgQnJvd3NlIG9yIHNlbGVjdCBDOik6ICQoJHNjcmlwdDpJbnN0YWxsZXJVTkMpIiBHb29kDQogICAgdHJ5IHsNCiAgICAgICAgU2V0LUNsaXBib2FyZCAtVmFsdWUgJHNjcmlwdDpJbnN0YWxsZXJVTkMgLUVycm9yQWN0aW9uIFN0b3ANCiAgICAgICAgV3JpdGUtQ0JJVCAnTVNJIFVOQyBwYXRoIGNvcGllZCB0byBjbGlwYm9hcmQuIFBhc3RlIGl0IGludG8gdGhlIE5ldyBQYWNrYWdlIGZpbGUgbmFtZSBib3ggKEN0cmwrVikuJyBHb29kDQogICAgfSBjYXRjaCB7DQogICAgICAgIFdyaXRlLUNCSVQgJ0NvdWxkIG5vdCBjb3B5IHRvIGNsaXBib2FyZC4gQ29weSB0aGUgZnVsbCBVTkMgcGF0aCBzaG93biBhYm92ZSBtYW51YWxseS4nIFdhcm4NCiAgICB9DQogICAgV3JpdGUtQ0JJVCAnU2VsZWN0IEFTU0lHTkVEIChub3QgUHVibGlzaGVkKSwgdGhlbiBjbG9zZSB0aGUgZWRpdG9yLicgRGV0YWlsDQogICAgV3JpdGUtSG9zdCAnJw0KICAgIHRyeSB7IFN0YXJ0LVByb2Nlc3MgLUZpbGVQYXRoICdncG1jLm1zYycgLUVycm9yQWN0aW9uIFN0b3A7IFdyaXRlLUNCSVQgJ0xhdW5jaGVkIEdQTUMuJyBHb29kIH0NCiAgICBjYXRjaCB7IFdyaXRlLUNCSVQgJ0dQTUMgZGlkIG5vdCBsYXVuY2g7IG9wZW4gZ3BtYy5tc2MgbWFudWFsbHkuJyBXYXJuIH0NCiAgICB3aGlsZSAoJHRydWUpIHsNCiAgICAgICAgV3JpdGUtSG9zdCAnJw0KICAgICAgICAkYW5zd2VyID0gKFJlYWQtSG9zdCAnUHJlc3MgRW50ZXIgdG8gdmVyaWZ5IE1TSSBhc3NpZ25tZW50LCBvciB0eXBlIEVYSVQgdG8gcGF1c2UgZm9yIC1SZXN1bWUnKS5UcmltKCkNCiAgICAgICAgaWYgKCRhbnN3ZXIgLW1hdGNoICdeKD9pOmV4aXR8Y2FuY2VsKSQnKSB7IHRocm93ICdQYXVzZWQgYmVmb3JlIHBhY2thZ2UgYXNzaWdubWVudC4gUmUtcnVuIHdpdGggLVJlc3VtZSB3aGVuIHJlYWR5LicgfQ0KICAgICAgICBpZiAoJGFuc3dlciAtbmUgJycpIHsNCiAgICAgICAgICAgIFdyaXRlLUNCSVQgJ1ByZXNzIEVudGVyIHRvIHJldHJ5IHZlcmlmaWNhdGlvbiwgb3IgdHlwZSBFWElUIHRvIHNhdmUgYW5kIHJlc3VtZSBsYXRlci4nIFdhcm4NCiAgICAgICAgICAgIGNvbnRpbnVlDQogICAgICAgIH0NCiAgICAgICAgaWYgKEdldC1QYWNrYWdlRXZpZGVuY2UgLVRhcmdldEdwbyAkc2NyaXB0OkdwbykgeyBicmVhayB9DQogICAgICAgIFdyaXRlLUNCSVQgJ01TSSBhc3NpZ25tZW50IG5vdCB2ZXJpZmllZCB5ZXQuIENoZWNrIEdQTUMgYW5kIHByZXNzIEVudGVyIHRvIHRyeSBhZ2Fpbi4nIFdhcm4NCiAgICB9DQogICAgV3JpdGUtSG9zdCAnJw0KfQ0KDQpmdW5jdGlvbiBHZXQtUGFja2FnZUV2aWRlbmNlIHsNCiAgICBwYXJhbSgkVGFyZ2V0R3BvKQ0KICAgICRndWlkQiA9ICRUYXJnZXRHcG8uSWQuVG9TdHJpbmcoJ0InKS5Ub1VwcGVySW52YXJpYW50KCkNCiAgICAkYmFzZSA9ICJDTj1QYWNrYWdlcyxDTj1DbGFzcyBTdG9yZSxDTj1NYWNoaW5lLENOPSRndWlkQixDTj1Qb2xpY2llcyxDTj1TeXN0ZW0sJCgkc2NyaXB0OkRvbWFpbkROKSINCiAgICAkb2JqZWN0cyA9IEAoKQ0KICAgIHRyeSB7DQogICAgICAgICRvYmplY3RzID0gQChHZXQtQURPYmplY3QgLVNlYXJjaEJhc2UgJGJhc2UgLVNlYXJjaFNjb3BlIE9uZUxldmVsIC1MREFQRmlsdGVyICcob2JqZWN0Q2xhc3M9cGFja2FnZVJlZ2lzdHJhdGlvbiknIC1Qcm9wZXJ0aWVzIG1zaUZpbGVMaXN0LGRpc3BsYXlOYW1lIC1FcnJvckFjdGlvbiBTdG9wKQ0KICAgIH0gY2F0Y2ggew0KICAgICAgICBXcml0ZS1DQklUICJDYW5ub3QgaW5zcGVjdCB0aGUgR1BPIG1hY2hpbmUgcGFja2FnZSByZWdpc3RyYXRpb246ICQoJF8uRXhjZXB0aW9uLk1lc3NhZ2UpIiBXYXJuDQogICAgICAgIHJldHVybiAkZmFsc2UNCiAgICB9DQogICAgaWYgKCRvYmplY3RzLkNvdW50IC1uZSAxKSB7DQogICAgICAgIFdyaXRlLUNCSVQgIkV4cGVjdGVkIGV4YWN0bHkgT05FIGNvbXB1dGVyLWFzc2lnbmVkIHBhY2thZ2U7IGZvdW5kICQoJG9iamVjdHMuQ291bnQpLiIgQmFkDQogICAgICAgIHJldHVybiAkZmFsc2UNCiAgICB9DQogICAgJHBhdGhzID0gQCgpDQogICAgZm9yZWFjaCAoJHZhbHVlIGluIEAoJG9iamVjdHNbMF0ubXNpRmlsZUxpc3QpKSB7DQogICAgICAgICRjYW5kaWRhdGUgPSBbc3RyaW5nXSR2YWx1ZQ0KICAgICAgICAjIE1pY3Jvc29mdCB0eXBpY2FsbHkgc3RvcmVzIHBhY2thZ2UgcGF0aHMgcHJlZml4ZWQgd2l0aCAnMDonIGV0Yy4NCiAgICAgICAgJGNhbmRpZGF0ZSA9ICRjYW5kaWRhdGUgLXJlcGxhY2UgJ15cZCs6JywgJycNCiAgICAgICAgaWYgKCRjYW5kaWRhdGUpIHsgJHBhdGhzICs9ICRjYW5kaWRhdGUgfQ0KICAgIH0NCiAgICBpZiAoQCgkcGF0aHMgfCBXaGVyZS1PYmplY3QgeyAkXyAtaWVxICRzY3JpcHQ6SW5zdGFsbGVyVU5DIH0pLkNvdW50IC1lcSAwKSB7DQogICAgICAgIFdyaXRlLUNCSVQgJ1JlZ2lzdGVyZWQgQXNzaWduZWQgTVNJIGRvZXMgbm90IHJlZmVyZW5jZSB0aGUgZXhhY3QgdmVyaWZpZWQgVU5DIHBhdGguJyBCYWQNCiAgICAgICAgZm9yZWFjaCAoJHAgaW4gJHBhdGhzKSB7IFdyaXRlLUNCSVQgIlJlZ2lzdGVyZWQ6ICRwIiBXYXJuIH0NCiAgICAgICAgV3JpdGUtQ0JJVCAiRXhwZWN0ZWQ6ICAgJCgkc2NyaXB0Okluc3RhbGxlclVOQykiIFdhcm4NCiAgICAgICAgcmV0dXJuICRmYWxzZQ0KICAgIH0NCiAgICBXcml0ZS1DQklUICdFeGFjdGx5IG9uZSBtYWNoaW5lIHBhY2thZ2UgcmVnaXN0ZXJlZCBhdCB0aGUgdmVyaWZpZWQgQWN0aW9uMSBNU0kgVU5DLicgR29vZA0KICAgIHJldHVybiAkdHJ1ZQ0KfQ0KDQpmdW5jdGlvbiBUZXN0LVNlY3VyaXR5RmlsdGVyaW5nIHsNCiAgICBwYXJhbSgkVGFyZ2V0R3BvKQ0KICAgIHRyeSB7DQogICAgICAgICRwZXJtcyA9IEAoR2V0LUdQUGVybWlzc2lvbiAtR3VpZCAkVGFyZ2V0R3BvLklkIC1BbGwgLURvbWFpbk5hbWUgJHNjcmlwdDpEb21haW4pDQogICAgICAgICRhdXRoID0gQCgkcGVybXMgfCBXaGVyZS1PYmplY3Qgew0KICAgICAgICAgICAgJF8uVHJ1c3RlZS5OYW1lIC1lcSAnQXV0aGVudGljYXRlZCBVc2VycycgLWFuZCAkXy5QZXJtaXNzaW9uIC1lcSAnR3BvQXBwbHknDQogICAgICAgIH0pDQogICAgICAgIGlmICgkYXV0aC5Db3VudCAtZ3QgMCkgeyBXcml0ZS1DQklUICdBdXRoZW50aWNhdGVkIFVzZXJzIGhhcyBHcG9BcHBseSAoaW5jbHVkZXMgZG9tYWluIGNvbXB1dGVyIGFjY291bnRzKS4nIEdvb2Q7IHJldHVybiAkdHJ1ZSB9DQogICAgICAgIFdyaXRlLUNCSVQgJ0Nhbm5vdCBjb25maXJtIEF1dGhlbnRpY2F0ZWQgVXNlcnMgLyBHcG9BcHBseSBzZWN1cml0eSBmaWx0ZXJpbmcuIFJldmlldyBEZWxlZ2F0aW9uIGFuZCBTZWN1cml0eSBGaWx0ZXJpbmcgaW4gR1BNQy4nIEJhZA0KICAgICAgICByZXR1cm4gJGZhbHNlDQogICAgfSBjYXRjaCB7DQogICAgICAgIFdyaXRlLUNCSVQgKCJTZWN1cml0eSBmaWx0ZXJpbmcgY2hlY2sgZmFpbGVkOiB7MH0iIC1mICRfLkV4Y2VwdGlvbi5NZXNzYWdlKSBCYWQNCiAgICAgICAgcmV0dXJuICRmYWxzZQ0KICAgIH0NCn0NCg0KZnVuY3Rpb24gRW5hYmxlLVJvb3REZXBsb3ltZW50IHsNCiAgICBTaG93LUJhbm5lcg0KICAgIFdyaXRlLUNCSVQgJ1NURVAgNSAgLyAgRklOQUwgVkVSSUZJQ0FUSU9OICsgTElOSyBBUFBST1ZBTCcgSGVhZGVyDQogICAgJHNjcmlwdDpHcG8gPSBHZXQtQ0JJVEdQTw0KICAgIGlmICgtbm90ICRzY3JpcHQ6R3BvKSB7IHRocm93ICdUYXJnZXQgR1BPIG5vdCBmb3VuZC4nIH0NCiAgICBpZiAoLW5vdCAkc2NyaXB0OlN0YXRlLkdwb0d1aWQgLW9yICRzY3JpcHQ6R3BvLklkLlRvU3RyaW5nKCkgLWluZSBbc3RyaW5nXSRzY3JpcHQ6U3RhdGUuR3BvR3VpZCkgew0KICAgICAgICB0aHJvdyAnR1BPIGRvZXMgbm90IG1hdGNoIGNoZWNrcG9pbnQgR1VJRC4nDQogICAgfQ0KICAgIFRlc3QtSW5zdGFsbGVyU3RhZ2UNCiAgICBpZiAoLW5vdCAoVGVzdC1TZWN1cml0eUZpbHRlcmluZyAtVGFyZ2V0R3BvICRzY3JpcHQ6R3BvKSkgeyB0aHJvdyAnU2VjdXJpdHkgZmlsdGVyaW5nIG5vdCB2ZXJpZmllZC4nIH0NCiAgICBpZiAoLW5vdCAoR2V0LVBhY2thZ2VFdmlkZW5jZSAtVGFyZ2V0R3BvICRzY3JpcHQ6R3BvKSkgeyB0aHJvdyAnRXhhY3QgQXNzaWduZWQgTVNJIHBhY2thZ2Ugbm90IHZlcmlmaWVkLicgfQ0KICAgICRleGlzdGluZyA9IEAoR2V0LURlcGxveW1lbnRMaW5rKQ0KICAgIGlmICgkZXhpc3RpbmcuQ291bnQgLWd0IDEpIHsgdGhyb3cgJ1VuZXhwZWN0ZWQgZHVwbGljYXRlIGRlcGxveW1lbnQgbGlua3MuJyB9DQogICAgaWYgKCRleGlzdGluZy5Db3VudCAtZXEgMSAtYW5kICRleGlzdGluZ1swXS5FbmFibGVkKSB7DQogICAgICAgIFdyaXRlLUNCSVQgJ0RlcGxveW1lbnQgbGluayBhbHJlYWR5IGVuYWJsZWQ7IHZlcmlmaWVkIGFuZCB1bmNoYW5nZWQuJyBHb29kDQogICAgICAgIHJldHVybiAkdHJ1ZQ0KICAgIH0NCiAgICBXcml0ZS1DQklUICdORVhUIENPTVBVVEVSIEJPT1QgbWF5IGRlcGxveSBBY3Rpb24xIG9uIEFMTCB0YXJnZXRlZCB3b3Jrc3RhdGlvbnMsIG1lbWJlciBzZXJ2ZXJzLCBmaWxlIHNlcnZlcnMgYW5kIERDcy4nIFdhcm4NCiAgICBXcml0ZS1DQklUICdSb290IHNjb3BlIGRvZXMgbm90IGJ5cGFzcyBibG9ja2VkIGluaGVyaXRhbmNlOyBubyByZW1vdGUgc3lzdGVtIHdpbGwgYmUgcmVib290ZWQgYnkgdGhpcyB3aXphcmQuJyBXYXJuDQogICAgV3JpdGUtSG9zdCAnJw0KICAgIFdyaXRlLUNCSVQgIlJlY29tbWVuZGVkIGxpbmsgdGFyZ2V0OiBkb21haW4gcm9vdCAoJCgkc2NyaXB0OkRvbWFpbikpLiIgSGVhZGVyDQogICAgaWYgKCRzY3JpcHQ6U3RhdGUuTGlua1RhcmdldEROKSB7DQogICAgICAgIFdyaXRlLUNCSVQgIlJlc3VtaW5nIGFwcHJvdmVkIG5vbnN0YW5kYXJkIGxpbmsgdGFyZ2V0OiAkKCRzY3JpcHQ6U3RhdGUuTGlua1RhcmdldEROKSIgR29vZA0KICAgIH0gZWxzZSB7DQogICAgICAgIFdyaXRlLUNCSVQgJ1R5cGUgTElOSyB0byBhcHByb3ZlLCBTT01FVEhJTkcgRUxTRSBmb3IgYSBkaWZmZXJlbnQgT1UsIG9yIExBVEVSIHRvIHBhdXNlLicgV2Fybg0KICAgICAgICB3aGlsZSAoJHRydWUpIHsNCiAgICAgICAgICAgICRhcHByb3ZhbCA9IChSZWFkLUhvc3QgJ0FwcHJvdmFsJykuVHJpbSgpDQogICAgICAgICAgICBpZiAoJGFwcHJvdmFsIC1pZXEgJ0xJTksnIC1vciAkYXBwcm92YWwgLWllcSAnQVBQUk9WRScgLW9yICRhcHByb3ZhbCAtaWVxICgnTElOSyAnICsgJHNjcmlwdDpEb21haW4pKSB7IGJyZWFrIH0NCiAgICAgICAgICAgIGlmICgkYXBwcm92YWwgLWllcSAnTEFURVInIC1vciAkYXBwcm92YWwgLWllcSAnRVhJVCcgLW9yICRhcHByb3ZhbCAtaWVxICdDQU5DRUwnKSB7DQogICAgICAgICAgICAgICAgdGhyb3cgJ0FjdGl2YXRpb24gZGVmZXJyZWQuIFVubGlua2VkIEdQTyByZW1haW5zIHN0YWdlZC4gUmVzdW1lIGxhdGVyIHdpdGggLVJlc3VtZS4nDQogICAgICAgICAgICB9DQogICAgICAgICAgICBpZiAoJGFwcHJvdmFsIC1pZXEgJ1NPTUVUSElORyBFTFNFJykgew0KICAgICAgICAgICAgICAgIFdyaXRlLUhvc3QgJycNCiAgICAgICAgICAgICAgICBXcml0ZS1DQklUICdBIGRpZmZlcmVudCBPVSBsaW5rIGNoYW5nZXMgZGVwbG95bWVudCBjb3ZlcmFnZS4gRG9jdW1lbnQgdGhpcyBub25zdGFuZGFyZCBkZXBsb3ltZW50LicgV2Fybg0KICAgICAgICAgICAgICAgICRvdUlucHV0ID0gKFJlYWQtSG9zdCAnRW50ZXIgZXhpc3RpbmcgdGFyZ2V0IE9VIGRpc3Rpbmd1aXNoZWQgbmFtZSAob3IgQkFDSyknKS5UcmltKCkNCiAgICAgICAgICAgICAgICBpZiAoJG91SW5wdXQgLWllcSAnQkFDSycpIHsgY29udGludWUgfQ0KICAgICAgICAgICAgICAgIHRyeSB7DQogICAgICAgICAgICAgICAgICAgICRvdSA9IEdldC1BRE9yZ2FuaXphdGlvbmFsVW5pdCAtSWRlbnRpdHkgJG91SW5wdXQgLUVycm9yQWN0aW9uIFN0b3ANCiAgICAgICAgICAgICAgICAgICAgaWYgKC1ub3QgJG91LkRpc3Rpbmd1aXNoZWROYW1lLkVuZHNXaXRoKCcsJyArICRzY3JpcHQ6RG9tYWluRE4sIFtTdHJpbmdDb21wYXJpc29uXTo6T3JkaW5hbElnbm9yZUNhc2UpKSB7DQogICAgICAgICAgICAgICAgICAgICAgICBXcml0ZS1DQklUICdUaGUgdGFyZ2V0IG11c3QgYmUgYW4gT1Ugd2l0aGluIHRoZSBjdXJyZW50IGRvbWFpbi4nIFdhcm4NCiAgICAgICAgICAgICAgICAgICAgICAgIGNvbnRpbnVlDQogICAgICAgICAgICAgICAgICAgIH0NCiAgICAgICAgICAgICAgICB9IGNhdGNoIHsNCiAgICAgICAgICAgICAgICAgICAgV3JpdGUtQ0JJVCAnQ2Fubm90IHJlc29sdmUgdGhhdCBPVSBpbiB0aGlzIGRvbWFpbi4gVHJ5IFNPTUVUSElORyBFTFNFIGFnYWluLicgV2Fybg0KICAgICAgICAgICAgICAgICAgICBjb250aW51ZQ0KICAgICAgICAgICAgICAgIH0NCiAgICAgICAgICAgICAgICBXcml0ZS1DQklUICJOb25zdGFuZGFyZCBsaW5rIHRhcmdldDogJCgkb3UuRGlzdGluZ3Vpc2hlZE5hbWUpIiBXYXJuDQogICAgICAgICAgICAgICAgaWYgKC1ub3QgKENvbmZpcm0tRXhhY3QgLVByb21wdCAnUGxlYXNlIGRvY3VtZW50IHRoaXMgbm9uc3RhbmRhcmQgZGVwbG95bWVudC4gSWYgeW91IHN0aWxsIHdpc2ggdG8gcHJvY2VlZCwgY29uZmlybS4nIC1QaHJhc2UgJ1lFUycpKSB7IGNvbnRpbnVlIH0NCiAgICAgICAgICAgICAgICAkc2NyaXB0OlN0YXRlLkxpbmtUYXJnZXRETiA9ICRvdS5EaXN0aW5ndWlzaGVkTmFtZQ0KICAgICAgICAgICAgICAgIFNhdmUtQ2hlY2twb2ludCAtU3RlcCA0DQogICAgICAgICAgICAgICAgYnJlYWsNCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIFdyaXRlLUNCSVQgJ05vdCByZWNvZ25pemVkLiBUeXBlIExJTkssIFNPTUVUSElORyBFTFNFLCBvciBMQVRFUiAoY2FzZSBkb2VzIG5vdCBtYXR0ZXIpLicgV2Fybg0KICAgICAgICB9DQogICAgfQ0KICAgIFdyaXRlLUhvc3QgJycNCiAgICAkdGFyZ2V0ID0gaWYgKCRzY3JpcHQ6U3RhdGUuTGlua1RhcmdldEROKSB7IFtzdHJpbmddJHNjcmlwdDpTdGF0ZS5MaW5rVGFyZ2V0RE4gfSBlbHNlIHsgJHNjcmlwdDpEb21haW5ETiB9DQogICAgJGV4aXN0aW5nID0gQChHZXQtRGVwbG95bWVudExpbmspDQogICAgaWYgKCRleGlzdGluZy5Db3VudCAtZ3QgMSkgeyB0aHJvdyAnVW5leHBlY3RlZCBkdXBsaWNhdGUgbGlua3MgYXQgZGVwbG95bWVudCB0YXJnZXQuJyB9DQogICAgaWYgKCRleGlzdGluZy5Db3VudCAtZXEgMSkgew0KICAgICAgICBTZXQtR1BMaW5rIC1HdWlkICRzY3JpcHQ6R3BvLklkIC1UYXJnZXQgJHRhcmdldCAtRG9tYWluICRzY3JpcHQ6RG9tYWluIC1MaW5rRW5hYmxlZCBZZXMgLUVuZm9yY2VkIE5vIHwgT3V0LU51bGwNCiAgICB9IGVsc2Ugew0KICAgICAgICBOZXctR1BMaW5rIC1HdWlkICRzY3JpcHQ6R3BvLklkIC1UYXJnZXQgJHRhcmdldCAtRG9tYWluICRzY3JpcHQ6RG9tYWluIC1MaW5rRW5hYmxlZCBZZXMgLUVuZm9yY2VkIE5vIHwgT3V0LU51bGwNCiAgICB9DQogICAgJHZlcmlmeSA9IEAoR2V0LURlcGxveW1lbnRMaW5rKQ0KICAgIGlmICgkdmVyaWZ5LkNvdW50IC1uZSAxIC1vciAtbm90ICR2ZXJpZnlbMF0uRW5hYmxlZCAtb3IgJHZlcmlmeVswXS5FbmZvcmNlZCkgew0KICAgICAgICB0aHJvdyAnUG9zdC1jaGFuZ2UgZGVwbG95bWVudCBsaW5rIHZhbGlkYXRpb24gZmFpbGVkOyBpbnNwZWN0IEdQTUMuJw0KICAgIH0NCiAgICBXcml0ZS1DQklUICJEZXBsb3ltZW50IGxpbmsgZW5hYmxlZCAobm9uLWVuZm9yY2VkKSBhbmQgdmVyaWZpZWQ6ICR0YXJnZXQiIEdvb2QNCiAgICByZXR1cm4gJHRydWUNCn0NCg0KZnVuY3Rpb24gU2F2ZS1DQklURXZpZGVuY2Ugew0KICAgIFNob3ctQmFubmVyDQogICAgV3JpdGUtQ0JJVCAnU1RFUCA2ICAvICBFWFBPUlQgRVZJREVOQ0UnIEhlYWRlcg0KICAgIGlmICgtbm90ICRzY3JpcHQ6R3BvKSB7ICRzY3JpcHQ6R3BvID0gR2V0LUNCSVRHUE8gfQ0KICAgIGlmICgtbm90ICRzY3JpcHQ6R3BvKSB7IFdyaXRlLUNCSVQgJ0dQTyBub3QgeWV0IGNyZWF0ZWQ7IG5vIEdQTyByZXBvcnQgdG8gZXhwb3J0LicgV2FybjsgcmV0dXJuIH0NCiAgICAkdGltZXN0YW1wID0gR2V0LURhdGUgLUZvcm1hdCAneXl5eU1NZGQtSEhtbXNzJw0KICAgICRwcmVmaXggPSBKb2luLVBhdGggJHNjcmlwdDpBdWRpdERpciAoIkFjdGlvbjEtezB9IiAtZiAkdGltZXN0YW1wKQ0KICAgIEdldC1HUE9SZXBvcnQgLUd1aWQgJHNjcmlwdDpHcG8uSWQgLURvbWFpbiAkc2NyaXB0OkRvbWFpbiAtUmVwb3J0VHlwZSBIVE1MIC1QYXRoICgkcHJlZml4ICsgJy5odG1sJykNCiAgICBHZXQtR1BPUmVwb3J0IC1HdWlkICRzY3JpcHQ6R3BvLklkIC1Eb21haW4gJHNjcmlwdDpEb21haW4gLVJlcG9ydFR5cGUgWE1MIC1QYXRoICgkcHJlZml4ICsgJy54bWwnKQ0KICAgICRyb290TGlua3MgPSBAKEdldC1EZXBsb3ltZW50TGluaykNCiAgICAkdGFyZ2V0ID0gaWYgKCRzY3JpcHQ6U3RhdGUgLWFuZCAkc2NyaXB0OlN0YXRlLkxpbmtUYXJnZXRETikgeyBbc3RyaW5nXSRzY3JpcHQ6U3RhdGUuTGlua1RhcmdldEROIH0gZWxzZSB7ICRzY3JpcHQ6RG9tYWluRE4gfQ0KICAgICRub3RlID0gQCgNCiAgICAgICAgJ0NCSVQgQWN0aW9uMSBHUE8gLSBzbmFwc2hvdCcNCiAgICAgICAgIlRha2VuOiAkKEdldC1EYXRlIC1Gb3JtYXQgbykiDQogICAgICAgICJEb21haW46ICQoJHNjcmlwdDpEb21haW4pIg0KICAgICAgICAiR1BPOiAkKCRzY3JpcHQ6TmFtZSkiDQogICAgICAgICJHVUlEOiAkKCRzY3JpcHQ6R3BvLklkKSINCiAgICAgICAgIkluc3RhbGxlclVOQzogJCgkc2NyaXB0Okluc3RhbGxlclVOQykiDQogICAgICAgICJJbnN0YWxsZXJTSEEyNTY6ICQoJHNjcmlwdDpJbnN0YWxsZXJIYXNoKSINCiAgICAgICAgIkRlcGxveW1lbnRMaW5rVGFyZ2V0OiAkdGFyZ2V0Ig0KICAgICAgICAiRGVwbG95bWVudExpbmtzOiAkKCRyb290TGlua3MuQ291bnQpIg0KICAgICAgICAnUkVWSUVXOiBUZXN0IFNIQVJFIGFuZCBOVEZTIHJlYWQgYXMgY29tcHV0ZXIgYWNjb3VudHMgb24gZGlmZmVyZW50IGRldmljZSBjbGFzc2VzLicNCiAgICAgICAgJ1JFVklFVzogQ29uZmlybSBjb3JyZWN0IEFjdGlvbjEgb3JnYW5pemF0aW9uIGFuZCBhc3NpZ25lZCBNU0kgaW4gR1BNQy4nDQogICAgICAgICdSRVZJRVc6IEJsb2NrIGluaGVyaXRhbmNlLCBvdGhlciBmaWx0ZXJzLCBBRCByZXBsaWNhdGlvbiBhbmQgcmVib290IGRlcGVuZGVuY2llcy4nDQogICAgKQ0KICAgICRub3RlIHwgU2V0LUNvbnRlbnQgLUxpdGVyYWxQYXRoICgkcHJlZml4ICsgJy50eHQnKSAtRW5jb2RpbmcgVVRGOA0KICAgIFdyaXRlLUNCSVQgKCJTYXZlZCBldmlkZW5jZTogezB9LltodG1sfHhtbHx0eHRdIiAtZiAkcHJlZml4KSBHb29kDQp9DQoNCmZ1bmN0aW9uIERpc2FibGUtUm9vdERlcGxveW1lbnQgew0KICAgIFNob3ctQmFubmVyDQogICAgV3JpdGUtQ0JJVCAnU1RFUCA3ICAvICBFTUVSR0VOQ1kgTElOSyBESVNBQkxFIChOTyBVTklOU1RBTEwpJyBIZWFkZXINCiAgICAkc2NyaXB0OkdwbyA9IEdldC1DQklUR1BPDQogICAgaWYgKC1ub3QgJHNjcmlwdDpHcG8pIHsgV3JpdGUtQ0JJVCAnVGFyZ2V0IEdQTyBub3QgZm91bmQ7IG5vdGhpbmcgdG8gZGlzYWJsZS4nIERldGFpbDsgcmV0dXJuIH0NCiAgICAkcGF0aCA9IEpvaW4tUGF0aCAkc2NyaXB0OkF1ZGl0RGlyICgnY2hlY2twb2ludC0nICsgJHNjcmlwdDpEb21haW4gKyAnLmpzb24nKQ0KICAgIGlmIChUZXN0LVBhdGggLUxpdGVyYWxQYXRoICRwYXRoIC1QYXRoVHlwZSBMZWFmKSB7DQogICAgICAgICRzY3JpcHQ6U3RhdGUgPSBHZXQtQ29udGVudCAtTGl0ZXJhbFBhdGggJHBhdGggLVJhdyB8IENvbnZlcnRGcm9tLUpzb24NCiAgICAgICAgaWYgKC1ub3QgKCRzY3JpcHQ6U3RhdGUuUFNPYmplY3QuUHJvcGVydGllcy5OYW1lIC1jb250YWlucyAnTGlua1RhcmdldEROJykpIHsNCiAgICAgICAgICAgICRzY3JpcHQ6U3RhdGUgfCBBZGQtTWVtYmVyIC1Ob3RlUHJvcGVydHlOYW1lIExpbmtUYXJnZXRETiAtTm90ZVByb3BlcnR5VmFsdWUgJG51bGwNCiAgICAgICAgfQ0KICAgICAgICBpZiAoJHNjcmlwdDpTdGF0ZS5Eb21haW4gLWluZSAkc2NyaXB0OkRvbWFpbiAtb3IgJHNjcmlwdDpTdGF0ZS5Ib3N0IC1pbmUgJGVudjpDT01QVVRFUk5BTUUgLW9yIFtzdHJpbmddJHNjcmlwdDpTdGF0ZS5HcG9HdWlkIC1pbmUgJHNjcmlwdDpHcG8uSWQuVG9TdHJpbmcoKSkgew0KICAgICAgICAgICAgdGhyb3cgJ0NoZWNrcG9pbnQgaWRlbnRpdHkgbWlzbWF0Y2guIFJlZnVzaW5nIHRvIGRpc2FibGUgYW4gdW52ZXJpZmllZCBHUE8gbGluay4nDQogICAgICAgIH0NCiAgICB9DQogICAgJHRhcmdldCA9IGlmICgkc2NyaXB0OlN0YXRlIC1hbmQgJHNjcmlwdDpTdGF0ZS5QU09iamVjdC5Qcm9wZXJ0aWVzLk5hbWUgLWNvbnRhaW5zICdMaW5rVGFyZ2V0RE4nIC1hbmQgJHNjcmlwdDpTdGF0ZS5MaW5rVGFyZ2V0RE4pIHsgW3N0cmluZ10kc2NyaXB0OlN0YXRlLkxpbmtUYXJnZXRETiB9IGVsc2UgeyAkc2NyaXB0OkRvbWFpbkROIH0NCiAgICAkbGlua3MgPSBAKEdldC1EZXBsb3ltZW50TGluaykNCiAgICBpZiAoJGxpbmtzLkNvdW50IC1lcSAwKSB7IFdyaXRlLUNCSVQgIlRhcmdldCBHUE8gaXMgbm90IGxpbmtlZCBhdDogJHRhcmdldCIgR29vZDsgcmV0dXJuIH0NCiAgICBpZiAoJGxpbmtzLkNvdW50IC1ndCAxKSB7IHRocm93ICdVbmV4cGVjdGVkIGR1cGxpY2F0ZSBkZXBsb3ltZW50IGxpbmtzLicgfQ0KICAgIGlmICgtbm90ICRsaW5rc1swXS5FbmFibGVkKSB7IFdyaXRlLUNCSVQgJ0RlcGxveW1lbnQgbGluayBhbHJlYWR5IGRpc2FibGVkLicgR29vZDsgcmV0dXJuIH0NCiAgICBpZiAoLW5vdCAoQ29uZmlybS1FeGFjdCAtUHJvbXB0ICJEaXNhYmxlIEdQTyBsaW5rIGF0ICR0YXJnZXQ/IEluc3RhbGxlZCBhZ2VudHMgV0lMTCByZW1haW4gaW5zdGFsbGVkLiIgLVBocmFzZSAnRElTQUJMRScpKSB7IHJldHVybiB9DQogICAgU2V0LUdQTGluayAtR3VpZCAkc2NyaXB0Okdwby5JZCAtVGFyZ2V0ICR0YXJnZXQgLURvbWFpbiAkc2NyaXB0OkRvbWFpbiAtTGlua0VuYWJsZWQgTm8gfCBPdXQtTnVsbA0KICAgIFdyaXRlLUNCSVQgIkRpc2FibGVkIHRhcmdldCBHUE8gbGluayBhdCAkdGFyZ2V0LiBEaWQgbm90IGRlbGV0ZSBHUE8gb3IgdW5pbnN0YWxsIEFjdGlvbjEuIiBHb29kDQp9DQoNCmZ1bmN0aW9uIFN0YXJ0LUNCSVRBdWRpdCB7DQogICAgJHNjcmlwdDpBdWRpdERpciA9IEpvaW4tUGF0aCAkZW52OlByb2dyYW1EYXRhICdDQklUXEF1ZGl0XEFjdGlvbjEtR1BPLXYyJw0KICAgICRuZXcgPSAtbm90IChUZXN0LVBhdGggLUxpdGVyYWxQYXRoICRzY3JpcHQ6QXVkaXREaXIpDQogICAgJG51bGwgPSBOZXctSXRlbSAtUGF0aCAkc2NyaXB0OkF1ZGl0RGlyIC1JdGVtVHlwZSBEaXJlY3RvcnkgLUZvcmNlIC1FcnJvckFjdGlvbiBTdG9wDQogICAgaWYgKCRuZXcpIHsNCiAgICAgICAgJGFjbCA9IEdldC1BY2wgLUxpdGVyYWxQYXRoICRzY3JpcHQ6QXVkaXREaXINCiAgICAgICAgJGFjbC5TZXRBY2Nlc3NSdWxlUHJvdGVjdGlvbigkdHJ1ZSwgJGZhbHNlKQ0KICAgICAgICBmb3JlYWNoICgkcnVsZSBpbiBAKCRhY2wuQWNjZXNzKSkgeyBbdm9pZF0kYWNsLlJlbW92ZUFjY2Vzc1J1bGVBbGwoJHJ1bGUpIH0NCiAgICAgICAgZm9yZWFjaCAoJHNpZCBpbiBAKCdTLTEtNS0zMi01NDQnLCdTLTEtNS0xOCcpKSB7DQogICAgICAgICAgICAkaWQgPSBbU2VjdXJpdHkuUHJpbmNpcGFsLlNlY3VyaXR5SWRlbnRpZmllcl06Om5ldygkc2lkKQ0KICAgICAgICAgICAgJHJpZ2h0cyA9IFtTZWN1cml0eS5BY2Nlc3NDb250cm9sLkZpbGVTeXN0ZW1SaWdodHNdOjpGdWxsQ29udHJvbA0KICAgICAgICAgICAgJGluaGVyaXQgPSBbU2VjdXJpdHkuQWNjZXNzQ29udHJvbC5Jbmhlcml0YW5jZUZsYWdzXSdDb250YWluZXJJbmhlcml0LE9iamVjdEluaGVyaXQnDQogICAgICAgICAgICAkcnVsZSA9IFtTZWN1cml0eS5BY2Nlc3NDb250cm9sLkZpbGVTeXN0ZW1BY2Nlc3NSdWxlXTo6bmV3KCRpZCwgJHJpZ2h0cywgJGluaGVyaXQsIFtTZWN1cml0eS5BY2Nlc3NDb250cm9sLlByb3BhZ2F0aW9uRmxhZ3NdOjpOb25lLCBbU2VjdXJpdHkuQWNjZXNzQ29udHJvbC5BY2Nlc3NDb250cm9sVHlwZV06OkFsbG93KQ0KICAgICAgICAgICAgJGFjbC5BZGRBY2Nlc3NSdWxlKCRydWxlKQ0KICAgICAgICB9DQogICAgICAgIFNldC1BY2wgLUxpdGVyYWxQYXRoICRzY3JpcHQ6QXVkaXREaXIgLUFjbE9iamVjdCAkYWNsIC1FcnJvckFjdGlvbiBTdG9wDQogICAgfSBlbHNlaWYgKC1ub3QgKEdldC1BY2wgLUxpdGVyYWxQYXRoICRzY3JpcHQ6QXVkaXREaXIpLkFyZUFjY2Vzc1J1bGVzUHJvdGVjdGVkKSB7DQogICAgICAgIHRocm93ICJFeGlzdGluZyBhdWRpdCBmb2xkZXIgaGFzIGluaGVyaXRlZCBwZXJtaXNzaW9uczsgcmV2aWV3IGl0IGJlZm9yZSB3cml0aW5nIGNoZWNrcG9pbnRzOiAkKCRzY3JpcHQ6QXVkaXREaXIpIg0KICAgIH0NCiAgICAkc2NyaXB0OkF1ZGl0RGlyID0gKFJlc29sdmUtUGF0aCAtTGl0ZXJhbFBhdGggJHNjcmlwdDpBdWRpdERpcikuUGF0aA0KICAgIHRyeSB7DQogICAgICAgICRsb2cgPSBKb2luLVBhdGggJHNjcmlwdDpBdWRpdERpciAoIldpemFyZC17MH0ubG9nIiAtZiAoR2V0LURhdGUgLUZvcm1hdCAneXl5eU1NZGQtSEhtbXNzJykpDQogICAgICAgIFN0YXJ0LVRyYW5zY3JpcHQgLUxpdGVyYWxQYXRoICRsb2cgLUVycm9yQWN0aW9uIFN0b3AgfCBPdXQtTnVsbA0KICAgICAgICAkc2NyaXB0OlRyYW5zY3JpcHRTdGFydGVkID0gJHRydWUNCiAgICB9IGNhdGNoIHsgV3JpdGUtQ0JJVCAoJ1VuYWJsZSB0byBzdGFydCB0cmFuc2NyaXB0OiAnICsgJF8uRXhjZXB0aW9uLk1lc3NhZ2UpIFdhcm4gfQ0KfQ0KDQpmdW5jdGlvbiBTdGFydC1EZXBsb3ltZW50RmxvdyB7DQogICAgU2hvdy1QcmVmbGlnaHQNCiAgICBpZiAoW2ludF0kc2NyaXB0OlN0YXRlLlN0ZXAgLWx0IDEpIHsgU2F2ZS1DaGVja3BvaW50IC1TdGVwIDEgfQ0KICAgIGlmIChbaW50XSRzY3JpcHQ6U3RhdGUuU3RlcCAtbHQgMikgew0KICAgICAgICBTZXQtSW5zdGFsbGVyDQogICAgICAgIFNhdmUtQ2hlY2twb2ludCAtU3RlcCAyDQogICAgfSBlbHNlIHsNCiAgICAgICAgVGVzdC1JbnN0YWxsZXJTdGFnZQ0KICAgIH0NCiAgICBpZiAoW2ludF0kc2NyaXB0OlN0YXRlLlN0ZXAgLWx0IDMpIHsNCiAgICAgICAgTmV3LVN0YWdlZEdwbw0KICAgICAgICBTYXZlLUNoZWNrcG9pbnQgLVN0ZXAgMw0KICAgIH0gZWxzZSB7DQogICAgICAgICRzY3JpcHQ6R3BvID0gR2V0LUNCSVRHUE8NCiAgICAgICAgaWYgKC1ub3QgJHNjcmlwdDpHcG8gLW9yICRzY3JpcHQ6R3BvLklkLlRvU3RyaW5nKCkgLWluZSBbc3RyaW5nXSRzY3JpcHQ6U3RhdGUuR3BvR3VpZCkgew0KICAgICAgICAgICAgdGhyb3cgJ1NhdmVkIEdQTyBpZGVudGl0eSBub3QgZm91bmQgb3IgY2hhbmdlZC4nDQogICAgICAgIH0NCiAgICAgICAgV3JpdGUtQ0JJVCAnUHJldmlvdXNseSBjcmVhdGVkIEdQTyBHVUlEIHJldmFsaWRhdGVkLicgR29vZA0KICAgIH0NCiAgICBpZiAoW2ludF0kc2NyaXB0OlN0YXRlLlN0ZXAgLWx0IDQpIHsNCiAgICAgICAgT3Blbi1HcG1jR3VpZGUNCiAgICAgICAgU2F2ZS1DaGVja3BvaW50IC1TdGVwIDQNCiAgICB9IGVsc2Ugew0KICAgICAgICBpZiAoLW5vdCAoR2V0LVBhY2thZ2VFdmlkZW5jZSAtVGFyZ2V0R3BvICRzY3JpcHQ6R3BvKSkgeyB0aHJvdyAnUHJldmlvdXNseSBhc3NpZ25lZCBNU0kgaXMgbWlzc2luZyBvciBkaWZmZXJlbnQuJyB9DQogICAgfQ0KICAgIGlmIChbaW50XSRzY3JpcHQ6U3RhdGUuU3RlcCAtbHQgNSkgew0KICAgICAgICAkbGlua2VkID0gRW5hYmxlLVJvb3REZXBsb3ltZW50DQogICAgICAgIGlmICgtbm90ICRsaW5rZWQpIHsgdGhyb3cgJ1Jvb3QgbGluayB3YXMgbm90IGFjdGl2YXRlZC4nIH0NCiAgICAgICAgU2F2ZS1DaGVja3BvaW50IC1TdGVwIDUNCiAgICB9IGVsc2Ugew0KICAgICAgICAkbGlua3MgPSBAKEdldC1EZXBsb3ltZW50TGluaykNCiAgICAgICAgaWYgKCRsaW5rcy5Db3VudCAtbmUgMSAtb3IgLW5vdCAkbGlua3NbMF0uRW5hYmxlZCAtb3IgJGxpbmtzWzBdLkVuZm9yY2VkKSB7DQogICAgICAgICAgICB0aHJvdyAnUHJldmlvdXNseSBlbmFibGVkIGRlcGxveW1lbnQgbGluayBpcyBtaXNzaW5nLCBkaXNhYmxlZCwgb3IgdW5leHBlY3RlZGx5IGVuZm9yY2VkLiBJbnNwZWN0IEdQTUMuJw0KICAgICAgICB9DQogICAgICAgIFdyaXRlLUNCSVQgJ0RlcGxveW1lbnQtbGluayBzdGF0ZSByZXZhbGlkYXRlZC4nIEdvb2QNCiAgICB9DQogICAgU2F2ZS1DQklURXZpZGVuY2UNCiAgICBTYXZlLUNoZWNrcG9pbnQgLVN0ZXAgNg0KICAgIFdyaXRlLUNCSVQgJ0RFUExPWU1FTlQgQ09NUExFVEU6IEdQTyBsaW5rZWQgYW5kIGV2aWRlbmNlIGV4cG9ydGVkLiBFbmRwb2ludCBpbnN0YWxsYXRpb24gc3RpbGwgcmVxdWlyZXMgcG9saWN5IHByb2Nlc3NpbmcgYW5kIGNvbXB1dGVyIHN0YXJ0dXAuJyBHb29kDQogICAgV3JpdGUtSG9zdCAnJw0KICAgIFdyaXRlLUNCSVQgJ1ZhbGlkYXRlIHJlcHJlc2VudGF0aXZlIHdvcmtzdGF0aW9uLCBtZW1iZXIgc2VydmVyLCBhbmQgREMgKHBsYW5uZWQgcmVib290cyBvbmx5KSBhbmQgY29ycmVjdCBBY3Rpb24xIHRlbmFudCBlbnJvbGxtZW50LicgV2Fybg0KfQ0KDQoNCnRyeSB7DQogICAgU3RhcnQtQ0JJVEF1ZGl0DQogICAgSW5pdGlhbGl6ZS1DQklUDQogICAgSW5pdGlhbGl6ZS1QcmluY2lwYWxzDQogICAgaWYgKCgkQXVkaXRPbmx5IC1hbmQgKCRSZXN1bWUgLW9yICREaXNhYmxlUm9vdExpbmspKSAtb3IgKCRSZXN1bWUgLWFuZCAkRGlzYWJsZVJvb3RMaW5rKSkgew0KICAgICAgICB0aHJvdyAnQ2hvb3NlIG9ubHkgb25lIG9mIC1BdWRpdE9ubHksIC1SZXN1bWUsIG9yIC1EaXNhYmxlUm9vdExpbmsuJw0KICAgIH0NCiAgICBpZiAoJEF1ZGl0T25seSkgew0KICAgICAgICBTaG93LVByZWZsaWdodA0KICAgIH0gZWxzZWlmICgkRGlzYWJsZVJvb3RMaW5rKSB7DQogICAgICAgIERpc2FibGUtUm9vdERlcGxveW1lbnQNCiAgICB9IGVsc2Ugew0KICAgICAgICAjIE5vcm1hbCBleGVjdXRpb24gaXMgYWx3YXlzIHNlcXVlbnRpYWw7IG5vIG1lbnUgb3Igb3B0aW9uIHNlbGVjdGlvbi4NCiAgICAgICAgSW5pdGlhbGl6ZS1DaGVja3BvaW50DQogICAgICAgIFN0YXJ0LURlcGxveW1lbnRGbG93DQogICAgfQ0KfSBjYXRjaCB7DQogICAgJG1lc3NhZ2UgPSAkXy5FeGNlcHRpb24uTWVzc2FnZQ0KICAgICRwYXVzZWQgPSAoJG1lc3NhZ2UgLWxpa2UgJ0FjdGl2YXRpb24gZGVmZXJyZWQuKicgLW9yICRtZXNzYWdlIC1saWtlICdQYXVzZWQgYmVmb3JlIHBhY2thZ2UgYXNzaWdubWVudC4qJykNCiAgICBpZiAoJHBhdXNlZCkgew0KICAgICAgICBXcml0ZS1DQklUICgiUEFVU0VEOiAkbWVzc2FnZSIpIFdhcm4NCiAgICB9IGVsc2Ugew0KICAgICAgICBXcml0ZS1DQklUICgiU1RPUFBFRDogJG1lc3NhZ2UiKSBCYWQNCiAgICB9DQogICAgaWYgKCRzY3JpcHQ6U3RhdGVGaWxlKSB7IFdyaXRlLUNCSVQgIlRvIHJlc3VtZTogLlxEZXBsb3ktQ0JJVEFjdGlvbjFHUE8ucHMxIC1SZXN1bWUgKGNoZWNrcG9pbnQ6ICQoJHNjcmlwdDpTdGF0ZUZpbGUpKSIgV2FybiB9DQogICAgaWYgKC1ub3QgJHBhdXNlZCkgeyBleGl0IDEgfQ0KfSBmaW5hbGx5IHsNCiAgICBpZiAoJHNjcmlwdDpUcmFuc2NyaXB0U3RhcnRlZCkgeyB0cnkgeyBTdG9wLVRyYW5zY3JpcHQgfCBPdXQtTnVsbCB9IGNhdGNoIHt9IH0NCn0NCg=='
function Invoke-CBITAction1Deployment {
    [CmdletBinding()]
    param([switch]$Resume,[switch]$AuditOnly,[switch]$DisableRootLink)
    if(([int]$Resume.IsPresent+[int]$AuditOnly.IsPresent+[int]$DisableRootLink.IsPresent) -gt 1){throw 'Choose only one Action1 mode.'}
    $e=Get-CBITEnvironment
    $dir=Join-Path $script:CBITLogRoot 'Action1'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file=Join-Path $dir 'Deploy-CBITAction1GPO.ps1'
    [IO.File]::WriteAllBytes($file,[Convert]::FromBase64String($script:CBITAction1SourceBase64))
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$file)
    if($Resume){$args+='-Resume'}
    if($AuditOnly){$args+='-AuditOnly'}
    if($DisableRootLink){$args+='-DisableRootLink'}
    & powershell.exe @args | Out-Host
    $runExit=$LASTEXITCODE
    $audit=Join-Path $env:ProgramData 'CBIT\Audit\Action1-GPO-v2'
    $checkpoint=Join-Path $audit ('checkpoint-'+$e.Domain+'.json')
    if($runExit){throw "Action1 failed (exit $runExit). Review $audit; select menu 6 to resume."}
    $status='Incomplete; review wizard output';$detail='Completion is not confirmed.'
    if($AuditOnly){$status='Audit finished';$detail='Read-only assessment; local audit evidence saved.'}
    elseif($DisableRootLink){$status='Link-disable review finished';$detail='Review wizard output for disabled, absent, already disabled, or declined link. Agents remain installed.'}
    elseif(Test-Path -LiteralPath $checkpoint -PathType Leaf){
        $state=Get-Content -LiteralPath $checkpoint -Raw | ConvertFrom-Json
        if($state.Domain -ine $e.Domain -or $state.Host -ine $env:COMPUTERNAME){throw 'Action1 checkpoint domain/host mismatch.'}
        if([int]$state.Step -ge 6){$status='Configured; endpoint validation pending';$detail='Assigned MSI policy linked and evidence exported; installation requires policy processing and startup.'}
        else{$status='Paused; resume required';$detail='Checkpoint step '+$state.Step+'; select menu 6 to resume.'}
    }
    [pscustomobject]@{Policy='Action1';Status=$status;Detail=$detail;LogPath=$audit;CheckpointPath=$checkpoint;FollowUps=@('Review Action1 evidence: '+$audit;'Confirm correct Action1 organization and representative endpoint installation; planned reboots only.')}
}

function Get-CBITStackPath {
    param($Environment)
    Join-Path (Join-Path $env:ProgramData 'CBIT\Deployment') ('stack-'+$Environment.Domain+'-'+$env:COMPUTERNAME+'.json')
}
function Save-CBITStack {
    param($State,[string]$Path)
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    $State.Updated=(Get-Date -Format o)
    $temp=$Path+'.tmp'
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Get-CBITPolicyReportSignature {
    param([xml]$Report)
    $nodes=New-Object 'System.Collections.Generic.List[string]'
    $nodes.Add($Report.GPO.Computer.OuterXml);$nodes.Add($Report.GPO.User.OuterXml)
    foreach($link in @($Report.GPO.LinksTo)){$nodes.Add($link.OuterXml)}
    $nodes.Add($Report.GPO.SecurityDescriptor.OuterXml)
    $nodes -join "`n"
}
function Get-CBITStackFingerprint {
    param($Environment,[string]$Policy)
    $name=switch($Policy){'Axis'{'CBIT MSP - Axis'}'SentinelOne'{'CBIT MSP - SentinelOne'}'Action1'{'CBIT MSP - Action1'}'CyberQP'{'CBIT MSP - Endpoint Admin'}}
    $gpos=@(Get-GPO -All -Domain $Environment.Domain -Server $Environment.Server -ErrorAction Stop | Where-Object DisplayName -eq $name)
    if($gpos.Count -ne 1){throw 'Previously completed policy is missing or ambiguous.'}
    [xml]$report=Get-GPOReport -Guid $gpos[0].Id -Domain $Environment.Domain -Server $Environment.Server -ReportType Xml -ErrorAction Stop
    $parts=New-Object 'System.Collections.Generic.List[string]'
    $parts.Add($gpos[0].Id.ToString());$parts.Add((Get-CBITPolicyReportSignature $report))
    if($Policy -in 'Axis','SentinelOne','Action1'){
        $root=switch($Policy){'Axis'{'C:\CBIT\AXISdeploy'}'SentinelOne'{'C:\CBIT\S1deploy'}'Action1'{'C:\CBIT\Action1-deploy'}}
        if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'Deployment payload folder is missing.'}
        if($Policy -eq 'SentinelOne'){
            $manifest=Get-Content -LiteralPath (Join-Path $root 'Share\manifest.json') -Raw | ConvertFrom-Json
            if([IO.Path]::GetFileName($manifest.fileName) -cne $manifest.fileName){throw 'Invalid S1 package filename.'}
            if((Get-FileHash -LiteralPath (Join-Path (Join-Path $root 'Share') $manifest.fileName) -Algorithm SHA1).Hash -ine $manifest.sha1){throw 'S1 package integrity check failed.'}
        }
        foreach($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName)){
            # Sync.log changes on every daily download and is not policy configuration.
            if($file.Name -eq 'Sync.log'){continue}
            # Valid daily package refreshes are expected; retain configuration, not package version.
            if($Policy -eq 'SentinelOne' -and $file.DirectoryName -ieq (Join-Path $root 'Share')){continue}
            $parts.Add($file.FullName+':'+(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
            $parts.Add((Get-Acl -LiteralPath $file.FullName).Sddl)
        }
        $shareName=switch($Policy){'Axis'{'AXISdeploy$'}'SentinelOne'{'S1deploy$'}'Action1'{'Action1-deploy$'}}
        $share=Get-SmbShare -Name $shareName -ErrorAction Stop
        $expected=if($Policy -eq 'SentinelOne'){Join-Path $root 'Share'}else{$root}
        if($share.Path -ine $expected){throw 'Deployment share points to an unexpected folder.'}
        $parts.Add(($share | Select-Object Name,Path,FolderEnumerationMode | ConvertTo-Json -Compress))
        $parts.Add((@(Get-SmbShareAccess -Name $shareName | Sort-Object AccountName,AccessRight) | Select-Object AccountName,AccessControlType,AccessRight | ConvertTo-Json -Compress))
        $parts.Add((Get-Acl -LiteralPath $root).Sddl)
        if($Policy -eq 'SentinelOne'){$parts.Add((Get-Acl -LiteralPath (Join-Path $root 'Share')).Sddl)}
        if($Policy -eq 'SentinelOne'){$parts.Add((Export-ScheduledTask -TaskName 'CBIT - SentinelOne Package Sync' -TaskPath '\'))}
    }
    if($Policy -eq 'CyberQP'){
        foreach($sam in 'CBIT','CBIT-DA'){
            $user=Get-ADUser -Identity $sam -Server $Environment.Server -Properties Enabled,MemberOf,PasswordNeverExpires,CannotChangePassword -ErrorAction Stop
            $parts.Add(($user | Select-Object SamAccountName,ObjectGUID,Enabled,PasswordNeverExpires,CannotChangePassword,@{n='MemberOf';e={@($_.MemberOf | Sort-Object)}} | ConvertTo-Json -Compress))
        }
        $group=Get-ADGroup -Identity 'CBIT-Endpoint-Admins' -Server $Environment.Server -Properties Members,MemberOf -ErrorAction Stop
        $parts.Add(($group | Select-Object ObjectGUID,GroupScope,GroupCategory,@{n='Members';e={@($_.Members | Sort-Object)}},@{n='MemberOf';e={@($_.MemberOf | Sort-Object)}} | ConvertTo-Json -Compress))
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))))).Replace('-','')}finally{$sha.Dispose()}
}
function New-CBITStack {
    param($Environment,[string[]]$Items)
    [pscustomobject]@{Version=1;Domain=$Environment.Domain;Host=$env:COMPUTERNAME;Items=$Items;Steps=@();
        LogRoot=$script:CBITLogRoot;ReportRoot=$script:CBITReportRoot;Updated='';Completed=$false}
}
function Import-CBITPreviousStack {
    param($Environment,[string[]]$Items)
    # Explicitly selected legacy summary; only matching verification reports can seed skips.
    $path=(Read-Host 'No stack checkpoint found. Paste the prior DeploymentSummary.json path, or Enter to start new').Trim().Trim('"')
    if(-not $path){return $null}
    $rows=Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
    $state=New-CBITStack $Environment $Items
    $state.ReportRoot=Split-Path $path
    $state.LogRoot=Join-Path (Split-Path $state.ReportRoot) 'logs'
    $prefix=[IO.Path]::GetFileName($path).Split('-')[0]
    foreach($row in $rows){
        if($row.Policy -notin 'Axis','SentinelOne' -or $row.Status -notmatch '^(Successfully configured and verified|Changed and successfully verified|Already correctly configured)$'){continue}
        $evidence=@(Get-ChildItem -LiteralPath $state.ReportRoot -Filter ($prefix+'-*.json') -File | ForEach-Object {
            $data=Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
            if($data.PSObject.Properties['Policy'] -and $data.Policy -eq $row.Policy -and $data.PSObject.Properties['Checks'] -and -not @($data.Checks.PSObject.Properties | Where-Object {-not $_.Value}).Count){[pscustomobject]@{Data=$data;Path=$_.FullName}}
        })
        if($evidence.Count -ne 1){Write-Warning ($row.Policy+': matching verification evidence unavailable; will rerun.');continue}
        try{
            [xml]$saved=Get-Content -LiteralPath ([IO.Path]::ChangeExtension($evidence[0].Path,'.xml')) -Raw
            [xml]$live=Get-GPOReport -Guid $evidence[0].Data.Id -Domain $Environment.Domain -Server $Environment.Server -ReportType Xml -ErrorAction Stop
            if((Get-CBITPolicyReportSignature $saved) -cne (Get-CBITPolicyReportSignature $live)){throw 'Policy settings or links differ from verified report.'}
            if($row.Policy -eq 'Axis'){
                $payload=Get-Content -LiteralPath (Join-Path $state.ReportRoot ($prefix+'-AxisPayload.json')) -Raw | ConvertFrom-Json
                $actual=@(Get-CBITAxisManifest -Path 'C:\CBIT\AXISdeploy')
                if(@(Compare-Object @($payload.Files) $actual -Property RelativePath,Length,SHA256).Count){throw 'Axis payload differs from verified files.'}
            }else{
                $shareRoot='C:\CBIT\S1deploy\Share'
                $manifest=Get-Content -LiteralPath (Join-Path $shareRoot 'manifest.json') -Raw | ConvertFrom-Json
                if([IO.Path]::GetFileName($manifest.fileName) -cne $manifest.fileName){throw 'Invalid S1 manifest filename.'}
                if((Get-FileHash -LiteralPath (Join-Path $shareRoot $manifest.fileName) -Algorithm SHA1).Hash -ine $manifest.sha1){throw 'S1 package differs from its verified manifest.'}
            }
            $fingerprint=Get-CBITStackFingerprint $Environment $row.Policy
            $item=if($row.Policy -eq 'Axis'){'1'}else{'3'}
            $state.Steps+= [pscustomobject]@{Item=$item;Policy=$row.Policy;Complete=$true;Fingerprint=$fingerprint;Outcome=$row;Attempted=$true}
        }catch{Write-Warning ($row.Policy+': prior verification cannot be reused; will rerun.')}
    }
    return $state
}
function Initialize-CBITStackPlan {
    param($Environment,[string[]]$Items,[switch]$ForceResume)
    $path=Get-CBITStackPath $Environment
    $state=$null
    if(Test-Path -LiteralPath $path){
        $state=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if($state.Version -ne 1 -or $state.Domain -ine $Environment.Domain -or $state.Host -ine $env:COMPUTERNAME){throw 'Stack checkpoint identity/version mismatch.'}
        if(($state.Items -join ',') -ne ($Items -join ',')){
            if($ForceResume){throw 'Saved checkpoint plan mismatch.'}
            Copy-Item -LiteralPath $path -Destination ($path+'.previous-'+(Get-Date -Format yyyyMMdd-HHmmssfff))
            $state=$null
        }
    }elseif($ForceResume){$state=Import-CBITPreviousStack $Environment $Items}
    $resume=$false
    if($state){
        foreach($step in $state.Steps){Write-CBITConsole ($step.Policy+': '+$(if($step.Complete){'previously completed'}else{'unfinished'})) -ForegroundColor Gray}
        if($ForceResume){$resume=$true}else{
            do{$answer=(Read-Host 'Saved deployment: Enter = resume unfinished; all = rerun selected plan; cancel = back').Trim()}while($answer -notin '','all','cancel')
            if($answer -eq 'cancel'){return $null};$resume=$answer -ne 'all'
        }
    }
    if(-not $resume){
        if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination ($path+'.previous-'+(Get-Date -Format yyyyMMdd-HHmmssfff))}
        $state=New-CBITStack $Environment $Items
    }
    $pending=New-Object 'System.Collections.Generic.List[string]'
    foreach($item in $Items){
        $step=@($state.Steps | Where-Object Item -eq $item)
        if($resume -and $step.Count -eq 1 -and $step[0].Complete){
            try{
                if((Get-CBITStackFingerprint $Environment $step[0].Policy) -cne $step[0].Fingerprint){throw 'Configuration changed'}
                Write-CBITConsole ($step[0].Policy+': verified unchanged; skipping completed step.') -ForegroundColor DarkGreen
                continue
            }catch{Write-Warning ($step[0].Policy+': configuration changed or could not be checked; this step will rerun.')}
        }
        $pending.Add($item)
    }
    Save-CBITStack $state $path
    [pscustomobject]@{State=$state;Path=$path;Pending=@($pending);Resume=$resume}
}
function Export-CBITGpoStatus {
    param($Environment,[string]$OutputRoot='C:\CBIT\Logs\GPO')
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('# CBIT GPO status');$lines.Add('')
    $lines.Add('Domain: '+$Environment.Domain);$lines.Add('Host: '+$env:COMPUTERNAME)
    $lines.Add('Checked: '+(Get-Date -Format o));$lines.Add('')
    $lines.Add('| Policy | GPO | Status | Links |');$lines.Add('| --- | --- | --- | --- |')
    $names=[ordered]@{Action1='CBIT MSP - Action1';Axis='CBIT MSP - Axis';CyberQP='CBIT MSP - Endpoint Admin';SentinelOne='CBIT MSP - SentinelOne'}
    $gpos=@(Get-GPO -All -Domain $Environment.Domain -Server $Environment.Server -ErrorAction Stop)
    foreach($policy in $names.Keys){
        $matches=@($gpos | Where-Object DisplayName -eq $names[$policy])
        if(-not $matches.Count){$lines.Add('| '+$policy+' | '+$names[$policy]+' | Absent | — |');continue}
        if($matches.Count -gt 1){$lines.Add('| '+$policy+' | '+$names[$policy]+' | Ambiguous: '+$matches.Count+' matches | Review required |');continue}
        [xml]$xml=Get-GPOReport -Guid $matches[0].Id -Domain $Environment.Domain -Server $Environment.Server -ReportType Xml -ErrorAction Stop
        $links=@($xml.GPO.LinksTo | ForEach-Object {
            ($_.SOMPath+' (enabled: '+$_.Enabled+', enforced: '+$_.NoOverride+')').Replace('|','\|').Replace("`r",' ').Replace("`n",' ')
        }) -join '<br>'
        if(-not $links){$links='Unlinked'}
        $lines.Add('| '+$policy+' | '+$names[$policy]+' | '+$matches[0].GpoStatus+' | '+$links+' |')
    }
    $lines.Add('');$lines.Add('This is current AD policy/link status. It does not confirm agent installation or endpoint policy processing.')
    $checkpoint=Get-CBITStackPath $Environment
    if(Test-Path -LiteralPath $checkpoint){
        $saved=Get-Content -LiteralPath $checkpoint -Raw | ConvertFrom-Json
        if($saved.Domain -ieq $Environment.Domain -and $saved.Host -ieq $env:COMPUTERNAME){
            $lines.Add('');$lines.Add('## Last deployment checkpoint');$lines.Add('')
            foreach($step in $saved.Steps){
                $lines.Add('- '+$step.Policy+': '+$step.Outcome.Status)
            }
            $lines.Add('');$lines.Add('Checkpoint outcomes are historical; the table above reflects current AD status.')
        }
    }
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $path=Join-Path $OutputRoot ('CBIT-GPO-Status-'+(Get-Date -Format yyyyMMdd-HHmmssfff)+'.md')
    $lines | Set-Content -LiteralPath $path -Encoding UTF8
    Write-CBITConsole ('GPO status exported: '+$path) -ForegroundColor DarkGreen
    return $path
}
function Update-CBITStackStep {
    param($Plan,[string]$Item,$Outcome,$Environment)
    $complete=$Outcome.Status -match '^(Successfully configured and verified|Changed and successfully verified|Already correctly configured|Configured;|Completed;)'
    $fingerprint=$null
    if($complete){
        try{$fingerprint=Get-CBITStackFingerprint $Environment $Outcome.Policy}
        catch{$complete=$false;Write-Warning ($Outcome.Policy+': checkpoint verification unavailable; resume will recheck this step.')}
    }
    $Plan.State.Steps=@($Plan.State.Steps | Where-Object Item -ne $Item)+@([pscustomobject]@{
        Item=$Item;Policy=$Outcome.Policy;Complete=$complete;Fingerprint=$fingerprint;Outcome=$Outcome;Attempted=$true})
    $Plan.State.Completed=(@($Plan.State.Steps | Where-Object Complete).Count -eq $Plan.State.Items.Count)
    Save-CBITStack $Plan.State $Plan.Path
}

function Start-CBITMenu {
    Show-CBITPreamble
    $e=Get-CBITEnvironment
    while($true){
        Write-CBITConsole "`nCBIT deployment: $($e.Domain) / $($e.Server)" -ForegroundColor Gray
        if($script:CBITResumeRequested){$selection='6';$script:CBITResumeRequested=$false}else{$selection=Select-CBITDeploymentMenu}
        if($selection -notmatch '^(0|1|2|3|4|5|6|7|8|9|r|5\s+-resume)$'){Write-Warning 'Select 0-9.';continue}
        $forceResume=$selection -match '^(6|r|5\s+-resume)$'
        $choice=switch($selection){'1'{'7'}'2'{'1'}'3'{'2'}'4'{'3'}'5'{'9'}'6'{'r'}'7'{'export'}'8'{'8'}'9'{'5'}'0'{'0'}default{$selection}}
        if($choice -eq 'export'){
            try{$null=Export-CBITGpoStatus $e}catch{Write-Warning ('Status export failed: '+$_.Exception.Message)}
            continue
        }
        if($forceResume){
            $savedPath=Get-CBITStackPath $e
            $choice=if(Test-Path -LiteralPath $savedPath){
                $savedPlan=Get-Content -LiteralPath $savedPath -Raw | ConvertFrom-Json
                if(@($savedPlan.Items).Count -eq 1){[string]$savedPlan.Items[0]}elseif(@($savedPlan.Items) -contains '7'){'9'}else{'4'}
            }else{'9'}
        }
        if($choice -eq '0'){return}
        if($choice -in '5','8'){
            if($choice -eq '8'){
                $mode=(Read-Host 'Action1: resume, audit (read-only), or disable (explicit link confirmation)').Trim()
                if($mode -notin 'resume','audit','disable'){Write-Warning 'Select resume, audit, or disable.';continue}
                try{$modeResult=switch($mode){'resume'{Invoke-CBITAction1Deployment -Resume}'audit'{Invoke-CBITAction1Deployment -AuditOnly}'disable'{Invoke-CBITAction1Deployment -DisableRootLink}}}
                catch{$modeResult=[pscustomobject]@{Policy='Action1';Status='Failed';Detail=$_.Exception.Message}}
            } else {
            $mode=(Read-Host 'CyberQP: resume = continue saved run; rollback = review/reverse saved changes; dryrun = inspect without changes').Trim()
            if($mode -notin 'resume','rollback','dryrun'){Write-Warning 'Select resume, rollback, or dryrun.';continue}
            try {
                $modeResult=switch($mode){
                    'resume'{Invoke-CBITPrivilegedAccessRunbook -Resume}
                    'rollback'{Invoke-CBITPrivilegedAccessRunbook -Rollback}
                    'dryrun'{Invoke-CBITPrivilegedAccessRunbook -DryRun}
                }
            } catch{$modeResult=[pscustomobject]@{Policy='CyberQP';Status='Failed';Detail=$_.Exception.Message}}
            }
            New-Item -ItemType Directory -Path $script:CBITReportRoot -Force | Out-Null
            $summaryPath=Join-Path $script:CBITReportRoot ($script:CBITRunId+'-'+(Get-Date -Format 'HHmmssfff')+'-DeploymentSummary.json')
            $modeResult | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
            if(Show-CBITCompletion -Outcomes @($modeResult) -Domain $e.Domain -SummaryPath $summaryPath){return}
            continue
        }
        if($choice -notin '1','2','3','4','7','9'){Write-Warning 'Select 0-9.';continue}
        # The guided account/OU workflow runs after the two installer policies.
        $items=if($choice -eq '4'){@('1','3','2')}elseif($choice -eq '9'){@('1','3','7','2')}else{@($choice)}
        $endpointTargets=@();$password=$null;$site=$null;$siteSelection=$null;$staging=$null
        $outcomes=New-Object 'System.Collections.Generic.List[object]'
        $stackPlan=$null
        try {
            if($choice -in '1','2','3','4','7','9'){
                $stackPlan=Initialize-CBITStackPlan $e $items -ForceResume:$forceResume
                if($null -eq $stackPlan){continue}
                $script:CBITLogRoot=$stackPlan.State.LogRoot
                $script:CBITReportRoot=$stackPlan.State.ReportRoot
                $items=@($stackPlan.Pending)
                foreach($step in $stackPlan.State.Steps){if($step.Item -notin $items -and $step.Complete){$outcomes.Add($step.Outcome)}}
                if(-not $items.Count){Write-CBITConsole 'All stack steps are already configured and unchanged. Choose rerun all to repeat them.' -ForegroundColor DarkGreen}
            }
            if($items -contains '1'){
                $kits=@(Get-ChildItem -LiteralPath 'C:\CBIT' -Directory -Force -ErrorAction SilentlyContinue | Where-Object Name -like 'CBITAgent-*-Setup')
                if($kits.Count -eq 1){$staging=$kits[0].FullName}
                elseif($kits.Count -gt 1){
                    Write-CBITConsole 'Multiple Axis kits are staged. Select THIS customer tenant.' -ForegroundColor DarkYellow
                    for($i=0;$i -lt $kits.Count;$i++){Write-CBITConsole ('{0}. {1}' -f ($i+1),$kits[$i].FullName) -ForegroundColor DarkGray}
                    $number=0
                    if(-not [int]::TryParse((Read-Host 'Axis tenant kit: select the numbered staging folder for THIS customer'),[ref]$number) -or $number -lt 1 -or $number -gt $kits.Count){throw 'Invalid kit selection; no deployments started.'}
                    $staging=$kits[$number-1].FullName
                }
                $kitPath=if($staging){$staging}else{'C:\CBIT\AXISdeploy'}
                $manifest=@(Get-CBITAxisManifest $kitPath)
                Write-CBITConsole ('Axis kit: '+$kitPath) -ForegroundColor Gray
                $manifest | Select-Object RelativePath,Length | Format-Table -AutoSize | Out-Host
                if($staging){Write-CBITConsole 'This staging folder will be deleted only after the protected destination is hash-verified.' -ForegroundColor DarkYellow}
                else{Write-CBITConsole 'Using the existing deployed kit; confirm its tenant against the AXIS portal.' -ForegroundColor DarkYellow}
            }
            if($items -contains '6'){
                $account=Get-ADUser -Filter 'SamAccountName -eq "CBIT"' -Server $e.Server -Properties Enabled
                if($account -and ($account.Name -ne 'CBIT-Elevation' -or -not $account.Enabled)){
                    throw 'Existing CBIT needs a specific account decision. Select 2 (CyberQP guided), which inspects the legacy identity and recovery path. No account was renamed/reset.'
                }
                $ous=@(Get-ADOrganizationalUnit -Filter * -Server $e.Server | Sort-Object DistinguishedName)
                Write-CBITConsole 'Advanced endpoint GPO scope: choose only confirmed workstation OUs. Blank configures without linking.' -ForegroundColor DarkYellow
                for($i=0;$i -lt $ous.Count;$i++){Write-CBITConsole ('{0}. {1}' -f ($i+1),$ous[$i].DistinguishedName) -ForegroundColor DarkGray}
                $selection=(Read-Host 'CyberQP local-admin policy: select workstation OU numbers (comma-separated) or paste one OU DN; blank = no link').Trim()
                if($selection -match '^\d+(\s*,\s*\d+)*$'){
                    foreach($number in ($selection -split ',')){
                        $index=[int]$number-1
                        if($index -lt 0 -or $index -ge $ous.Count){throw "OU selection outside list: $number"}
                        $endpointTargets+=$ous[$index].DistinguishedName
                    }
                    $endpointTargets=@($endpointTargets | Select-Object -Unique)
                } elseif($selection){$endpointTargets=@($selection)}
                Assert-CBITTargets $e $endpointTargets -WorkstationsOnly
                if(-not $account){$password=Read-Host 'New CBIT-Elevation password (prestage in management-only IT Glue)' -AsSecureString}
            }
            if($items -contains '3'){
                if (-not $script:CBITDefaultApiToken) { $script:CBITDefaultApiToken = Unlock-CBITS1Credential -Path $script:CBITCredentialPath }
                $siteSelection=Select-CBITS1Customer -Domain $e.Domain
                if($null -eq $siteSelection){return}
                $site=$siteSelection.Token
            }
            Write-CBITConsole "`nDeployment plan - confirm this is the correct customer environment" -ForegroundColor Gray
            Write-CBITConsole ('Domain: '+$e.Domain+'; policy DC: '+$e.Server+'; package host: '+$env:COMPUTERNAME) -ForegroundColor Gray
            if($items -contains '1'){
                Write-CBITConsole 'Axis: prepare and verify machine-only AXISdeploy$ payload; root link enabled, not enforced.' -ForegroundColor DarkYellow
            }
            if($items -contains '3'){
                Write-CBITConsole ('SentinelOne customer: '+$siteSelection.Name) -ForegroundColor Gray
                Write-CBITConsole 'SentinelOne: package sync + daily task; root link enabled and enforced for workstations, servers and DCs.' -ForegroundColor DarkYellow
            }
            if($items -contains '2'){
                Write-CBITConsole 'CyberQP: guided recovery/account/legacy conflict and workstation OU decisions, automated verified endpoint GPO, gated links and workstation validation.' -ForegroundColor DarkYellow
                Write-CBITConsole 'Have both IT Glue credentials ready. Renames, workstation moves, OU creation, redirection and RID-500 disablement retain their individual confirmations.' -ForegroundColor DarkGray
            }
            if($items -contains '7'){Write-CBITConsole 'Action1: protected MSI staging, guided GPMC assignment, explicit non-enforced root/custom OU activation; no automatic reboot.' -ForegroundColor DarkYellow}
            if($items -contains '6'){
                $scope=if($endpointTargets.Count){$endpointTargets -join '; '}else{'Unlinked; configuration only'}
                Write-CBITConsole ('Advanced endpoint GPO: '+$scope+'; no full privileged-access setup.') -ForegroundColor DarkYellow
            }
            Write-CBITConsole 'No tenant key/customer.ini contents are displayed. Existing GPOs are backed up before relevant edits.' -ForegroundColor DarkGray
            if((Read-Host 'Confirm customer/tenant and deploy this plan? [y/N]') -notmatch '^(y|yes)$'){continue}
            foreach($item in $items){
                if($stackPlan){
                    # Persist before launching a child: interruption still leaves a resumable stack.
                    Save-CBITStack $stackPlan.State $stackPlan.Path
                }
                $label=switch($item){'1'{'Axis'}'2'{'CyberQP'}'3'{'SentinelOne'}'6'{'Endpoint GPO only'}'7'{'Action1'}}
                try {
                    $result=switch($item){
                        '1'{Invoke-CBITAxisDeployment -StagingPath $staging -ApproveChanges}
                        '2'{
                            $open=@()
                            if($stackPlan -and $stackPlan.Resume){$open=@(Get-ChildItem -LiteralPath (Join-Path $script:CBITLogRoot 'CyberQP') -Filter state.json -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                                $child=Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                                $child.DomainDNS -ieq $e.Domain -and -not $child.Completed -and -not $child.DryRun
                            })}
                            Invoke-CBITPrivilegedAccessRunbook -Resume:($null -ne $stackPlan -and $stackPlan.Resume -and $open.Count -gt 0)
                        }
                        '3'{Invoke-CBITSentinelOneDeployment -SiteToken $site -ConsoleUrl $siteSelection.ConsoleUrl -ApproveChanges}
                        '7'{
                            $checkpoint=Join-Path $env:ProgramData ('CBIT\Audit\Action1-GPO-v2\checkpoint-'+$e.Domain+'.json')
                            Invoke-CBITAction1Deployment -Resume:(Test-Path -LiteralPath $checkpoint)
                        }
                        '6'{Invoke-CBITEndpointDeployment -TargetDn $endpointTargets -NewAccountPassword $password -ApproveChanges}
                    }
                    if($result){$result | Format-List | Out-Host}
                    $status=if($result -and $result.PSObject.Properties['Status']){$result.Status}elseif($item -eq '2'){'Guided workflow returned; review its summary and pending validation'}else{'Operation returned; review verification reports'}
                    $outcomes.Add([pscustomobject]@{Policy=$label;Status=$status;Detail=$(if($item -eq '3'){'Customer: '+$siteSelection.Name+'; domain-root policy.'}elseif($result -and $result.PSObject.Properties['Detail']){$result.Detail});SiteName=$(if($item -eq '3'){$siteSelection.Name});SiteId=$(if($item -eq '3'){$siteSelection.Id});TokenSource=$(if($item -eq '3'){$siteSelection.Source});FollowUps=$(if($result -and $result.PSObject.Properties['FollowUps']){@($result.FollowUps)}else{@()})})
                } catch {
                    Write-Warning ($label+': '+$_.Exception.Message)
                    $outcomes.Add([pscustomobject]@{Policy=$label;Status='Failed';Detail=$_.Exception.Message;SiteName=$(if($item -eq '3'){$siteSelection.Name});SiteId=$(if($item -eq '3'){$siteSelection.Id});TokenSource=$(if($item -eq '3'){$siteSelection.Source})})
                }
                if($stackPlan){Update-CBITStackStep $stackPlan $item $outcomes[$outcomes.Count-1] $e}
            }
            New-Item -ItemType Directory -Path $script:CBITReportRoot -Force | Out-Null
            $summaryPath=Join-Path $script:CBITReportRoot ($script:CBITRunId+'-'+(Get-Date -Format 'HHmmssfff')+'-DeploymentSummary.json')
            $outcomes | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
            if($stackPlan){Write-CBITConsole ('Resume: select 6, or run this script with -Resume. Checkpoint: '+$stackPlan.Path) -ForegroundColor Gray}
            if(Show-CBITCompletion -Outcomes @($outcomes.ToArray()) -Domain $e.Domain -SummaryPath $summaryPath){return}
        } catch{Write-Warning $_.Exception.Message}
        finally{$password=$null;$site=$null;$siteSelection=$null;$raw=$null;$b64=$null;$decoded=$null}
    }
}
$script:CBITResumeRequested=$Resume.IsPresent
if(-not $FunctionsOnly){
    try { Start-CBITMenu }
    finally { if ($script:CBITDefaultApiToken) { $script:CBITDefaultApiToken.Dispose(); $script:CBITDefaultApiToken=$null } }
}
