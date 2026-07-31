$appDir = Split-Path -Parent $PSCommandPath
$script = Join-Path $appDir 'ChatGPTUsageWidget.ps1'
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $script + '"'
$psi.WorkingDirectory = $appDir
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
[void][Diagnostics.Process]::Start($psi)
