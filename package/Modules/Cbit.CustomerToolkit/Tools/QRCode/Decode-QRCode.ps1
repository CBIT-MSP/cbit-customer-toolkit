#Requires -Version 5.1
<#
.SYNOPSIS
Decodes a QR image locally, returning its MFA secret, full URI, or raw text.
.DESCRIPTION
Uses the bundled ZXing.Net library. No installation, administrator rights, or
network connection is needed. With no arguments, opens the interactive menu.
-CopyToClipboard copies the selected output instead of printing the credential.
.PARAMETER Path
Local image file (PNG, JPEG, BMP, GIF, or TIFF). Crop to one QR code.
.PARAMETER Clipboard
Read an image from the Windows clipboard, such as a Win+Shift+S snip.
.PARAMETER Output
Secret (default): uppercase unpadded Base32. Uri: original otpauth:// URI.
Text: original text from any QR code. Object: parsed MFA properties.
.PARAMETER CopyToClipboard
Copy Secret, Uri, or Text without returning the value to the console.
.PARAMETER Menu
Open the interactive source and copy menus. This is the default with no arguments.
.EXAMPLE
.\Decode-QRCode.ps1 -Clipboard -CopyToClipboard
.EXAMPLE
.\Decode-QRCode.ps1 -Path .\mfa.png -Output Uri
.EXAMPLE
.\Decode-QRCode.ps1 -Clipboard -Output Object | Format-List
.NOTES
Windows PowerShell 5.1 or PowerShell 7 on Windows. Clipboard and file picker
require an STA session (powershell.exe -STA or pwsh.exe -STA).
The QR image, secret, and URI are credentials. Console output may be transcribed;
clipboard contents may be retained in clipboard history or synchronized.
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Position = 0, ParameterSetName = 'File')]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter(Mandatory, ParameterSetName = 'Clipboard')]
    [switch]$Clipboard,

    [Parameter(ParameterSetName = 'File')]
    [Parameter(ParameterSetName = 'Clipboard')]
    [ValidateSet('Secret', 'Uri', 'Text', 'Object')]
    [string]$Output = 'Secret',

    [Parameter(ParameterSetName = 'File')]
    [Parameter(ParameterSetName = 'Clipboard')]
    [switch]$CopyToClipboard,

    [Parameter(Mandatory, ParameterSetName = 'Menu')]
    [switch]$Menu
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'QRCodeUtility.psm1') -ErrorAction Stop
if ($Menu -or -not ($PSBoundParameters.ContainsKey('Path') -or $PSBoundParameters.ContainsKey('Clipboard') -or $PSBoundParameters.ContainsKey('Output') -or $PSBoundParameters.ContainsKey('CopyToClipboard'))) {
    Show-QRCodeMenu
}
else {
    Read-QRCode @PSBoundParameters
}
