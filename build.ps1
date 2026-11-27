# Builds EpicSteamLauncher.exe (the game launcher) and EpicToSteam.exe (opens the app)
# with the C# compiler that ships with Windows (.NET Framework 4). Nothing to install.
# Usage: powershell -ExecutionPolicy Bypass -File build.ps1 [-OutDir folder]
param([string]$OutDir = '')
$ErrorActionPreference = 'Stop'
$fw  = "$env:windir\Microsoft.NET\Framework64\v4.0.30319"
$csc = "$fw\csc.exe"
if (-not (Test-Path $csc)) { throw ".NET Framework 4 compiler not found at $csc" }
$wpf = "$fw\WPF"
Push-Location $PSScriptRoot
try {
  if (-not $OutDir) { $OutDir = $PSScriptRoot }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  if (-not (Test-Path icon.ico)) { & powershell -NoProfile -ExecutionPolicy Bypass -File .\make-icon.ps1 }
  $common = '/nologo', '/target:winexe', '/optimize+', '/win32icon:icon.ico', '/win32manifest:app.manifest'
  & $csc @common /platform:x64 "/out:$OutDir\EpicSteamLauncher.exe" `
    "/r:$wpf\PresentationFramework.dll" "/r:$wpf\PresentationCore.dll" "/r:$wpf\WindowsBase.dll" "/r:$fw\System.Xaml.dll" `
    EpicSteamLauncher.cs Loader.cs AssemblyInfo.cs
  if ($LASTEXITCODE -ne 0) { throw 'Build of EpicSteamLauncher.exe failed' }
  & $csc @common /platform:anycpu "/out:$OutDir\EpicToSteam.exe" /r:System.Windows.Forms.dll EpicToSteam.cs AssemblyInfo.cs
  if ($LASTEXITCODE -ne 0) { throw 'Build of EpicToSteam.exe failed' }
  Write-Host "Built EpicSteamLauncher.exe and EpicToSteam.exe in $OutDir"
} finally { Pop-Location }
