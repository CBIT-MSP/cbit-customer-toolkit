# QR Code Utility

Decode a QR image locally and extract the Base32 MFA secret, the complete
`otpauth://` URI, or the original text of any QR code. Works with Windows
PowerShell 5.1 and PowerShell 7 on Windows. No administrator rights, installation,
or Internet connection is needed. Keep the script, module, and `lib` folder together.

## Quick start: secret for IT Glue

1. Extract the entire ZIP and double-click **Start-QRUtility.cmd** in its folder.
2. Choose **1** for a clipboard image or **2** to browse for an image file, then
   press Enter. For clipboard input, first use **Win+Shift+S** to snip the QR code
   with its white border.
3. After decoding, choose **1** to copy the Base32 secret or **2** to copy the
   full `otpauth://` URI, then press Enter.
4. Paste the copied Base32 secret into your IT Glue OTP setup field. Check that
   the resulting code is accepted by the service before completing enrollment.
5. The copy menu stays open: copy the other format from the same scan, choose
   **3** to read another QR code, or **0** to exit.

The menu holds the decoded account in memory until you read another QR or exit.
It shows the account and issuer, but does not print the secret or URI. Copying
replaces the clipboard image with text, but **you can copy both formats from the
same scan without snipping again**. A new clipboard scan needs a new image.

The launcher starts a visible Windows PowerShell window in STA mode and keeps
startup errors on screen if startup fails. No commands are needed for menu use.

## Commands

```powershell
# Show the Base32 secret from a snip
.\Decode-QRCode.ps1 -Clipboard

# Copy the complete, original otpauth:// URI
.\Decode-QRCode.ps1 -Clipboard -Output Uri -CopyToClipboard

# Read a saved QR image
.\Decode-QRCode.ps1 -Path 'C:\Temp\mfa.png'
.\Decode-QRCode.ps1 -Path 'C:\Temp\mfa.png' -Output Uri

# Open the interactive menu
.\Decode-QRCode.ps1
.\Decode-QRCode.ps1 -Menu

# Open an image picker and return the full URI directly
.\Decode-QRCode.ps1 -Output Uri

# Inspect all MFA fields, including the secret and original URI
.\Decode-QRCode.ps1 -Clipboard -Output Object | Format-List

# Capture once, then select either value without reading the image again
$mfa = .\Decode-QRCode.ps1 -Clipboard -Output Object
$mfa.Secret
$mfa.Uri

# Decode an ordinary QR or inspect an unsupported enrollment payload
.\Decode-QRCode.ps1 -Path 'C:\Temp\qr.png' -Output Text

# Optional: import the function for repeated use
Import-Module .\QRCodeUtility.psm1
Read-QRCode -Clipboard -Output Uri
```

`-CopyToClipboard` accepts `Secret`, `Uri`, and `Text`. It prints a confirmation
instead of returning the credential to the console. Without that switch, the
selected value is returned normally and can be assigned to a variable or piped.

| Output | Result |
| --- | --- |
| `Secret` (default) | Validated uppercase Base32 secret, without trailing `=` padding |
| `Uri` | Original `otpauth://` text, with its original escaping and all parameters |
| `Object` | Type, Issuer, Account, Label, Secret, Algorithm, Digits, Period, Counter, Uri |
| `Text` | Original QR text without requiring an OTP payload |

## Behavior and limits

- Supports PNG, JPEG, BMP, GIF, and TIFF through Windows image support; only the
  initially loaded frame of an animated or multipage image is decoded.
- Attempts rotation and inverted QR colors; transparent images get a white background.
- Rejects images with multiple detected QR codes. Crop to one account's code.
  Detection cannot guarantee every code in a larger screenshot will be found.
- Supports individual `otpauth://totp/` and `otpauth://hotp/` payloads. Missing or
  invalid Base32 secrets, duplicate query parameters, and malformed settings
  produce an error instead of a guessed result. `Text` remains available for
  inspecting a nonstandard payload.
- `Object` reports omitted TOTP settings as SHA1, 6 digits, and 30 seconds. HOTP
  requires a counter. A secret-only request warns about non-default settings:
  the destination must support matching OTP type, algorithm, digits, and period
  or counter to generate matching codes. This utility does not generate OTPs or
  determine which settings IT Glue supports.
- Some MFA QR codes contain proprietary enrollment links instead of reusable
  OTP secrets. This utility cannot derive a secret that is not in the QR payload.
  Google Authenticator `otpauth-migration://` exports are not parsed; `Text` can
  extract their raw contents.
- Clipboard access and the file picker need an interactive Windows session in
  STA mode. If the utility reports an STA error, start `powershell.exe -STA` or
  `pwsh.exe -STA`, then run it again. File input with console output also works in MTA.
- This is an unsigned PowerShell utility. Follow your organization's script
  signing/execution policy; no policy is changed automatically.

## Credential handling

Decoding runs on your computer using the bundled library; the utility contains no
network requests and creates no credential files or logs. The QR image, URI, and
Base32 secret all contain sensitive enrollment data. Console transcripts, host
logging, clipboard history/sync, and screenshot auto-save can retain those values.
Use your normal credential-handling process for those copies. Copy mode avoids
printing the value but does not disable system logging or clipboard history.

## Verification

Run the included tests in each installed PowerShell version:

```powershell
powershell.exe -NoProfile -File .\tests\Test-QRCodeUtility.ps1
pwsh.exe -NoProfile -File .\tests\Test-QRCodeUtility.ps1
powershell.exe -NoProfile -File .\tests\Test-QRCodeMenu.ps1
pwsh.exe -NoProfile -File .\tests\Test-QRCodeMenu.ps1
```

Tests generate synthetic QR images and check secret/URI extraction, file formats,
rotation, inversion, transparency, multiple codes, invalid input, URI parsing,
and file-handle cleanup. Menu scenarios check both input sources, copying both
formats from one scan, invalid selections, cancellation, read errors, and copy
retries using mocked clipboard/file input. They do not read or change your clipboard. The native
clipboard and file-picker interactions require an interactive manual check.

See `lib\THIRD-PARTY.txt` for the bundled decoder version, source, and hashes.
The parser follows the [Google Authenticator Key URI format](https://github.com/google/google-authenticator/wiki/Key-Uri-Format).
