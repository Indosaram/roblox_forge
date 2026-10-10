# render-art.ps1 - programmatic launch art for the Kaiju Egg Raiders pack.
#
# Renders the store icon and thumbnail A/B variants with System.Drawing only
# (no generative models, no network). Run from anywhere:
#
#   powershell -ExecutionPolicy Bypass -File cli/forge/tools/render-art.ps1
#
# Output lives under assets/launchart-gdi/, a separate directory from the one
# `forge gen launchart` owns (assets/icon/, assets/thumbnails/): System.Drawing
# output is font- and GDI-version dependent, so it is not byte-stable, and
# `assets/manifest.yml` records the Luau-rendered files as tool forge-procgen.
# Silently overwriting those files here would make the manifest's provenance
# claim (forge-procgen) inaccurate. To publish a GDI-rendered variant instead,
# copy the desired file from assets/launchart-gdi/ over the forge gen launchart
# output by hand and update its manifest entry's tool/source yourself.
#
# Outputs:
#   games/kaiju-egg-raiders/assets/launchart-gdi/icon/icon-a.png        512x512   orange egg + lightning crack
#   games/kaiju-egg-raiders/assets/launchart-gdi/icon/icon-b.png        512x512   teal egg + claw marks
#   games/kaiju-egg-raiders/assets/launchart-gdi/thumbnails/thumb-a.png 1920x1080 "Hatch. Merge. Raid." Red vs Blue vault siege
#   games/kaiju-egg-raiders/assets/launchart-gdi/thumbnails/thumb-b.png 1920x1080 "Team Siege every 10 min" egg lineup

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
$packDir = Join-Path $repoRoot "games/kaiju-egg-raiders"
$iconDir = Join-Path $packDir "assets/launchart-gdi/icon"
$thumbDir = Join-Path $packDir "assets/launchart-gdi/thumbnails"
New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
New-Item -ItemType Directory -Force -Path $thumbDir | Out-Null

$TITLE = "KAIJU EGG RAIDERS"

function C([int]$r, [int]$g, [int]$b) {
	return [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
}

function CA([int]$a, [int]$r, [int]$g, [int]$b) {
	return [System.Drawing.Color]::FromArgb($a, $r, $g, $b)
}

function Shade([System.Drawing.Color]$color, [int]$delta) {
	$r = [Math]::Max(0, [Math]::Min(255, $color.R + $delta))
	$g = [Math]::Max(0, [Math]::Min(255, $color.G + $delta))
	$b = [Math]::Max(0, [Math]::Min(255, $color.B + $delta))
	return [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
}

function New-Graphics([System.Drawing.Bitmap]$bitmap) {
	$g = [System.Drawing.Graphics]::FromImage($bitmap)
	$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
	$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
	$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
	$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
	return $g
}

function New-Font([single]$size, [string]$family = "Arial") {
	return [System.Drawing.Font]::new($family, $size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
}

# Draws text centered on $centerX, shrinking the font until it fits $maxWidth.
function Draw-FittedText(
	[System.Drawing.Graphics]$g,
	[string]$text,
	[single]$centerX,
	[single]$top,
	[single]$maxWidth,
	[single]$maxSize,
	[System.Drawing.Color]$color
) {
	$size = $maxSize
	$font = New-Font $size
	while ($true) {
		$measured = $g.MeasureString($text, $font)
		if ($measured.Width -le $maxWidth -or $size -le 8) { break }
		$font.Dispose()
		$size -= 2
		if ($size -lt 8) { $size = 8 }
		$font = New-Font $size
	}
	$width = $g.MeasureString($text, $font).Width
	$x = $centerX - ($width / 2)
	$shadow = [System.Drawing.SolidBrush]::new((CA 190 0 0 0))
	$g.DrawString($text, $font, $shadow, ([single]($x + 3)), ([single]($top + 3)))
	$brush = [System.Drawing.SolidBrush]::new($color)
	$g.DrawString($text, $font, $brush, ([single]$x), ([single]$top))
	$brush.Dispose()
	$shadow.Dispose()
	$font.Dispose()
}

function Draw-Label(
	[System.Drawing.Graphics]$g,
	[string]$text,
	[single]$centerX,
	[single]$top,
	[single]$size,
	[System.Drawing.Color]$color,
	[bool]$shadow = $true
) {
	$font = New-Font $size
	$width = $g.MeasureString($text, $font).Width
	$x = $centerX - ($width / 2)
	if ($shadow) {
		$shadowBrush = [System.Drawing.SolidBrush]::new((CA 180 0 0 0))
		$g.DrawString($text, $font, $shadowBrush, ([single]($x + 2)), ([single]($top + 2)))
		$shadowBrush.Dispose()
	}
	$brush = [System.Drawing.SolidBrush]::new($color)
	$g.DrawString($text, $font, $brush, ([single]$x), ([single]$top))
	$brush.Dispose()
	$font.Dispose()
}

function New-EggPath([single]$cx, [single]$cy, [single]$w, [single]$h) {
	$path = [System.Drawing.Drawing2D.GraphicsPath]::new()
	$top = $cy - $h / 2
	$bottom = $cy + $h / 2
	$left = $cx - $w / 2
	$right = $cx + $w / 2
	$path.StartFigure()
	$path.AddBezier($cx, $top, ($cx + $w * 0.42), ($top + $h * 0.08), $right, ($cy - $h * 0.18), $right, ($cy + $h * 0.05))
	$path.AddBezier($right, ($cy + $h * 0.05), $right, ($bottom - $h * 0.06), ($cx + $w * 0.32), $bottom, $cx, $bottom)
	$path.AddBezier($cx, $bottom, ($cx - $w * 0.32), $bottom, $left, ($bottom - $h * 0.06), $left, ($cy + $h * 0.05))
	$path.AddBezier($left, ($cy + $h * 0.05), $left, ($cy - $h * 0.18), ($cx - $w * 0.42), ($top + $h * 0.08), $cx, $top)
	$path.CloseFigure()
	return $path
}

function Draw-Egg(
	[System.Drawing.Graphics]$g,
	[single]$cx,
	[single]$cy,
	[single]$w,
	[single]$h,
	[System.Drawing.Color]$light,
	[System.Drawing.Color]$dark
) {
	$path = New-EggPath $cx $cy $w $h
	$rect = [System.Drawing.RectangleF]::new(($cx - $w / 2), ($cy - $h / 2), $w, $h)
	$brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new($rect, $light, $dark, [single]65)
	$g.FillPath($brush, $path)
	$brush.Dispose()
	$outline = [System.Drawing.Pen]::new((CA 150 0 0 0), [single]([Math]::Max(2, $w * 0.02)))
	$g.DrawPath($outline, $path)
	$outline.Dispose()
	$path.Dispose()
}

# A bright zigzag crack with a soft glow, drawn over the egg.
function Draw-Crack([System.Drawing.Graphics]$g, [single]$cx, [single]$cy) {
	$points = [System.Drawing.PointF[]]@(
		[System.Drawing.PointF]::new(($cx - 6), ($cy - 108)),
		[System.Drawing.PointF]::new(($cx + 34), ($cy - 28)),
		[System.Drawing.PointF]::new(($cx - 22), ($cy - 8)),
		[System.Drawing.PointF]::new(($cx + 30), ($cy + 64)),
		[System.Drawing.PointF]::new(($cx - 10), ($cy + 86)),
		[System.Drawing.PointF]::new(($cx + 12), ($cy + 122))
	)
	$glow = [System.Drawing.Pen]::new((CA 130 255 210 60), [single]22)
	$glow.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
	$glow.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
	$glow.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
	$g.DrawLines($glow, $points)
	$glow.Dispose()
	$core = [System.Drawing.Pen]::new((C 255 250 170), [single]7)
	$core.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
	$core.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
	$core.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
	$g.DrawLines($core, $points)
	$core.Dispose()
}

# Three tapered talon gouges raked across the egg.
function Draw-ClawMarks([System.Drawing.Graphics]$g, [single]$cx, [single]$cy) {
	for ($i = 0; $i -lt 3; $i++) {
		$offset = $cx - 34 + ($i * 34)
		$x1 = $offset - 20
		$y1 = $cy + 104
		$x2 = $offset + 26
		$y2 = $cy - 96

		$shadow = [System.Drawing.Pen]::new((CA 170 0 0 0), [single](20 - ($i * 2)))
		$shadow.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
		$shadow.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
		$g.DrawLine($shadow, ([single]($x1 + 3)), ([single]($y1 + 3)), ([single]($x2 + 3)), ([single]($y2 + 3)))
		$shadow.Dispose()

		$gouge = [System.Drawing.Pen]::new((CA 235 12 54 66), [single](16 - ($i * 2)))
		$gouge.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
		$gouge.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
		$g.DrawLine($gouge, ([single]$x1), ([single]$y1), ([single]$x2), ([single]$y2))
		$gouge.Dispose()

		$edge = [System.Drawing.Pen]::new((CA 210 225 255 255), [single]4)
		$edge.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
		$edge.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
		$g.DrawLine($edge, ([single]($x1 - 3)), ([single]($y1 - 3)), ([single]($x2 - 3)), ([single]($y2 - 3)))
		$edge.Dispose()
	}
}

function Draw-Background([System.Drawing.Graphics]$g, [int]$w, [int]$h, [System.Drawing.Color]$top, [System.Drawing.Color]$bottom) {
	$rect = [System.Drawing.Rectangle]::new(0, 0, $w, $h)
	$brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new($rect, $top, $bottom, [single]90)
	$g.FillRectangle($brush, $rect)
	$brush.Dispose()
}

function Draw-Glow([System.Drawing.Graphics]$g, [single]$cx, [single]$cy, [single]$radius, [System.Drawing.Color]$color) {
	$brush = [System.Drawing.SolidBrush]::new($color)
	$g.FillEllipse($brush, ([single]($cx - $radius)), ([single]($cy - $radius)), ([single]($radius * 2)), ([single]($radius * 2)))
	$brush.Dispose()
}

# Isometric vault cube: front face, top face, side face.
function Draw-Vault(
	[System.Drawing.Graphics]$g,
	[single]$x,
	[single]$y,
	[single]$w,
	[System.Drawing.Color]$front
) {
	$h = $w * 1.2
	$d = $w * 0.42
	$top = Shade $front 70
	$side = Shade $front -60

	$topFace = [System.Drawing.PointF[]]@(
		[System.Drawing.PointF]::new($x, ($y + $d)),
		[System.Drawing.PointF]::new(($x + $w), ($y + $d)),
		[System.Drawing.PointF]::new(($x + $w + $d), $y),
		[System.Drawing.PointF]::new(($x + $d), $y)
	)
	$sideFace = [System.Drawing.PointF[]]@(
		[System.Drawing.PointF]::new(($x + $w), ($y + $d)),
		[System.Drawing.PointF]::new(($x + $w + $d), $y),
		[System.Drawing.PointF]::new(($x + $w + $d), ($y + $h)),
		[System.Drawing.PointF]::new(($x + $w), ($y + $h + $d))
	)
	$frontFace = [System.Drawing.PointF[]]@(
		[System.Drawing.PointF]::new($x, ($y + $d)),
		[System.Drawing.PointF]::new(($x + $w), ($y + $d)),
		[System.Drawing.PointF]::new(($x + $w), ($y + $h + $d)),
		[System.Drawing.PointF]::new($x, ($y + $h + $d))
	)

	$brush = [System.Drawing.SolidBrush]::new($top)
	$g.FillPolygon($brush, $topFace)
	$brush.Dispose()
	$brush = [System.Drawing.SolidBrush]::new($side)
	$g.FillPolygon($brush, $sideFace)
	$brush.Dispose()
	$brush = [System.Drawing.SolidBrush]::new($front)
	$g.FillPolygon($brush, $frontFace)
	$brush.Dispose()

	# Lock dial on the front face.
	$dial = [System.Drawing.SolidBrush]::new((CA 210 20 20 24))
	$r = $w * 0.22
	$g.FillEllipse($dial, ([single]($x + $w / 2 - $r)), ([single]($y + $h / 2 + $d - $r)), ([single]($r * 2)), ([single]($r * 2)))
	$dial.Dispose()
	$ring = [System.Drawing.Pen]::new((CA 230 255 255 255), [single]([Math]::Max(4, $w * 0.035)))
	$g.DrawEllipse($ring, ([single]($x + $w / 2 - $r)), ([single]($y + $h / 2 + $d - $r)), ([single]($r * 2)), ([single]($r * 2)))
	$ring.Dispose()
}

function Draw-Bolt([System.Drawing.Graphics]$g, [single]$cx, [single]$cy, [single]$scale) {
	$points = [System.Drawing.PointF[]]@(
		[System.Drawing.PointF]::new(($cx + 10 * $scale), ($cy - 150 * $scale)),
		[System.Drawing.PointF]::new(($cx - 70 * $scale), ($cy + 10 * $scale)),
		[System.Drawing.PointF]::new(($cx - 10 * $scale), ($cy + 10 * $scale)),
		[System.Drawing.PointF]::new(($cx - 40 * $scale), ($cy + 150 * $scale)),
		[System.Drawing.PointF]::new(($cx + 80 * $scale), ($cy - 20 * $scale)),
		[System.Drawing.PointF]::new(($cx + 20 * $scale), ($cy - 20 * $scale))
	)
	$glow = [System.Drawing.SolidBrush]::new((CA 90 255 220 80))
	$g.FillPolygon($glow, $points)
	$glow.Dispose()
	$brush = [System.Drawing.SolidBrush]::new((C 255 235 90))
	$g.FillPolygon($brush, $points)
	$brush.Dispose()
	$pen = [System.Drawing.Pen]::new((CA 200 255 255 255), [single]3)
	$g.DrawPolygon($pen, $points)
	$pen.Dispose()
}

$orangeLight = C 255 176 74
$orangeDark = C 196 62 16
$tealLight = C 96 236 226
$tealDark = C 16 108 132

# ---------------------------------------------------------------- icon A ----
$bmp = [System.Drawing.Bitmap]::new(512, 512)
$g = New-Graphics $bmp
Draw-Background $g 512 512 (C 22 24 38) (C 44 14 50)
Draw-Glow $g 256 220 210 (CA 70 255 140 40)
Draw-Egg $g 256 215 202 252 $orangeLight $orangeDark
Draw-Crack $g 256 214
Draw-FittedText $g $TITLE 256 428 470 58 (C 255 236 210)
$g.Dispose()
$bitmap = $bmp
$bitmap.Save((Join-Path $iconDir "icon-a.png"), [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host ("rendered {0} (512x512)" -f (Join-Path $iconDir "icon-a.png"))
$bitmap.Dispose()

# ---------------------------------------------------------------- icon B ----
$bmp = [System.Drawing.Bitmap]::new(512, 512)
$g = New-Graphics $bmp
Draw-Background $g 512 512 (C 12 28 40) (C 10 46 56)
Draw-Glow $g 256 220 210 (CA 70 60 220 235)
Draw-Egg $g 256 215 202 252 $tealLight $tealDark
Draw-ClawMarks $g 256 214
Draw-FittedText $g $TITLE 256 428 470 58 (C 224 252 255)
$g.Dispose()
$bitmap = $bmp
$bitmap.Save((Join-Path $iconDir "icon-b.png"), [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host ("rendered {0} (512x512)" -f (Join-Path $iconDir "icon-b.png"))
$bitmap.Dispose()

# ----------------------------------------------------------- thumbnail A ----
$bmp = [System.Drawing.Bitmap]::new(1920, 1080)
$g = New-Graphics $bmp
Draw-Background $g 1920 1080 (C 12 14 30) (C 48 12 56)

# Siege ground.
$ground = [System.Drawing.SolidBrush]::new((C 18 18 28))
$g.FillRectangle($ground, 0, 900, 1920, 180)
$ground.Dispose()
$groundLine = [System.Drawing.Pen]::new((CA 160 90 60 160), [single]4)
$g.DrawLine($groundLine, 0, 900, 1920, 900)
$groundLine.Dispose()

Draw-Label $g $TITLE 960 46 56 (C 255 178 84)
Draw-FittedText $g "Hatch. Merge. Raid." 960 148 1720 132 (C 255 255 255)

# Red team vault (left) vs Blue team vault (right).
Draw-Vault $g 300 520 230 (C 214 52 52)
Draw-Vault $g 1390 520 230 (C 58 110 226)
Draw-Label $g "RED" 530 872 40 (C 255 130 130)
Draw-Label $g "BLUE" 1620 872 40 (C 150 180 255)

# Clash in the middle.
Draw-Bolt $g 960 660 1.6

# Eggs caught between the vaults.
$eggXs = @(770, 880, 990, 1100)
for ($i = 0; $i -lt $eggXs.Count; $i++) {
	if ($i % 2 -eq 0) {
		Draw-Egg $g $eggXs[$i] 800 84 106 $orangeLight $orangeDark
	} else {
		Draw-Egg $g $eggXs[$i] 800 84 106 $tealLight $tealDark
	}
}

$g.Dispose()
$bitmap = $bmp
$bitmap.Save((Join-Path $thumbDir "thumb-a.png"), [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host ("rendered {0} (1920x1080)" -f (Join-Path $thumbDir "thumb-a.png"))
$bitmap.Dispose()

# ----------------------------------------------------------- thumbnail B ----
$bmp = [System.Drawing.Bitmap]::new(1920, 1080)
$g = New-Graphics $bmp
Draw-Background $g 1920 1080 (C 10 20 36) (C 8 52 62)

# Stage shelf behind the egg lineup.
$shelf = [System.Drawing.SolidBrush]::new((CA 90 10 40 50))
$g.FillRectangle($shelf, 0, 760, 1920, 320)
$shelf.Dispose()
$shelfLine = [System.Drawing.Pen]::new((CA 150 70 220 230), [single]4)
$g.DrawLine($shelfLine, 0, 760, 1920, 760)
$shelfLine.Dispose()

Draw-Label $g $TITLE 960 46 56 (C 255 178 84)
Draw-FittedText $g "Team Siege every 10 min" 960 150 1760 118 (C 255 255 255)

# Egg lineup: alternating Ember and Tidal.
$eggColors = @(
	@($orangeLight, $orangeDark, "EMBER"),
	@($tealLight, $tealDark, "TIDAL"),
	@($orangeLight, $orangeDark, "EMBER"),
	@($tealLight, $tealDark, "TIDAL"),
	@($orangeLight, $orangeDark, "EMBER"),
	@($tealLight, $tealDark, "TIDAL")
)
for ($i = 0; $i -lt $eggColors.Count; $i++) {
	$cx = 360 + ($i * 240)
	Draw-Glow $g $cx 600 150 (CA 45 $eggColors[$i][0].R $eggColors[$i][0].G $eggColors[$i][0].B)
	Draw-Egg $g $cx 600 168 214 $eggColors[$i][0] $eggColors[$i][1]
	Draw-Label $g $eggColors[$i][2] $cx 742 34 (C 226 244 255)
}

$g.Dispose()
$bitmap = $bmp
$bitmap.Save((Join-Path $thumbDir "thumb-b.png"), [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host ("rendered {0} (1920x1080)" -f (Join-Path $thumbDir "thumb-b.png"))
$bitmap.Dispose()

Write-Host "render-art: done"
