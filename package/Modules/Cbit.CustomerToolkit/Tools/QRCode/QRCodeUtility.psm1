#Requires -Version 5.1
Set-StrictMode -Version Latest

function Initialize-QrDecoder {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This utility requires Windows.'
    }
    $target = 'net40'
    $expectedHash = '643A5A3DB0AE02998B507BEB82DBC362A2D5593B429963DB17EB78089AABB95A'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $target = 'netstandard2.0'
        $expectedHash = 'F3B823B6FD6492525A7547989056883DEF5D43BE1E12C4F63FA54DF73E3C5CFC'
    }
    $dll = Join-Path $PSScriptRoot "lib\$target\zxing.dll"
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        throw 'The bundled QR decoder is missing. Extract the entire utility ZIP, including the lib folder.'
    }
    if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expectedHash) {
        throw 'The bundled QR decoder failed its integrity check. Restore it from the original utility package.'
    }
    $loaded = 'ZXing.BarcodeReaderGeneric' -as [type]
    if ($loaded) {
        if ($loaded.Assembly.Location -ne $dll) {
            throw 'Another ZXing library is already loaded. Run this utility in a fresh PowerShell session.'
        }
    }
    else {
        Add-Type -Path $dll -ErrorAction Stop
    }
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
}

function Initialize-QrClipboard {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'Clipboard and file selection require STA. Start PowerShell using powershell.exe -STA or pwsh.exe -STA, then rerun the command.'
    }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
}

function ConvertTo-QrBase32Secret {
    param([Parameter(Mandatory)][string]$Value)
    $valueUpper = $Value.ToUpperInvariant()
    if ($valueUpper -cnotmatch '\A[A-Z2-7]+=*\z') {
        throw 'The secret is not a valid Base32 value (A-Z and 2-7).'
    }
    $secret = $valueUpper.TrimEnd('=')
    $remainder = $secret.Length % 8
    if ($remainder -notin @(0, 2, 4, 5, 7)) {
        throw 'The Base32 secret has an invalid length.'
    }
    $padding = $valueUpper.Length - $secret.Length
    if ($padding -gt 0 -and $padding -ne ((8 - $remainder) % 8)) {
        throw 'The Base32 secret has invalid padding.'
    }
    # Reject nonzero unused bits so normalization never changes the key bytes.
    $unusedBits = ($secret.Length * 5) % 8
    $lastValue = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.IndexOf($secret[$secret.Length - 1])
    if (($lastValue -band ((1 -shl $unusedBits) - 1)) -ne 0) {
        throw 'The Base32 secret has invalid trailing bits.'
    }
    return $secret
}

function ConvertFrom-OtpAuthUri {
    param([Parameter(Mandatory)][string]$Text)
    if ($Text -match '^otpauth-migration://') {
        throw 'This is a Google Authenticator migration QR, not an individual otpauth URI. Use -Output Text to read the payload; migration imports are not supported.'
    }
    if ($Text -notmatch '(?i)\Aotpauth://(totp|hotp)/([^?#]+)\?([^#]+)\z') {
        throw 'This QR does not contain a supported otpauth://totp or otpauth://hotp URI. Use -Output Text to read its actual content. A proprietary enrollment link may not contain a Base32 secret.'
    }
    $otpType = $Matches[1].ToLowerInvariant()
    $encodedLabel = $Matches[2]
    $query = $Matches[3]
    if ($Text -match '\s|%(?![0-9A-Fa-f]{2})') {
        throw 'The otpauth URI contains invalid escaping or unescaped whitespace.'
    }
    $parameters = @{}
    foreach ($part in $query.Split('&')) {
        $pair = $part.Split([char[]]@('='), 2, [StringSplitOptions]::None)
        if ($pair.Count -ne 2 -or [string]::IsNullOrEmpty($pair[0])) {
            throw 'The otpauth URI contains an invalid query parameter.'
        }
        $name = [Uri]::UnescapeDataString($pair[0])
        if ($parameters.ContainsKey($name)) {
            throw 'The otpauth URI contains duplicate parameters; the intended settings are ambiguous.'
        }
        # URI escaping uses %20 for spaces. A literal plus remains a plus.
        $parameters[$name] = [Uri]::UnescapeDataString($pair[1])
    }
    if (-not $parameters.ContainsKey('secret') -or [string]::IsNullOrEmpty($parameters.secret)) {
        throw 'The otpauth URI has no secret parameter.'
    }
    $secret = ConvertTo-QrBase32Secret -Value $parameters.secret
    $label = [Uri]::UnescapeDataString($encodedLabel)
    $labelParts = $label.Split([char[]]@(':'), 2, [StringSplitOptions]::None)
    $account = $label
    $issuer = $null
    if ($labelParts.Count -eq 2) {
        $issuer = $labelParts[0]
        $account = $labelParts[1].TrimStart()
    }
    if ($parameters.ContainsKey('issuer')) { $issuer = $parameters.issuer }

    $algorithm = 'SHA1'
    if ($parameters.ContainsKey('algorithm')) { $algorithm = $parameters.algorithm.ToUpperInvariant() }
    $digits = 6
    if ($parameters.ContainsKey('digits')) {
        if ($parameters.digits -notmatch '^\d+$' -or -not [int]::TryParse($parameters.digits, [ref]$digits) -or $digits -lt 1) {
            throw 'The otpauth URI has an invalid digits parameter.'
        }
    }
    $period = $null
    $counter = $null
    if ($otpType -eq 'totp') {
        $period = 30
        if ($parameters.ContainsKey('period')) {
            if ($parameters.period -notmatch '^\d+$' -or -not [int]::TryParse($parameters.period, [ref]$period) -or $period -lt 1) {
                throw 'The otpauth URI has an invalid period parameter.'
            }
        }
    }
    else {
        [uint64]$counterValue = 0
        if (-not $parameters.ContainsKey('counter') -or $parameters.counter -notmatch '^\d+$' -or -not [uint64]::TryParse($parameters.counter, [ref]$counterValue)) {
            throw 'An HOTP URI requires a valid nonnegative counter parameter.'
        }
        $counter = $counterValue
    }
    [pscustomobject][ordered]@{
        Type = $otpType
        Issuer = $issuer
        Account = $account
        Label = $label
        Secret = $secret
        Algorithm = $algorithm
        Digits = $digits
        Period = $period
        Counter = $counter
        Uri = $Text # Preserve the original QR text, including unknown parameters.
    }
}

function Get-QrImageText {
    param([Parameter(Mandatory)][System.Drawing.Image]$Image)
    if ([long]$Image.Width * $Image.Height -gt 25000000) {
        throw 'The image exceeds 25 megapixels. Crop it to the QR code and try again.'
    }
    $bitmap = $null
    $graphics = $null
    $locked = $null
    try {
        # Normalize indexed/transparent images to a white-backed 32-bit bitmap.
        $bitmap = [System.Drawing.Bitmap]::new($Image.Width, $Image.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.DrawImageUnscaled($Image, 0, 0)
        $graphics.Dispose()
        $graphics = $null
        $rect = [System.Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height)
        $locked = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $rowBytes = $bitmap.Width * 4
        $pixels = New-Object byte[] ($rowBytes * $bitmap.Height)
        for ($row = 0; $row -lt $bitmap.Height; $row++) {
            $address = [IntPtr]::Add($locked.Scan0, $row * $locked.Stride)
            [Runtime.InteropServices.Marshal]::Copy($address, $pixels, $row * $rowBytes, $rowBytes)
        }
        $bitmap.UnlockBits($locked)
        $locked = $null
        $reader = [ZXing.BarcodeReaderGeneric]::new()
        $reader.AutoRotate = $true
        $reader.Options.TryHarder = $true
        $reader.Options.TryInverted = $true
        $reader.Options.PossibleFormats = [System.Collections.Generic.List[ZXing.BarcodeFormat]]::new()
        $reader.Options.PossibleFormats.Add([ZXing.BarcodeFormat]::QR_CODE)
        $luminance = [ZXing.RGBLuminanceSource]::new($pixels, $bitmap.Width, $bitmap.Height, [ZXing.RGBLuminanceSource+BitmapFormat]::BGRA32)
        $results = @($reader.DecodeMultiple($luminance) | Where-Object { $null -ne $_ })
        # ZXing's multiple-QR path does not consistently honor TryInverted.
        if ($results.Count -eq 0) {
            $results = @($reader.DecodeMultiple($luminance.invert()) | Where-Object { $null -ne $_ })
        }
        if ($results.Count -eq 0) {
            throw 'No readable QR code was found. Snip one QR code at its original size, including its white border, and try again.'
        }
        if ($results.Count -gt 1) {
            throw 'More than one QR code was found. Crop to the intended code so the wrong account is not selected.'
        }
        return $results[0].Text
    }
    finally {
        if ($locked -and $bitmap) { $bitmap.UnlockBits($locked) }
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
    }
}

function Set-QrClipboardText {
    param([Parameter(Mandatory)][string]$Text)
    Initialize-QrClipboard
    [System.Windows.Forms.Clipboard]::SetText($Text)
}

function Read-QRCode {
    [CmdletBinding(DefaultParameterSetName = 'File')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'File')]
        [ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Clipboard')][switch]$Clipboard,
        [ValidateSet('Secret', 'Uri', 'Text', 'Object')][string]$Output = 'Secret',
        [switch]$CopyToClipboard
    )
    $ErrorActionPreference = 'Stop'
    if ($CopyToClipboard -and $Output -eq 'Object') {
        throw '-CopyToClipboard supports Secret, Uri, or Text. Select one of those output modes.'
    }
    Initialize-QrDecoder
    $image = $null
    try {
        if ($Clipboard -or $CopyToClipboard -or -not $Path) { Initialize-QrClipboard }
        if ($Clipboard) {
            if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) {
                throw 'The clipboard has no image. Use Win+Shift+S to snip the QR code, then rerun the command.'
            }
            $image = [System.Windows.Forms.Clipboard]::GetImage()
        }
        else {
            if (-not $Path) {
                $picker = [System.Windows.Forms.OpenFileDialog]::new()
                try {
                    $picker.Title = 'Select a QR code image'
                    $picker.Filter = 'Image files|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|All files|*.*'
                    if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
                    $Path = $picker.FileName
                }
                finally { $picker.Dispose() }
            }
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($item.PSProvider.Name -ne 'FileSystem' -or $item.PSIsContainer) {
                throw '-Path must identify an image file.'
            }
            try { $image = [System.Drawing.Image]::FromFile($item.FullName) }
            catch { throw 'The file could not be opened as an image. Use a PNG, JPEG, BMP, GIF, or TIFF image.' }
        }
        if ($null -eq $image) { throw 'The image could not be read. Capture the QR code again.' }
        $text = Get-QrImageText -Image $image
    }
    finally { if ($image) { $image.Dispose() } }

    if ($Output -eq 'Text') { $value = $text }
    else {
        $otp = ConvertFrom-OtpAuthUri -Text $text
        switch ($Output) {
            'Secret' {
                if ($otp.Type -ne 'totp' -or $otp.Algorithm -ne 'SHA1' -or $otp.Digits -ne 6 -or $otp.Period -ne 30) {
                    Write-Warning 'This QR uses non-default OTP settings. Use -Output Object to inspect them and ensure the destination supports matching settings.'
                }
                $value = $otp.Secret
            }
            'Uri' { $value = $otp.Uri }
            'Object' { $value = $otp }
        }
    }
    if ($CopyToClipboard) {
        Set-QrClipboardText -Text ([string]$value)
        Write-Host "$Output copied to clipboard." -ForegroundColor DarkGreen
    }
    else { $value }
}

function Show-QRCodeMenu {
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    Initialize-QrDecoder
    Initialize-QrClipboard
    $otp = $null
    $oldTitle = $null
    try {
        try {
            $oldTitle = $Host.UI.RawUI.WindowTitle
            $Host.UI.RawUI.WindowTitle = 'CBIT - QR Code Utility'
        }
        catch { } # A custom host may not expose a window title.
        Write-Host ''
        Write-Host '  QR CODE UTILITY' -ForegroundColor Gray
        Write-Host '  Decode locally. Copy the MFA secret or the complete otpauth URI.' -ForegroundColor DarkGray

        while ($true) {
            $otp = $null
            Write-Host ''
            Write-Host '  Choose the QR image source' -ForegroundColor Gray
            Write-Host '  [1] Clipboard image (snip the QR code with Win+Shift+S)'
            Write-Host '  [2] Image file (browse)'
            Write-Host '  [0] Exit'
            $source = Read-Host '  Choice'
            if ($source -eq '0') { return }
            if ($source -notin @('1', '2')) {
                Write-Host '  Enter 1, 2, or 0.' -ForegroundColor DarkYellow
                continue
            }
            try {
                if ($source -eq '1') { $otp = Read-QRCode -Clipboard -Output Object }
                else { $otp = Read-QRCode -Output Object }
                if ($null -eq $otp) {
                    Write-Host '  File selection canceled.' -ForegroundColor DarkGray
                    continue
                }
            }
            catch {
                Write-Host ('  Could not read this QR: ' + $_.Exception.Message) -ForegroundColor DarkRed
                continue
            }

            Write-Host ''
            Write-Host '  QR code decoded.' -ForegroundColor DarkGreen
            # Remove terminal control characters from untrusted QR metadata.
            $accountText = [regex]::Replace([string]$otp.Account, '\p{C}', '')
            $issuerText = [regex]::Replace([string]$otp.Issuer, '\p{C}', '')
            Write-Host ('  Account: ' + $accountText)
            if ($issuerText) { Write-Host ('  Issuer:  ' + $issuerText) }
            if ($otp.Type -ne 'totp' -or $otp.Algorithm -ne 'SHA1' -or $otp.Digits -ne 6 -or $otp.Period -ne 30) {
                Write-Host '  This code uses non-default OTP settings. Match these in the destination:' -ForegroundColor DarkYellow
                $settings = '  Type: {0}; algorithm: {1}; digits: {2}; period: {3}; counter: {4}' -f $otp.Type, $otp.Algorithm, $otp.Digits, $otp.Period, $otp.Counter
                Write-Host ([regex]::Replace($settings, '\p{C}', '')) -ForegroundColor DarkYellow
            }
            Write-Host '  You can copy both formats from this scan; no second snip is needed.' -ForegroundColor DarkGray

            :CopyMenu while ($true) {
                Write-Host ''
                Write-Host '  [1] Copy Base32 secret (for IT Glue)'
                Write-Host '  [2] Copy full otpauth:// URI'
                Write-Host '  [3] Read another QR code'
                Write-Host '  [0] Exit'
                $choice = Read-Host '  Choice'
                switch ($choice) {
                    '0' { return }
                    '3' { break CopyMenu }
                    '1' {
                        try {
                            Set-QrClipboardText -Text $otp.Secret
                            Write-Host '  Base32 secret copied. Paste it into IT Glue.' -ForegroundColor DarkGreen
                        }
                        catch { Write-Host '  Could not copy to the clipboard. Try again.' -ForegroundColor DarkRed }
                    }
                    '2' {
                        try {
                            Set-QrClipboardText -Text $otp.Uri
                            Write-Host '  Full otpauth URI copied.' -ForegroundColor DarkGreen
                        }
                        catch { Write-Host '  Could not copy to the clipboard. Try again.' -ForegroundColor DarkRed }
                    }
                    default { Write-Host '  Enter 1, 2, 3, or 0.' -ForegroundColor DarkYellow }
                }
            }
        }
    }
    finally {
        $otp = $null
        if ($null -ne $oldTitle) {
            try { $Host.UI.RawUI.WindowTitle = $oldTitle } catch { }
        }
    }
}

Export-ModuleMember -Function Read-QRCode, Show-QRCodeMenu
