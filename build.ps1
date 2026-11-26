# Builds EpicSteamLauncher.exe with the C# compiler that ships with Windows (.NET Framework 4).
# Usage: powershell -ExecutionPolicy Bypass -File build.ps1
$ErrorActionPreference = 'Stop'
$csc = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw ".NET Framework 4 compiler not found at $csc" }
Push-Location $PSScriptRoot
try {
  & $csc /nologo /target:winexe /platform:x64 /optimize+ /out:EpicSteamLauncher.exe EpicSteamLauncher.cs
  if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
  Write-Host 'Built EpicSteamLauncher.exe'
} finally { Pop-Location }
