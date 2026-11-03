#Requires -Version 5.1
# Synthetic credentials only. Does not read or modify the user's clipboard.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'QRCodeUtility.psm1') -Force
$module = Get-Module QRCodeUtility
& $module { Initialize-QrDecoder }
$script:passed = 0

function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "FAIL: $Name" }
    $script:passed++
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Name) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.Exception.Message -notlike $Pattern) { throw "FAIL: $Name ($caught)" }
    $script:passed++
}
function Parse-Otp([string]$Value) { & $module { param($t) ConvertFrom-OtpAuthUri -Text $t } $Value }
function New-TestQr([string]$Text, [string]$Path) {
    $writer = [ZXing.BarcodeWriterPixelData]::new()
    $writer.Format = [ZXing.BarcodeFormat]::QR_CODE
    $writer.Options.Width = 400
    $writer.Options.Height = 400
    $writer.Options.Margin = 4
    $pixels = $writer.Write($Text)
    $bitmap = [Drawing.Bitmap]::new($pixels.Width, $pixels.Height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $rect = [Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height)
        $locked = $bitmap.LockBits($rect, [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try { [Runtime.InteropServices.Marshal]::Copy($pixels.Pixels, 0, $locked.Scan0, $pixels.Pixels.Length) }
        finally { $bitmap.UnlockBits($locked) }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
}

$secret = 'JBSWY3DPEHPK3PXP'
$uri = 'otpauth://totp/Example%20Co%3Aalice%2Btest%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example%20Co&x-extra=keep%2Bthis'
$otp = Parse-Otp $uri
Assert-Equal $otp.Secret $secret 'Base32 secret'
Assert-Equal $otp.Uri $uri 'Exact URI and unknown parameters preserved'
Assert-Equal $otp.Issuer 'Example Co' 'Issuer decoding'
Assert-Equal $otp.Account 'alice+test@example.com' 'Account decoding'
Assert-Equal $otp.Algorithm 'SHA1' 'Default algorithm'
Assert-Equal $otp.Digits 6 'Default digits'
Assert-Equal $otp.Period 30 'Default period'
Assert-Equal (Parse-Otp 'otpauth://totp/Example:alice+test?secret=my%3D%3D%3D%3D%3D%3D').Secret 'MY' 'Lowercase padded secret normalized'
Assert-Equal (Parse-Otp 'otpauth://totp/Example:alice+test?secret=MY').Account 'alice+test' 'Literal plus preserved'
Assert-Equal (Parse-Otp 'otpauth://totp/Example:alice?secret=MY').Issuer 'Example' 'Issuer fallback'
$custom = Parse-Otp 'otpauth://totp/test?secret=MY&algorithm=SHA256&digits=8&period=60'
Assert-Equal $custom.Algorithm 'SHA256' 'Custom algorithm'
Assert-Equal $custom.Digits 8 'Custom digits'
Assert-Equal $custom.Period 60 'Custom period'
$hotp = Parse-Otp 'otpauth://hotp/test?secret=MY&counter=18446744073709551615'
Assert-Equal $hotp.Counter ([uint64]::MaxValue) 'HOTP counter without precision loss'
Assert-Equal $hotp.Period $null 'HOTP has no period'
Assert-Throws { Parse-Otp 'https://example.com/enroll' } '*does not contain*' 'Non-OTP rejected'
Assert-Throws { Parse-Otp 'otpauth-migration://offline?data=test' } '*migration QR*' 'Migration payload explained'
Assert-Throws { Parse-Otp 'otpauth://totp/test?issuer=Example' } '*no secret*' 'Missing secret rejected'
Assert-Throws { Parse-Otp 'otpauth://totp/test?secret=MY&secret=MY' } '*duplicate*' 'Duplicate secret rejected'
Assert-Throws { Parse-Otp 'otpauth://totp/test?secret=MY&%73ecret=MY' } '*duplicate*' 'Escaped duplicate rejected'
Assert-Throws { Parse-Otp 'otpauth://totp/test?secret=INVALID0189' } '*valid Base32*' 'Invalid alphabet rejected'
Assert-Throws { Parse-Otp 'otpauth://totp/test?secret=A' } '*invalid length*' 'Invalid length rejected'
Assert-Throws { Parse-Otp 'otpauth://totp/test?secret=MZ' } '*trailing bits*' 'Invalid pad bits rejected'
Assert-Throws { Parse-Otp 'otpauth://totp/test?secret=MY=' } '*invalid padding*' 'Invalid padding rejected'
Assert-Throws { Parse-Otp 'otpauth://totp/test?secret=MY&issuer=%ZZ' } '*invalid escaping*' 'Bad escape rejected'
Assert-Throws { Parse-Otp 'otpauth://totp/test?secret=MY&period=0' } '*invalid period*' 'Invalid period rejected'
Assert-Throws { Parse-Otp 'otpauth://hotp/test?secret=MY' } '*counter*' 'Missing HOTP counter rejected'
Assert-Throws { Read-QRCode -Path unused.png -Output Object -CopyToClipboard } '*supports Secret*' 'Object clipboard rejected before side effects'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('qr-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $imagePath = Join-Path $temp "qr [test] & apostrophe's.png"
    New-TestQr $uri $imagePath
    Assert-Equal (Read-QRCode -Path $imagePath) $secret 'PNG decoding and literal special path'
    Assert-Equal (Read-QRCode -Path $imagePath -Output Uri) $uri 'Full URI from actual QR'
    Assert-Equal (Read-QRCode -Path $imagePath -Output Text) $uri 'Raw text from actual QR'
    Assert-Equal (Read-QRCode -Path $imagePath -Output Object).Issuer 'Example Co' 'Object from actual QR'
    Assert-Equal (& (Join-Path $root 'Decode-QRCode.ps1') -Path $imagePath -Output Uri) $uri 'Script entry point'

    $rotatedPath = Join-Path $temp 'rotated.png'
    $bitmap = [Drawing.Bitmap]::new($imagePath)
    try {
        $bitmap.RotateFlip([Drawing.RotateFlipType]::Rotate90FlipNone)
        $bitmap.Save($rotatedPath, [Drawing.Imaging.ImageFormat]::Png)
        foreach ($format in @('Jpeg', 'Bmp', 'Gif', 'Tiff')) {
            $formatPath = Join-Path $temp "qr.$format"
            $bitmap.Save($formatPath, [Drawing.Imaging.ImageFormat]::$format)
            Assert-Equal (Read-QRCode $formatPath) $secret "$format decoding"
        }
    }
    finally { $bitmap.Dispose() }
    Assert-Equal (Read-QRCode $rotatedPath) $secret 'Rotated QR decoding'

    $transparentPath = Join-Path $temp 'transparent.png'
    $transparent = [Drawing.Bitmap]::new($imagePath)
    try {
        $transparent.MakeTransparent([Drawing.Color]::White)
        $transparent.Save($transparentPath, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $transparent.Dispose() }
    Assert-Equal (Read-QRCode $transparentPath) $secret 'Transparent background decoding'

    $invertedPath = Join-Path $temp 'inverted.png'
    $source = [Drawing.Bitmap]::new($imagePath)
    $inverted = [Drawing.Bitmap]::new($source.Width, $source.Height)
    $graphics = [Drawing.Graphics]::FromImage($inverted)
    $attributes = [Drawing.Imaging.ImageAttributes]::new()
    try {
        $matrix = [Drawing.Imaging.ColorMatrix]::new()
        $matrix.Matrix00 = -1; $matrix.Matrix11 = -1; $matrix.Matrix22 = -1
        $matrix.Matrix40 = 1; $matrix.Matrix41 = 1; $matrix.Matrix42 = 1
        $attributes.SetColorMatrix($matrix)
        $rect = [Drawing.Rectangle]::new(0, 0, $source.Width, $source.Height)
        $graphics.DrawImage($source, $rect, 0, 0, $source.Width, $source.Height, [Drawing.GraphicsUnit]::Pixel, $attributes)
        $inverted.Save($invertedPath, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $attributes.Dispose(); $graphics.Dispose(); $inverted.Dispose(); $source.Dispose() }
    Assert-Equal (Read-QRCode $invertedPath) $secret 'Inverted QR decoding'

    $rawPath = Join-Path $temp 'raw.png'
    New-TestQr 'https://example.com/demo?a=1&b=2' $rawPath
    Assert-Equal (Read-QRCode $rawPath -Output Text) 'https://example.com/demo?a=1&b=2' 'Generic QR text'
    Assert-Throws { Read-QRCode $rawPath } '*does not contain*' 'Generic QR cannot become secret'

    $blankPath = Join-Path $temp 'blank.png'
    $blank = [Drawing.Bitmap]::new(400, 400)
    $graphics = [Drawing.Graphics]::FromImage($blank)
    try { $graphics.Clear([Drawing.Color]::White); $blank.Save($blankPath, [Drawing.Imaging.ImageFormat]::Png) }
    finally { $graphics.Dispose(); $blank.Dispose() }
    Assert-Throws { Read-QRCode $blankPath } '*No readable QR*' 'Blank image rejected'

    $multiPath = Join-Path $temp 'multiple.png'
    $canvas = [Drawing.Bitmap]::new(850, 450)
    $graphics = [Drawing.Graphics]::FromImage($canvas)
    $left = [Drawing.Bitmap]::new($imagePath)
    $right = [Drawing.Bitmap]::new($rawPath)
    try {
        $graphics.Clear([Drawing.Color]::White)
        $graphics.DrawImageUnscaled($left, 0, 0)
        $graphics.DrawImageUnscaled($right, 450, 0)
        $canvas.Save($multiPath, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $graphics.Dispose(); $canvas.Dispose(); $left.Dispose(); $right.Dispose() }
    Assert-Throws { Read-QRCode $multiPath } '*More than one QR*' 'Multiple QR codes rejected'

    $badFile = Join-Path $temp 'invalid.png'
    [IO.File]::WriteAllText($badFile, 'not an image')
    Assert-Throws { Read-QRCode $badFile } '*could not be opened as an image*' 'Corrupt image rejected'
    Assert-Throws { Read-QRCode (Join-Path $temp 'missing.png') } '*does not exist*' 'Missing file rejected'

    # File handles must be released after both successful and unsuccessful decoding.
    $exclusive = [IO.File]::Open($imagePath, 'Open', 'ReadWrite', 'None')
    $exclusive.Dispose()
    $script:passed++
}
finally {
    # Only remove the unique temporary directory created by this test run.
    $resolvedTemp = [IO.Path]::GetFullPath($temp)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedTemp.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected temporary directory.' }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
Write-Output "$script:passed checks passed on PowerShell $($PSVersionTable.PSVersion)."
