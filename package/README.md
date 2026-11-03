# CBIT Customer Toolkit — preview 0.3.4

This is a separate, temporary-session edition of your technician tools for a normal PowerShell window accessed through ScreenConnect, RDP, or locally. Your working roaming repository and profile loader have not been modified.

## Start locally

In PowerShell, run the launcher from this extracted folder:

```powershell
& '.\Start-Toolkit.ps1'
```

A separate toolkit window opens directly to the technician menu. Type `exit`, or close the toolkit window, when finished. Opening the toolkit requires no elevation; individual administrative actions retain their existing requirements. The child window inherits the launcher's privileges.

Use the arrow keys to highlight a tool, or use its letter shortcut. Opening a tool displays a small action screen: press `Enter` to run with defaults, `O` to configure menu-safe options, `H` for help, or `B` to return. Because the default run is the normal path, it starts automatically after eight seconds if no key is pressed. Press `F1` or `?` on the main menu for help on the highlighted tool. The help screen names the underlying command for advanced technicians, but normal menu use does not require knowing PowerShell syntax.

The launcher prefers an installed `pwsh.exe` found in PATH. If PowerShell 7 is absent in normal Auto mode, it asks whether to install PowerShell 7 with Windows Package Manager. Answering `N` or pressing Enter uses Windows PowerShell 5.1 without installing anything; Network Scanner and Email Auth Check require PowerShell 7. You can choose an engine explicitly:

```powershell
& '.\Start-Toolkit.ps1' -Engine PowerShell7
& '.\Start-Toolkit.ps1' -Engine WindowsPowerShell
```

Explicit `-Engine WindowsPowerShell` and `-Verify` never prompt or install PowerShell. An explicit `-Engine PowerShell7` request also asks before installing when PowerShell 7 is absent; declining stops that launch. The launcher does not change execution policy. The interactive session uses the installed PSReadLine module; a missing or blocked editor causes startup to fail rather than fall back to persistent history settings.

For a startup check that invokes none of the administrative tools:

```powershell
& '.\Start-Toolkit.ps1' -Verify
```

## Included tools

The package contains the technician tools, shared colors, menu, existing aliases, the OUI database, and its required binaries. `Get-ToolkitStatus` shows the version and paths currently in use.

`Get-SystemDetails` now adds concise triage evidence after its existing hardware summary: pending-reboot state, system-impact reliability events, and network readiness. From **System Info**, choose **Configure options** to enter an application name, choose a 1-30 day event window, or omit gateway, DNS, and HTTPS probes. For advanced console use, the equivalent parameters are `-Application`, `-EventDays`, and `-SkipConnectivity`. These runs display in the console and do not create report files.

The same action/help framework exposes curated options for Network Test, Email Auth Check, Network Scanner, Speed Test, and Server Inventory. Internal implementation parameters are intentionally hidden. Tools that already have a guided workflow, such as Pulse Monitor and BitLocker Manager, keep that workflow and explain it on their help screens.

## CBIT GPO Deployment

The rc11 candidate includes **CBIT GPO Deployment** (shortcut **M**). Select it with M, or highlight it and press Enter, to open the existing Action1, Axis, CyberQP, and SentinelOne guided deployment menu immediately; select 0 there to return. This item skips the toolkit action screen and its eight-second countdown. The supplied `Deploy-CBITStandardGPO.ps1` has the requested spacing and toolkit-specific preparation wording; the credential is now encrypted in the package and unlocked before SentinelOne customer lookup. This tool always uses native Windows PowerShell 5.1, even when the toolkit runs in PowerShell 7. Start the toolkit elevated on the customer DC/package host, with the ActiveDirectory and GroupPolicy modules and the selected workflow's prerequisites available.

Deployment reports and backups use `C:\CBIT\Reports\GPO`; logs and CyberQP resume/rollback state use `C:\CBIT\Logs\GPO`. They survive temporary toolkit cleanup. Reopen the same candidate and use the deployment menu's option 6 to resume the saved deployment plan. The workflow can change GPOs, installer shares, scheduled tasks, AD accounts and OU placement, and delete legacy local CBIT accounts; all existing deployment prompts remain in the supplied script. Opening or verifying the toolkit does not execute this deployment script.

SentinelOne and All three selections prompt for the separately supplied **CBIT deployment unlock passphrase** before customer lookup or deployment. Entry is hidden; blank cancels. A successful unlock is reused only within that deployment process. Axis, CyberQP, and other tools do not prompt. Obtain the unique password-manager-generated passphrase from the approved technician vault; never put it in a command line, repository, release notes, or chat. Credential preparation requires at least 14 characters; use a randomly generated value rather than a predictable phrase. Unlock requires .NET Framework 4.7.2 or later on the Windows PowerShell 5.1 host.

The package contains an authenticated encrypted credential envelope, not the plaintext API token or its decryption key. The existing daily SYSTEM synchronization task still uses the API token in `C:\CBIT\S1deploy\Sync-S1Package.ps1`, restricted to SYSTEM/Administrators. No passphrase is stored there. Package encryption does not hide a deployed token from machine administrators. Changing the passphrase only protects newly encrypted releases; revoking access through older copies requires rotating the SentinelOne API token and updating deployed synchronization tasks.

## Adding tools in future previews

CBIT GPO Deployment uses `SkipActionMenu` to open its existing guided workflow directly; main-menu F1/? help remains available. Other technician-menu items follow the action contract: `Enter` runs with defaults (including the eight-second automatic default), `O` configures options when appropriate, `H` opens help, and `B` returns. Its menu definition must include a friendly name and description, underlying command name, default behavior, execution block, and icon. Curated options must use the shared typed schema so values are validated and passed as named arguments; never accept or evaluate a raw command line. Help must state defaults, output or reports, requirements, and material side effects.

When adding a tool or option, update the expected menu counts in `Tests\Test-Module.ps1` and run that guarded test in both Windows PowerShell 5.1 and PowerShell 7. Also run `Start-Toolkit.ps1 -Verify` with each explicit engine. These checks validate the menu schema and parameter names without executing technician commands.

In the network scanner, selecting devices and clicking OK opens the console action menu. Copying an IP or MAC keeps the same devices selected, so you can copy another attribute. Only **B** reopens the grid; **Q** finishes. Blank or invalid input stays at the action menu. Version 0.1.1 fixes the previous automatic grid reopening.

PowerShell 7 loads all tools. Windows PowerShell 5.1 loads the other tools and provides clear explanatory placeholders for `Scan-Network` and `Test-EmailAuthentication`, which retain their PowerShell 7 implementations. Availability of Windows components, external endpoints, and executable compatibility can still affect individual commands.

## Temporary-session behavior

- Each launch copies the module and session helpers to its own `CBIT-Toolkit-<unique ID>` folder in the user's temporary directory.
- Neither the roaming `Profile.ps1` nor its bootstrap runs. No Git metadata or Git synchronization code is included in the runtime package.
- A separate hidden PowerShell process waits for the toolkit window and removes only that session's staging directory when it ends. There is no scheduled task, service, login hook, forced timeout, or persistent profile registration.
- Closing the launching terminal after the toolkit has opened does not intentionally terminate its separate monitor.
- The child starts with `-NoProfile`. Its theme, key bindings, aliases, and history-saving preference apply only to that child. PSReadLine does not save new history from this toolkit shell; existing history and system audit logging are not erased.
- Cleanup validates the directory name and ownership marker and refuses linked directories. Concurrent sessions have separate staging folders.
- A power loss, logoff, termination of the monitor itself, or locked files can leave a staging folder behind. This preview does not install a later cleanup mechanism. The folder contains `.cbit-session.json` identifying its creation time and owner. Do not manually delete a folder belonging to a live toolkit session.

When you start from a manually extracted package, that package and its ZIP remain where you placed them. Starting through the separate HTTPS download launcher verifies the release hash, extracts it into an owned temporary directory, starts the toolkit, and removes that downloaded delivery copy once the session has its own files. The generated one-command instructions also verify and remove the downloaded launcher. Hosting details and live endpoint validation are still pending.

## Reports and command effects

Reports remain in the locations selected by the tools. Server inventory retains its default `C:\CBIT\Audit` output, and Pulse retains its existing output selection. The toolkit window starts in the launcher's working directory, outside its staging folder, so ordinary relative output paths are not pointed at disposable files.

Individual tools retain their existing behavior when explicitly invoked: repairs can install or change components; BitLocker actions change drive encryption; speed tests can download their CLI and contact external services; external programs can retain their own settings. Those effects are not undone when the session ends. Files deliberately saved inside the staging directory will be removed with it.

In this edition, DHCP release/renew always requires confirmation because ScreenConnect can appear to be a local console session. The menu does not fall back to an unconfirmed renewal if its helper is missing.

## Scope and validation

This is a release candidate, not a signed or published customer release. Startup, command exports, cancellation, and cleanup have been checked without invoking real scans, speed tests, repairs, inventory collection, or encryption actions. The HTTPS download path is tested with local transport fixtures until the MSP hosting address is supplied. See `VALIDATION.md` for the tested boundaries.

The MSP RMM background terminal is not yet a supported target; its interactive-console and process-lifetime behavior needs separate investigation.

## Action1 in the unified deployment menu

Use **CBIT GPO Deployment** (M), then **1: Action1**. There is no separate Action1 toolkit item or automatic Action1 countdown. The unified menu also offers **5: Complete CBIT Stack**, **6: Resume**, **8: Action1 resume / audit / disable link**, and **9: CyberQP resume / rollback / dry run**. Option 0 returns to the toolkit.

Run elevated on a writable DC with ActiveDirectory and GroupPolicy modules. Have the MSI for the correct Action1 organization ready. The unchanged embedded Action1 wizard handles protected staging, manual Assigned MSI setup in GPMC, and explicit link approval. Action1 audit evidence/checkpoints remain at `%ProgramData%\CBIT\Audit\Action1-GPO-v2`; staging defaults to `C:\CBIT\Action1-deploy`. Resume on the same DC.

The authoritative source is the project's `Deploy-CBITStandardGPO\Deploy-CBITStandardGPO.ps1`. `Build-GpoDeployment.ps1` creates the toolkit copy with its existing encrypted SentinelOne credential initialization, deferred unlock, and cleanup. The embedded Action1 payload remains byte-identical to the validated standalone script. The supplied `Action1-GPO-README.md` is retained as reference; its older validation-status paragraph predates the user's end-to-end validation.

For a focused live check: verify toolkit startup, open M, select 8 and enter `audit`, and confirm return to the unified menu. Then test option 1 on the intended test domain, including pause/resume and evidence persistence. Audit writes local logs. Deployment changes remain gated by the wizard's existing prompts. Publication follows successful live testing.

## QR Code Utility

Select **QR Code Utility** (shortcut **N**) to open its source menu directly.
Choose **1** for a clipboard image (snip the QR with Win+Shift+S first) or **2**
to browse for an image. After decoding, choose **1** to copy the Base32 secret
for IT Glue or **2** to copy the complete `otpauth://` URI. Both formats remain
available from the same scan; choose **3** for another image or **0** to finish,
then press Enter to return to the main toolkit menu.

The decoder runs offline in the existing console using a Windows PowerShell
STA child process. It requires no elevation, install, or network connection.
It creates no credential files and does not print the secret or URI in menu
mode. Clipboard history, screenshot auto-save, and system logging can retain
credentials. Check that the destination's generated OTP is accepted before
completing enrollment. Non-default OTP settings are shown when present.

Individual TOTP/HOTP `otpauth://` QR codes are supported. Proprietary enrollment
links and Google Authenticator migration exports are not parsed. See the
packaged `Modules\Cbit.CustomerToolkit\Tools\QRCode\README.md` for details.
ZXing.Net 0.16.11 and its license are bundled under that tool's `lib` directory.
The payload loads only when selected and is protected by the toolkit's existing
worker tracking until the QR menu exits. The advanced command is
`Start-CBITQRCodeUtility`.

