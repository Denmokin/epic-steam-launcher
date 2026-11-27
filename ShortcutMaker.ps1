# Epic -> Steam Shortcut Maker
# Lists installed Epic games and adds them to Steam (and optionally Moonlight/Sunshine) using
# EpicSteamLauncher.exe in --chain mode, so games get Steam's real overlay.
# Run: powershell -ExecutionPolicy Bypass -File ShortcutMaker.ps1   (add -NoGui -Test for a dry check)
param([switch]$NoGui, [switch]$Test, [ValidateSet('Epic','Steam','SteamGridDB')][string]$Art = 'Epic', [string]$Snapshot)
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
# Game = candidate real game exes (first one that exists in the game folder wins).
$Known = @{
  'PlayGTAV.exe' = @{ Game = @('GTA5_Enhanced.exe', 'GTA5.exe'); Kill = @($RockstarLauncher) }
  'PlayRDR2.exe' = @{ Game = @('RDR2.exe'); Kill = @($RockstarLauncher) }
}
# Rockstar's "Play*.exe" redirector re-runs the Rockstar Games Launcher installer (as admin, so
# Windows asks for permission) on every launch unless it gets -skipInstallers. We put that in
# Epic's per-game launch arguments.
$RockstarArgs = '-skipInstallers'
function Test-RockstarRedirector([string]$path) {
  try { (Get-Item $path).VersionInfo.FileDescription -eq 'Rockstar Games Launcher Redirector' } catch { $false }
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
    $rockstar = Test-RockstarRedirector (Join-Path $e.dir $e.launchExecutable)
    $real = $exe
    if ($k) { $real = ($k.Game | Where-Object { Test-Path (Join-Path $e.dir $_) } | Select-Object -First 1); if (-not $real) { $real = $k.Game[0] } }
    [pscustomobject]@{
      Name  = $name
      Dir   = $e.dir
      AppKey = "$($e.namespace):$($e.itemId):$($e.artifactId)"
      Uri   = "com.epicgames.launcher://apps/$($e.namespace)%3A$($e.itemId)%3A$($e.artifactId)?action=launch&silent=true"
      Game  = $real
      Kill  = $(if ($k) { $k.Kill } elseif ($rockstar) { @($RockstarLauncher) } else { @() })
      EpicArgs = $(if ($rockstar) { $RockstarArgs } else { '' })
      Icon  = Join-Path $e.dir $e.launchExecutable
      Images = $item.keyImages
      SteamId = $null
    }
  }
}

# Adds launch arguments to Epic's per-game settings (Epic must be closed, or it overwrites the file).
function Set-EpicLaunchArgs($games, $log) {
  $todo = @($games | Where-Object { $_.EpicArgs })
  if (-not $todo) { return }
  $f = "$EpicData\settings\game-settings.json"
  $j = if (Test-Path $f) { [IO.File]::ReadAllText($f) | ConvertFrom-Json } else { [pscustomobject]@{ games = [pscustomobject]@{} } }
  if (-not $j.games) { $j | Add-Member -NotePropertyName games -NotePropertyValue ([pscustomobject]@{}) -Force }
  $changed = $false
  foreach ($g in $todo) {
    $s = $j.games.($g.AppKey)
    if (-not $s) { $s = [pscustomobject]@{}; $j.games | Add-Member -NotePropertyName $g.AppKey -NotePropertyValue $s -Force }
    $cur = [string]$s.additionalCommands
    if ($s.additionalCommandsEnabled -eq $true -and $cur -match [regex]::Escape($g.EpicArgs)) { continue }
    $new = if ($cur -match [regex]::Escape($g.EpicArgs)) { $cur } else { ("$cur $($g.EpicArgs)").Trim() }
    $s | Add-Member -NotePropertyName additionalCommandsEnabled -NotePropertyValue $true -Force
    $s | Add-Member -NotePropertyName additionalCommands -NotePropertyValue $new -Force
    & $log "   Epic launch arguments for $($g.Name): $new (stops the Rockstar admin prompt)"
    $changed = $true
  }
  if (-not $changed) { return }
  if ($Test) { & $log '   [test] would update Epic game settings'; return }
  foreach ($p in @(Get-Process EpicGamesLauncher, EpicWebHelper -ErrorAction SilentlyContinue)) { try { $p.CloseMainWindow() | Out-Null; if (-not $p.WaitForExit(5000)) { $p.Kill() } } catch {} }
  if (Test-Path $f) { Copy-Item $f "$f.bak-$(Get-Date -f yyyyMMddHHmmss)" }
  [IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 20), $enc)
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
  $opts = "--chain --hide-launchers --loader --title `"$($g.Name -replace '"','')`" --uri `"$($g.Uri)`" --game $($g.Game)" + (($g.Kill | ForEach-Object { " --kill-path `"$_`"" }) -join '')
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
# ---------------------------------------------------------------- Steam / SteamDB art
# SteamDB blocks automated access, but every image it shows comes from Steam's own CDN,
# so we look the game up with Steam's store search and download from the CDN directly.
function Find-SteamAppId([string]$name) {
  $hit = Find-SteamAppIdOnce $name
  if (-not $hit) {
    # retry without edition suffixes: "X: Complete Edition", "X - Deluxe Edition", "X Enhanced Edition"...
    $short = ($name -replace '\s*[:\-–]\s*[^:\-–]*(Edition|Collection|Remaster(ed)?|Definitive|GOTY|Game of the Year)\b.*$', '') -replace '\s+(Complete|Deluxe|Gold|Ultimate|Definitive|Enhanced|Special|Standard)\s+Edition$', ''
    if ($short -ne $name -and $short) { $hit = Find-SteamAppIdOnce $short; if ($hit) { $hit.Exact = $false } }
  }
  $hit
}
function Find-SteamAppIdOnce([string]$name) {
  $clean = ($name -replace '[™®©]', '').Trim()
  try {
    $r = Invoke-RestMethod ("https://store.steampowered.com/api/storesearch/?term=" + [uri]::EscapeDataString($clean) + "&l=english&cc=US") -UseBasicParsing -TimeoutSec 15
  } catch { return $null }
  if (-not $r.items) { return $null }
  $norm = { param($s) (($s -replace '[™®©]', '') -replace '[^a-z0-9]', '').ToLower() }
  $exact = $r.items | Where-Object { (& $norm $_.name) -eq (& $norm $clean) } | Select-Object -First 1
  $hit = if ($exact) { $exact } else { $r.items[0] }
  [pscustomobject]@{ Id = [string]$hit.id; Name = $hit.name; Exact = [bool]$exact }
}
function Get-SteamArt([string]$appid, $tmp) {
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $cdn = "https://shared.steamstatic.com/store_item_assets/steam/apps/$appid"
  $art = @{}
  foreach ($k in @(@{k='tall'; f=@('library_600x900_2x.jpg','library_600x900.jpg')}, @{k='wide'; f=@('header.jpg')}, @{k='hero'; f=@('library_hero.jpg')}, @{k='logo'; f=@('logo.png')})) {
    foreach ($file in $k.f) {
      $dst = Join-Path $tmp "steam-$($k.k)$([IO.Path]::GetExtension($file))"
      try { Invoke-WebRequest "$cdn/$file" -OutFile $dst -UseBasicParsing -TimeoutSec 20; $art[$k.k] = $dst; break } catch {}
    }
  }
  $art
}

# ---------------------------------------------------------------- SteamGridDB art
# Needs a free API key from https://www.steamgriddb.com/profile/preferences/api
# The key is kept in steamgriddb.key next to this script (never in the repo).
$SgdbKeyFile = Join-Path $Here 'steamgriddb.key'
function Get-SgdbKey { if (Test-Path $SgdbKeyFile) { (Get-Content $SgdbKeyFile -Raw).Trim() } else { '' } }
function Invoke-Sgdb([string]$path) {
  $key = Get-SgdbKey; if (-not $key) { throw 'No SteamGridDB API key' }
  $r = Invoke-RestMethod "https://www.steamgriddb.com/api/v2/$path" -Headers @{ Authorization = "Bearer $key" } -UseBasicParsing -TimeoutSec 20
  if (-not $r.success) { throw "SteamGridDB: $($r.errors -join ', ')" }
  $r.data
}
function Find-SgdbGame([string]$name, [string]$steamId) {
  if ($steamId -match '^\d+$') { try { $d = Invoke-Sgdb "games/steam/$steamId"; if ($d.id) { return [pscustomobject]@{ Id = $d.id; Name = $d.name; Exact = $true } } } catch {} }
  $clean = ($name -replace '[™®©]', '').Trim()
  $d = @(Invoke-Sgdb ("search/autocomplete/" + [uri]::EscapeDataString($clean)))
  if (-not $d.Count) { return $null }
  $norm = { param($s) (($s -replace '[™®©]', '') -replace '[^a-z0-9]', '').ToLower() }
  $exact = $d | Where-Object { (& $norm $_.name) -eq (& $norm $clean) } | Select-Object -First 1
  $hit = if ($exact) { $exact } else { $d[0] }
  [pscustomobject]@{ Id = $hit.id; Name = $hit.name; Exact = [bool]$exact }
}
function Get-SgdbArt($gameId, $tmp) {
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $art = @{}
  # static PNG/JPEG only (no animated or WebP, which Windows' image code can't read)
  $kinds = @(
    @{ k = 'tall'; q = "grids/game/${gameId}?dimensions=600x900&types=static&mimes=image/png,image/jpeg" },
    @{ k = 'wide'; q = "grids/game/${gameId}?dimensions=920x430,460x215&types=static&mimes=image/png,image/jpeg" },
    @{ k = 'hero'; q = "heroes/game/${gameId}?types=static&mimes=image/png,image/jpeg" },
    @{ k = 'logo'; q = "logos/game/${gameId}?types=static&mimes=image/png" })
  foreach ($kd in $kinds) {
    try {
      $u = (@(Invoke-Sgdb $kd.q) | Select-Object -First 1).url
      if ($u) { $dst = Join-Path $tmp "sgdb-$($kd.k)$([IO.Path]::GetExtension(([uri]$u).AbsolutePath))"; Invoke-WebRequest $u -OutFile $dst -UseBasicParsing -TimeoutSec 30; $art[$kd.k] = $dst }
    } catch {}
  }
  $art
}

# Photos for the loading screen slideshow: art\<appid>\ next to the launcher.
# SteamGridDB backgrounds (needs the key), Steam store screenshots, Epic's wide images.
function Save-Backgrounds($g, [uint32]$appid, $log) {
  $dir = Join-Path $Here "art\$appid"
  $tmp = Join-Path $env:TEMP "esl-bg-$appid"
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $urls = New-Object System.Collections.Generic.List[string]
  if (Get-SgdbKey) {
    try {
      $sg = Find-SgdbGame $g.Name $g.SteamId
      if ($sg) { @(Invoke-Sgdb "heroes/game/$($sg.Id)?types=static&mimes=image/png,image/jpeg") | Select-Object -First 5 | ForEach-Object { $urls.Add($_.url) } }
    } catch {}
  }
  $sid = $g.SteamId
  if (-not $sid) { $hit = Find-SteamAppId $g.Name; if ($hit -and $hit.Exact) { $sid = $hit.Id } }
  if ($sid) {
    try {
      $d = Invoke-RestMethod "https://store.steampowered.com/api/appdetails?appids=$sid&filters=screenshots" -UseBasicParsing -TimeoutSec 20
      @($d.$sid.data.screenshots) | Select-Object -First 6 | ForEach-Object { if ($_.path_full) { $urls.Add(($_.path_full -replace '\?.*$', '')) } }
    } catch {}
  }
  # Epic's wide images often have the logo printed on them, so only use them when there's little else
  if ($urls.Count -lt 3) { foreach ($t in 'DieselStoreFrontWide', 'OfferImageWide', 'DieselGameBox') {
    $u = ($g.Images | Where-Object { $_.type -eq $t } | Select-Object -First 1).url
    if ($u -and -not $urls.Contains($u)) { $urls.Add($u) }
  } }
  $n = 0
  foreach ($u in $urls) {
    $ext = [IO.Path]::GetExtension(([uri]$u).AbsolutePath).ToLower(); if ($ext -notin '.jpg', '.jpeg', '.png') { $ext = '.jpg' }
    $dst = Join-Path $tmp ("bg{0:00}{1}" -f ($n + 1), $ext)
    try {
      Invoke-WebRequest $u -OutFile $dst -UseBasicParsing -TimeoutSec 30
      $img = [Drawing.Image]::FromFile($dst); $ok = $img.Width -ge 1000; $img.Dispose()   # skip small pictures
      if ($ok) { $n++ } else { Remove-Item $dst }
    } catch { Remove-Item $dst -ErrorAction SilentlyContinue }
  }
  if ($n -gt 0) {
    if ($Test) { & $log "   [test] would save $n loading-screen photo(s)"; return }
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Split-Path $dir) | Out-Null
    Move-Item $tmp $dir
    & $log "   loading screen: $n photo(s)"
  } else { & $log '   loading screen: no extra photos found (uses the cover art)' }
}

function Install-Art($art, $gridDir, [uint32]$appid) {
  New-Item -ItemType Directory -Force $gridDir | Out-Null
  if ($art.tall) { Save-Fitted $art.tall (Join-Path $gridDir "${appid}p.jpg") 600 900 }
  if ($art.wide) { Save-Fitted $art.wide (Join-Path $gridDir "$appid.jpg") 920 430 }
  $heroSrc = if ($art.hero) { $art.hero } else { $art.wide }
  if ($heroSrc) { Save-Fitted $heroSrc (Join-Path $gridDir "${appid}_hero.jpg") 1920 620 }
  if ($art.logo) { Copy-Item $art.logo (Join-Path $gridDir "${appid}_logo.png") -Force }
}

# ---------------------------------------------------------------- main action
function Invoke-Make($games, $accounts, [bool]$moonlight, $log, [string]$artSource = 'Epic') {
  $steamWasRunning = [bool](Get-Process steam -ErrorAction SilentlyContinue)
  if ($steamWasRunning -and -not $Test) {
    & $log 'Closing Steam...'
    Start-Process "$Steam\steam.exe" -ArgumentList '-shutdown'
    for ($i = 0; $i -lt 60 -and (Get-Process steam -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    if (Get-Process steam -ErrorAction SilentlyContinue) { throw 'Steam did not close. Exit Steam from the tray icon and try again.' }
  }
  $tiles = @()
  Set-EpicLaunchArgs $games $log
  foreach ($g in $games) {
    & $log "== $($g.Name)"
    $tmp = Join-Path $env:TEMP "esl-art-$([Math]::Abs($g.Name.GetHashCode()))"
    $art = @{}
    # fill any missing picture from the next source: SteamGridDB -> Steam -> Epic
    $addMissing = { param($more) foreach ($k in @($more.Keys)) { if (-not $art.ContainsKey($k)) { $art[$k] = $more[$k] } } }
    if ($artSource -eq 'SteamGridDB') {
      try {
        $sg = Find-SgdbGame $g.Name $g.SteamId
        if ($sg) { & $log "   SteamGridDB match: $($sg.Name)$(if (-not $sg.Exact) { ' - not an exact name match, check it' })"; & $addMissing (Get-SgdbArt $sg.Id $tmp) }
        else { & $log '   not found on SteamGridDB' }
      } catch { & $log "   SteamGridDB: $($_.Exception.Message)" }
    }
    if ($artSource -eq 'Steam' -or ($artSource -eq 'SteamGridDB' -and $art.Count -lt 4)) {
      if (-not $g.SteamId) { $hit = Find-SteamAppId $g.Name; if ($hit) { $g.SteamId = $hit.Id; & $log "   Steam match: $($hit.Name) (App ID $($hit.Id))$(if (-not $hit.Exact) { ' - not an exact name match, check it' })" } }
      if ($g.SteamId) { & $addMissing (Get-SteamArt $g.SteamId $tmp) } elseif ($artSource -eq 'Steam') { & $log '   not found on Steam' }
    }
    if ($art.Count -lt 3) { & $addMissing (Get-Art $g $tmp) }
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
    Save-Backgrounds $g $appid $log
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
  if ($Test) { Invoke-Make $games @($accounts | Where-Object Default) $false { param($m) Write-Host $m } $Art }
  return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Epic to Steam" Width="1180" Height="880" WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="CanMinimize" Background="#0E1116" BorderBrush="#263040" BorderThickness="1"
        FontFamily="Segoe UI Variable Display, Segoe UI" Foreground="#E8EDF3" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#1A9FFF"/>
    <SolidColorBrush x:Key="Muted" Color="#8A96A8"/>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#334055"/></ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="50"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="12">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#2D6BF9" Offset="0"/>
                  <GradientStop Color="#19B5FF" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <Border.Effect><DropShadowEffect Color="#1A9FFF" BlurRadius="22" ShadowDepth="0" Opacity="0.45"/></Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Secondary" TargetType="Button">
      <Setter Property="Foreground" Value="#E8EDF3"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="10" Background="#1E2530" BorderBrush="#2E3948" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#263040"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Foreground" Value="#8A96A8"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#222A36"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#E8EDF3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Row" Background="#1A2029" CornerRadius="10" Padding="14,10" Margin="0,0,0,8">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <ContentPresenter VerticalAlignment="Center"/>
                <Border x:Name="Track" Grid.Column="1" Width="42" Height="24" CornerRadius="12" Background="#2A3342" VerticalAlignment="Center">
                  <Border x:Name="Knob" Width="18" Height="18" CornerRadius="9" Background="#8A96A8" HorizontalAlignment="Left" Margin="3,0"/>
                </Border>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Row" Property="Background" Value="#202835"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#1A9FFF"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Background" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#8A96A8"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" CornerRadius="8" Padding="6,8" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#1E2530"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="#1A9FFF"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Field" TargetType="Control">
      <Setter Property="Foreground" Value="#E8EDF3"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <ControlTemplate x:Key="FieldTemplate" TargetType="Control">
      <Border x:Name="B" Background="#0E1116" BorderBrush="#2E3948" BorderThickness="1" CornerRadius="8" Padding="8,6">
        <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="#1A9FFF"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>

    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#6F7C8F"/>
      <Setter Property="Margin" Value="2,16,0,8"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="84"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="400"/></Grid.ColumnDefinitions>

    <!-- header -->
    <Grid x:Name="Header" Grid.ColumnSpan="2" Background="Transparent">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="28,0,0,0">
        <Border Width="44" Height="44" CornerRadius="12" Margin="0,0,14,0">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#2D6BF9" Offset="0"/><GradientStop Color="#19B5FF" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <TextBlock Text="&#xE7FC;" FontFamily="Segoe MDL2 Assets" FontSize="22" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Epic to Steam" FontSize="22" FontWeight="SemiBold"/>
          <TextBlock Text="Your Epic games in Steam, with the Steam overlay, controller support and a loading screen" FontSize="12.5" Foreground="{StaticResource Muted}" Margin="0,2,0,0"/>
        </StackPanel>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,10,10,0">
        <Button x:Name="MinBtn" Style="{StaticResource Chrome}" Content="&#xE921;" FontFamily="Segoe MDL2 Assets" FontSize="10"/>
        <Button x:Name="CloseBtn" Style="{StaticResource Chrome}" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" FontSize="10"/>
      </StackPanel>
    </Grid>

    <!-- games -->
    <Grid Grid.Row="1" Margin="28,0,12,24">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <Grid Margin="0,0,16,14">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Installed Epic games" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Bottom"/>
          <TextBlock x:Name="GameCount" FontSize="13" Foreground="{StaticResource Muted}" Margin="10,0,0,1" VerticalAlignment="Bottom"/>
        </StackPanel>
        <TextBlock x:Name="SelectAll" Text="Select all" Foreground="{StaticResource Accent}" FontSize="13" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
      </Grid>
      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <WrapPanel x:Name="Cards"/>
      </ScrollViewer>
      <TextBlock x:Name="Empty" Grid.Row="1" Visibility="Collapsed" Foreground="{StaticResource Muted}" FontSize="14"
                 Text="No installed Epic games found." HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Grid>

    <!-- side panel -->
    <Border Grid.Row="1" Grid.Column="1" Background="#151A21" CornerRadius="16" Margin="0,0,24,24" Padding="22,6,22,22">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <StackPanel>
          <TextBlock Text="STEAM ACCOUNTS" Style="{StaticResource Section}"/>
          <StackPanel x:Name="Accounts"/>

          <TextBlock Text="COVER ART AND LOADING SCREEN PHOTOS" Style="{StaticResource Section}"/>
          <Border Background="#0E1116" CornerRadius="10" Padding="4">
            <UniformGrid Columns="3">
              <RadioButton x:Name="ArtEpic" Style="{StaticResource Seg}" GroupName="Art" Content="Epic"/>
              <RadioButton x:Name="ArtSteam" Style="{StaticResource Seg}" GroupName="Art" Content="Steam"/>
              <RadioButton x:Name="ArtSgdb" Style="{StaticResource Seg}" GroupName="Art" Content="SteamGridDB"/>
            </UniformGrid>
          </Border>
          <Grid x:Name="KeyRow" Margin="0,10,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <PasswordBox x:Name="KeyBox" CaretBrush="#E8EDF3" Style="{StaticResource Field}" Template="{StaticResource FieldTemplate}" ToolTip="SteamGridDB API key"/>
            <TextBlock x:Name="KeyLink" Grid.Column="1" Text="Get a key" Foreground="{StaticResource Accent}" FontSize="12.5" Cursor="Hand" VerticalAlignment="Center" Margin="12,0,2,0"/>
          </Grid>
          <TextBlock x:Name="ArtHint" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="2,8,0,0"/>

          <TextBlock Text="OPTIONS" Style="{StaticResource Section}"/>
          <CheckBox x:Name="Moonlight" Style="{StaticResource Switch}">
            <StackPanel>
              <TextBlock Text="Moonlight tile" FontSize="14"/>
              <TextBlock Text="Also show the game in Moonlight (asks for admin once)" FontSize="11.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
            </StackPanel>
          </CheckBox>

          <Grid Margin="0,10,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Button x:Name="FindBtn" Style="{StaticResource Secondary}" Content="Find Steam IDs"/>
            <Button x:Name="DbBtn" Grid.Column="2" Style="{StaticResource Secondary}" Content="Open SteamDB"/>
          </Grid>
          <Button x:Name="GoBtn" Style="{StaticResource Primary}" Margin="0,14,0,0" Content="Select games to add"/>
          <TextBlock Text="Steam closes and reopens by itself while games are added." FontSize="11.5" Foreground="{StaticResource Muted}" HorizontalAlignment="Center" Margin="0,8,0,0"/>
          <Border x:Name="Banner" CornerRadius="10" Padding="12,10" Margin="0,12,0,0" Visibility="Collapsed" BorderThickness="1">
            <TextBlock x:Name="BannerText" FontSize="13" TextWrapping="Wrap"/>
          </Border>
        </StackPanel>

        <Grid Grid.Row="1" Margin="0,4,0,0">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock Text="ACTIVITY" Style="{StaticResource Section}"/>
          <Border Grid.Row="1" Background="#0B0E12" CornerRadius="10" Padding="10,8" MinHeight="90">
            <TextBox x:Name="Log" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#9FB0C4"
                     FontFamily="Cascadia Mono, Consolas" FontSize="11.5" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
          </Border>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$cardXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="180" Margin="0,0,16,16" CornerRadius="14" Background="#1A2029" BorderThickness="2" BorderBrush="Transparent">
  <StackPanel>
    <Grid x:Name="Pick" Height="240" Cursor="Hand" Background="Transparent">
      <Border CornerRadius="12,12,0,0" Background="#222A36">
        <TextBlock x:Name="Initials" FontSize="40" FontWeight="Bold" Foreground="#3A4658" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <Border x:Name="Cover" CornerRadius="12,12,0,0"/>
      <Border x:Name="Shade" CornerRadius="12,12,0,0" Background="#661A9FFF" Visibility="Collapsed"/>
      <Border x:Name="InSteam" CornerRadius="6" Background="#CC0E1116" Padding="7,3" Margin="10" HorizontalAlignment="Left" VerticalAlignment="Top" Visibility="Collapsed">
        <TextBlock Text="IN STEAM" FontSize="10" FontWeight="Bold" Foreground="#7FD1FF"/>
      </Border>
      <Border x:Name="Check" Width="30" Height="30" CornerRadius="15" Background="#1A9FFF" Margin="10" HorizontalAlignment="Right" VerticalAlignment="Top" Visibility="Collapsed">
        <Border.Effect><DropShadowEffect BlurRadius="10" ShadowDepth="0" Opacity="0.6"/></Border.Effect>
        <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </Grid>
    <TextBlock x:Name="Title" Margin="12,10,12,0" FontSize="13.5" FontWeight="SemiBold" Foreground="#E8EDF3" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" Height="38"/>
    <Grid Margin="12,6,12,12">
      <Border Background="#0E1116" CornerRadius="7" BorderBrush="#2E3948" BorderThickness="1" Padding="7,4">
        <Grid>
          <TextBlock x:Name="IdHint" Text="Steam App ID" FontSize="11.5" Foreground="#5B677A" IsHitTestVisible="False" VerticalAlignment="Center"/>
          <TextBox x:Name="SteamId" Background="Transparent" BorderThickness="0" Foreground="#E8EDF3" CaretBrush="#E8EDF3" FontSize="11.5" Padding="0"/>
        </Grid>
      </Border>
    </Grid>
  </StackPanel>
</Border>
'@

$win = [Windows.Markup.XamlReader]::Parse($xaml)
$iconPath = Join-Path $Here 'icon.ico'; if (Test-Path $iconPath) { try { $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([uri]$iconPath) } catch {} }
$ui = @{}
foreach ($n in 'Header','MinBtn','CloseBtn','Cards','Empty','GameCount','SelectAll','Accounts','ArtEpic','ArtSteam','ArtSgdb','KeyRow','KeyBox','KeyLink','ArtHint','Moonlight','FindBtn','DbBtn','GoBtn','Banner','BannerText','Log') { $ui[$n] = $win.FindName($n) }

$ui.Header.Add_MouseLeftButtonDown({ $win.DragMove() })
$ui.MinBtn.Add_Click({ $win.WindowState = 'Minimized' })
$ui.CloseBtn.Add_Click({ $win.Close() })

$log = {
  param($m)
  $ui.Log.AppendText($m + "`r`n"); $ui.Log.ScrollToEnd()
  $win.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)   # let the window repaint
}
function Show-Banner([string]$text, [bool]$ok) {
  $bc = New-Object Windows.Media.BrushConverter
  $ui.Banner.Background = $bc.ConvertFrom($(if ($ok) { '#14301F' } else { '#3A1518' }))
  $ui.Banner.BorderBrush = $bc.ConvertFrom($(if ($ok) { '#2F9E5B' } else { '#E5484D' }))
  $ui.BannerText.Foreground = $bc.ConvertFrom($(if ($ok) { '#8FE3B0' } else { '#FFB4B6' }))
  $ui.BannerText.Text = $text; $ui.Banner.Visibility = 'Visible'
}

# ---- accounts ----
$accSwitches = @()
foreach ($a in $accounts) {
  $cb = New-Object Windows.Controls.CheckBox
  $cb.Style = $win.FindResource('Switch')
  $sp = New-Object Windows.Controls.StackPanel
  $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = ($a.Name -replace '\s*\(id \d+\)$', ''); $t1.FontSize = 14
  $t2 = New-Object Windows.Controls.TextBlock; $t2.Text = "Steam ID $($a.Id)"; $t2.FontSize = 11.5; $t2.Foreground = $win.FindResource('Muted')
  [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
  $cb.Content = $sp; $cb.IsChecked = [bool]$a.Default
  [void]$ui.Accounts.Children.Add($cb); $accSwitches += $cb
}

# ---- which games are already in Steam (any ticked-by-default account) ----
function Get-InSteam {
  $names = @{}
  foreach ($a in $accounts) {
    try { foreach ($s in (Read-Shortcuts "$Steam\userdata\$($a.Id)\config\shortcuts.vdf")) { $nm = $s['AppName']; if (-not $nm) { $nm = $s['appname'] }; if ($nm) { $names[$nm] = $true } } } catch {}
  }
  $names
}

# ---- game cards ----
$cards = New-Object System.Collections.ArrayList
function Update-Go {
  $c = @($cards | Where-Object { $_.Selected }).Count
  $ui.GoBtn.IsEnabled = $c -gt 0
  $ui.GoBtn.Content = if ($c -eq 0) { 'Select games to add' } elseif ($c -eq 1) { 'Add 1 game to Steam' } else { "Add $c games to Steam" }
  $ui.SelectAll.Text = if ($c -eq $cards.Count -and $c -gt 0) { 'Clear selection' } else { 'Select all' }
}
function Set-Selected($card, [bool]$on) {
  $card.Selected = $on
  $vis = if ($on) { 'Visible' } else { 'Collapsed' }
  $card.Check.Visibility = $vis; $card.Shade.Visibility = $vis
  $card.Root.BorderBrush = if ($on) { $win.FindResource('Accent') } else { [Windows.Media.Brushes]::Transparent }
}
$inSteam = Get-InSteam
for ($i = 0; $i -lt $games.Count; $i++) {
  $g = $games[$i]
  $root = [Windows.Markup.XamlReader]::Parse($cardXaml)
  $card = [pscustomobject]@{ Root = $root; Check = $root.FindName('Check'); Shade = $root.FindName('Shade'); Id = $root.FindName('SteamId'); Badge = $root.FindName('InSteam'); Selected = $false; Game = $g }
  $root.FindName('Title').Text = $g.Name
  $root.FindName('Initials').Text = (($g.Name -split '\s+' | Where-Object { $_ -match '^\w' } | Select-Object -First 2 | ForEach-Object { $_.Substring(0, 1) }) -join '').ToUpper()
  if ($inSteam[$g.Name]) { $card.Badge.Visibility = 'Visible' }
  $hint = $root.FindName('IdHint')
  $card.Id.Tag = $hint
  $card.Id.Add_TextChanged({ param($s, $e) $s.Tag.Visibility = if ($s.Text) { 'Collapsed' } else { 'Visible' } })
  # portrait cover from Epic (WPF downloads it in the background)
  $u = ($g.Images | Where-Object { $_.type -eq 'DieselGameBoxTall' } | Select-Object -First 1).url
  if (-not $u) { $u = ($g.Images | Where-Object { $_.type -in 'OfferImageTall', 'Thumbnail' } | Select-Object -First 1).url }
  if ($u) {
    try {
      $bi = New-Object Windows.Media.Imaging.BitmapImage
      $bi.BeginInit(); $bi.UriSource = [uri]$u; $bi.DecodePixelWidth = 360; $bi.CacheOption = 'OnLoad'; $bi.EndInit()
      $br = New-Object Windows.Media.ImageBrush $bi; $br.Stretch = 'UniformToFill'
      $root.FindName('Cover').Background = $br
    } catch {}
  }
  $pick = $root.FindName('Pick'); $pick.Tag = $card
  $pick.Add_MouseLeftButtonUp({ param($s, $e) $c = $s.Tag; Set-Selected $c (-not $c.Selected); Update-Go })
  $root.Add_MouseEnter({ param($s, $e) if ($s.BorderBrush -eq [Windows.Media.Brushes]::Transparent) { $s.Background = (New-Object Windows.Media.BrushConverter).ConvertFrom('#202835') } })
  $root.Add_MouseLeave({ param($s, $e) $s.Background = (New-Object Windows.Media.BrushConverter).ConvertFrom('#1A2029') })
  [void]$ui.Cards.Children.Add($root); [void]$cards.Add($card)
}
$ui.GameCount.Text = "$($games.Count) found"
if (-not $games.Count) { $ui.Empty.Visibility = 'Visible' }
$ui.SelectAll.Add_MouseLeftButtonUp({
  $all = @($cards | Where-Object { $_.Selected }).Count -lt $cards.Count
  foreach ($c in $cards) { Set-Selected $c $all }; Update-Go
})
Update-Go

# ---- art source ----
$ui.KeyBox.Password = (Get-SgdbKey)
$setHint = {
  $ui.KeyRow.Visibility = if ($ui.ArtSgdb.IsChecked) { 'Visible' } else { 'Collapsed' }
  $ui.ArtHint.Text = if ($ui.ArtSgdb.IsChecked) { 'Community art from SteamGridDB. Missing pictures come from Steam, then Epic.' }
                     elseif ($ui.ArtSteam.IsChecked) { 'Official Steam store art. Games not on Steam use Epic art.' }
                     else { "Epic's own art. Always available." }
}
foreach ($rb in $ui.ArtEpic, $ui.ArtSteam, $ui.ArtSgdb) { $rb.Add_Checked($setHint) }
if ($ui.KeyBox.Password) { $ui.ArtSgdb.IsChecked = $true } else { $ui.ArtEpic.IsChecked = $true }
& $setHint
$ui.KeyLink.Add_MouseLeftButtonUp({ Start-Process 'https://www.steamgriddb.com/profile/preferences/api' })

# ---- buttons ----
$ui.FindBtn.Add_Click({
  $ui.FindBtn.IsEnabled = $false; $ui.Log.Clear(); $ui.Banner.Visibility = 'Collapsed'
  foreach ($c in $cards) {
    $hit = Find-SteamAppId $c.Game.Name
    if ($hit) { $c.Id.Text = $hit.Id; & $log "$($c.Game.Name) -> $($hit.Name) ($($hit.Id))$(if (-not $hit.Exact) { '  <- check this one' })" }
    else { & $log "$($c.Game.Name) -> not on Steam (Epic art will be used)" }
  }
  if (-not $ui.ArtSgdb.IsChecked) { $ui.ArtSteam.IsChecked = $true }
  $ui.FindBtn.IsEnabled = $true
})
$ui.DbBtn.Add_Click({
  $c = @($cards | Where-Object { $_.Selected }) | Select-Object -First 1
  if (-not $c) { $c = $cards | Select-Object -First 1 }
  if (-not $c) { return }
  $id = $c.Id.Text.Trim()
  Start-Process $(if ($id -match '^\d+$') { "https://steamdb.info/app/$id/" } else { "https://steamdb.info/search/?a=app&q=" + [uri]::EscapeDataString($c.Game.Name) })
})
$ui.GoBtn.Add_Click({
  $ui.Banner.Visibility = 'Collapsed'
  $sel = @()
  foreach ($c in $cards) { if ($c.Selected) { $id = $c.Id.Text.Trim(); $c.Game.SteamId = if ($id -match '^\d+$') { $id } else { $null }; $sel += $c.Game } }
  $acc = @(); for ($i = 0; $i -lt $accounts.Count; $i++) { if ($accSwitches[$i].IsChecked) { $acc += $accounts[$i] } }
  if (-not $acc) { Show-Banner 'Turn on at least one Steam account.' $false; return }
  $k = $ui.KeyBox.Password.Trim()
  if ($k -ne (Get-SgdbKey)) { if ($k) { [IO.File]::WriteAllText($SgdbKeyFile, $k) } elseif (Test-Path $SgdbKeyFile) { Remove-Item $SgdbKeyFile } }
  if ($ui.ArtSgdb.IsChecked -and -not $k) { Show-Banner 'Paste your SteamGridDB API key first, or pick another art source.' $false; return }
  $src = if ($ui.ArtSgdb.IsChecked) { 'SteamGridDB' } elseif ($ui.ArtSteam.IsChecked) { 'Steam' } else { 'Epic' }
  $ui.GoBtn.IsEnabled = $false; $ui.FindBtn.IsEnabled = $false; $ui.Log.Clear(); $win.Cursor = [Windows.Input.Cursors]::Wait
  $ui.GoBtn.Content = 'Working...'
  try {
    Invoke-Make $sel $acc ([bool]$ui.Moonlight.IsChecked) $log $src
    Show-Banner "Done! $($sel.Count) game$(if ($sel.Count -ne 1) { 's' }) added to Steam." $true
    $now = Get-InSteam; foreach ($c in $cards) { if ($now[$c.Game.Name]) { $c.Badge.Visibility = 'Visible' }; Set-Selected $c $false }
  }
  catch { & $log "ERROR: $($_.Exception.Message)"; Show-Banner "Something went wrong: $($_.Exception.Message)" $false }
  $win.Cursor = $null; $ui.FindBtn.IsEnabled = $true; Update-Go
})

if ($Snapshot) {
  for ($i = 0; $i -lt $accSwitches.Count; $i++) {
    $sp = $accSwitches[$i].Content
    $sp.Children[0].Text = @('Player One', 'Player Two', 'Living Room')[$i % 3]
    $sp.Children[1].Text = 'Steam ID ' + (12345678 + $i * 1111111)
  }
  if ($cards.Count) { Set-Selected $cards[0] $true; Update-Go }
  $ui.Log.Text = "Grand Theft Auto V Enhanced -> Grand Theft Auto V Enhanced (3240220)`r`n== Grand Theft Auto V Enhanced`r`n   SteamGridDB match: Grand Theft Auto V Enhanced`r`n   cover art: hero, wide, logo, tall`r`n   loading screen: 11 photo(s)"
  $win.Add_ContentRendered({
    $tm = New-Object Windows.Threading.DispatcherTimer; $tm.Interval = [TimeSpan]::FromSeconds(6)
    $tm.Add_Tick({
      param($s, $e) $s.Stop()
      $c = $win.Content
      $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$c.ActualWidth), ([int]$c.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
      $bgv = New-Object Windows.Media.DrawingVisual; $dc = $bgv.RenderOpen(); $dc.DrawRectangle($win.Background, $null, (New-Object Windows.Rect 0, 0, $c.ActualWidth, $c.ActualHeight)); $dc.Close(); $rtb.Render($bgv)
      $rtb.Render($c)
      $enc2 = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc2.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
      $fs = [IO.File]::Create($Snapshot); $enc2.Save($fs); $fs.Close(); $win.Close()
    })
    $tm.Start()
  })
}
[void]$win.ShowDialog()
