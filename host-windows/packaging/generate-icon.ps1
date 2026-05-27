# Generates host-windows/assets/icon.ico, a multi-resolution Windows icon
# matching the procedural monitor drawn at runtime by ui::make_icon()
# (dark bezel, blue screen, gray stand + base on a transparent field,
# laid out on a 64-unit grid). Run on Windows with PowerShell:
#
#   pwsh host-windows/packaging/generate-icon.ps1
#
# The .ico is committed to the repo; only re-run this if the icon design
# in src/ui.rs changes.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outPath = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\assets\icon.ico'))

# Rectangles expressed on the same 64-unit grid as ui::make_icon():
#   x0, y0, x1, y1
$bezel  = @(4, 6, 60, 46)
$screen = @(8, 10, 56, 42)
$stand  = @(28, 46, 36, 54)
$base   = @(18, 54, 46, 58)

$bezelColor  = [System.Drawing.Color]::FromArgb(255, 38, 42, 50)
$screenColor = [System.Drawing.Color]::FromArgb(255, 58, 132, 255)
$standColor  = [System.Drawing.Color]::FromArgb(255, 180, 180, 190)

function New-MonitorPng([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $scale = $size / 64.0

    function Fill($rect, $color) {
        $x = [int][math]::Floor($rect[0] * $scale)
        $y = [int][math]::Floor($rect[1] * $scale)
        $w = [int][math]::Ceiling($rect[2] * $scale) - $x
        $h = [int][math]::Ceiling($rect[3] * $scale) - $y
        if ($w -lt 1) { $w = 1 }
        if ($h -lt 1) { $h = 1 }
        $brush = New-Object System.Drawing.SolidBrush($color)
        try { $g.FillRectangle($brush, $x, $y, $w, $h) }
        finally { $brush.Dispose() }
    }

    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
        $g.Clear([System.Drawing.Color]::Transparent)
        Fill $bezel  $bezelColor
        Fill $screen $screenColor
        Fill $stand  $standColor
        Fill $base   $standColor
    }
    finally {
        $g.Dispose()
    }

    $ms = New-Object System.IO.MemoryStream
    try {
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        # Unary comma prevents PowerShell from unrolling the byte[] on return.
        return , $ms.ToArray()
    }
    finally {
        $ms.Dispose()
        $bmp.Dispose()
    }
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngImages = New-Object 'System.Collections.Generic.List[byte[]]'
foreach ($size in $sizes) {
    $pngImages.Add((New-MonitorPng $size))
}

# Assemble the ICO container. Each entry stores a PNG payload, which
# Windows Vista+ reads natively and keeps the file small.
$out = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($out)
try {
    $count = $pngImages.Count
    $writer.Write([uint16]0)      # reserved
    $writer.Write([uint16]1)      # type: icon
    $writer.Write([uint16]$count) # image count

    $offset = 6 + (16 * $count)
    for ($i = 0; $i -lt $count; $i++) {
        $size = $sizes[$i]
        $len = $pngImages[$i].Length
        $dim = if ($size -ge 256) { 0 } else { $size }
        $writer.Write([byte]$dim)        # width  (0 => 256)
        $writer.Write([byte]$dim)        # height (0 => 256)
        $writer.Write([byte]0)           # palette count
        $writer.Write([byte]0)           # reserved
        $writer.Write([uint16]1)         # color planes
        $writer.Write([uint16]32)        # bits per pixel
        $writer.Write([uint32]$len)
        $writer.Write([uint32]$offset)
        $offset += $len
    }

    for ($i = 0; $i -lt $count; $i++) {
        $writer.Write($pngImages[$i], 0, $pngImages[$i].Length)
    }

    $writer.Flush()
    [System.IO.File]::WriteAllBytes($outPath, $out.ToArray())
}
finally {
    $writer.Dispose()
    $out.Dispose()
}

$bytes = [System.IO.FileInfo]::new($outPath).Length
Write-Host "Wrote $outPath ($bytes bytes, $($sizes.Count) sizes)"
