# Draws the app icon (icon.ico + icon.png): a blue gradient rounded square with a white
# game controller and a small "launch" arrow badge.
Add-Type -AssemblyName System.Drawing
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

function New-IconBitmap([int]$s) {
  $bmp = New-Object Drawing.Bitmap $s, $s
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
  $pad = [Math]::Max(1, $s * 0.04); $r = $s * 0.24; $w = $s - 2 * $pad
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $path.AddArc($pad, $pad, 2 * $r, 2 * $r, 180, 90); $path.AddArc($pad + $w - 2 * $r, $pad, 2 * $r, 2 * $r, 270, 90)
  $path.AddArc($pad + $w - 2 * $r, $pad + $w - 2 * $r, 2 * $r, 2 * $r, 0, 90); $path.AddArc($pad, $pad + $w - 2 * $r, 2 * $r, 2 * $r, 90, 90); $path.CloseFigure()
  $rect = New-Object Drawing.RectangleF $pad, $pad, $w, $w
  $bg = New-Object Drawing.Drawing2D.LinearGradientBrush $rect, ([Drawing.Color]::FromArgb(255, 0x2D, 0x5B, 0xF0)), ([Drawing.Color]::FromArgb(255, 0x19, 0xC0, 0xFF)), 45
  $g.FillPath($bg, $path)
  # soft top highlight
  $hrect = New-Object Drawing.RectangleF $pad, ($pad - 1), $w, ($w * 0.62 + 2); $hl = New-Object Drawing.Drawing2D.LinearGradientBrush $hrect, ([Drawing.Color]::FromArgb(60, 255, 255, 255)), ([Drawing.Color]::FromArgb(0, 255, 255, 255)), 90
  $g.SetClip($path); $g.FillRectangle($hl, $pad, $pad, $w, $w * 0.62); $g.ResetClip()

  # controller glyph
  $glyph = [string][char]0xE7FC
  $font = New-Object Drawing.Font 'Segoe MDL2 Assets', ($s * 0.50), ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $shadow = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(60, 0, 20, 60))
  $g.DrawString($glyph, $font, $shadow, (New-Object Drawing.RectangleF 0, ($s * 0.03), $s, ($s * 0.94)), $sf)
  $g.DrawString($glyph, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, 0, $s, ($s * 0.94)), $sf)

  # launch badge (bottom right): dark circle with a play arrow
  if ($s -ge 32) {
    $d = $s * 0.36; $bx = $s - $d - $pad * 1.2; $by = $s - $d - $pad * 1.2
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 0x0E, 0x11, 0x16))), $bx, $by, $d, $d)
    $ring = New-Object Drawing.Pen ([Drawing.Color]::White), ([Math]::Max(1, $s * 0.025)); $g.DrawEllipse($ring, $bx, $by, $d, $d)
    $cx = $bx + $d / 2 + $d * 0.05; $cy = $by + $d / 2; $a = $d * 0.22
    $tri = [Drawing.PointF[]]@((New-Object Drawing.PointF ($cx - $a * 0.8), ($cy - $a)), (New-Object Drawing.PointF ($cx + $a), $cy), (New-Object Drawing.PointF ($cx - $a * 0.8), ($cy + $a)))
    $g.FillPolygon((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 0x19, 0xC0, 0xFF))), $tri)
  }
  $g.Dispose(); $bmp
}

$sizes = 256, 128, 64, 48, 32, 24, 16
$pngs = foreach ($s in $sizes) { $b = New-IconBitmap $s; $ms = New-Object IO.MemoryStream; $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png); if ($s -eq 256) { $b.Save((Join-Path $Here 'icon.png'), [Drawing.Imaging.ImageFormat]::Png) }; $b.Dispose(); , $ms.ToArray() }

# write a multi-size .ico (PNG-compressed entries)
$fs = [IO.File]::Create((Join-Path $Here 'icon.ico')); $w = New-Object IO.BinaryWriter $fs
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $len = $pngs[$i].Length
  $w.Write([byte]($s % 256)); $w.Write([byte]($s % 256)); $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$len); $w.Write([uint32]$offset); $offset += $len
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Close()
Write-Host 'icon.ico and icon.png written'
