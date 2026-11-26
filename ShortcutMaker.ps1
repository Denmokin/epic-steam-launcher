# Epic -> Steam Shortcut Maker
# Lists installed Epic games and adds them to Steam (and optionally Moonlight/Sunshine) using
# EpicSteamLauncher.exe in --chain mode, so games get Steam's real overlay.
# Run: powershell -ExecutionPolicy Bypass -File ShortcutMaker.ps1   (add -NoGui -Test for a dry check)
param([switch]$NoGui, [switch]$Test)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms

$Here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Launcher  = Join-Path $Here 'EpicSteamLauncher.exe'
$Steam     = (Get-ItemProperty HKCU:\Software\Valve\Steam).SteamPath -replace '/', '\'
$EpicData  = "$env:USERPROFILE\AppData\Local\com.epicgames.eglv2"
$Sunshine  = 'C:\Program Files\Sunshine\config'
$enc       = New-Object Text.UTF8Encoding($false)

# Rockstar Games Launcher location (read from Windows; it can live anywhere)
$rsl = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Rockstar Games\Launcher' -ErrorAction SilentlyContinue).InstallFolder
$RockstarLauncher = if ($rsl) { Join-Path $rsl 'Launcher.exe' } else { '\Rockstar Games\Launcher\Launcher.exe' }

# Games whose Epic "launch exe" is only a bootstrapper: wait for the real game, close leftovers after.
$Known = @{
  'PlayGTAV.exe' = @{ Game = 'GTA5_Enhanced.exe'; Kill = @($RockstarLauncher) }
}

# ---------------------------------------------------------------- Epic
function Get-EpicGames {
  $inst = @{}
  Get-Content "$EpicData\installations.jsonl" | Select-Object -Skip 1 | ForEach-Object {
    try { $e = $_ | ConvertFrom-Json } catch { return }
    $inst[$e.installationId] = $e          # later lines win
  }
  $cat = [IO.File]::ReadAllText("$EpicData\cache\prod\catalog-cache.json") | ConvertFrom-Json
  foreach ($e in $inst.Values) {
    if (-not $e.complete -or $e.parentInstallationId -or -not $e.launchExecutable) { continue }
    $item = $cat.items.($e.itemId).item
    $name = if ($item.title) { $item.title } else { Split-Path $e.dir -Leaf }
    $exe  = Split-Path $e.launchExecutable -Leaf
    $k    = $Known[$exe]
    [pscustomobject]@{
      Name  = $name
      Dir   = $e.dir
      Uri   = "com.epicgames.launcher://apps/$($e.namespace)%3A$($e.itemId)%3A$($e.artifactId)?action=launch&silent=true"
      Game  = $(if ($k) { $k.Game } else { $exe })
      Kill  = $(if ($k) { $k.Kill } else { @() })
      Icon  = Join-Path $e.dir $e.launchExecutable
      Images = $item.keyImages
    }
  }
}

# ---------------------------------------------------------------- Steam accounts
function Get-SteamAccounts {
  # every account that has used Steam on this PC; name from its own localconfig.vdf
  Get-ChildItem "$Steam\userdata" -Directory | Where-Object { $_.Name -match '^\d+$' -and (Test-Path "$($_.FullName)\config\localconfig.vdf") } | ForEach-Object {
    $m = Select-String "$($_.FullName)\config\localconfig.vdf" -Pattern '"PersonaName"\s+"([^"]*)"' | Select-Object -First 1
    $name = if ($m) { $m.Matches[0].Groups[1].Value } else { 'Steam user' }
    [pscustomobject]@{
      Id = $_.Name; Name = "$name  (id $($_.Name))"
      Default = (Test-Path "$($_.FullName)\config\shortcuts.vdf")   # pre-tick accounts that already have non-Steam games
    }
  }
}

# ---------------------------------------------------------------- binary shortcuts.vdf
function Read-CStr([byte[]]$b, [ref]$i) { $s = $i.Value; while ($b[$i.Value] -ne 0) { $i.Value++ }; $r = $enc.GetString($b, $s, $i.Value - $s); $i.Value++; $r }
function Read-Map([byte[]]$b, [ref]$i) {
  $m = [ordered]@{}
  while ($true) {
    $t = $b[$i.Value]; $i.Value++
    if ($t -eq 8) { return $m }
    $k = Read-CStr $b $i
    switch ($t) { 0 { $m[$k] = Read-Map $b $i } 1 { $m[$k] = Read-CStr $b $i } 2 { $m[$k] = [BitConverter]::ToInt32($b, $i.Value); $i.Value += 4 } default { throw "bad VDF type $t" } }
  }
}
function Write-CStr($w, [string]$s) { $w.Write($enc.GetBytes($s)); $w.Write([byte]0) }
function Write-Map($w, $m) {
  foreach ($k in $m.Keys) { $v = $m[$k]
    if ($v -is [Collections.IDictionary]) { $w.Write([byte]0); Write-CStr $w $k; Write-Map $w $v }
    elseif ($v -is [int]) { $w.Write([byte]2); Write-CStr $w $k; $w.Write([int]$v) }
    else { $w.Write([byte]1); Write-CStr $w $k; Write-CStr $w ([string]$v) } }
  $w.Write([byte]8)
}
function Get-Crc32([byte[]]$data) {
  $crc = [uint32]::MaxValue
  foreach ($x in $data) { $crc = $crc -bxor $x; for ($j = 0; $j -lt 8; $j++) { if ($crc -band 1) { $crc = ($crc -shr 1) -bxor [uint32]3988292384 } else { $crc = $crc -shr 1 } } }
  [uint32]($crc -bxor [uint32]::MaxValue)
}
function ToSigned([uint32]$u) { [BitConverter]::ToInt32([BitConverter]::GetBytes($u), 0) }
function ToUnsigned([int]$s)  { [BitConverter]::ToUInt32([BitConverter]::GetBytes($s), 0) }

function Read-Shortcuts($path) {
  $list = New-Object Collections.ArrayList
  if (Test-Path $path) { $b = [IO.File]::ReadAllBytes($path); $i = 1; $null = Read-CStr $b ([ref]$i); foreach ($v in (Read-Map $b ([ref]$i)).Values) { [void]$list.Add($v) } }
  , $list
}
function Save-Shortcuts($path, $list) {
  Copy-Item $path "$path.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -ErrorAction SilentlyContinue
  $out = [ordered]@{}; $n = 0; foreach ($e in $list) { $out["$n"] = $e; $n++ }
  $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
  $w.Write([byte]0); Write-CStr $w 'shortcuts'; Write-Map $w $out; $w.Write([byte]8); $w.Flush()
  [IO.File]::WriteAllBytes($path, $ms.ToArray())
}

function New-ShortcutEntry($g, [uint32]$appid) {
  $opts = "--chain --uri `"$($g.Uri)`" --game $($g.Game)" + (($g.Kill | ForEach-Object { " --kill-path `"$_`"" }) -join '')
  [ordered]@{
    appid = (ToSigned $appid); AppName = $g.Name; Exe = "`"$Launcher`""; StartDir = "$Here\"   # unquoted + trailing \ (quotes break CreateProcess)
    icon = $g.Icon; ShortcutPath = ''; LaunchOptions = $opts; IsHidden = 0; AllowDesktopConfig = 1; AllowOverlay = 1
    OpenVR = 0; Devkit = 0; DevkitGameID = ''; DevkitOverrideAppID = 0; LastPlayTime = 0; FlatpakAppID = ''; sortas = ''; tags = [ordered]@{}
  }
}

# ---------------------------------------------------------------- cover art (Epic's own key art)
function Save-Fitted($src, $dst, $w, $h, [switch]$Png) {
  $img = [Drawing.Image]::FromFile($src)
  $scale = [Math]::Max($w / $img.Width, $h / $img.Height)
  $sw = $w / $scale; $sh = $h / $scale; $sx = ($img.Width - $sw) / 2; $sy = ($img.Height - $sh) / 2
  $bmp = New-Object Drawing.Bitmap $w, $h; $gr = [Drawing.Graphics]::FromImage($bmp); $gr.InterpolationMode = 'HighQualityBicubic'
  $gr.DrawImage($img, (New-Object Drawing.Rectangle 0, 0, $w, $h), [single]$sx, [single]$sy, [single]$sw, [single]$sh, 'Pixel')
  $gr.Dispose(); $img.Dispose()
  $bmp.Save($dst, $(if ($Png) { [Drawing.Imaging.ImageFormat]::Png } else { [Drawing.Imaging.ImageFormat]::Jpeg })); $bmp.Dispose()
}
function Get-Art($g, $tmp) {
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $pick = { param($types) foreach ($t in $types) { $u = ($g.Images | Where-Object { $_.type -eq $t } | Select-Object -First 1).url; if ($u) { return $u } } }
  $art = @{}
  foreach ($kind in @(@{k='tall'; t=@('DieselGameBoxTall','OfferImageTall','Thumbnail')}, @{k='wide'; t=@('DieselGameBox','OfferImageWide','DieselStoreFrontWide')}, @{k='logo'; t=@('DieselGameBoxLogo')})) {
    $u = & $pick $kind.t
    if ($u) { $f = Join-Path $tmp "$($kind.k).img"; try { Invoke-WebRequest $u -OutFile $f -UseBasicParsing; $art[$kind.k] = $f } catch {} }
  }
  $art
}
function Install-Art($art, $gridDir, [uint32]$appid) {
  New-Item -ItemType Directory -Force $gridDir | Out-Null
  if ($art.tall) { Save-Fitted $art.tall (Join-Path $gridDir "${appid}p.jpg") 600 900 }
  if ($art.wide) { Save-Fitted $art.wide (Join-Path $gridDir "$appid.jpg") 920 430; Save-Fitted $art.wide (Join-Path $gridDir "${appid}_hero.jpg") 1920 620 }
  if ($art.logo) { Copy-Item $art.logo (Join-Path $gridDir "${appid}_logo.png") -Force }
}

# ---------------------------------------------------------------- main action
function Invoke-Make($games, $accounts, [bool]$moonlight, $log) {
  $steamWasRunning = [bool](Get-Process steam -ErrorAction SilentlyContinue)
  if ($steamWasRunning -and -not $Test) {
    & $log 'Closing Steam...'
    Start-Process "$Steam\steam.exe" -ArgumentList '-shutdown'
    for ($i = 0; $i -lt 60 -and (Get-Process steam -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    if (Get-Process steam -ErrorAction SilentlyContinue) { throw 'Steam did not close. Exit Steam from the tray icon and try again.' }
  }
  $tiles = @()
  foreach ($g in $games) {
    & $log "== $($g.Name)"
    $art = Get-Art $g (Join-Path $env:TEMP "esl-art-$([Math]::Abs($g.Name.GetHashCode()))")
    & $log ("   cover art: " + $(if ($art.Count) { ($art.Keys -join ', ') } else { 'none found' }))
    $appid = $null
    foreach ($a in $accounts) {
      $cfg = "$Steam\userdata\$($a.Id)\config"; $path = Join-Path $cfg 'shortcuts.vdf'
      $list = Read-Shortcuts $path
      $old = @($list | Where-Object { $_.AppName -eq $g.Name })
      if (-not $appid) {
        # reuse an existing shortcut's ID so Moonlight tiles / Steam art keep working
        $appid = if ($old) { ToUnsigned $old[0].appid } else { (Get-Crc32 $enc.GetBytes("`"$Launcher`"" + $g.Name)) -bor [uint32]2147483648 }
      }
      foreach ($o in $old) { $list.Remove($o) }
      [void]$list.Add((New-ShortcutEntry $g $appid))
      if ($Test) { & $log "   [test] would write $path" } else { Save-Shortcuts $path $list; Install-Art $art "$cfg\grid" $appid }
      & $log "   added to Steam account $($a.Name)"
    }
    if ($moonlight) { $tiles += @{ Name = $g.Name; AppId = $appid; Art = $art.tall } }
  }
  if ($tiles -and -not $Test) { Add-MoonlightTiles $tiles $log }
  if ($steamWasRunning -and -not $Test) { & $log 'Starting Steam...'; Start-Process "$Steam\steam.exe" }
  & $log 'Done.'
}

function Add-MoonlightTiles($tiles, $log) {
  $stage = 'C:\Users\Public\esl-sunshine'; New-Item -ItemType Directory -Force $stage | Out-Null
  $apps = Get-Content "$Sunshine\apps.json" -Raw | ConvertFrom-Json
  $list = [Collections.ArrayList]@($apps.apps)
  foreach ($t in $tiles) {
    $gid = ([uint64]$t.AppId -shl 32) -bor [uint64]0x02000000
    $file = ($t.Name -replace '[^A-Za-z0-9]', '') + '.png'
    if ($t.Art) { Save-Fitted $t.Art (Join-Path $stage $file) 600 900 -Png }
    foreach ($x in @($list | Where-Object { $_.name -eq $t.Name })) { $list.Remove($x) }
    $entry = [ordered]@{ name = $t.Name; 'prep-cmd' = @([ordered]@{ do = 'steam://open/bigpicture'; undo = 'steam://close/bigpicture' }); detached = @("steam://rungameid/$gid") }
    if ($t.Art) { $entry['image-path'] = "$Sunshine\covers\$file" }
    [void]$list.Add([pscustomobject]$entry)
    & $log "   Moonlight tile: $($t.Name)"
  }
  $apps.apps = $list.ToArray()
  [IO.File]::WriteAllText((Join-Path $stage 'apps.json'), ($apps | ConvertTo-Json -Depth 8), $enc)
  $script = @"
`$c='$Sunshine'
Copy-Item "`$c\apps.json" "`$c\apps.json.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Force "`$c\covers" | Out-Null
Get-ChildItem '$stage' -Filter *.png | Copy-Item -Destination "`$c\covers" -Force
Copy-Item '$stage\apps.json' "`$c\apps.json" -Force
Restart-Service SunshineService
"@
  [IO.File]::WriteAllText((Join-Path $stage 'apply.ps1'), $script, $enc)
  & $log '   Updating Sunshine (Windows will ask for permission)...'
  try { Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$stage\apply.ps1`"" ; & $log '   Sunshine updated.' }
  catch { & $log '   Sunshine NOT updated (permission was declined).' }
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- UI
$games = @(Get-EpicGames | Sort-Object Name)
$accounts = @(Get-SteamAccounts)
if ($NoGui) {
  $games | ForEach-Object { "GAME  $($_.Name)  [$($_.Game)]  $($_.Dir)" }
  $accounts | ForEach-Object { "STEAM $($_.Name) ($($_.Id))" }
  if ($Test) { Invoke-Make $games @($accounts | Where-Object Default) $false { param($m) Write-Host $m } }
  return
}

$f = New-Object Windows.Forms.Form
$f.Text = 'Epic -> Steam Shortcut Maker'; $f.Size = New-Object Drawing.Size 520, 560; $f.StartPosition = 'CenterScreen'; $f.Font = New-Object Drawing.Font 'Segoe UI', 10
$l1 = New-Object Windows.Forms.Label; $l1.Text = 'Installed Epic games:'; $l1.Location = '12,10'; $l1.AutoSize = $true
$gl = New-Object Windows.Forms.CheckedListBox; $gl.Location = '12,34'; $gl.Size = '480,170'; $gl.CheckOnClick = $true
foreach ($g in $games) { [void]$gl.Items.Add($g.Name) }
$l2 = New-Object Windows.Forms.Label; $l2.Text = 'Add to these Steam accounts:'; $l2.Location = '12,212'; $l2.AutoSize = $true
$al = New-Object Windows.Forms.CheckedListBox; $al.Location = '12,236'; $al.Size = '480,60'; $al.CheckOnClick = $true
for ($i = 0; $i -lt $accounts.Count; $i++) { [void]$al.Items.Add($accounts[$i].Name, [bool]$accounts[$i].Default) }
$ml = New-Object Windows.Forms.CheckBox; $ml.Text = 'Also add a Moonlight tile (asks for admin permission)'; $ml.Location = '12,304'; $ml.AutoSize = $true
$note = New-Object Windows.Forms.Label; $note.Text = 'Steam will be closed and reopened automatically.'; $note.Location = '12,332'; $note.AutoSize = $true; $note.ForeColor = 'DimGray'
$go = New-Object Windows.Forms.Button; $go.Text = 'Create shortcuts'; $go.Location = '12,358'; $go.Size = '480,36'
$out = New-Object Windows.Forms.TextBox; $out.Multiline = $true; $out.ReadOnly = $true; $out.ScrollBars = 'Vertical'; $out.Location = '12,402'; $out.Size = '480,104'
$f.Controls.AddRange(@($l1, $gl, $l2, $al, $ml, $note, $go, $out))
$go.Add_Click({
  $sel = @(); foreach ($i in $gl.CheckedIndices) { $sel += $games[$i] }
  $acc = @(); foreach ($i in $al.CheckedIndices) { $acc += $accounts[$i] }
  if (-not $sel -or -not $acc) { [Windows.Forms.MessageBox]::Show('Pick at least one game and one Steam account.') | Out-Null; return }
  $go.Enabled = $false; $out.Clear()
  $log = { param($m) $out.AppendText($m + "`r`n"); [Windows.Forms.Application]::DoEvents() }
  try { Invoke-Make $sel $acc $ml.Checked $log; [Windows.Forms.MessageBox]::Show('All done!') | Out-Null }
  catch { & $log "ERROR: $($_.Exception.Message)"; [Windows.Forms.MessageBox]::Show("Something went wrong:`n$($_.Exception.Message)") | Out-Null }
  $go.Enabled = $true
})
[void]$f.ShowDialog()
