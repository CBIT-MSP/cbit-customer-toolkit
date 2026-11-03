function Show-TechMenu {
    <#
    .SYNOPSIS
        Interactive technician menu with arrow key navigation
    
    .DESCRIPTION
        Displays a multi-column, keyboard-navigable menu for common IT tasks.
        Use arrow keys to highlight options, letter keys or Enter to open a
        tool, F1 or ? for help, and Q to quit.
        
        Automatically organizes menu items into columns based on terminal width.
        Easily extensible - just add new items to the $menuItems array.
    
    .PARAMETER Columns
        Number of columns to display (default: auto-detect based on terminal width)
    
    .EXAMPLE
        Show-TechMenu
        Display interactive menu
    
    .EXAMPLE
        tech
        Using alias to launch menu
    #>
    
    [CmdletBinding()]
    param(
        [int]$Columns = 0,  # 0 = auto-detect
        [Parameter(DontShow)][switch]$ValidateOnly
    )
    $defaultRunTimeoutSeconds = 8
    
    # ══════════════════════════════════════════════════════════════════════════
    # Menu Configuration - ADD NEW ITEMS HERE
    # Every item must use the same action/help contract: Name, Description,
    # CommandName, DefaultBehavior, Command, and Icon. Curated parameters go in
    # Options; never accept or evaluate a raw command line. Update README help
    # and Tests\Test-Module.ps1 whenever a tool or menu option is added.
    # ══════════════════════════════════════════════════════════════════════════
    
    $menuItems = @(
        @{ 
            Name        = "Network Test"
            Description = "LAN/WAN/Internet speed testing"
            CommandName = 'Test-Network'
            DefaultBehavior = 'Opens the existing interactive mode selector.'
            Options     = @(
                @{ Name='Mode'; Label='Test mode'; Type='Choice'; Default='Interactive'; AllowedValues=@('Interactive','LAN','WAN','Internet'); Help='Chooses the test workflow' }
                @{ Name='Target'; Label='Target hostname or IP'; Type='String'; Default=''; Required=$false; Help='Sets the LAN or WAN test target when applicable' }
            )
            Examples    = @('Test-Network -Mode Internet', "Test-Network -Mode LAN -Target '192.168.1.100'")
            Notes       = @('Internet and WAN tests can contact external services. LAN mode requires an iperf3 target.')
            Command     = { 
                if (Get-Command Test-Network -ErrorAction SilentlyContinue) {
                    Test-Network
                } elseif (Get-Command Invoke-NetTest -ErrorAction SilentlyContinue) {
                    Invoke-NetTest
                } else {
                    Write-Color "$script:CbitCross Test-Network function not found. Close and reopen the customer toolkit" 'Bad'
                }
            }
            Icon        = "🌐"
        }
        @{
            Name        = "Renew Network"
            Description = "Flush DNS + release/renew DHCP"
            CommandName = 'FlushMe'
            DefaultBehavior = 'Displays the existing confirmation before changing network state.'
            Notes       = @('This can temporarily interrupt the current remote connection. The command requires explicit confirmation.')
            Command     = {
                if (Get-Command FlushMe -ErrorAction SilentlyContinue) {
                    FlushMe
                } else {
                    throw 'The network renewal command is unavailable. Reopen the toolkit.'
                }
            }
            Icon        = "🔄"
        }
        @{ 
            Name        = "Email Auth Check"
            Description = "Test SPF/DKIM/DMARC records"
            CommandName = 'Test-EmailAuthentication'
            DefaultBehavior = 'Prompts for a domain, then performs the standard DNS authentication checks.'
            Options     = @(
                @{ Name='Domain'; Label='Domain'; Type='String'; Required=$true; Help='Domain to check, such as contoso.com' }
                @{ Name='DKIMSelectors'; Label='Custom DKIM selectors'; Type='StringArray'; Default=@(); Required=$false; Help='Overrides or supplements selector discovery with comma-separated selectors' }
                @{ Name='IncludeMTA_STS'; Label='Check MTA-STS'; Type='Switch'; Default=$false; Help='Also tests the MTA-STS policy' }
                @{ Name='ExportResults'; Label='Export JSON results'; Type='Switch'; Default=$false; Help='Writes a JSON result file using the command existing behavior' }
            )
            Examples    = @("Test-EmailAuthentication -Domain 'contoso.com'", "Test-EmailAuthentication -Domain 'contoso.com' -IncludeMTA_STS")
            Notes       = @('Requires PowerShell 7.', 'DNS lookups contact configured DNS services. Export is off by default.')
            Command     = { 
                $domain = Read-Host "`nEnter domain to check"
                if ($domain) {
                    if (Get-Command Test-EmailAuthentication -ErrorAction SilentlyContinue) {
                        Test-EmailAuthentication -Domain $domain
                    } elseif (Get-Command Test-EmailDNS -ErrorAction SilentlyContinue) {
                        Test-EmailDNS -Domain $domain
                    } else {
                        Write-Color "$script:CbitCross Email auth function not found. Close and reopen the customer toolkit" 'Bad'
                    }
                }
            }
            Icon        = "📧"
        }
        @{ 
            Name        = "Network Scanner"
            Description = "Scan LAN for active hosts"
            CommandName = 'Scan-Network'
            DefaultBehavior = 'Scans active local networks with the standard port list and opens the existing results workflow.'
            Options     = @(
                @{ Name='Preset'; Label='Port preset'; Type='Choice'; Default=''; Required=$false; AllowedValues=@('Quick','Standard','Dental','Deep','Web','Database'); ConflictsWith='Ports'; Help='Uses a curated group of service ports' }
                @{ Name='Ports'; Label='Custom ports'; Type='IntegerArray'; Default=@(); Required=$false; Help='Scans comma-separated ports instead of a preset' }
                @{ Name='ThrottleLimit'; Label='Concurrent scan limit'; Type='Integer'; Default=30; Minimum=1; Help='Controls the number of concurrent scan operations' }
                @{ Name='QuickScan'; Label='Skip port scanning'; Type='Switch'; Default=$false; Help='Uses ping and MAC discovery only' }
                @{ Name='NoCacheClear'; Label='Keep the ARP cache'; Type='Switch'; Default=$false; Help='Skips the normal ARP cache clear' }
            )
            Examples    = @('Scan-Network -Preset Dental', 'Scan-Network -Ports 80,443,8080 -ThrottleLimit 50', 'Scan-Network -QuickScan')
            Notes       = @('Requires PowerShell 7.', 'A preset and custom ports cannot be used together. The packaged OUI database remains automatic.')
            Command     = { 
                if (Get-Command Scan-Network -ErrorAction SilentlyContinue) {
                    Scan-Network
                } else {
                    Write-Color "$script:CbitCross Scan-Network function not found. Close and reopen the customer toolkit" 'Bad'
                }
            }
            Icon        = "📡"
        }
        @{ 
            Name        = "Speed Test"
            Description = "Quick internet speed test"
            CommandName = 'Invoke-InternetSpeedTest'
            DefaultBehavior = 'Uses the session copy of the Ookla CLI, downloading it into temporary toolkit storage when absent.'
            Options     = @(
                @{ Name='Force'; Label='Download a fresh Speedtest CLI'; Type='Switch'; Default=$false; Help='Replaces the session copy before running the test' }
            )
            Examples    = @('Invoke-InternetSpeedTest', 'Invoke-InternetSpeedTest -Force')
            Notes       = @('Contacts Ookla services and can download the CLI. License handling remains internal and is not exposed as a menu option.')
            Command     = { 
                if (Get-Command Invoke-InternetSpeedTest -ErrorAction SilentlyContinue) {
                    Invoke-InternetSpeedTest
                } else {
                    Write-Color "$script:CbitCross Speedtest function not found. Close and reopen the customer toolkit" 'Bad'
                }
            }
            Icon        = "⚡"
        }
        @{ 
            Name        = "System Info"
            Description = "Comprehensive system details"
            CommandName = 'Get-SystemDetails'
            DefaultBehavior = 'Shows hardware details, seven days of system-impact events, and network readiness. No application-specific lookup is performed.'
            Options     = @(
                @{ Name='Application'; Label='Application name'; Type='String'; Default=''; Required=$false; Help='Looks only for matching application errors and hangs' }
                @{ Name='EventDays'; Label='Event window in days'; Type='Integer'; Default=7; Minimum=1; Maximum=30; Help='Controls how many days of event history are examined' }
                @{ Name='SkipConnectivity'; Label='Skip connectivity tests'; Type='Switch'; Default=$false; Help='Omits gateway, DNS, and HTTPS reachability probes' }
            )
            Examples    = @(
                "Get-SystemDetails -Application 'Outlook'"
                'Get-SystemDetails -EventDays 3 -SkipConnectivity'
            )
            Notes       = @('Displays results in the console and does not create report files.')
            Command     = { 
                if (Get-Command Get-SystemDetails -ErrorAction SilentlyContinue) {
                    Get-SystemDetails
                } else {
                    Get-ComputerInfo | Select-Object CsName, OsName, OsVersion, OsArchitecture, CsProcessors | Format-List
                }
            }
            Icon        = "💻"
        }
        @{ 
            Name        = "BitLocker Manager"
            Description = "Manage drive encryption"
            CommandName = 'Get-BitLockerInformation'
            DefaultBehavior = 'Opens the existing BitLocker status and management workflow.'
            Notes       = @('Some choices change drive encryption and require elevation. Existing confirmations remain in place.')
            Command     = { 
                if (Get-Command Get-BitLockerInformation -ErrorAction SilentlyContinue) {
                    Get-BitLockerInformation
                } else {
                    Write-Color "$script:CbitCross Get-BitLockerInformation function not found. Close and reopen the customer toolkit" 'Bad'
                }
            }
            Icon        = "🔒"
        }
        @{
            Name        = "Pulse Monitor"
            Description = "TCP/ICMP connectivity & latency tracker"
            CommandName = 'Start-Pulse'
            DefaultBehavior = 'Opens the existing guided setup for target, ports, duration, interval, output path, and display mode.'
            Notes       = @('The guided setup already collects its options, so no duplicate menu form is added.')
            Command     = {
                if (Get-Command Start-Pulse -ErrorAction SilentlyContinue) {
                    Start-Pulse
                } else {
                    Write-Color "$script:CbitCross Start-Pulse function not found. Close and reopen the customer toolkit" 'Bad'
                }
            }
            Icon        = "💓"
        }
        @{
            Name        = "Server Inventory"
            Description = "Full system audit report (HTML + TXT)"
            CommandName = 'Invoke-ServerInventory'
            DefaultBehavior = 'Collects a read-only inventory and writes HTML and TXT reports to C:\CBIT\Audit.'
            Options     = @(
                @{ Name='OutputPath'; Label='Report output folder'; Type='String'; Default='C:\CBIT\Audit'; Required=$true; Help='Directory that receives the HTML and TXT reports' }
            )
            Examples    = @('Invoke-ServerInventory', "Invoke-ServerInventory -OutputPath 'D:\Audits'")
            Notes       = @('Creates report files. The inventory collection itself is read-only and can take time on servers.')
            Command     = {
                if (Get-Command Invoke-ServerInventory -ErrorAction SilentlyContinue) {
                    Invoke-ServerInventory
                } else {
                    Write-Color "$script:CbitCross Invoke-ServerInventory function not found. Close and reopen the customer toolkit" 'Bad'
                }
            }
            Icon        = "📋"
        }
    )
    
    # ══════════════════════════════════════════════════════════════════════════
    # Helper Functions
    # ══════════════════════════════════════════════════════════════════════════
    
    $menuItems += @(
        @{ Name='OEM Cleanup'; Description='Review and remove selected OEM software'; CommandName='Remove-OEMBloatware'; DefaultBehavior='Opens the existing review-and-confirm maintenance workflow.'; Notes=@("Can remove selected software only after the command's existing review and confirmation steps."); Command={ Remove-OEMBloatware }; Icon='🧹' }
        @{ Name='Dell Power Settings'; Description='Review BIOS, sleep and wake settings'; CommandName='Configure-DellPower'; DefaultBehavior='Opens the existing Dell power-settings review workflow.'; Notes=@("Can change BIOS, sleep, and wake settings only through the command's existing confirmation flow."); Command={ Configure-DellPower }; Icon='🔌' }
        @{ Name='Windows 11 Optimization'; Description='Review Windows maintenance changes'; CommandName='Optimize-Windows11'; DefaultBehavior='Opens the existing Windows maintenance review workflow.'; Notes=@("Can make material workstation changes only after the command's existing review and confirmation flow."); Command={ Optimize-Windows11 }; Icon='🔧' }
    )

    $menuItems += @{
        Name = 'CBIT GPO Deployment'
        Description = 'Action1, Axis, CyberQP and SentinelOne setup'
        CommandName = 'Start-CBITGPODeployment'
        SkipActionMenu = $true
        DefaultBehavior = 'Opens the existing guided deployment menu in Windows PowerShell 5.1. Choose the deployment there; 0 returns to the toolkit.'
        Notes = @(
            'Run the toolkit elevated on the customer DC/package host with ActiveDirectory and GroupPolicy tools installed.'
            'Have the correct Action1 organization MSI ready. Stage the customer Axis kit. Have the CBIT deployment unlock passphrase for SentinelOne and the CyberQP IT Glue credentials ready.'
            'The existing workflow can change domain GPOs, shares, tasks, accounts and OU placement, and delete legacy local CBIT accounts. Its prompts remain in control.'
            'Action1 audit/checkpoints: %ProgramData%\CBIT\Audit\Action1-GPO-v2. Reports/backups: C:\CBIT\Reports\GPO. Logs/resume state: C:\CBIT\Logs\GPO. These remain after toolkit cleanup.'
        )
        Command = { Start-CBITGPODeployment }
        Icon = '📦'
    }

    $menuItems += @{
        Name = 'QR Code Utility'
        Description = 'Copy an MFA secret or full otpauth URI'
        CommandName = 'Start-CBITQRCodeUtility'
        SkipActionMenu = $true
        DefaultBehavior = 'Opens the clipboard/image-file selector and copy menu in this console. Choose 0 to return to the toolkit.'
        Notes = @(
            'Snip one QR code with Win+Shift+S or browse for a saved image. Keep its white border.'
            'Copy the Base32 secret for IT Glue or the complete otpauth URI. Both formats are available from the same scan.'
            'Decodes locally with the bundled library. No administrator rights, installation, or internet connection is needed.'
            'The utility creates no credential files and does not print secrets. Clipboard history, screenshots, and system logging may retain enrollment data.'
            'Supports individual TOTP/HOTP otpauth QR codes; proprietary enrollment links and Google migration exports are not parsed.'
        )
        Examples = @('Start-CBITQRCodeUtility')
        Command = { Start-CBITQRCodeUtility }
        Icon = '📷'
    }
    Assert-ToolkitMenuConfiguration -Items $menuItems
    if ($ValidateOnly) {
        $configurableItems = @($menuItems | Where-Object { $_.ContainsKey('Options') -and $null -ne $_.Options })
        $optionCount = @($configurableItems | ForEach-Object { @($_.Options).Count } | Measure-Object -Sum).Sum
        return [pscustomobject]@{
            MenuItems = $menuItems.Count
            ConfigurableItems = $configurableItems.Count
            Options = $optionCount
            DefaultRunTimeoutSeconds = $defaultRunTimeoutSeconds
        }
    }

    function Get-OptimalColumns {
        param([int]$ItemCount, [int]$TerminalWidth)
        
        $itemWidth = 35
        $maxCols = [math]::Floor($TerminalWidth / $itemWidth)
        $maxCols = [math]::Min($maxCols, 4)
        $maxCols = [math]::Max($maxCols, 1)
        
        $optimalCols = 1
        $minWaste = $ItemCount
        
        for ($cols = 1; $cols -le $maxCols; $cols++) {
            $rows = [math]::Ceiling($ItemCount / $cols)
            $totalCells = $rows * $cols
            $waste = $totalCells - $ItemCount
            
            if ($waste -lt $minWaste) {
                $minWaste = $waste
                $optimalCols = $cols
            }
        }
        
        return $optimalCols
    }
    
    # Letter keys mapped to menu indices (A=0, B=1, ... K=10, etc.)
    $script:LetterKeys = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

    function Show-Menu {
        param(
            [array]$Items,
            [int]$SelectedIndex,
            [int]$ColumnCount,
            [switch]$FirstDraw
        )

        # First draw clears the screen; subsequent redraws reposition the cursor
        if ($FirstDraw) {
            Clear-Host
        } else {
            [Console]::SetCursorPosition(0, 0)
        }

        $boxWidth = 63
        $titleText = "  TECHNICIAN TOOLKIT  "
        $padding = [math]::Floor(($boxWidth - $titleText.Length) / 2)
        $paddedTitle = (" " * $padding) + $titleText

        Write-Host ""
        Write-Color ("=" * $boxWidth) 'Header'
        Write-Color $paddedTitle 'Header'
        Write-Color ("=" * $boxWidth) 'Header'
        Write-Host ""

        Write-Color "  Use " 'Detail' -NoNewline
        Write-Color "arrows" 'Warn' -NoNewline
        Write-Color " to navigate; " 'Detail' -NoNewline
        Write-Color "letter keys/Enter" 'Warn' -NoNewline
        Write-Color " to open, " 'Detail' -NoNewline
        Write-Color "Q" 'Warn' -NoNewline
        Write-Color " to quit, " 'Detail' -NoNewline
        Write-Color "F1/?" 'Warn' -NoNewline
        Write-Color " for help" 'Detail'
        Write-Host ""

        $rows = [math]::Ceiling($Items.Count / $ColumnCount)
        $columnWidth = 35; $compact = (($rows * 3 + 12) -gt [Console]::WindowHeight)

        for ($row = 0; $row -lt $rows; $row++) {
            for ($col = 0; $col -lt $ColumnCount; $col++) {
                $index = $row + ($col * $rows)

                if ($index -lt $Items.Count) {
                    $item = $Items[$index]
                    $isSelected = ($index -eq $SelectedIndex)

                    $letter = $script:LetterKeys[$index]
                    $displayText = "  $($item.Icon) [$letter] $($item.Name)"

                    if ($isSelected) {
                        Write-Color " > " 'Warn' -NoNewline
                        Write-Host $displayText.PadRight($columnWidth - 3) -NoNewline -BackgroundColor DarkGray -ForegroundColor Gray
                    }
                    else {
                        Write-Host "   " -NoNewline
                        Write-Color "  $($item.Icon) " -NoNewline
                        Write-Color "[$letter]" 'Warn' -NoNewline
                        Write-Color " $($item.Name)".PadRight(($columnWidth - 3) - "  $($item.Icon) [$letter]".Length) -NoNewline
                    }
                }
                else {
                    Write-Host (" " * $columnWidth) -NoNewline
                }
            }
            Write-Host ""

            if (-not $compact) { # Description line for selected item (pad non-selected rows to maintain layout)
            $descWritten = $false
            for ($col = 0; $col -lt $ColumnCount; $col++) {
                $index = $row + ($col * $rows)

                if ($index -eq $SelectedIndex -and $index -lt $Items.Count) {
                    $descText = "      -- $($Items[$index].Description)"
                    Write-Color $descText.PadRight($boxWidth) 'Detail'
                    $descWritten = $true
                }
            }
            if (-not $descWritten) {
                Write-Host (" " * $boxWidth)
            }

            Write-Host ""
            }
        }

        Write-Host ""
        Write-Color ("─" * $boxWidth) 'Detail'
        if ($compact) { Write-Color ("  " + $Items[$SelectedIndex].Description).PadRight($boxWidth) 'Detail' }; $letter = $script:LetterKeys[$SelectedIndex]
        Write-Color "  Selected: $($Items[$SelectedIndex].Icon) [$letter] $($Items[$SelectedIndex].Name)".PadRight($boxWidth) 'Warn'
        Write-Color ("─" * $boxWidth) 'Detail'
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # Main Menu Loop
    # ══════════════════════════════════════════════════════════════════════════
    
    if ($Columns -eq 0) {
        $terminalWidth = [Console]::WindowWidth
        $Columns = Get-OptimalColumns -ItemCount $menuItems.Count -TerminalWidth $terminalWidth
    }
    
    $rows = [math]::Ceiling($menuItems.Count / $Columns)
    $selectedIndex = 0
    $running = $true
    $firstDraw = $true

    # Helper to execute the selected menu item
    function Invoke-MenuItem {
        param([hashtable]$Item, [hashtable]$Arguments = @{})

        Clear-Host
        Write-Host ""
        Write-Color ("=" * 63) 'Header'
        Write-Color "  Executing: $($Item.Icon) $($Item.Name)" 'Header'
        Write-Color ("=" * 63) 'Header'
        Write-Host ""

        try {
            if ($Arguments.Count -gt 0 -and $Item.CommandName) {
                $command = Get-Command $Item.CommandName -ErrorAction SilentlyContinue
                if (-not $command) { throw "$($Item.CommandName) is unavailable. Close and reopen the toolkit." }
                & $command @Arguments
            }
            else { & $Item.Command }
        } catch {
            Write-Color "`nError: $_" 'Bad'
        }

        Write-Host ""
        Write-Color ("─" * 63) 'Detail'
        Write-Color "Press Enter to return to menu..." 'Detail'
        Read-Host
    }

    function Show-MenuItemActions {
        param([hashtable]$Item)

        if ($Item.SkipActionMenu) {
            Invoke-MenuItem -Item $Item
            return
        }

        while ($true) {
            Clear-Host
            Write-Host ''
            Write-Color ('=' * 63) 'Header'
            Write-Color "  $($Item.Icon) $($Item.Name)" 'Header'
            Write-Color ('=' * 63) 'Header'
            Write-Color "  $($Item.Description)" 'Detail'
            if ($Item.CommandName) { Write-Color "  Command: $($Item.CommandName)" 'Detail' }
            Write-Host ''
            Write-Color '  [Enter] Run with defaults' 'Warn'
            if ($Item.Options -and $Item.Options.Count -gt 0) { Write-Color '  [O] Configure options and run' 'Warn' }
            Write-Color '  [H] Help' 'Warn'
            Write-Color '  [B] Back to toolkit menu' 'Warn'
            Write-Color "`n  Defaults run automatically in $defaultRunTimeoutSeconds seconds." 'Detail'
            Write-Host ''

            $actionKey = Read-ToolkitMenuActionKey -TimeoutSeconds $defaultRunTimeoutSeconds
            if ($null -eq $actionKey -or $actionKey.Key -eq 'Enter') {
                Invoke-MenuItem -Item $Item
                return
            }
            if ($actionKey.Key -eq 'Escape') { return }
            $action = [char]::ToUpper($actionKey.KeyChar)
            switch ($action) {
                'O' {
                    if ($Item.Options -and $Item.Options.Count -gt 0) {
                        $arguments = Read-ToolkitMenuArguments -Item $Item
                        if ($null -ne $arguments -and (Confirm-ToolkitMenuArguments -Item $Item -Arguments $arguments)) {
                            Invoke-MenuItem -Item $Item -Arguments $arguments
                            return
                        }
                    }
                }
                'H' { Show-ToolkitMenuItemHelp -Item $Item }
                'B' { return }
            }
        }
    }

    while ($running) {
        if ($firstDraw) {
            Show-Menu -Items $menuItems -SelectedIndex $selectedIndex -ColumnCount $Columns -FirstDraw
            $firstDraw = $false
        } else {
            Show-Menu -Items $menuItems -SelectedIndex $selectedIndex -ColumnCount $Columns
        }

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'UpArrow' {
                $selectedIndex -= 1
                if ($selectedIndex -lt 0) { $selectedIndex = $menuItems.Count - 1 }
            }

            'DownArrow' {
                $selectedIndex += 1
                if ($selectedIndex -ge $menuItems.Count) { $selectedIndex = 0 }
            }

            'LeftArrow' {
                $currentRow = $selectedIndex % $rows
                $currentCol = [math]::Floor($selectedIndex / $rows)
                $newCol = if ($currentCol -eq 0) { $Columns - 1 } else { $currentCol - 1 }
                $newIndex = $currentRow + ($newCol * $rows)
                if ($newIndex -ge $menuItems.Count) { $newIndex = $menuItems.Count - 1 }
                $selectedIndex = $newIndex
            }

            'RightArrow' {
                $currentRow = $selectedIndex % $rows
                $currentCol = [math]::Floor($selectedIndex / $rows)
                $newCol = ($currentCol + 1) % $Columns
                $newIndex = $currentRow + ($newCol * $rows)
                if ($newIndex -ge $menuItems.Count) { $newIndex = 0 }
                $selectedIndex = $newIndex
            }

            'Enter' {
                if ($menuItems[$selectedIndex].CommandName) { Show-MenuItemActions -Item $menuItems[$selectedIndex] }
                else { Invoke-MenuItem -Item $menuItems[$selectedIndex] }
                $firstDraw = $true
            }

            'Escape' {
                $running = $false
                Clear-Host
                Write-Color "`nExiting Technician Toolkit`n" 'Good'
            }

            'Q' {
                $running = $false
                Clear-Host
                Write-Color "`nExiting Technician Toolkit`n" 'Good'
            }

            'F1' {
                Show-ToolkitMenuItemHelp -Item $menuItems[$selectedIndex]
                $firstDraw = $true
            }

            default {
                if ($key.KeyChar -eq '?') {
                    Show-ToolkitMenuItemHelp -Item $menuItems[$selectedIndex]
                    $firstDraw = $true
                    continue
                }
                # Letter key direct selection — A opens item 0, B opens item 1, etc.
                $letterChar = [char]::ToUpper($key.KeyChar)
                $letterIndex = $script:LetterKeys.IndexOf($letterChar)

                if ($letterIndex -ge 0 -and $letterIndex -lt $menuItems.Count) {
                    $selectedIndex = $letterIndex
                    if ($menuItems[$selectedIndex].CommandName) { Show-MenuItemActions -Item $menuItems[$selectedIndex] }
                    else { Invoke-MenuItem -Item $menuItems[$selectedIndex] }
                    $firstDraw = $true
                }
            }
        }
    }
}

# Create aliases
New-Alias -Name tech -Value Show-TechMenu -Force -Scope Script
New-Alias -Name techmenu -Value Show-TechMenu -Force -Scope Script
