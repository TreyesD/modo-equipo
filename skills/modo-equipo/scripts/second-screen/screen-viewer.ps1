param(
    [switch]$SelfTest,
    [switch]$Smoke,
    [int]$SmokeSeconds = 5,
    [string]$SmokeOn = '',
    [string]$Screen = '',
    [string]$ScreenId = ''
)
# Live, touch-style view of the second screen, shown on the main screen.
# Moving the pointer over the image puts the real cursor on the second screen (direct mode):
# clicks, drags, the wheel and typing are ordinary native input there. Push past any edge of the
# image, or press Ctrl+Alt+Q, to come back.
# The screen keeper (parsec-vdd.ps1) keeps the real cursor on the main screen(s) while a virtual
# screen exists; the viewer lets it cross in direct mode and turns that lock on or off from its
# toolbar.
# The picture comes from the Windows Magnification API (GPU, ~60 fps, real cursor shape); when it
# is not available the viewer falls back to a GDI screen copy.
# The window has no Windows title bar: a thin strip on top moves it and its edges resize it.
# The toolbar is a small rounded pill docked at the top centre (of the window, or of the screen
# in full screen): it rests as a thin handle, opens while the pointer is near it, can be slid
# along the top edge from its grip, and holds always-on-top, pointer, mute, mouse lock, next
# screen (when there are several), full screen, keep-open, minimize and close.
# -Screen <device> shows that screen (for example \\.\DISPLAY6); -ScreenId <id> names the
# screen keeper session it belongs to, so the viewer follows it if the keeper gives that session
# a new display. Without them it shows the first second screen.
# -SelfTest runs the layout checks without opening any window (exit code 0 = pass).
# -Smoke opens the viewer on the second screen for a few seconds, without direct mode, and
# prints which renderer it used (developer check). Halfway through it opens the toolbar.
# -SmokeOn <device> (with -Smoke) puts the viewer window on that screen instead, for
# screenshots when other windows cover the second screen.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

[StructLayout(LayoutKind.Sequential)] public struct SvPt { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)] public struct SvRect { public int Left; public int Top; public int Right; public int Bottom; }

public static class SvNative {
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(SvPt p);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint p);
    [DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint p);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr h, int index);
    // Always on top applies to the small window only: never in full screen (Alt+Tab and Win+Tab
    // must switch away normally), whatever the "always on top" toggle says.
    public static bool WantTopMost(bool fullScreen, bool onTopToggle) { return onTopToggle && !fullScreen; }
    public static bool IsTopMost(IntPtr h) { return (GetWindowLong(h, -20) & 0x8) != 0; }   // WS_EX_TOPMOST
    // Sets or clears the topmost state through the window manager (SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE).
    public static void SetTopMost(IntPtr h, bool on) {
        SetWindowPos(h, on ? new IntPtr(-1) : new IntPtr(-2), 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0010);
    }
}

// Borderless window that can still be resized from its edges and moved from any control.
public class SvForm : Form {
    public int Grip = 6;
    public bool Resizable = true;
    public bool NoActivate = false;
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    protected override bool ShowWithoutActivation { get { return NoActivate; } }
    public static void DragMove(Form f) { ReleaseCapture(); SendMessage(f.Handle, 0xA1, (IntPtr)2, IntPtr.Zero); }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (m.Msg == 0x84 && Resizable && WindowState == FormWindowState.Normal) {
            long lp = m.LParam.ToInt64();
            Point p = PointToClient(new Point((short)(lp & 0xFFFF), (short)((lp >> 16) & 0xFFFF)));
            bool l = p.X < Grip, r = p.X >= ClientSize.Width - Grip, t = p.Y < Grip, b = p.Y >= ClientSize.Height - Grip;
            int hit = 0;
            if (t && l) hit = 13; else if (t && r) hit = 14; else if (b && l) hit = 16; else if (b && r) hit = 17;
            else if (l) hit = 10; else if (r) hit = 11; else if (t) hit = 12; else if (b) hit = 15;
            if (hit != 0) m.Result = (IntPtr)hit;
        }
    }
}

// Floating toolbar: a small rounded pill docked at the top centre of the viewer (or of the screen
// in full screen). It rests as a thin handle and opens while the pointer is near it. It is a
// per-pixel-alpha layered window, so the corners, the shadow and the translucent background are
// anti-aliased on Windows 10 too. It never takes the focus.
public class SvBarButton {
    public string Id = "", Glyph = "", Tip = "";
    public bool On, Danger, GapBefore, Visible = true;
}
public class SvBarClickEventArgs : EventArgs {
    public string Id;
    public SvBarClickEventArgs(string id) { Id = id; }
}
public class SvBar : Form {
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
    [StructLayout(LayoutKind.Sequential)] struct PT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SZ { public int W, H; }
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dstDc, ref PT dst, ref SZ size, IntPtr srcDc, ref PT src, int key, ref BLENDFUNCTION blend, int flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);

    public readonly List<SvBarButton> Buttons = new List<SvBarButton>();
    public Rectangle DockRect;          // the bar is centred on the top edge of this rectangle
    public Rectangle Limit;           // and kept inside this one (the screen)
    public int Offset;                // horizontal offset from the anchor centre (dragging)
    public bool KeepOpen, ForceOpen;
    public Color Accent = Color.FromArgb(96, 170, 255);
    public string DragTip = "";
    public event EventHandler<SvBarClickEventArgs> ButtonClick;
    public event EventHandler WindowDrag;   // pressed the pill outside its buttons: move the viewer window

    readonly float k;
    readonly Font glyphFont;
    readonly Timer tick = new Timer();
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly ToolTip tip = new ToolTip();
    float t;                          // 0 = handle, 1 = open
    bool wantOpen;
    long lastNear = -100000, hoverSince;
    int hover = -1, pressed = -1;     // button index, -2 = drag grip
    bool tipShown, dragging;
    int dragX, dragOffset;
    Point winPos;
    Size winSize;

    int S(float v) { return (int)Math.Round(v * k); }
    int BtnW { get { return S(34); } }
    int BtnH { get { return S(30); } }
    int Pad { get { return S(5); } }
    int GripW { get { return S(16); } }
    int Gap { get { return S(9); } }
    int Shadow { get { return S(10); } }

    public SvBar(float scale, string glyphFamily) {
        k = scale;
        glyphFont = new Font(glyphFamily, S(14), GraphicsUnit.Pixel);
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        tip.ShowAlways = true;
        tick.Interval = 15;
        tick.Tick += delegate { Step(); };
    }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80000 | 0x80 | 0x08000000; return cp; }   // layered, tool window, no activate
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Render(); tick.Start(); }
    protected override void OnFormClosed(FormClosedEventArgs e) { tick.Stop(); base.OnFormClosed(e); }

    // --- geometry -------------------------------------------------------------------------
    List<SvBarButton> ShownButtons() { List<SvBarButton> l = new List<SvBarButton>(); foreach (SvBarButton b in Buttons) if (b.Visible) l.Add(b); return l; }
    Size OpenSize() {
        int w = Pad + GripW;
        foreach (SvBarButton b in ShownButtons()) w += BtnW + (b.GapBefore ? Gap : 0);
        return new Size(w + Pad, BtnH + 2 * Pad);
    }
    static float Ease(float v) { float u = 1 - v; return 1 - u * u * u; }
    // Pill rectangle inside the window for the current animation state.
    RectangleF PillRect() {
        Size o = OpenSize();
        float e = Ease(t);
        float w = S(46) + (o.Width - S(46)) * e, h = S(6) + (o.Height - S(6)) * e;
        float y = Shadow + S(2) + (S(4) - S(2)) * e;
        return new RectangleF(Shadow + (o.Width - w) / 2f, y, w, h);
    }
    Rectangle ButtonRect(int i) {
        int x = Shadow + Pad + GripW;
        List<SvBarButton> l = ShownButtons();
        for (int j = 0; j < l.Count; j++) {
            if (l[j].GapBefore) x += Gap;
            if (j == i) return new Rectangle(x, Shadow + S(4) + Pad, BtnW, BtnH);
            x += BtnW;
        }
        return Rectangle.Empty;
    }
    Rectangle GripRect() { return new Rectangle(Shadow + Pad, Shadow + S(4) + Pad, GripW, BtnH); }
    public Rectangle PillBounds {
        get { RectangleF p = PillRect(); return new Rectangle(winPos.X + (int)p.X, winPos.Y + (int)p.Y, (int)p.Width, (int)p.Height); }
    }
    public bool IsOpen { get { return t >= 1f; } }

    void Place() {
        Size o = OpenSize();
        winSize = new Size(o.Width + 2 * Shadow, o.Height + 2 * Shadow + S(4));
        int x = PlaceX(DockRect.X, DockRect.Width, Limit.Left, Limit.Right, o.Width, Shadow, ref Offset);
        winPos = new Point(x, DockRect.Top - Shadow);
    }
    // Left edge of the bar window: centred on the anchor plus the dragged offset, the offset kept
    // within the anchor's top edge, and the pill kept inside the screen limits.
    public static int PlaceX(int anchorX, int anchorW, int limitL, int limitR, int openW, int shadow, ref int offset) {
        int half = Math.Max(0, (anchorW - openW) / 2);
        offset = Math.Max(-half, Math.Min(half, offset));
        int winW = openW + 2 * shadow;
        int x = anchorX + anchorW / 2 + offset - winW / 2;
        if (limitR > limitL) x = Math.Max(limitL - shadow, Math.Min(limitR - winW + shadow, x));
        return x;
    }

    // --- public actions -------------------------------------------------------------------
    public void Redraw() { if (IsHandleCreated) Render(); }
    public void Open() { lastNear = clock.ElapsedMilliseconds; wantOpen = true; }
    public void ShowTip(string text, string id) {
        List<SvBarButton> l = ShownButtons();
        for (int i = 0; i < l.Count; i++) if (l[i].Id == id) {
            Rectangle r = ButtonRect(i);
            tip.Show(text, this, r.X, r.Bottom + S(10), 2500);
        }
    }
    public Point OpenCenter() {
        Size o = OpenSize();
        return new Point(winPos.X + Shadow + o.Width / 2, winPos.Y + Shadow + S(4) + o.Height / 2);
    }

    // --- behaviour ------------------------------------------------------------------------
    // The bar is only on screen while its viewer is: hidden when the viewer is minimized or
    // hidden, whatever KeepOpen says (KeepOpen only stops it folding into the handle).
    public static bool ShouldShow(bool ownerMinimized, bool ownerVisible, bool keepOpen) {
        return ownerVisible && !ownerMinimized;
    }
    public static bool OwnerShown(Form o, bool keepOpen) {
        return o != null && o.IsHandleCreated && ShouldShow(IsIconic(o.Handle), IsWindowVisible(o.Handle), keepOpen);
    }
    void Step() {
        if (!Visible) return;
        // Win32 state of the viewer window, so every way of minimizing it counts (its own button,
        // the taskbar, Win+M, a shell command), not only what WinForms reported.
        Form o = Owner;
        if (o != null && !OwnerShown(o, KeepOpen)) {
            if (tipShown) { tip.Hide(this); tipShown = false; }
            Hide();
            return;
        }
        long now = clock.ElapsedMilliseconds;
        Point c = Cursor.Position;
        Rectangle pill = PillBounds;
        Rectangle zone = t > 0.05f ? Rectangle.Inflate(pill, S(10), S(10))
                                   : new Rectangle(pill.X - S(18), DockRect.Top, pill.Width + S(36), S(12));
        if (zone.Contains(c)) lastNear = now;
        bool open = KeepOpen || ForceOpen || dragging || (now - lastNear) < 600;
        if (open != wantOpen) wantOpen = open;
        float target = wantOpen ? 1f : 0f;
        bool changed = false;
        if (t != target) {
            float stepT = tick.Interval / 160f;
            t = wantOpen ? Math.Min(1f, t + stepT) : Math.Max(0f, t - stepT);
            changed = true;
        }
        // Hover and tooltips, only while open.
        int h = -1;
        if (t >= 1f) {
            Point p = new Point(c.X - winPos.X, c.Y - winPos.Y);
            if (GripRect().Contains(p)) h = -2;
            List<SvBarButton> l = ShownButtons();
            for (int i = 0; i < l.Count; i++) if (ButtonRect(i).Contains(p)) h = i;
            if (!new Rectangle(winPos, winSize).Contains(c)) h = -1;
        }
        if (h != hover) {
            hover = h; hoverSince = now; changed = true;
            if (tipShown) { tip.Hide(this); tipShown = false; }
            Cursor = h == -2 ? Cursors.SizeWE : (h >= 0 ? Cursors.Hand : Cursors.Default);
        } else if (h != -1 && !tipShown && !dragging && now - hoverSince > 450) {
            string text = h == -2 ? DragTip : ShownButtons()[h].Tip;
            Rectangle r = h == -2 ? GripRect() : ButtonRect(h);
            if (!string.IsNullOrEmpty(text)) { tip.Show(text, this, r.X, r.Bottom + S(10), 4000); tipShown = true; }
        }
        if (changed) Render();
    }

    // What a left press does: "slide" (the dotted grip slides the bar along the edge), "button",
    // "window" (the rest of the pill drags the viewer window, so the bar never blocks moving it)
    // or "none" (outside the pill: the transparent margin).
    public static string PressAction(float openness, int hover, bool inPill) {
        if (openness >= 1f) {
            if (hover == -2) return "slide";
            if (hover >= 0) return "button";
        }
        return inPill ? "window" : "none";
    }
    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        string act = PressAction(t, hover, PillBounds.Contains(Cursor.Position));
        if (act == "slide") { dragging = true; dragX = Cursor.Position.X; dragOffset = Offset; Capture = true; }
        else if (act == "button") { pressed = hover; Render(); }
        else if (act == "window") { EventHandler h = WindowDrag; if (h != null) h(this, EventArgs.Empty); }
    }
    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        if (dragging) { Offset = dragOffset + Cursor.Position.X - dragX; Render(); }
    }
    protected override void OnMouseUp(MouseEventArgs e) {
        base.OnMouseUp(e);
        if (dragging) { dragging = false; Capture = false; return; }
        int p = pressed; pressed = -1;
        if (p >= 0 && p == hover) {
            Render();
            EventHandler<SvBarClickEventArgs> h = ButtonClick;
            if (h != null) h(this, new SvBarClickEventArgs(ShownButtons()[p].Id));
        } else if (p >= 0) Render();
    }

    // --- drawing --------------------------------------------------------------------------
    static GraphicsPath Round(RectangleF r, float rad) {
        GraphicsPath g = new GraphicsPath();
        rad = Math.Max(0.5f, Math.Min(rad, Math.Min(r.Width, r.Height) / 2f));
        float d = rad * 2;
        g.AddArc(r.X, r.Y, d, d, 180, 90);
        g.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        g.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        g.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        g.CloseFigure();
        return g;
    }
    static Color A(int a, Color c) { return Color.FromArgb(Math.Max(0, Math.Min(255, a)), c.R, c.G, c.B); }
    static Color Lighter(Color c, float f) { return Color.FromArgb(c.R + (int)((255 - c.R) * f), c.G + (int)((255 - c.G) * f), c.B + (int)((255 - c.B) * f)); }

    void Render() {
        Place();
        using (Bitmap bmp = new Bitmap(winSize.Width, winSize.Height, PixelFormat.Format32bppArgb))
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.Clear(Color.Transparent);
            RectangleF pill = PillRect();
            float e = Ease(t);
            float rad = Math.Min(pill.Height / 2f, S(12));
            // Soft shadow, slightly below the pill.
            int sh = Math.Max(2, (int)(Shadow * (0.4f + 0.6f * e)));
            for (int i = sh; i >= 1; i--) {
                RectangleF r = RectangleF.Inflate(pill, i, i); r.Offset(0, S(2));
                float f = 1f - (float)i / (sh + 1);
                using (GraphicsPath p = Round(r, rad + i))
                using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(16 * f * f), 0, 0, 0))) g.FillPath(b, p);
            }
            using (GraphicsPath p = Round(pill, rad)) {
                Color fill = e < 0.5f ? Color.FromArgb(210, 58, 60, 66) : Color.FromArgb(236, 32, 33, 37);
                using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
                using (Pen pen = new Pen(Color.FromArgb(e < 0.5f ? 90 : 44, 255, 255, 255), 1f)) g.DrawPath(pen, p);
            }
            float ca = Math.Max(0f, Math.Min(1f, (e - 0.55f) / 0.45f));   // contents fade in last
            if (ca > 0f) {
                int a = (int)(255 * ca);
                // Grip: two columns of dots.
                Rectangle gr = GripRect();
                using (SolidBrush b = new SolidBrush(A((int)(a * (hover == -2 || dragging ? 0.85f : 0.45f)), Color.White))) {
                    float dr = Math.Max(1.2f, k * 1.3f), cx = gr.X + gr.Width / 2f, cy = gr.Y + gr.Height / 2f;
                    for (int row = -1; row <= 1; row++) for (int col = 0; col < 2; col++)
                        g.FillEllipse(b, cx + (col == 0 ? -S(2.5f) : S(2.5f)) - dr, cy + row * S(5) - dr, 2 * dr, 2 * dr);
                }
                StringFormat sf = new StringFormat(); sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
                List<SvBarButton> l = ShownButtons();
                for (int i = 0; i < l.Count; i++) {
                    SvBarButton btn = l[i];
                    Rectangle r = ButtonRect(i);
                    if (btn.GapBefore) {
                        using (Pen sep = new Pen(A((int)(a * 0.16f), Color.White), 1f))
                            g.DrawLine(sep, r.X - Gap / 2f, r.Y + S(8), r.X - Gap / 2f, r.Bottom - S(8));
                    }
                    RectangleF hr = RectangleF.Inflate(r, -S(2), -S(1));
                    Color glyph = A(a, Color.FromArgb(232, 232, 236));
                    if (btn.On) {
                        using (GraphicsPath p = Round(hr, S(6))) using (SolidBrush b = new SolidBrush(A((int)(a * 0.28f), Accent))) g.FillPath(b, p);
                        glyph = A(a, Lighter(Accent, 0.35f));
                    }
                    if (i == hover) {
                        Color hc = btn.Danger ? Color.FromArgb(196, 43, 28) : Color.White;
                        int ha = btn.Danger ? a : (int)(a * (pressed == i ? 0.10f : 0.14f));
                        using (GraphicsPath p = Round(hr, S(6))) using (SolidBrush b = new SolidBrush(A(ha, hc))) g.FillPath(b, p);
                        if (btn.Danger) glyph = A(a, Color.White);
                    }
                    using (SolidBrush b = new SolidBrush(glyph)) g.DrawString(btn.Glyph, glyphFont, b, new RectangleF(r.X, r.Y + (pressed == i ? 1 : 0), r.Width, r.Height), sf);
                }
            }
            Push(bmp);
        }
    }

    void Push(Bitmap bmp) {
        IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen);
        IntPtr hb = bmp.GetHbitmap(Color.FromArgb(0)), old = SelectObject(mem, hb);
        try {
            PT dst; dst.X = winPos.X; dst.Y = winPos.Y;
            SZ size; size.W = bmp.Width; size.H = bmp.Height;
            PT src; src.X = 0; src.Y = 0;
            BLENDFUNCTION bf; bf.BlendOp = 0; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1;   // AC_SRC_ALPHA
            UpdateLayeredWindow(Handle, screen, ref dst, ref size, mem, ref src, 0, ref bf, 2);                       // ULW_ALPHA
        } finally {
            SelectObject(mem, old); DeleteObject(hb); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen);
        }
    }
}

// Windows Magnification API: a child window that shows another screen area, drawn by the GPU.
public static class SvMag {
    [StructLayout(LayoutKind.Sequential)] struct MAGTRANSFORM { [MarshalAs(UnmanagedType.ByValArray, SizeConst = 9)] public float[] v; }
    [DllImport("Magnification.dll")] static extern bool MagInitialize();
    [DllImport("Magnification.dll")] static extern bool MagUninitialize();
    [DllImport("Magnification.dll")] static extern bool MagSetWindowSource(IntPtr h, SvRect r);
    [DllImport("Magnification.dll")] static extern bool MagSetWindowTransform(IntPtr h, ref MAGTRANSFORM t);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
    [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr h, IntPtr r, bool erase);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
    public static bool Init() { try { return MagInitialize(); } catch { return false; } }
    public static void Shutdown() { try { MagUninitialize(); } catch { } }
    // WS_CHILD | WS_VISIBLE, plus MS_SHOWMAGNIFIEDCURSOR when the cursor should be drawn.
    public static IntPtr Create(IntPtr parent, bool showCursor) {
        int style = 0x40000000 | 0x10000000 | (showCursor ? 1 : 0);
        return CreateWindowEx(0, "Magnifier", "SvMag", style, 0, 0, 1, 1, parent, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
    }
    public static bool Place(IntPtr h, int x, int y, int w, int hh, float scale) {
        MoveWindow(h, x, y, w, hh, true);
        MAGTRANSFORM t = new MAGTRANSFORM(); t.v = new float[9];
        t.v[0] = scale; t.v[4] = scale; t.v[8] = 1f;
        return MagSetWindowTransform(h, ref t);
    }
    public static bool Show(IntPtr h, int x, int y, int w, int hh) {
        SvRect r; r.Left = x; r.Top = y; r.Right = x + w; r.Bottom = y + hh;
        bool ok = MagSetWindowSource(h, r);
        InvalidateRect(h, IntPtr.Zero, false);
        return ok;
    }
    public static void SetCursorVisible(IntPtr h, bool on) {
        int s = GetWindowLong(h, -16);
        SetWindowLong(h, -16, on ? (s | 1) : (s & ~1));
        InvalidateRect(h, IntPtr.Zero, true);
    }
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class SvMMDeviceEnumerator { }
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out ISvMMDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out ISvMMDevice device);
}
[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvMMDeviceCollection {
    [PreserveSig] int GetCount(out int n);
    [PreserveSig] int Item(int i, out ISvMMDevice device);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}
[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvAudioSessionManager2 {
    [PreserveSig] int GetAudioSessionControl(IntPtr g, int flags, out IntPtr c);
    [PreserveSig] int GetSimpleAudioVolume(IntPtr g, int flags, out IntPtr v);
    [PreserveSig] int GetSessionEnumerator(out ISvAudioSessionEnumerator e);
}
[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvAudioSessionEnumerator {
    [PreserveSig] int GetCount(out int n);
    [PreserveSig] int GetSession(int i, out ISvAudioSessionControl2 s);
}
[ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvAudioSessionControl2 {
    [PreserveSig] int GetState(out int s);
    [PreserveSig] int GetDisplayName(out IntPtr n);
    [PreserveSig] int SetDisplayName(IntPtr n, IntPtr g);
    [PreserveSig] int GetIconPath(out IntPtr p);
    [PreserveSig] int SetIconPath(IntPtr p, IntPtr g);
    [PreserveSig] int GetGroupingParam(out Guid g);
    [PreserveSig] int SetGroupingParam(IntPtr a, IntPtr b);
    [PreserveSig] int RegisterAudioSessionNotification(IntPtr n);
    [PreserveSig] int UnregisterAudioSessionNotification(IntPtr n);
    [PreserveSig] int GetSessionIdentifier(out IntPtr s);
    [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr s);
    [PreserveSig] int GetProcessId(out uint pid);
    [PreserveSig] int IsSystemSoundsSession();
    [PreserveSig] int SetDuckingPreference(bool optOut);
}
// IID from audioclient.h (ISimpleAudioVolume). BOOL arguments are 32-bit ints, not .NET bool.
[ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvSimpleAudioVolume {
    [PreserveSig] int SetMasterVolume(float level, ref Guid g);
    [PreserveSig] int GetMasterVolume(out float level);
    [PreserveSig] int SetMute(int mute, ref Guid g);
    [PreserveSig] int GetMute(out int mute);
}

// Mute the apps shown on the second screen (Windows has no per-screen mute).
public static class SvAudio {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out SvRect r);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);

    // Windows shell processes own the desktop and taskbar on every screen; never mute them.
    static readonly string[] Shell = { "explorer", "shellexperiencehost", "startmenuexperiencehost", "textinputhost", "applicationframehost", "searchhost", "searchapp" };

    // Process names of the visible windows whose center is on the given screen area.
    public static string[] ProcessNamesOn(int x, int y, int w, int h, int ownPid) {
        List<string> names = new List<string>();
        EnumWindows(delegate (IntPtr hw, IntPtr l) {
            if (!IsWindowVisible(hw) || IsIconic(hw) || GetWindowTextLength(hw) == 0) return true;
            SvRect r; if (!GetWindowRect(hw, out r)) return true;
            int cx = (r.Left + r.Right) / 2, cy = (r.Top + r.Bottom) / 2;
            if (cx < x || cx >= x + w || cy < y || cy >= y + h) return true;
            uint pid; GetWindowThreadProcessId(hw, out pid);
            if ((int)pid == ownPid || pid == 0) return true;
            try {
                string n = Process.GetProcessById((int)pid).ProcessName;
                if (Array.IndexOf(Shell, n.ToLowerInvariant()) < 0 && !names.Contains(n)) names.Add(n);
            } catch { }
            return true;
        }, IntPtr.Zero);
        return names.ToArray();
    }

    // Session selection: a session belongs to an app on the second screen when its process has
    // the same name as one of that screen's window processes (exact name, any case). Matching by
    // name covers apps whose sound comes from a helper process with the same name (Chrome's
    // audio service), at the cost of muting that app's other windows too.
    public static bool Wanted(string processName, string[] names) {
        if (string.IsNullOrEmpty(processName) || names == null) return false;
        foreach (string want in names)
            if (string.Equals(want, processName, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    // Set mute on every audio session, on every active output device, whose process is wanted.
    // Returns how many sessions were changed; LastError holds the last per-session failure.
    public static string LastError = "";
    public static Guid VolumeIid { get { return typeof(ISvSimpleAudioVolume).GUID; } }
    public static int SetMute(string[] names, bool mute) {
        LastError = "";
        ISvMMDeviceEnumerator en = (ISvMMDeviceEnumerator)(new SvMMDeviceEnumerator());
        ISvMMDeviceCollection devices;
        Marshal.ThrowExceptionForHR(en.EnumAudioEndpoints(0, 1, out devices));   // render, DEVICE_STATE_ACTIVE
        int nd, changed = 0;
        devices.GetCount(out nd);
        for (int d = 0; d < nd; d++) {
            ISvMMDevice dev;
            if (devices.Item(d, out dev) != 0 || dev == null) continue;
            Guid iid = typeof(ISvAudioSessionManager2).GUID;
            object o;
            if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) continue;
            ISvAudioSessionEnumerator se;
            if (((ISvAudioSessionManager2)o).GetSessionEnumerator(out se) != 0) continue;
            int n;
            se.GetCount(out n);
            for (int i = 0; i < n; i++) {
                ISvAudioSessionControl2 c;
                if (se.GetSession(i, out c) != 0 || c == null) continue;
                uint pid; c.GetProcessId(out pid);
                if (pid == 0) continue;
                string pn = "";
                try { pn = Process.GetProcessById((int)pid).ProcessName; } catch { continue; }
                if (!Wanted(pn, names)) continue;
                try {
                    Guid g = Guid.Empty;
                    int hr = ((ISvSimpleAudioVolume)c).SetMute(mute ? 1 : 0, ref g);
                    if (hr == 0) changed++; else LastError = pn + ": 0x" + hr.ToString("X8");
                } catch (Exception ex) { LastError = pn + ": " + ex.Message; }
            }
        }
        return changed;
    }

    // Mute state of the sessions of the given process names (for checks): "name=0/1" pairs.
    public static string[] MuteStates(string[] names) {
        List<string> r = new List<string>();
        ISvMMDeviceEnumerator en = (ISvMMDeviceEnumerator)(new SvMMDeviceEnumerator());
        ISvMMDeviceCollection devices;
        if (en.EnumAudioEndpoints(0, 1, out devices) != 0) return r.ToArray();
        int nd; devices.GetCount(out nd);
        for (int d = 0; d < nd; d++) {
            ISvMMDevice dev; if (devices.Item(d, out dev) != 0) continue;
            Guid iid = typeof(ISvAudioSessionManager2).GUID; object o;
            if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) continue;
            ISvAudioSessionEnumerator se; if (((ISvAudioSessionManager2)o).GetSessionEnumerator(out se) != 0) continue;
            int n; se.GetCount(out n);
            for (int i = 0; i < n; i++) {
                ISvAudioSessionControl2 c; if (se.GetSession(i, out c) != 0 || c == null) continue;
                uint pid; c.GetProcessId(out pid); if (pid == 0) continue;
                string pn; try { pn = Process.GetProcessById((int)pid).ProcessName; } catch { continue; }
                if (!Wanted(pn, names)) continue;
                int m = -1; try { ((ISvSimpleAudioVolume)c).GetMute(out m); } catch { }
                r.Add(pn + "=" + m);
            }
        }
        return r.ToArray();
    }
}

// Keeps the real cursor on the main screen(s) while a virtual screen exists: plain movement
// stops at the edge, while a held button (dragging a window) or the viewer's direct mode can
// still cross. ClipCursor is system-wide and other programs (or Windows) may change or reset
// it, so the viewer re-applies it only when nobody else holds a clip.
public static class SvClip {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint i, ref DISPLAY_DEVICE d, uint flags);
    [DllImport("user32.dll")] static extern bool ClipCursor(ref SvRect r);
    [DllImport("user32.dll")] static extern bool ClipCursor(IntPtr r);
    [DllImport("user32.dll")] static extern bool GetClipCursor(out SvRect r);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);

    // Adapter description of a screen (for example "Parsec Virtual Display Adapter").
    public static string AdapterOf(string screenDevice) {
        DISPLAY_DEVICE d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        for (uint i = 0; EnumDisplayDevices(null, i, ref d, 0); i++) {
            if (string.Equals(d.DeviceName, screenDevice, StringComparison.OrdinalIgnoreCase)) return d.DeviceString;
            d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        }
        return "";
    }
    public static bool IsVirtual(string screenDevice) {
        string a = AdapterOf(screenDevice);
        return a.IndexOf("Parsec", StringComparison.OrdinalIgnoreCase) >= 0 || a.IndexOf("Virtual Display", StringComparison.OrdinalIgnoreCase) >= 0;
    }
    // Physical buttons (GetAsyncKeyState reads the device, so swapped buttons do not matter here).
    public static bool AnyButtonDown() {
        return (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0 || (GetAsyncKeyState(0x04) & 0x8000) != 0;
    }
    public static Rectangle Current() { SvRect r; GetClipCursor(out r); return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom); }
    public static void Set(Rectangle b) { SvRect r; r.Left = b.Left; r.Top = b.Top; r.Right = b.Right; r.Bottom = b.Bottom; ClipCursor(ref r); }
    public static void Release() { ClipCursor(IntPtr.Zero); }
}

// Sticky mute for the second screen: while on, a background thread mutes, about once a second,
// every app whose window is on that screen, so apps that start playing later are muted too.
// Turning it off (or closing the viewer) unmutes every app it muted.
public static class SvAutoMute {
    static readonly object gate = new object();
    static System.Threading.Thread worker;
    static volatile bool on;
    static Rectangle area;
    static int ownPid;
    static readonly List<string> done = new List<string>();
    public static string LastError = "";
    public static bool On { get { return on; } }
    public static string[] Muted { get { lock (gate) { return done.ToArray(); } } }
    public static void Start(Rectangle screen, int pid) {
        lock (gate) { area = screen; ownPid = pid; on = true; }
        Apply();
        if (worker == null) {
            worker = new System.Threading.Thread(Loop);
            worker.IsBackground = true;
            worker.Start();
        }
    }
    public static void SetArea(Rectangle screen) { lock (gate) { area = screen; } }
    public static void Stop() {
        string[] names;
        lock (gate) { on = false; names = done.ToArray(); done.Clear(); }
        if (names.Length > 0) { try { SvAudio.SetMute(names, false); } catch { } }
    }
    static void Loop() {
        while (true) {
            System.Threading.Thread.Sleep(1000);
            if (on) { try { Apply(); } catch (Exception ex) { LastError = ex.Message; } }
        }
    }
    // Returns how many sessions were muted in this pass.
    public static int Apply() {
        Rectangle a; int pid;
        lock (gate) { if (!on) return 0; a = area; pid = ownPid; }
        string[] names = SvAudio.ProcessNamesOn(a.X, a.Y, a.Width, a.Height, pid);
        if (names.Length == 0) return 0;
        int n = SvAudio.SetMute(names, true);
        LastError = SvAudio.LastError;
        lock (gate) {
            if (!on) { SvAudio.SetMute(names, false); return 0; }   // turned off meanwhile
            foreach (string x in names) if (!done.Contains(x)) done.Add(x);
        }
        return n;
    }
}

// Direct mode: drives the real cursor on the second screen from its own 1 ms thread. Reading
// the cursor, scaling the motion and moving the cursor happen within microseconds, so no hand
// motion is lost in between (from the slow UI tick part of it was, which felt coarse and slower
// than the normal mouse). The UI tick only reads the result and handles the exits.
public static class SvDrive {
    [DllImport("user32.dll")] static extern bool GetCursorPos(out SvPt p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr h, IntPtr r, bool erase);
    static readonly object gate = new object();
    static System.Threading.Thread worker;
    static bool active, exitReq;
    static double px, py, scale = 1;
    static int lastX, lastY, exitX, exitY;
    static Rectangle area;
    static readonly Stopwatch clock = Stopwatch.StartNew();
    static long lastPaint;
    // Window that shows the picture; repainted right after each move so the image follows the hand.
    public static IntPtr Picture = IntPtr.Zero;
    public static int Moves;
    public static bool Active { get { lock (gate) { return active; } } }
    public static int X { get { lock (gate) { return lastX; } } }
    public static int Y { get { lock (gate) { return lastY; } } }
    public static double PX { get { lock (gate) { return px; } } }
    public static double PY { get { lock (gate) { return py; } } }

    public static void Start(int x, int y, Rectangle screen, double s) {
        lock (gate) {
            px = x; py = y; lastX = x; lastY = y; area = screen; scale = s > 0 ? s : 1;
            exitReq = false; active = true;
            SetCursorPos(x, y);
        }
        if (worker == null) {
            worker = new System.Threading.Thread(Loop);
            worker.IsBackground = true;
            worker.Priority = System.Threading.ThreadPriority.AboveNormal;
            worker.Start();
        }
    }
    public static void Update(Rectangle screen, double s) { lock (gate) { area = screen; if (s > 0) scale = s; } }
    public static void Stop() { lock (gate) { active = false; exitReq = false; } }
    // Set when the hand moved past an edge of the second screen with no button held.
    public static int[] TakeExit() {
        lock (gate) {
            if (!exitReq) return null;
            exitReq = false;
            return new int[] { exitX, exitY };
        }
    }
    static bool AnyButton() {
        return (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0 || (GetAsyncKeyState(0x04) & 0x8000) != 0;
    }
    static void Loop() {
        while (true) {
            Step();
            System.Threading.Thread.Sleep(1);
        }
    }
    static void Step() {
        bool moved = false;
        lock (gate) {
            if (!active) return;
            SvPt c;
            if (!GetCursorPos(out c)) return;
            int dx = c.X - lastX, dy = c.Y - lastY;
            if (dx == 0 && dy == 0) return;
            int ox, oy;
            if (Advance(ref px, ref py, dx, dy, scale, area, AnyButton(), out ox, out oy)) {
                active = false; exitReq = true; exitX = ox; exitY = oy;
                return;
            }
            lastX = (int)Math.Round(px); lastY = (int)Math.Round(py);
            SetCursorPos(lastX, lastY);
            Moves++;
            moved = true;
        }
        if (moved && Picture != IntPtr.Zero && clock.ElapsedMilliseconds - lastPaint >= 4) {
            lastPaint = clock.ElapsedMilliseconds;
            InvalidateRect(Picture, IntPtr.Zero, false);
        }
    }
    // One step of the scaled motion: the hand moved (dx, dy) on the cursor; on the second screen
    // that is (dx, dy) / scale, so the pointer on the image follows the hand 1:1. Returns true
    // (and the edge it left by) when the point leaves the screen with no button held; otherwise
    // the point is clamped to the screen (a drag keeps going).
    public static bool Advance(ref double x, ref double y, int dx, int dy, double s, Rectangle b, bool held, out int ox, out int oy) {
        if (s <= 0) s = 1;
        x += dx / s; y += dy / s;
        ox = x < b.Left ? -1 : (x >= b.Right ? 1 : 0);
        oy = y < b.Top ? -1 : (y >= b.Bottom ? 1 : 0);
        if ((ox != 0 || oy != 0) && !held) return true;
        x = Math.Max(b.Left, Math.Min(b.Right - 1, x));
        y = Math.Max(b.Top, Math.Min(b.Bottom - 1, y));
        ox = 0; oy = 0;
        return false;
    }
}

// Hidden window that receives raw mouse motion (still reported when Windows holds the cursor
// at the edge of the desktop) and the global exit hotkey (Ctrl+Alt+Q).
public class SvInput : NativeWindow {
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort UsagePage; public ushort Usage; public uint Flags; public IntPtr Target; }
    [DllImport("user32.dll")] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint n, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint header);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    const int WM_INPUT = 0x00FF, WM_HOTKEY = 0x0312, HOTKEY_ID = 0x5356;
    int dx, dy; bool hot;
    public bool RawOk, HotkeyOk;
    public SvInput() {
        CreateHandle(new CreateParams());
        RAWINPUTDEVICE[] d = new RAWINPUTDEVICE[1];
        d[0].UsagePage = 1; d[0].Usage = 2; d[0].Flags = 0x100; d[0].Target = Handle;   // mouse, RIDEV_INPUTSINK
        RawOk = RegisterRawInputDevices(d, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
        HotkeyOk = RegisterHotKey(Handle, HOTKEY_ID, 0x0002 | 0x0001 | 0x4000, 0x51);       // Ctrl+Alt, no repeat, Q
    }
    public int TakeX() { int v = dx; dx = 0; return v; }
    public int TakeY() { int v = dy; dy = 0; return v; }
    public bool TakeHotkey() { bool v = hot; hot = false; return v; }
    public void Close() { UnregisterHotKey(Handle, HOTKEY_ID); DestroyHandle(); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_INPUT) {
            uint header = (uint)(8 + 2 * IntPtr.Size), size = 0;
            GetRawInputData(m.LParam, 0x10000003, IntPtr.Zero, ref size, header);
            if (size > 0) {
                IntPtr buf = Marshal.AllocHGlobal((int)size);
                try {
                    if (GetRawInputData(m.LParam, 0x10000003, buf, ref size, header) == size && Marshal.ReadInt32(buf) == 0) {
                        int off = (int)header;
                        bool absolute = (Marshal.ReadInt16(buf, off) & 1) != 0;   // MOUSE_MOVE_ABSOLUTE (tablets, remote desktop)
                        if (!absolute) { dx += Marshal.ReadInt32(buf, off + 12); dy += Marshal.ReadInt32(buf, off + 16); }
                    }
                } finally { Marshal.FreeHGlobal(buf); }
            }
        } else if (m.Msg == WM_HOTKEY && (int)m.WParam == HOTKEY_ID) {
            hot = true;
        }
        base.WndProc(ref m);
    }
}
"@

# Physical pixels on every monitor. With mixed scaling (for example 125% main screen and a
# 100% virtual screen) a system-DPI-aware process sees the second screen at the wrong size,
# so per-monitor awareness is required for the cursor to land where the image shows.
function Set-PerMonitorDpi {
    try { if ([SvNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) { return 'per-monitor-v2' } } catch {}
    try { if ([SvNative]::SetProcessDpiAwareness(2) -eq 0) { return 'per-monitor' } } catch {}
    try { if ([SvNative]::SetProcessDPIAware()) { return 'system' } } catch {}
    return 'unaware'
}

# Map a point inside a box that shows the screen letterboxed (Zoom) to screen coordinates.
# Returns $null when the point falls on the letterbox bars around the image.
function Convert-ViewToScreen([double]$px, [double]$py, [double]$boxW, [double]$boxH, $bounds) {
    $scale = [Math]::Min($boxW / $bounds.Width, $boxH / $bounds.Height)
    if ($scale -le 0) { return $null }
    $offX = ($boxW - $bounds.Width * $scale) / 2
    $offY = ($boxH - $bounds.Height * $scale) / 2
    $rx = ($px - $offX) / $scale
    $ry = ($py - $offY) / $scale
    if ($rx -lt 0 -or $ry -lt 0 -or $rx -ge $bounds.Width -or $ry -ge $bounds.Height) { return $null }
    return [pscustomobject]@{ X = [int]($bounds.X + $rx); Y = [int]($bounds.Y + $ry) }
}

# Inverse of Convert-ViewToScreen: a screen point to box coordinates.
function Convert-ScreenToView([double]$sx, [double]$sy, [double]$boxW, [double]$boxH, $bounds) {
    $scale = [Math]::Min($boxW / $bounds.Width, $boxH / $bounds.Height)
    $offX = ($boxW - $bounds.Width * $scale) / 2
    $offY = ($boxH - $bounds.Height * $scale) / 2
    return [pscustomobject]@{ X = $offX + ($sx - $bounds.X) * $scale; Y = $offY + ($sy - $bounds.Y) * $scale; Scale = $scale }
}

# Rectangle inside a box where the screen image goes (same math as Convert-ViewToScreen).
function Get-LetterBox([double]$boxW, [double]$boxH, $bounds) {
    $scale = [Math]::Min($boxW / $bounds.Width, $boxH / $bounds.Height)
    if ($scale -le 0) { $scale = 0.01 }
    $w = [int][Math]::Round($bounds.Width * $scale)
    $h = [int][Math]::Round($bounds.Height * $scale)
    return [pscustomobject]@{ X = [int][Math]::Floor(($boxW - $w) / 2); Y = [int][Math]::Floor(($boxH - $h) / 2); W = $w; H = $h; Scale = $scale }
}

# How hard the hand pushes past an edge where Windows holds the cursor still (the outer edges
# of the desktop). $x,$y is the cursor on screen $bounds; $rawX,$rawY is the raw mouse motion
# since the last tick; $push is the previous result. Moving back inward resets the push; a
# tick with no motion keeps it. OverX/OverY is -1 or 1 once the push passes $threshold.
function Get-EdgePush([int]$x, [int]$y, $bounds, [int]$rawX, [int]$rawY, $push, [int]$threshold = 6) {
    $nx = 0; $ny = 0
    if ($x -le $bounds.X) {
        if ($rawX -lt 0) { $nx = [Math]::Min(0, $push.X) + $rawX } elseif ($rawX -eq 0) { $nx = [Math]::Min(0, $push.X) }
    } elseif ($x -ge $bounds.X + $bounds.Width - 1) {
        if ($rawX -gt 0) { $nx = [Math]::Max(0, $push.X) + $rawX } elseif ($rawX -eq 0) { $nx = [Math]::Max(0, $push.X) }
    }
    if ($y -le $bounds.Y) {
        if ($rawY -lt 0) { $ny = [Math]::Min(0, $push.Y) + $rawY } elseif ($rawY -eq 0) { $ny = [Math]::Min(0, $push.Y) }
    } elseif ($y -ge $bounds.Y + $bounds.Height - 1) {
        if ($rawY -gt 0) { $ny = [Math]::Max(0, $push.Y) + $rawY } elseif ($rawY -eq 0) { $ny = [Math]::Max(0, $push.Y) }
    }
    $ox = if ($nx -le -$threshold) { -1 } elseif ($nx -ge $threshold) { 1 } else { 0 }
    $oy = if ($ny -le -$threshold) { -1 } elseif ($ny -ge $threshold) { 1 } else { 0 }
    return [pscustomobject]@{ X = $nx; Y = $ny; OverX = $ox; OverY = $oy }
}

# Name of the screen after $current in $names (wraps around); the first one when $current is unknown.
function Get-NextScreenName([string[]]$names, [string]$current) {
    if (-not $names -or $names.Count -eq 0) { return $null }
    $i = [Array]::IndexOf($names, $current)
    return $names[($i + 1) % $names.Count]
}

if ($SelfTest) {
    $fail = 0; $total = 0
    function Check([bool]$ok, [string]$what) { $script:total++; if (-not $ok) { $script:fail++; Write-Output "FAIL $what" } }
    $b = [pscustomobject]@{ X = 1920; Y = 0; Width = 1920; Height = 1080 }
    $cases = @(
        @{ In = @(320, 180, 640, 360); Want = @(2880, 540) },   # center, exact fit
        @{ In = @(0, 0, 640, 360);     Want = @(1920, 0) },     # top-left corner
        @{ In = @(320, 240, 640, 480); Want = @(2880, 540) },   # center with letterbox bars
        @{ In = @(320, 10, 640, 480);  Want = $null },          # on the top bar
        @{ In = @(-5, 100, 640, 360);  Want = $null }           # outside the box
    )
    foreach ($c in $cases) {
        $r = Convert-ViewToScreen $c.In[0] $c.In[1] $c.In[2] $c.In[3] $b
        $ok = if ($null -eq $c.Want) { $null -eq $r } else { $r -and $r.X -eq $c.Want[0] -and $r.Y -eq $c.Want[1] }
        Check $ok "view-to-screen in=$($c.In -join ',') got=$($r.X),$($r.Y)"
    }
    $inv = Convert-ScreenToView 2880 540 640 480 $b
    Check ([Math]::Abs($inv.X - 320) -le 0.01 -and [Math]::Abs($inv.Y - 240) -le 0.01) "inverse got=$($inv.X),$($inv.Y)"
    # Letterbox: a 16:9 screen in a 4:3 box gets bars on top and bottom only.
    $lb = Get-LetterBox 640 480 $b
    Check ($lb.X -eq 0 -and $lb.Y -eq 60 -and $lb.W -eq 640 -and $lb.H -eq 360) "letterbox 4:3 got=$($lb.X),$($lb.Y),$($lb.W),$($lb.H)"
    $lb = Get-LetterBox 1920 1080 ([pscustomobject]@{ X = 2400; Y = 0; Width = 2400; Height = 1350 })
    Check ($lb.X -eq 0 -and $lb.Y -eq 0 -and $lb.W -eq 1920 -and $lb.H -eq 1080 -and [Math]::Abs($lb.Scale - 0.8) -lt 0.0001) "letterbox full got=$($lb.X),$($lb.Y),$($lb.W),$($lb.H),$($lb.Scale)"
    # Toolbar: centred on the window's top edge, slid by dragging only along that edge, and kept
    # on the screen. Arguments: anchor x, width, screen left, right, pill width, shadow, offset.
    $o = 0;    $x = [SvBar]::PlaceX(1000, 800, 0, 1920, 300, 10, [ref]$o)
    Check ($x -eq 1240 -and $o -eq 0) "bar centred got=$x off=$o"
    $o = 900;  $x = [SvBar]::PlaceX(1000, 800, 0, 1920, 300, 10, [ref]$o)
    Check ($x -eq 1490 -and $o -eq 250) "bar slid, offset clamped to the edge got=$x off=$o"
    $o = -60;  $x = [SvBar]::PlaceX(1000, 200, 0, 1920, 300, 10, [ref]$o)
    Check ($x -eq 940 -and $o -eq 0) "bar wider than the window stays centred got=$x off=$o"
    $o = 0;    $x = [SvBar]::PlaceX(1800, 300, 0, 1920, 300, 10, [ref]$o)
    Check ($x -eq 1610 -and $o -eq 0) "bar kept inside the screen got=$x off=$o"
    # Edge push: Windows stops the cursor at the outer edges of the desktop, so only the raw
    # mouse motion shows that the hand keeps pushing outward.
    $zero = [pscustomobject]@{ X = 0; Y = 0 }
    $pushCases = @(
        @{ At = @(3839, 500); Raw = @(4, 0);   Push = $zero;                                Want = @(4, 0, 0, 0) },   # right edge, below threshold
        @{ At = @(3839, 500); Raw = @(3, 0);   Push = [pscustomobject]@{ X = 4; Y = 0 };    Want = @(7, 0, 1, 0) },   # right edge, accumulates past it
        @{ At = @(2500, 0);   Raw = @(0, -9);  Push = $zero;                                Want = @(0, -9, 0, -1) }, # top edge, one strong push
        @{ At = @(2500, 1079); Raw = @(0, 0);  Push = [pscustomobject]@{ X = 0; Y = 5 };    Want = @(0, 5, 0, 0) },   # bottom edge, still: keeps push
        @{ At = @(3839, 500); Raw = @(-2, 0);  Push = [pscustomobject]@{ X = 5; Y = 0 };    Want = @(0, 0, 0, 0) },   # moving back inward resets
        @{ At = @(2500, 500); Raw = @(50, 50); Push = [pscustomobject]@{ X = 5; Y = 5 };    Want = @(0, 0, 0, 0) }    # not on an edge: no push
    )
    foreach ($c in $pushCases) {
        $r = Get-EdgePush $c.At[0] $c.At[1] $b $c.Raw[0] $c.Raw[1] $c.Push
        $got = @($r.X, $r.Y, $r.OverX, $r.OverY)
        Check (($got -join ',') -eq ($c.Want -join ',')) "push at=$($c.At -join ',') raw=$($c.Raw -join ',') got=$($got -join ',')"
    }
    # Direct mode motion: scaled by the image size, no motion lost, clamped while a button is held.
    $sb = New-Object Drawing.Rectangle(1920, 0, 1920, 1080)
    $x = 2000.0; $y = 500.0; $ox = 0; $oy = 0
    $left = [SvDrive]::Advance([ref]$x, [ref]$y, 3, -2, 0.25, $sb, $false, [ref]$ox, [ref]$oy)
    Check (-not $left -and $x -eq 2012 -and $y -eq 492) "drive scaled step got=$x,$y"
    $x = 2000.0; $y = 500.0
    for ($i = 0; $i -lt 40; $i++) { [SvDrive]::Advance([ref]$x, [ref]$y, 1, 0, 0.3, $sb, $false, [ref]$ox, [ref]$oy) | Out-Null }
    Check ([Math]::Abs($x - (2000 + 40 / 0.3)) -lt 0.001) "drive keeps fractions of small moves got=$x"
    $x = 3830.0; $y = 500.0
    $left = [SvDrive]::Advance([ref]$x, [ref]$y, 5, 0, 0.5, $sb, $false, [ref]$ox, [ref]$oy)
    Check ($left -and $ox -eq 1 -and $oy -eq 0) "drive leaves by the right edge got=$left $ox,$oy"
    $x = 3830.0; $y = 500.0
    $left = [SvDrive]::Advance([ref]$x, [ref]$y, 5, 0, 0.5, $sb, $true, [ref]$ox, [ref]$oy)
    Check (-not $left -and $x -eq 3839) "drive clamps while a button is held got=$x"
    Check (-not [SvAutoMute]::On) "auto mute starts off"
    # Next-screen button order.
    Check ((Get-NextScreenName @('A', 'B', 'C') 'A') -eq 'B') "next screen after A"
    Check ((Get-NextScreenName @('A', 'B', 'C') 'C') -eq 'A') "next screen wraps around"
    Check ((Get-NextScreenName @('A', 'B') 'gone') -eq 'A') "next screen from a removed one starts at the first"
    Check ($null -eq (Get-NextScreenName @() 'A')) "next screen with none"
    # Always on top: small window only.
    Check ([SvNative]::WantTopMost($false, $true)) "small window follows the always-on-top toggle (on)"
    Check (-not [SvNative]::WantTopMost($false, $false)) "small window follows the always-on-top toggle (off)"
    Check (-not [SvNative]::WantTopMost($true, $true)) "full screen is never topmost, even with the toggle on"
    Check (-not [SvNative]::WantTopMost($true, $false)) "full screen is not topmost with the toggle off"
    # The window manager really clears and sets the topmost state (invisible test window).
    $tw = New-Object Windows.Forms.Form
    $tw.FormBorderStyle = 'None'; $tw.ShowInTaskbar = $false; $tw.StartPosition = 'Manual'; $tw.Opacity = 0
    $tw.Location = New-Object Drawing.Point(-30000, -30000); $tw.Size = New-Object Drawing.Size(10, 10)
    $tw.Show()
    [SvNative]::SetTopMost($tw.Handle, $true)
    Check ([SvNative]::IsTopMost($tw.Handle)) "SetTopMost(true) makes a window topmost"
    [SvNative]::SetTopMost($tw.Handle, $false)
    Check (-not [SvNative]::IsTopMost($tw.Handle)) "SetTopMost(false) clears it (full screen)"
    $tw.Close(); $tw.Dispose()
    # Toolbar presses: the pill outside its buttons drags the window; the dotted grip slides the bar.
    Check ([SvBar]::PressAction(1.0, 2, $true) -eq 'button') "press on a button clicks it"
    Check ([SvBar]::PressAction(1.0, -2, $true) -eq 'slide') "press on the dotted grip slides the bar"
    Check ([SvBar]::PressAction(1.0, -1, $true) -eq 'window') "press on the open pill's background drags the window"
    Check ([SvBar]::PressAction(0.0, -1, $true) -eq 'window') "press on the resting handle drags the window"
    Check ([SvBar]::PressAction(0.5, 1, $true) -eq 'window') "press while the bar is still opening drags the window"
    Check ([SvBar]::PressAction(1.0, -1, $false) -eq 'none') "press on the transparent margin does nothing"
    # Toolbar visibility: it follows the viewer, and the pin (keep open) never keeps it on screen.
    Check ([SvBar]::ShouldShow($false, $true, $false)) "bar shown with the viewer"
    Check ([SvBar]::ShouldShow($false, $true, $true)) "bar shown with the viewer, pinned"
    Check (-not [SvBar]::ShouldShow($true, $true, $true)) "pinned bar hidden while the viewer is minimized"
    Check (-not [SvBar]::ShouldShow($true, $true, $false)) "bar hidden while the viewer is minimized"
    Check (-not [SvBar]::ShouldShow($false, $false, $true)) "pinned bar hidden while the viewer is hidden"
    Write-Output "selftest: $($total - $fail)/$total passed"
    exit $fail
}

$script:dpiMode = Set-PerMonitorDpi

# Hide only the console window, so the viewer form itself stays visible.
if (-not $Smoke) { [SvNative]::ShowWindow([SvNative]::GetConsoleWindow(), 0) | Out-Null }

# Which second screen the viewer shows: -Screen, the keeper session -ScreenId, or the first one.
$script:target = $Screen
$script:targetId = $ScreenId
$script:keeperJson = Join-Path $env:USERPROFILE '.claude\modo-equipo\screen-keeper-v2\keeper.json'
function Get-SessionDevice([string]$id) {
    if (-not $id -or -not (Test-Path $script:keeperJson)) { return $null }
    try { (Get-Content $script:keeperJson -Raw | ConvertFrom-Json).sessions | Where-Object { $_.id -eq $id } | Select-Object -First 1 -ExpandProperty device } catch { $null }
}
function Get-SessionOf([string]$device) {
    if (-not (Test-Path $script:keeperJson)) { return $null }
    try { (Get-Content $script:keeperJson -Raw | ConvertFrom-Json).sessions | Where-Object { $_.device -eq $device } | Select-Object -First 1 -ExpandProperty id } catch { $null }
}
function Get-OtherScreens { @([Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y }) }
function Get-SecondScreen {
    $all = Get-OtherScreens
    if ($script:target) {
        $s = $all | Where-Object { $_.DeviceName -eq $script:target } | Select-Object -First 1
        if ($s) { return $s }
        if ($script:targetId) {
            $d = Get-SessionDevice $script:targetId
            $s = $all | Where-Object { $_.DeviceName -eq $d } | Select-Object -First 1
            if ($s) { $script:target = $d; return $s }
        }
        return $null   # the chosen screen is gone: never jump to another session's screen
    }
    $all | Select-Object -First 1
}

$screen = Get-SecondScreen
if (-not $screen -and $script:target) { $script:target = ''; $screen = Get-SecondScreen }   # asked-for screen not there yet
if (-not $screen) {
    [Windows.Forms.MessageBox]::Show("No second screen found. Connect a monitor or add a virtual display first.", "Screen viewer") | Out-Null
    exit 1
}

# Optional event log for troubleshooting: set MODO_EQUIPO_VIEWER_LOG to a file path.
function Write-ViewerLog($text) {
    if ($env:MODO_EQUIPO_VIEWER_LOG) {
        Add-Content -Path $env:MODO_EQUIPO_VIEWER_LOG -Value "$(Get-Date -Format 'HH:mm:ss.fff') $text"
    }
    if ($Smoke) { [Console]::WriteLine($text) }
}

# Per-monitor awareness turns off automatic scaling: size everything by the main screen's scale.
$probe = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$k = [Math]::Max(1.0, $probe.DpiX / 96.0)
$probe.Dispose()
function Px([double]$v) { [int][Math]::Round($v * $k) }

$cWindow = [Drawing.Color]::FromArgb(24, 24, 26)
$cBar    = [Drawing.Color]::FromArgb(36, 36, 40)
$cDim    = [Drawing.Color]::FromArgb(150, 150, 156)

# --- state ----------------------------------------------------------------------------------
$script:remote = $false
$script:needLeave = $false
$script:px = 0.0
$script:py = 0.0
$script:lastX = 0
$script:lastY = 0
$script:bmp = $null
$script:push = [pscustomobject]@{ X = 0; Y = 0 }
$script:full = $false
$script:normalBounds = $null
$script:onTop = $true
$script:showPointer = $true
$script:keepBar = $false
$script:mag = [IntPtr]::Zero
$script:magOk = $false
$script:pic = $null
$script:magBounds = $null
$script:clock = [Diagnostics.Stopwatch]::StartNew()
$script:screensCheckMs = -10000
$script:screensSig = ''
$script:lastFrameMs = -1000

# --- main window ----------------------------------------------------------------------------
$form = New-Object SvForm
function Update-Title {
    $s = Get-SecondScreen
    if (-not $s) { return }
    $short = $s.DeviceName -replace '^\\\\\.\\', ''
    $id = Get-SessionOf $s.DeviceName
    $form.Text = "Test screen $short$(if ($id) { " ($id)" }) - live, touch"
}
$form.Text = "Test screen (live, touch)"
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.StartPosition = 'Manual'
$form.BackColor = $cWindow
$form.Grip = Px 5
$form.Padding = New-Object Windows.Forms.Padding($form.Grip)
$form.MinimumSize = New-Object Drawing.Size((Px 240), (Px 150))
$form.Size = New-Object Drawing.Size((Px 640), (Px 380))
$primary = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(($primary.Right - $form.Width - (Px 20)), ($primary.Bottom - $form.Height - (Px 20)))
if ($Smoke) {
    $sb = $screen.Bounds
    if ($SmokeOn) { $on = [Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $SmokeOn } | Select-Object -First 1; if ($on) { $sb = $on.Bounds } }
    $form.Location = New-Object Drawing.Point(($sb.Right - $form.Width - (Px 40)), ($sb.Bottom - $form.Height - (Px 60)))
}
Write-ViewerLog "start dpi=$($script:dpiMode) scale=$k second=$($screen.Bounds)"

# Thin strip on top: drag it to move the window; hovering it opens the toolbar.
$grip = New-Object Windows.Forms.Panel
$grip.Dock = 'Top'
$grip.Height = Px 10
$grip.BackColor = $cBar
$grip.Cursor = [Windows.Forms.Cursors]::SizeAll
$grip.Add_MouseDown({ param($sender, $e) if ($e.Button -eq 'Left') { [SvForm]::DragMove($form) } })
$grip.Add_MouseEnter({ Show-Toolbar })

$view = New-Object Windows.Forms.Panel
$view.Dock = 'Fill'
$view.BackColor = [Drawing.Color]::Black
$form.Controls.Add($view)
$form.Controls.Add($grip)

# --- floating toolbar -----------------------------------------------------------------------
# Accent: the Windows accent colour when it is a real colour, otherwise a calm blue (a grey
# accent would not mark a pressed toggle on the dark bar).
function Get-AccentColor {
    try {
        $v = [uint32](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -ErrorAction Stop).AccentColor
        $c = [Drawing.Color]::FromArgb([int]($v -band 0xFF), [int](($v -shr 8) -band 0xFF), [int](($v -shr 16) -band 0xFF))
        if ($c.GetSaturation() -ge 0.3 -and $c.GetBrightness() -ge 0.25) { return $c }
    } catch {}
    return [Drawing.Color]::FromArgb(76, 160, 255)
}
$glyphFamily = if ((New-Object Drawing.Text.InstalledFontCollection).Families | Where-Object { $_.Name -eq 'Segoe Fluent Icons' }) { 'Segoe Fluent Icons' } else { 'Segoe MDL2 Assets' }
$bar = New-Object SvBar([single]$k, $glyphFamily)
$bar.Accent = Get-AccentColor

function New-BarButton([string]$id, [bool]$gap = $false, [bool]$danger = $false) {
    $b = New-Object SvBarButton
    $b.Id = $id; $b.GapBefore = $gap; $b.Danger = $danger
    $bar.Buttons.Add($b)
    return $b
}
$btnPin     = New-BarButton 'pin'
$btnPointer = New-BarButton 'pointer'
$btnMute    = New-BarButton 'mute'
$btnLock    = New-BarButton 'lock'
$btnScreen  = New-BarButton 'screen'
$btnFull    = New-BarButton 'full' $true
$btnKeep    = New-BarButton 'keep'
$btnMin     = New-BarButton 'min' $true
$btnClose   = New-BarButton 'close' $false $true
# Pressing the toolbar outside its buttons moves the window (not in full screen).
$bar.Add_WindowDrag({ if (-not $script:full) { [SvForm]::DragMove($form) } })
$bar.Add_ButtonClick({
    param($sender, $e)
    switch ($e.Id) {
        'pin'     { $script:onTop = -not $script:onTop; Apply-TopMost; Update-Glyphs }
        'pointer' { Switch-Pointer }
        'mute'    { Switch-Mute }
        'lock'    { Switch-Lock }
        'screen'  { Switch-Screen }
        'full'    { Set-Fullscreen (-not $script:full) }
        'keep'    { Switch-KeepBar }
        'min'     { $form.WindowState = 'Minimized' }
        'close'   { $form.Close() }
    }
})

# The window and its toolbar are topmost only for the small window with the toggle on; the
# window manager is told directly, so full screen can never stay above other apps.
function Apply-TopMost {
    $want = [SvNative]::WantTopMost($script:full, $script:onTop)
    $form.TopMost = $want
    if ($form.IsHandleCreated -and ([SvNative]::IsTopMost($form.Handle) -ne $want)) { [SvNative]::SetTopMost($form.Handle, $want) }
    if ($bar.IsHandleCreated -and ([SvNative]::IsTopMost($bar.Handle) -ne $want)) { [SvNative]::SetTopMost($bar.Handle, $want) }
}

function Update-ToolbarSize {
    $btnPin.Visible = -not $script:full   # "always on top" only exists for the small window
    $btnScreen.Visible = (Get-OtherScreens).Count -gt 1   # only when there is another screen to show
    $bar.Redraw()
}

function Update-Glyphs {
    $btnPin.Glyph = [string][char]0xE81E
    $btnPin.On = $script:onTop
    $btnPin.Tip = if ($script:onTop) { "Always on top: on" } else { "Always on top: off" }
    $btnPointer.Glyph = [string][char]0xE8B0
    $btnPointer.On = $script:showPointer
    $btnPointer.Tip = if ($script:showPointer) { "Pointer shown in the image (turn off when an app draws its own)" } else { "Pointer hidden in the image" }
    $muteOn = [SvAutoMute]::On
    $btnMute.Glyph = if ($muteOn) { [string][char]0xE74F } else { [string][char]0xE767 }
    $btnMute.On = $muteOn
    $btnMute.Tip = if ($muteOn) { "Second screen sound: muted (the apps on that screen, including ones that start playing later). Click to unmute" } else { "Second screen sound: on. Click to mute the apps on that screen (Windows has no per-screen mute)" }
    $cur = Get-SecondScreen
    $others = Get-OtherScreens
    $btnScreen.Glyph = [string][char]0xE7F4
    $btnScreen.On = $false
    if ($cur) {
        $pos = [Array]::IndexOf(@($others | ForEach-Object { $_.DeviceName }), $cur.DeviceName) + 1
        $sid = Get-SessionOf $cur.DeviceName
        $btnScreen.Tip = "Showing screen $pos of $($others.Count): $($cur.DeviceName -replace '^\\\\\.\\', '')$(if ($sid) { " (session $sid)" }). Click for the next one"
    }
    $lockOn = -not (Test-Path $script:lockOffFile)
    $btnLock.Glyph = if ($lockOn) { [string][char]0xE72E } else { [string][char]0xE785 }
    $btnLock.On = $lockOn
    $btnLock.Tip = if ($lockOn) { "Mouse kept on the main screen while the virtual screen exists (drag a window or use the image to cross): on" } else { "Mouse kept on the main screen: off" }
    $btnFull.Glyph = if ($script:full) { [string][char]0xE73F } else { [string][char]0xE740 }
    $btnFull.Tip = if ($script:full) { "Back to the small window" } else { "Full screen" }
    $btnKeep.Glyph = [string][char]0xE840
    $btnKeep.On = $script:keepBar
    $btnKeep.Tip = if ($script:keepBar) { "Bar kept open: click to let it fold into the handle" } else { "Keep this bar open" }
    $btnMin.Glyph = [string][char]0xE921
    $btnMin.Tip = "Minimize"
    $btnClose.Glyph = [string][char]0xE8BB
    $btnClose.Tip = "Close"
    $bar.KeepOpen = $script:keepBar
    $bar.Redraw()
}

function Update-ToolbarPlacement {
    $sc = [Windows.Forms.Screen]::FromControl($form)
    $bar.DockRect = $form.Bounds
    $bar.Limit = $sc.Bounds
    $bar.Redraw()
}

function Show-Toolbar {
    if ($form.WindowState -eq 'Minimized') { return }
    Update-ToolbarPlacement
    if (-not $bar.Visible) { $bar.Show($form) }
    $bar.Open()
}

function Switch-KeepBar {
    $script:keepBar = -not $script:keepBar
    Update-Glyphs
}

function Set-Fullscreen([bool]$on) {
    if ($on -eq $script:full) { return }
    if ($on) {
        $script:normalBounds = $form.Bounds
        $sb = [Windows.Forms.Screen]::FromControl($form).Bounds
        $script:full = $true
        $form.Resizable = $false
        $grip.Visible = $false
        $form.Padding = New-Object Windows.Forms.Padding(0)
        Apply-TopMost
        $form.Bounds = $sb
    } else {
        $script:full = $false
        $form.Resizable = $true
        $grip.Visible = $true
        $form.Padding = New-Object Windows.Forms.Padding($form.Grip)
        $form.Bounds = $script:normalBounds
    }
    Apply-TopMost
    Write-ViewerLog "fullscreen=$on"
    Update-ToolbarSize
    Update-Glyphs
    Update-MagLayout
    Show-Toolbar
}

# --- mouse lock (owned by the screen keeper) -----------------------------------------------
# The screen keeper (parsec-vdd.ps1 -Ensure) confines the cursor to the real screens while a
# virtual screen exists. The viewer only (a) owns the named mutex Local\ModoEquipo.CursorFree
# while in direct mode, so the keeper lifts its clip, and (b) turns the lock on or off through
# the keeper's flag file. If the viewer dies in direct mode the mutex is abandoned and the
# keeper takes the lock back.
$script:lockOffFile = Join-Path $env:USERPROFILE '.claude\modo-equipo\screen-keeper-v2\lock-off'
$script:freeMutex = New-Object Threading.Mutex($false, 'Local\ModoEquipo.CursorFree')
$script:freeOwned = $false

function Test-KeeperOn {
    $m = $null
    try { return [Threading.Mutex]::TryOpenExisting('Local\ModoEquipo.ScreenKeeper-v2', [ref]$m) } finally { if ($m) { $m.Dispose() } }
}

# Before the cursor goes onto the second screen: take the mutex and give the keeper a moment to
# lift its clip (it checks every 10 ms).
function Grant-CursorFree {
    if (-not $script:freeOwned) {
        try { $script:freeOwned = $script:freeMutex.WaitOne(100) } catch [Threading.AbandonedMutexException] { $script:freeOwned = $true }
    }
    $desk = [Windows.Forms.SystemInformation]::VirtualScreen
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ([SvClip]::Current() -ne $desk -and $sw.ElapsedMilliseconds -lt 100) { Start-Sleep -Milliseconds 5 }
}

# After the cursor is back on the main screen.
function Return-CursorFree {
    if ($script:freeOwned) { try { $script:freeMutex.ReleaseMutex() } catch {}; $script:freeOwned = $false }
}

function Switch-Lock {
    try {
        if (Test-Path $script:lockOffFile) { Remove-Item $script:lockOffFile -ErrorAction Stop }
        else { New-Item -ItemType File -Force -Path $script:lockOffFile -ErrorAction Stop | Out-Null }
    } catch { Write-ViewerLog "mouse lock switch failed: $($_.Exception.Message)" }
    Write-ViewerLog "mouse lock=$(-not (Test-Path $script:lockOffFile))"
    Update-Glyphs
}

function Switch-Screen {
    $names = @(Get-OtherScreens | ForEach-Object { $_.DeviceName })
    $cur = Get-SecondScreen
    $next = Get-NextScreenName $names $(if ($cur) { $cur.DeviceName } else { '' })
    if (-not $next) { return }
    if ($script:remote) { [SvDrive]::Stop(); $script:remote = $false; Return-CursorFree }
    $script:target = $next
    $script:targetId = Get-SessionOf $next
    $script:magBounds = $null
    Update-MagLayout
    Update-Title
    Write-ViewerLog "showing $next session=$($script:targetId)"
    Update-Glyphs
    $bar.Redraw()
}

function Switch-Pointer {
    $script:showPointer = -not $script:showPointer
    if ($script:magOk) { [SvMag]::SetCursorVisible($script:mag, $script:showPointer) }
    Update-Glyphs
}

function Switch-Mute {
    try {
        if ([SvAutoMute]::On) {
            $was = [SvAutoMute]::Muted
            [SvAutoMute]::Stop()
            Write-ViewerLog "mute off, unmuted $($was -join ',')"
            $bar.ShowTip("Second screen sound: on", 'mute')
        } else {
            $s = Get-SecondScreen
            if (-not $s) { return }
            [SvAutoMute]::Start($s.Bounds, $PID)
            $names = [SvAutoMute]::Muted
            Write-ViewerLog "mute on apps=$($names -join ',') error=$([SvAutoMute]::LastError)"
            if ([SvAutoMute]::LastError) { $bar.ShowTip("Muted, but one app failed: $([SvAutoMute]::LastError)", 'mute') }
            elseif ($names.Count) { $bar.ShowTip("Second screen sound: muted ($($names -join ', '))", 'mute') }
            else { $bar.ShowTip("Second screen sound: muted (no app there is playing yet; any that starts is muted)", 'mute') }
        }
    } catch {
        # Never fail silently: the owner sees why the button did nothing.
        Write-ViewerLog "mute failed: $($_.Exception.Message)"
        $bar.ShowTip("Could not mute: $($_.Exception.Message)", 'mute')
    }
    Update-Glyphs
}

# --- picture: Magnification API, or GDI copy as fallback ------------------------------------
function Initialize-View {
    $script:magOk = [SvMag]::Init()
    if ($script:magOk) {
        $script:mag = [SvMag]::Create($view.Handle, $script:showPointer)
        if ($script:mag -eq [IntPtr]::Zero) { $script:magOk = $false; [SvMag]::Shutdown() }
    }
    if (-not $script:magOk) {
        $script:pic = New-Object Windows.Forms.PictureBox
        $script:pic.Dock = 'Fill'
        $script:pic.SizeMode = 'Zoom'
        $view.Controls.Add($script:pic)
    }
    if ($script:magOk) { [SvDrive]::Picture = $script:mag }
    Write-ViewerLog "renderer=$(if ($script:magOk) { 'magnification' } else { 'gdi' })"
    Update-MagLayout
}

function Update-MagLayout {
    if (-not $script:magOk) { return }
    $s = Get-SecondScreen
    if (-not $s) { return }
    $lb = Get-LetterBox $view.ClientSize.Width $view.ClientSize.Height $s.Bounds
    [SvMag]::Place($script:mag, $lb.X, $lb.Y, $lb.W, $lb.H, [single]$lb.Scale) | Out-Null
    $script:magBounds = $s.Bounds
}

function Update-GdiFrame($b) {
    if (-not $script:bmp -or $script:bmp.Width -ne $b.Width -or $script:bmp.Height -ne $b.Height) {
        $script:bmp = New-Object Drawing.Bitmap($b.Width, $b.Height, [Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $script:pic.Image = $script:bmp
    }
    $g = [Drawing.Graphics]::FromImage($script:bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $script:bmp.Size)
    # Screen copies do not include the cursor: draw a marker where it is on that screen.
    $c = [Windows.Forms.Cursor]::Position
    if ($script:showPointer -and $b.Contains($c)) {
        $r = [Math]::Max(6, [int]($b.Width / 160))
        $g.FillEllipse([Drawing.Brushes]::Red, $c.X - $b.X - $r, $c.Y - $b.Y - $r, 2 * $r, 2 * $r)
    }
    $g.Dispose()
    $script:pic.Invalidate()
}

$view.Add_Resize({ Update-MagLayout })
$form.Add_LocationChanged({ if ($bar.Visible) { Update-ToolbarPlacement } })
$form.Add_SizeChanged({
    if ($form.WindowState -eq 'Minimized') { if ($bar.Visible) { $bar.Hide() }; return }
    if ($bar.Visible) { Update-ToolbarPlacement } else { Show-Toolbar }
})

# --- direct mode ----------------------------------------------------------------------------
# While the pointer is over the image, the real cursor lives on the second screen and moves
# with the hand, scaled so the cursor on the image follows the pointer 1:1. Clicks, double
# clicks, drags and the wheel are then ordinary native input. Moving past the image edge
# hands the cursor back to the viewer's side.
$script:input = New-Object SvInput
Write-ViewerLog "raw input=$($script:input.RawOk) hotkey Ctrl+Alt+Q=$($script:input.HotkeyOk)"
$hintText = if ($script:input.HotkeyOk) { "Move over the image to use the second screen; push past any edge or press Ctrl+Alt+Q to come back" } else { "Move over the image to use the second screen; push past any edge to come back" }
$bar.DragTip = "Drag to slide the bar along the top edge. $hintText"

function Test-OverImage($cur) {
    $pt = New-Object SvPt; $pt.X = $cur.X; $pt.Y = $cur.Y
    $h = [SvNative]::WindowFromPoint($pt)
    if ($h -eq $view.Handle) { return $true }
    if ($script:magOk -and $h -eq $script:mag) { return $true }
    if ($script:pic -and $h -eq $script:pic.Handle) { return $true }
    return $false
}

function Enter-Remote($cur) {
    $p = $view.PointToClient($cur)
    $s = Get-SecondScreen
    if (-not $s) { return }
    $t = Convert-ViewToScreen $p.X $p.Y $view.ClientSize.Width $view.ClientSize.Height $s.Bounds
    if (-not $t) { return }
    $script:px = [double]$t.X; $script:py = [double]$t.Y
    $script:lastX = $t.X; $script:lastY = $t.Y
    Grant-CursorFree   # the keeper's clip would hold the cursor on the main screen
    [SvDrive]::Start($t.X, $t.Y, $s.Bounds, (Get-ViewScale $s.Bounds))
    $script:push = [pscustomobject]@{ X = 0; Y = 0 }
    $script:remote = $true
    Write-ViewerLog "enter remote at $($t.X),$($t.Y)"
}

function Get-ViewScale($b) {
    $scale = [Math]::Min($view.ClientSize.Width / $b.Width, $view.ClientSize.Height / $b.Height)
    if ($scale -le 0) { $scale = 1 }
    return [double]$scale
}

function Exit-Remote($b, $overX, $overY) {
    [SvDrive]::Stop()
    $script:px = [SvDrive]::PX; $script:py = [SvDrive]::PY
    $script:remote = $false
    $script:needLeave = $true
    if ($script:full) {
        # The image covers the whole screen: come back onto the toolbar.
        Show-Toolbar
        $c = $bar.OpenCenter()
        [SvNative]::SetCursorPos($c.X, $c.Y) | Out-Null
    } else {
        $v = Convert-ScreenToView ([Math]::Max($b.Left, [Math]::Min($b.Right - 1, $script:px))) ([Math]::Max($b.Top, [Math]::Min($b.Bottom - 1, $script:py))) $view.ClientSize.Width $view.ClientSize.Height $b
        # Step just outside the image in the direction the cursor left.
        $out = Px 10
        $vx = $v.X; $vy = $v.Y
        if ($overX -lt 0) { $vx -= $out } elseif ($overX -gt 0) { $vx += $out }
        if ($overY -lt 0) { $vy -= $out } elseif ($overY -gt 0) { $vy += $out }
        $sp = $view.PointToScreen((New-Object Drawing.Point([int]$vx, [int]$vy)))
        [SvNative]::SetCursorPos($sp.X, $sp.Y) | Out-Null
    }
    Return-CursorFree
    Write-ViewerLog "exit remote"
}

# --- main loop ------------------------------------------------------------------------------
[SvNative]::timeBeginPeriod(1) | Out-Null
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 16
$timer.Add_Tick({
    # The toolbar follows the viewer: SvBar hides itself while the viewer is minimized or hidden
    # (pinned or not); it comes back here once the viewer is shown again.
    if ($script:full -and ([SvNative]::IsTopMost($form.Handle) -or ($bar.IsHandleCreated -and [SvNative]::IsTopMost($bar.Handle)))) { Apply-TopMost }
    if (-not $bar.Visible -and [SvBar]::OwnerShown($form, $script:keepBar)) {
        Update-ToolbarPlacement
        $bar.Show($form)
    }
    $s = Get-SecondScreen
    if (-not $s) {
        [SvDrive]::Stop()
        $script:remote = $false
        Return-CursorFree
        $form.Text = "Test screen (display removed)"
        return
    }
    $b = $s.Bounds
    if ([SvAutoMute]::On) { [SvAutoMute]::SetArea($b) }
    if (($script:clock.ElapsedMilliseconds - $script:screensCheckMs) -ge 1000) {
        $script:screensCheckMs = $script:clock.ElapsedMilliseconds
        $sig = (@(Get-OtherScreens | ForEach-Object { $_.DeviceName }) -join ',') + '|' + $s.DeviceName
        if ($sig -ne $script:screensSig) { $script:screensSig = $sig; Update-Title; Update-ToolbarSize; Update-Glyphs }
    }
    $now = $script:clock.ElapsedMilliseconds
    $cur = [Windows.Forms.Cursor]::Position
    # Drain the raw motion and the hotkey every tick so old motion never counts later.
    $rawX = $script:input.TakeX(); $rawY = $script:input.TakeY()
    $hotkey = $script:input.TakeHotkey()
    if ($script:remote -and $hotkey) {
        Write-ViewerLog "exit by hotkey"
        Exit-Remote $b 0 0
    }
    if ($script:remote) {
        # The cursor itself is moved by SvDrive's thread; here only its exits are handled.
        $exit = [SvDrive]::TakeExit()
        if ($exit) {
            Exit-Remote $b $exit[0] $exit[1]
        } else {
            [SvDrive]::Update($b, (Get-ViewScale $b))
            $script:lastX = [SvDrive]::X; $script:lastY = [SvDrive]::Y
        }
        # At the outer edges of the desktop Windows holds the cursor still, so the motion
        # above never leaves; the raw motion still shows the hand pushing outward.
        if ($script:remote -and [Windows.Forms.Control]::MouseButtons -eq 'None') {
            $script:push = Get-EdgePush $script:lastX $script:lastY $b $rawX $rawY $script:push
            if ($script:push.OverX -ne 0 -or $script:push.OverY -ne 0) {
                Write-ViewerLog "exit by edge push $($script:push.OverX),$($script:push.OverY)"
                Exit-Remote $b $script:push.OverX $script:push.OverY
            }
        } else {
            $script:push = [pscustomobject]@{ X = 0; Y = 0 }
        }
    } elseif (-not $Smoke) {
        $over = Test-OverImage $cur
        if (-not $over) { $script:needLeave = $false }
        elseif (-not $script:needLeave -and $form.WindowState -ne 'Minimized' -and [Windows.Forms.Control]::MouseButtons -eq 'None') { Enter-Remote $cur }
    }

    # Faster ticks while the cursor is driven or the image fills the screen.
    $want = if ($script:remote) { 8 } else { 16 }
    if ($timer.Interval -ne $want) { $timer.Interval = $want }
    if ($form.WindowState -eq 'Minimized') { return }
    if ($script:magOk) {
        # GPU picture: ~60 fps while in use or in full screen, ~30 fps when just watching.
        $every = if ($script:remote -or $script:full) { 15 } else { 32 }
        if (($now - $script:lastFrameMs) -ge $every) {
            $script:lastFrameMs = $now
            if (-not $script:magBounds -or $script:magBounds -ne $b) { Update-MagLayout }
            [SvMag]::Show($script:mag, $b.X, $b.Y, $b.Width, $b.Height) | Out-Null
        }
    } else {
        # GDI fallback: about 20 fps in direct mode, 8 fps when idle.
        $every = if ($script:remote) { 50 } else { 125 }
        if (($now - $script:lastFrameMs) -ge $every) {
            $script:lastFrameMs = $now
            Update-GdiFrame $b
        }
    }
})

$form.Add_Shown({
    Initialize-View
    Update-ToolbarSize
    Update-Glyphs
    Show-Toolbar
    $timer.Start()
    if ($Smoke) {
        $script:stop = New-Object Windows.Forms.Timer
        $script:stop.Interval = [Math]::Max(1, $SmokeSeconds) * 1000
        $script:stop.Add_Tick({
            $script:stop.Stop()
            $s = Get-SecondScreen
            $b = $s.Bounds
            Write-ViewerLog "smoke toolbar=$($bar.PillBounds) open=$($bar.IsOpen) visible=$($bar.Visible) form=$($form.Bounds)"
            try {
                $names = [SvAudio]::ProcessNamesOn($b.X, $b.Y, $b.Width, $b.Height, $PID)
                $n = [SvAudio]::SetMute([string[]]@(), $false)
                Write-ViewerLog "smoke audio ok apps-on-second=$($names -join ',') changed=$n"
            } catch { Write-ViewerLog "smoke audio failed: $($_.Exception.Message)" }
            $form.Close()
        })
        $script:stop.Start()
        # Halfway through, open the toolbar so both of its states can be checked.
        $script:half = New-Object Windows.Forms.Timer
        $script:half.Interval = [Math]::Max(1, [int]($SmokeSeconds * 500))
        $script:half.Add_Tick({
            $script:half.Stop(); $bar.ForceOpen = $true; Write-ViewerLog "smoke toolbar opened"
            # Then: pin the bar, minimize the viewer, restore it; log whether the bar is on screen.
            $script:visStep = 0
            $script:vis = New-Object Windows.Forms.Timer
            $script:vis.Interval = 400
            $script:vis.Add_Tick({
                $script:visStep++
                switch ($script:visStep) {
                    1 { $script:keepBar = $true; Update-Glyphs; $form.WindowState = 'Minimized' }
                    2 { Write-ViewerLog "smoke pinned+minimized bar visible=$($bar.Visible)"; $form.WindowState = 'Normal' }
                    3 { Write-ViewerLog "smoke restored bar visible=$($bar.Visible)"; $script:vis.Stop() }
                }
            })
            $script:vis.Start()
        })
        $script:half.Start()
    }
})
$form.Add_FormClosed({
    $timer.Stop()
    [SvDrive]::Stop()
    Return-CursorFree
    try { [SvAutoMute]::Stop() } catch {}
    $script:input.Close()
    if ($script:magOk) { [SvMag]::Shutdown() }
    [SvNative]::timeEndPeriod(1) | Out-Null
})

[Windows.Forms.Application]::Run($form)
