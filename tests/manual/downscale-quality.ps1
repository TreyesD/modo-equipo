param([switch]$Live, [double]$Scale = 0.4, [string]$Out = "$PSScriptRoot\out", [int]$SrcW = 1000, [int]$SrcH = 600)
# Compares ways of downscaling a text-heavy "screen" to Scale: live Magnification API, live DWM thumbnail,
# and offline resamplers on the identical source. Shows two small windows on the main screen for ~2 s.
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class ShNoAct : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams { get { CreateParams p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; } } // NOACTIVATE | TOOLWINDOW
}

[StructLayout(LayoutKind.Sequential)] public struct ShRect { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct ShThumb {
    public uint Flags; public ShRect Dest; public ShRect Src; public byte Opacity;
    [MarshalAs(UnmanagedType.Bool)] public bool Visible; [MarshalAs(UnmanagedType.Bool)] public bool ClientOnly;
}

public static class Sh {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] public static extern int DwmRegisterThumbnail(IntPtr dest, IntPtr src, out IntPtr thumb);
    [DllImport("dwmapi.dll")] public static extern int DwmUpdateThumbnailProperties(IntPtr thumb, ref ShThumb p);
    [DllImport("dwmapi.dll")] public static extern int DwmUnregisterThumbnail(IntPtr thumb);
    [DllImport("Magnification.dll")] static extern bool MagInitialize();
    [DllImport("Magnification.dll")] static extern bool MagUninitialize();
    [DllImport("Magnification.dll")] static extern bool MagSetWindowSource(IntPtr h, ShRect r);
    [DllImport("Magnification.dll")] static extern bool MagSetWindowTransform(IntPtr h, ref ShMag t);
    [StructLayout(LayoutKind.Sequential)] public struct ShMag { [MarshalAs(UnmanagedType.ByValArray, SizeConst = 9)] public float[] v; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
    [DllImport("gdi32.dll")] public static extern bool StretchBlt(IntPtr d, int dx, int dy, int dw, int dh, IntPtr s, int sx, int sy, int sw, int sh, int rop);
    [DllImport("gdi32.dll")] public static extern int SetStretchBltMode(IntPtr hdc, int mode);
    [DllImport("gdi32.dll")] public static extern bool SetBrushOrgEx(IntPtr hdc, int x, int y, IntPtr old);

    public static IntPtr MagHost(IntPtr parent, int w, int h, ShRect src, float scale) {
        if (!MagInitialize()) return IntPtr.Zero;
        IntPtr m = CreateWindowEx(0, "Magnifier", "m", 0x40000000 | 0x10000000, 0, 0, w, h, parent, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
        ShMag t = new ShMag(); t.v = new float[9]; t.v[0] = scale; t.v[4] = scale; t.v[8] = 1f;
        MagSetWindowTransform(m, ref t);
        MagSetWindowSource(m, src);
        return m;
    }
    public static void MagStop() { try { MagUninitialize(); } catch { } }

    // ---- float images: [h, w, 3] flattened --------------------------------------------------
    public static float[] ToFloat(Bitmap b) {
        int w = b.Width, h = b.Height; float[] o = new float[w * h * 3];
        BitmapData d = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        byte[] raw = new byte[d.Stride * h]; Marshal.Copy(d.Scan0, raw, 0, raw.Length); b.UnlockBits(d);
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { int i = y * d.Stride + x * 3, j = (y * w + x) * 3; o[j] = raw[i + 2]; o[j + 1] = raw[i + 1]; o[j + 2] = raw[i]; }
        return o;
    }
    public static Bitmap ToBitmap(float[] f, int w, int h) {
        Bitmap b = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        BitmapData d = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
        byte[] raw = new byte[d.Stride * h];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { int i = y * d.Stride + x * 3, j = (y * w + x) * 3;
            raw[i + 2] = Cl(f[j]); raw[i + 1] = Cl(f[j + 1]); raw[i] = Cl(f[j + 2]); }
        Marshal.Copy(raw, 0, d.Scan0, raw.Length); b.UnlockBits(d); return b;
    }
    static byte Cl(float v) { return (byte)(v < 0 ? 0 : v > 255 ? 255 : (int)(v + 0.5f)); }

    // kernels: 0 box, 1 triangle, 2 catmull-rom (bicubic), 3 lanczos3, 4 mitchell
    static double K(int kind, double x) {
        x = Math.Abs(x);
        switch (kind) {
            case 0: return x < 0.5 ? 1 : 0;
            case 1: return x < 1 ? 1 - x : 0;
            case 2: if (x < 1) return 1.5 * x * x * x - 2.5 * x * x + 1; if (x < 2) return -0.5 * x * x * x + 2.5 * x * x - 4 * x + 2; return 0;
            case 3: if (x < 1e-9) return 1; if (x >= 3) return 0; return 3 * Math.Sin(Math.PI * x) * Math.Sin(Math.PI * x / 3) / (Math.PI * Math.PI * x * x);
            default: { double B = 1.0 / 3, C = 1.0 / 3; if (x < 1) return ((12 - 9 * B - 6 * C) * x * x * x + (-18 + 12 * B + 6 * C) * x * x + (6 - 2 * B)) / 6; if (x < 2) return ((-B - 6 * C) * x * x * x + (6 * B + 30 * C) * x * x + (-12 * B - 48 * C) * x + (8 * B + 24 * C)) / 6; return 0; }
        }
    }
    static double Support(int kind) { return kind == 0 ? 0.5 : kind == 1 ? 1 : kind == 3 ? 3 : 2; }

    public static float[] Resample(float[] src, int sw, int sh, int dw, int dh, int kind) {
        float[] tmp = Pass(src, sw, sh, dw, sh, kind, true);
        return Pass(tmp, dw, sh, dw, dh, kind, false);
    }
    static float[] Pass(float[] s, int sw, int sh, int dw, int dh, int kind, bool horiz) {
        int n = horiz ? sw : sh, m = horiz ? dw : dh; double ratio = (double)n / m, fs = Math.Max(1.0, ratio), sup = Support(kind) * fs;
        float[] o = new float[dw * dh * 3];
        for (int i = 0; i < m; i++) {
            double c = (i + 0.5) * ratio; int lo = (int)Math.Floor(c - sup + 0.5), hi = (int)Math.Floor(c + sup + 0.5);
            List<int> idx = new List<int>(); List<double> wt = new List<double>(); double sum = 0;
            for (int k = lo; k <= hi; k++) { double w = K(kind, (k + 0.5 - c) / fs); if (w == 0) continue; int kk = k < 0 ? 0 : k >= n ? n - 1 : k; idx.Add(kk); wt.Add(w); sum += w; }
            for (int q = 0; q < wt.Count; q++) wt[q] /= sum;
            if (horiz) { for (int y = 0; y < sh; y++) for (int ch = 0; ch < 3; ch++) { double a = 0; for (int q = 0; q < idx.Count; q++) a += wt[q] * s[(y * sw + idx[q]) * 3 + ch]; o[(y * dw + i) * 3 + ch] = (float)a; } }
            else { for (int x = 0; x < dw; x++) for (int ch = 0; ch < 3; ch++) { double a = 0; for (int q = 0; q < idx.Count; q++) a += wt[q] * s[(idx[q] * sw + x) * 3 + ch]; o[(i * dw + x) * 3 + ch] = (float)a; } }
        }
        return o;
    }
    public static float[] Sharpen(float[] f, int w, int h, double amount) {
        float[] blur = Resample(f, w, h, w, h, 1); // identity: use a 3x3 blur instead
        float[] o = new float[f.Length];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) for (int c = 0; c < 3; c++) {
            double a = 0; int cnt = 0;
            for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) { int xx = Math.Min(w - 1, Math.Max(0, x + dx)), yy = Math.Min(h - 1, Math.Max(0, y + dy)); double wgt = (dx == 0 && dy == 0) ? 4 : (dx == 0 || dy == 0) ? 2 : 1; a += wgt * f[(yy * w + xx) * 3 + c]; cnt += (int)wgt; }
            double bl = a / cnt, v = f[(y * w + x) * 3 + c]; o[(y * w + x) * 3 + c] = (float)(v + amount * (v - bl));
        }
        return o;
    }
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr h, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr h);
    public static Bitmap Gdi(Bitmap src, int dw, int dh, int mode) {
        Bitmap d = new Bitmap(dw, dh, PixelFormat.Format24bppRgb);
        IntPtr hbS = src.GetHbitmap(), hbD = d.GetHbitmap();
        IntPtr ds = CreateCompatibleDC(IntPtr.Zero), dd = CreateCompatibleDC(IntPtr.Zero);
        IntPtr os = SelectObject(ds, hbS), od = SelectObject(dd, hbD);
        SetStretchBltMode(dd, mode); SetBrushOrgEx(dd, 0, 0, IntPtr.Zero);
        StretchBlt(dd, 0, 0, dw, dh, ds, 0, 0, src.Width, src.Height, 0x00CC0020);
        SelectObject(ds, os); SelectObject(dd, od);
        Bitmap res = Image.FromHbitmap(hbD);
        Bitmap o = new Bitmap(dw, dh, PixelFormat.Format24bppRgb); using (Graphics g = Graphics.FromImage(o)) g.DrawImageUnscaled(res, 0, 0);
        res.Dispose(); DeleteObject(hbS); DeleteObject(hbD); DeleteDC(ds); DeleteDC(dd); d.Dispose();
        return o;
    }
    public static Bitmap GdiPlus(Bitmap src, int dw, int dh, InterpolationMode m) {
        Bitmap d = new Bitmap(dw, dh, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(d)) { g.InterpolationMode = m; g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.DrawImage(src, new Rectangle(0, 0, dw, dh), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel); }
        return d;
    }

    // ---- metrics -----------------------------------------------------------------------------
    static float[] Luma(float[] f, int n) { float[] y = new float[n]; for (int i = 0; i < n; i++) y[i] = 0.299f * f[i * 3] + 0.587f * f[i * 3 + 1] + 0.114f * f[i * 3 + 2]; return y; }
    public static string Metrics(float[] a, float[] r, int w, int h) {
        float[] ya = Luma(a, w * h), yr = Luma(r, w * h);
        double mse = 0; for (int i = 0; i < ya.Length; i++) { double d = ya[i] - yr[i]; mse += d * d; } mse /= ya.Length;
        double psnr = mse < 1e-9 ? 99 : 10 * Math.Log10(255.0 * 255.0 / mse);
        // block SSIM (8x8, stride 4)
        double c1 = 6.5025, c2 = 58.5225, ss = 0; int cnt = 0;
        for (int by = 0; by + 8 <= h; by += 4) for (int bx = 0; bx + 8 <= w; bx += 4) {
            double ma = 0, mr = 0; for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) { ma += ya[(by + y) * w + bx + x]; mr += yr[(by + y) * w + bx + x]; } ma /= 64; mr /= 64;
            double va = 0, vr = 0, cv = 0; for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) { double da = ya[(by + y) * w + bx + x] - ma, dr = yr[(by + y) * w + bx + x] - mr; va += da * da; vr += dr * dr; cv += da * dr; } va /= 63; vr /= 63; cv /= 63;
            ss += ((2 * ma * mr + c1) * (2 * cv + c2)) / ((ma * ma + mr * mr + c1) * (va + vr + c2)); cnt++;
        }
        double ssim = ss / cnt;
        double ga = Grad(ya, w, h), gr = Grad(yr, w, h);
        return string.Format("{0:F2} {1:F4} {2:F2}", psnr, ssim, ga / gr);
    }
    static double Grad(float[] y, int w, int h) { double s = 0; for (int j = 1; j < h; j++) for (int i = 1; i < w; i++) s += Math.Abs(y[j * w + i] - y[j * w + i - 1]) + Math.Abs(y[j * w + i] - y[(j - 1) * w + i]); return s / (w * h); }
    // 10-90% rise width (in output pixels) of the vertical black bar's left edge, averaged over rows
    public static double EdgeWidth(float[] f, int w, int h, int x0, int x1, int y0, int y1) {
        double tot = 0; int n = 0;
        for (int y = y0; y < y1; y++) {
            double lo = 255, hi = 0; for (int x = x0; x < x1; x++) { double v = 0.299 * f[(y * w + x) * 3] + 0.587 * f[(y * w + x) * 3 + 1] + 0.114 * f[(y * w + x) * 3 + 2]; if (v < lo) lo = v; if (v > hi) hi = v; }
            if (hi - lo < 100) continue; double t10 = hi - 0.1 * (hi - lo), t90 = hi - 0.9 * (hi - lo); double xa = -1, xb = -1;
            for (int x = x0; x < x1 - 1; x++) { double v = 0.299 * f[(y * w + x) * 3] + 0.587 * f[(y * w + x) * 3 + 1] + 0.114 * f[(y * w + x) * 3 + 2], v2 = 0.299 * f[(y * w + x + 1) * 3] + 0.587 * f[(y * w + x + 1) * 3 + 1] + 0.114 * f[(y * w + x + 1) * 3 + 2];
                if (xa < 0 && v >= t10 && v2 < t10) xa = x + (v - t10) / (v - v2); if (xb < 0 && v >= t90 && v2 < t90) xb = x + (v - t90) / (v - v2); }
            if (xa >= 0 && xb >= 0) { tot += Math.Abs(xb - xa); n++; }
        }
        return n > 0 ? tot / n : -1;
    }
}
'@ -ErrorAction Stop

[void][Sh]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ---- the text-heavy source -------------------------------------------------------------------
$W = $SrcW; $H = $SrcH
$src = New-Object Drawing.Bitmap($W, $H, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [Drawing.Graphics]::FromImage($src)
$g.Clear([Drawing.Color]::White)
$g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$y = 8
foreach ($px in 11, 13, 15, 18, 22) {
    $f = New-Object Drawing.Font('Segoe UI', $px, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $g.DrawString("Quest log ${px}px: Level 42 HP 1523/2000 Gold 18,450 - Defeat the Ember Warden", $f, [Drawing.Brushes]::Black, 10, $y)
    $y += [int]($px * 1.6) + 4
    $f.Dispose()
}
# game-UI style: light text on dark panel
$panel = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(24, 32, 56))
$g.FillRectangle($panel, 10, $y + 4, 600, 150)
$f = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$fb = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$lines = 'Inventory   Skills   Map   Guild   Shop   Settings', 'Iron Sword +7      ATK 312   DEF 0      Durability 88/100', 'Leather Vest +3    ATK 0     DEF 145    Durability 61/100', 'Health Potion x24  Mana Potion x12   Scroll of Return x3'
$yy = $y + 12; foreach ($l in $lines) { $g.DrawString($l, $f, [Drawing.Brushes]::WhiteSmoke, 18, $yy); $yy += 24 }
$g.DrawString('SERVER  EU-West-3   Ping 48ms', $fb, [Drawing.Brushes]::Gold, 18, $yy + 8)
# sharp-edge bars (edge width probe) and thin line patterns (aliasing probe)
$g.FillRectangle([Drawing.Brushes]::Black, 700, 20, 60, 160)
for ($i = 0; $i -lt 40; $i++) { $g.FillRectangle([Drawing.Brushes]::Black, 780 + $i * 5, 20, 1 + ($i % 3), 160) }
$f2 = New-Object Drawing.Font('Consolas', 12, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$yy = $y + 190; while ($yy -lt $H - 14) { $g.DrawString('0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz  {}[]();:.,', $f2, [Drawing.Brushes]::Black, 10, $yy); $yy += 16 }
$g.Dispose()
$src.Save("$Out\source.png")

$dw = [int][Math]::Round($W * $Scale); $dh = [int][Math]::Round($H * $Scale)
"source ${W}x${H} -> ${dw}x${dh} (scale $Scale)"

if ($Live) {
# ---- live: show the source and two receivers on the main screen, no focus, ~2 s -----------------
$srcForm = New-Object ShNoAct
$srcForm.FormBorderStyle = 'None'; $srcForm.ShowInTaskbar = $false; $srcForm.StartPosition = 'Manual'; $srcForm.TopMost = $true
$srcForm.Location = New-Object Drawing.Point(0, 0); $srcForm.ClientSize = New-Object Drawing.Size($W, $H)
$srcForm.BackgroundImage = $src; $srcForm.BackgroundImageLayout = 'None'
$magForm = New-Object ShNoAct
$magForm.FormBorderStyle = 'None'; $magForm.ShowInTaskbar = $false; $magForm.StartPosition = 'Manual'; $magForm.TopMost = $true
$magForm.Location = New-Object Drawing.Point(($W + 20), 0); $magForm.ClientSize = New-Object Drawing.Size($dw, $dh)
$dwmForm = New-Object ShNoAct
$dwmForm.FormBorderStyle = 'None'; $dwmForm.ShowInTaskbar = $false; $dwmForm.StartPosition = 'Manual'; $dwmForm.TopMost = $true
$dwmForm.Location = New-Object Drawing.Point(($W + 20), ($dh + 20)); $dwmForm.ClientSize = New-Object Drawing.Size($dw, $dh)
$srcForm.Show(); $magForm.Show(); $dwmForm.Show()
$r = New-Object ShRect; $r.Left = 0; $r.Top = 0; $r.Right = $W; $r.Bottom = $H
$mag = [Sh]::MagHost($magForm.Handle, $dw, $dh, $r, [single]$Scale)
$thumb = [IntPtr]::Zero
$hr = [Sh]::DwmRegisterThumbnail($dwmForm.Handle, $srcForm.Handle, [ref]$thumb)
$tp = New-Object ShThumb
$tp.Flags = 1 -bor 4 -bor 8; $tp.Opacity = 255; $tp.Visible = $true
$tp.Dest.Left = 0; $tp.Dest.Top = 0; $tp.Dest.Right = $dw; $tp.Dest.Bottom = $dh
$hr2 = -1; if ($hr -eq 0) { $hr2 = [Sh]::DwmUpdateThumbnailProperties($thumb, [ref]$tp) }; "dwm register=$hr update=$hr2 thumb=$thumb struct=$([Runtime.InteropServices.Marshal]::SizeOf([type]'ShThumb'))"
$t = [Diagnostics.Stopwatch]::StartNew(); while ($t.ElapsedMilliseconds -lt 1000) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 }
function Grab($form, $w, $h) {
    $p = $form.PointToScreen([Drawing.Point]::Empty)
    $b = New-Object Drawing.Bitmap($w, $h, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $gg = [Drawing.Graphics]::FromImage($b); $gg.CopyFromScreen($p.X, $p.Y, 0, 0, $b.Size); $gg.Dispose(); $b
}
$liveMag = Grab $magForm $dw $dh
$liveDwm = Grab $dwmForm $dw $dh
$liveSrc = Grab $srcForm $W $H     # proves the screen showed the source 1:1
if ($thumb -ne [IntPtr]::Zero) { [void][Sh]::DwmUnregisterThumbnail($thumb) }
[Sh]::MagStop()
$srcForm.Close(); $magForm.Close(); $dwmForm.Close()
$sf = [Sh]::ToFloat($src)
$lf = [Sh]::ToFloat($liveSrc)
$diff = 0.0; for ($i = 0; $i -lt $sf.Length; $i += 97) { $diff += [Math]::Abs($sf[$i] - $lf[$i]) }
"screen showed the source 1:1: mean abs diff sampled = $([Math]::Round($diff / ($sf.Length / 97), 3))"
$liveMag.Save("$Out\live_magnification.png"); $liveDwm.Save("$Out\live_dwm.png")

}
$sf = [Sh]::ToFloat($src)
# ---- offline candidates on the identical source ----------------------------------------------------
$cands = [ordered]@{}
if ($Live) {
$cands['A live Magnification (current)'] = [Sh]::ToFloat($liveMag)
$cands['B live DWM thumbnail'] = [Sh]::ToFloat($liveDwm)
}
$cands['C GDI StretchBlt COLORONCOLOR (nearest)'] = [Sh]::ToFloat([Sh]::Gdi($src, $dw, $dh, 3))
$cands['D GDI StretchBlt HALFTONE'] = [Sh]::ToFloat([Sh]::Gdi($src, $dw, $dh, 4))
$cands['E GDI+ Bilinear'] = [Sh]::ToFloat([Sh]::GdiPlus($src, $dw, $dh, [Drawing.Drawing2D.InterpolationMode]::Bilinear))
$cands['F GDI+ HighQualityBicubic'] = [Sh]::ToFloat([Sh]::GdiPlus($src, $dw, $dh, [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic))
$cands['G area average (box)'] = [Sh]::Resample($sf, $W, $H, $dw, $dh, 0)
$cands['H Mitchell'] = [Sh]::Resample($sf, $W, $H, $dw, $dh, 4)
$ref = [Sh]::Resample($sf, $W, $H, $dw, $dh, 3)
$cands['I Lanczos3 (reference)'] = $ref
$cands['J Lanczos3 + sharpen 0.6'] = [Sh]::Sharpen($ref, $dw, $dh, 0.6)
$cands['K area average + sharpen 0.6'] = [Sh]::Sharpen($cands['G area average (box)'], $dw, $dh, 0.6)

if (Test-Path "$Out\gpu_0.4.png") { $gb = [Drawing.Bitmap]::FromFile("$Out\gpu_0.4.png"); $gb24 = New-Object Drawing.Bitmap($dw,$dh,[Drawing.Imaging.PixelFormat]::Format24bppRgb); $gx=[Drawing.Graphics]::FromImage($gb24); $gx.DrawImageUnscaled($gb,0,0); $gx.Dispose(); $cands['L GPU Lanczos3 (Direct3D, new)'] = [Sh]::ToFloat($gb24) }
# the black bar's left edge is at x=700*scale, rows 20..180
$ex0 = [int](690 * $Scale); $ex1 = [int](730 * $Scale); $ey0 = [int](30 * $Scale); $ey1 = [int](170 * $Scale)
$rows = foreach ($k in $cands.Keys) {
    $m = ([Sh]::Metrics($cands[$k], $ref, $dw, $dh)).Split(' ')
    $ew = [Sh]::EdgeWidth($cands[$k], $dw, $dh, $ex0, $ex1, $ey0, $ey1)
    [pscustomobject]@{ Method = $k; PSNR_vs_ref = $m[0]; SSIM_vs_ref = $m[1]; GradientRatio = $m[2]; EdgeWidthPx = [Math]::Round($ew, 2) }
}
$rows | Format-Table -AutoSize | Out-String -Width 200
$rows | ConvertTo-Json | Set-Content "$Out\metrics.json"

# ---- contact sheet: text crop of each method, enlarged 3x with nearest neighbour ------------------------------
$cw = [int](620 * $Scale); $ch = [int](200 * $Scale); $z = 3
$sheetW = $cw * $z + 8; $sheet = New-Object Drawing.Bitmap(($sheetW * 2), (([int][Math]::Ceiling($cands.Count / 2.0)) * ($ch * $z + 24)), [Drawing.Imaging.PixelFormat]::Format24bppRgb)
$sg = [Drawing.Graphics]::FromImage($sheet); $sg.Clear([Drawing.Color]::Gray); $sg.InterpolationMode = 'NearestNeighbor'; $sg.PixelOffsetMode = 'Half'
$lab = New-Object Drawing.Font('Segoe UI', 11, [Drawing.GraphicsUnit]::Pixel); $i = 0
foreach ($k in $cands.Keys) {
    $b = [Sh]::ToBitmap($cands[$k], $dw, $dh)
    $ox = ($i % 2) * $sheetW; $oy = [int][Math]::Floor($i / 2) * ($ch * $z + 24)
    $sg.DrawString($k, $lab, [Drawing.Brushes]::White, $ox + 2, $oy + 4)
    $sg.DrawImage($b, (New-Object Drawing.Rectangle(($ox + 2), ($oy + 20), ($cw * $z), ($ch * $z))), 0, 0, $cw, $ch, [Drawing.GraphicsUnit]::Pixel)
    $b.Dispose(); $i++
}
$sg.Dispose(); $sheet.Save("$Out\sheet.png"); "saved $Out\sheet.png"
