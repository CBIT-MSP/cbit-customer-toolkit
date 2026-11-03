# cbit-customer-toolkit
Public scripts-only CBIT Customer Toolkit releases for technician deployment.

Select **📷 [N] QR Code Utility** in the technician menu to decode an MFA
enrollment image locally. Choose the clipboard or an image file, then copy
the Base32 secret for IT Glue or the complete `otpauth://` URI. Both outputs
are available from one scan. Choose **0**, then Enter, to return to the toolkit.

The `package` directory contains the files added or replaced by the QR
update. To build the toolkit, download the original
[v0.3.4-rc15 release ZIP](https://github.com/CBIT-MSP/cbit-customer-toolkit/releases/tag/v0.3.4-rc15)
and run the following command with Python 3.8 or newer.

```powershell
python .\build.py C:\Downloads\CBIT-CustomerToolkit-0.3.4.zip
```

The build checks the input ZIP's SHA256 and writes the updated ZIP to
`dist`. Extract it outside OneDrive and run `Start-Toolkit.ps1`.
The QR decoder, both Windows assemblies, and the upstream license are bundled
under `Modules\Cbit.CustomerToolkit\Tools\QRCode`.

Run `tests\Test-QrIntegration.ps1 -PackageRoot <extracted toolkit folder>`
in a clean Windows PowerShell 5.1 or PowerShell 7 session to check the menu
and launch behavior. The packaged QR utility also includes its own decoder
and menu tests using synthetic QR codes.
