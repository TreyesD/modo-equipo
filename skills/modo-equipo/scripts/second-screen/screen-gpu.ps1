# GPU mirror for the touch viewer: Desktop Duplication (DXGI) + a Direct3D 11 Lanczos3 downscale.
# Dot-sourced by screen-viewer.ps1; it only defines [SvGpu], [SvGpuHost] and [SvGpuCore].
#
# Why: the Windows Magnification API shrinks with nearest-neighbour (measured: identical output to a
# nearest-neighbour StretchBlt, SSIM 0.79 against a Lanczos3 reference at 0.4x), which breaks small
# text. This path keeps the picture on the GPU: the screen is duplicated into a texture, shrunk by
# two separable Lanczos3 passes (horizontal, then vertical, with the pointer drawn on top) and
# presented in a child window. No pixel ever comes back to the CPU.
# Everything talks to D3D11/DXGI through raw COM vtable calls (no SharpDX), so the only
# dependencies are system DLLs: d3d11, dxgi and d3dcompiler_47.
if ('SvGpu' -as [type]) { return }
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class SvGpuNative {
    [DllImport("d3d11.dll")] public static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr sw, uint flags, IntPtr levels, uint nLevels, uint sdk, out IntPtr dev, out int fl, out IntPtr ctx);
    [DllImport("dxgi.dll")] public static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr f);
    [DllImport("d3dcompiler_47.dll")] public static extern int D3DCompile(byte[] src, IntPtr len, string name, IntPtr defs, IntPtr inc, string entry, string target, uint f1, uint f2, out IntPtr code, out IntPtr err);
    [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] public struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public IntPtr hbmMask, hbmColor; }
    [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr icon, int w, int h, int step, IntPtr brush, int flags);
    [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr icon, out ICONINFO info);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
}

// The child window that shows the picture (a swap chain is attached to its handle).
public sealed class SvGpuHost : Control {
    public SvGpuHost() { SetStyle(ControlStyles.Opaque | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true); TabStop = false; }
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) { }
}

// Raw COM calls and the shared D3D11 state: device, the downscale shaders and the helpers to run them.
public sealed class SvGpuCore {
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int F0(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int F1(IntPtr s, IntPtr a);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int F2(IntPtr s, IntPtr a, IntPtr b);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int F3(IntPtr s, IntPtr a, IntPtr b, IntPtr c);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int F4(IntPtr s, IntPtr a, IntPtr b, IntPtr c, IntPtr d);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int F5(IntPtr s, IntPtr a, IntPtr b, IntPtr c, IntPtr d, IntPtr e);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int F6(IntPtr s, IntPtr a, IntPtr b, IntPtr c, IntPtr d, IntPtr e, IntPtr f);
    static readonly Dictionary<long, Delegate> cache = new Dictionary<long, Delegate>();
    static readonly object cacheLock = new object();

    public static IntPtr I(long v) { return new IntPtr(v); }
    // Calls slot `slot` of COM object `o` (a vtable index) with IntPtr-sized arguments.
    public static int C(IntPtr o, int slot, params IntPtr[] a) {
        IntPtr fn = Marshal.ReadIntPtr(Marshal.ReadIntPtr(o), slot * IntPtr.Size);
        Delegate d; long key = fn.ToInt64() * 8 + a.Length;
        lock (cacheLock) {
            if (!cache.TryGetValue(key, out d)) {
                switch (a.Length) {
                    case 0: d = Marshal.GetDelegateForFunctionPointer(fn, typeof(F0)); break;
                    case 1: d = Marshal.GetDelegateForFunctionPointer(fn, typeof(F1)); break;
                    case 2: d = Marshal.GetDelegateForFunctionPointer(fn, typeof(F2)); break;
                    case 3: d = Marshal.GetDelegateForFunctionPointer(fn, typeof(F3)); break;
                    case 4: d = Marshal.GetDelegateForFunctionPointer(fn, typeof(F4)); break;
                    case 5: d = Marshal.GetDelegateForFunctionPointer(fn, typeof(F5)); break;
                    case 6: d = Marshal.GetDelegateForFunctionPointer(fn, typeof(F6)); break;
                    default: throw new ArgumentException("too many COM arguments");
                }
                cache[key] = d;
            }
        }
        switch (a.Length) {
            case 0: return ((F0)d)(o);
            case 1: return ((F1)d)(o, a[0]);
            case 2: return ((F2)d)(o, a[0], a[1]);
            case 3: return ((F3)d)(o, a[0], a[1], a[2]);
            case 4: return ((F4)d)(o, a[0], a[1], a[2], a[3]);
            case 5: return ((F5)d)(o, a[0], a[1], a[2], a[3], a[4]);
            default: return ((F6)d)(o, a[0], a[1], a[2], a[3], a[4], a[5]);
        }
    }
    public static void Release(ref IntPtr o) { if (o != IntPtr.Zero) { C(o, 2); o = IntPtr.Zero; } }
    public static IntPtr Query(IntPtr o, Guid iid) {
        IntPtr p = Marshal.AllocHGlobal(8), g = Marshal.AllocHGlobal(16);
        try { Marshal.Copy(iid.ToByteArray(), 0, g, 16); int hr = C(o, 0, g, p); if (hr != 0) return IntPtr.Zero; return Marshal.ReadIntPtr(p); }
        finally { Marshal.FreeHGlobal(p); Marshal.FreeHGlobal(g); }
    }
    public static void Chk(int hr, string what) { if (hr < 0) throw new InvalidOperationException(what + " failed (0x" + hr.ToString("X8") + ")"); }
    public static IntPtr Alloc(int n) { IntPtr p = Marshal.AllocHGlobal(n); byte[] z = new byte[n]; Marshal.Copy(z, 0, p, n); return p; }

    public static readonly Guid IID_Texture2D = new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    public static readonly Guid IID_Output1 = new Guid("00cddea8-939b-4b83-a340-a685226666cc");

    public IntPtr Dev, Ctx;
    IntPtr vs, psH, psV, cb, s8, s16, vpBuf;

    const string Hlsl = @"
cbuffer C : register(b0) { float4 a; float4 b; float4 c; float4 d; };
Texture2D T0 : register(t0);
Texture2D T1 : register(t1);
struct VSO { float4 pos : SV_Position; float2 uv : TEXCOORD0; };
VSO VS(uint id : SV_VertexID) {
    VSO o; float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o;
}
float lz(float x) {
    x = abs(x);
    if (x < 1e-4) return 1;
    if (x >= 3) return 0;
    float px = 3.14159265 * x;
    return 3 * sin(px) * sin(px / 3) / (px * px);
}
float4 PSH(VSO i) : SV_Target {
    int y = (int)i.pos.y;
    float ratio = a.x / a.z, fs = max(1.0, ratio), cx = i.pos.x * ratio;
    int lo = (int)floor(cx - 3 * fs + 0.5), hi = (int)floor(cx + 3 * fs + 0.5), mx = (int)a.x - 1;
    float3 sum = 0; float ws = 0;
    [loop] for (int k = lo; k <= hi; k++) {
        float w = lz((k + 0.5 - cx) / fs);
        sum += w * T0.Load(int3(clamp(k, 0, mx), y, 0)).rgb; ws += w;
    }
    return float4(sum / ws, 1);
}
float4 PSV(VSO i) : SV_Target {
    int x = (int)i.pos.x;
    float ratio = a.y / a.w, fs = max(1.0, ratio), cy = i.pos.y * ratio;
    int lo = (int)floor(cy - 3 * fs + 0.5), hi = (int)floor(cy + 3 * fs + 0.5), my = (int)a.y - 1;
    float3 sum = 0; float ws = 0;
    [loop] for (int k = lo; k <= hi; k++) {
        float w = lz((k + 0.5 - cy) / fs);
        sum += w * T0.Load(int3(x, clamp(k, 0, my), 0)).rgb; ws += w;
    }
    float3 col = sum / ws;
    if (c.x > 0.5) {
        int px = (int)i.pos.x - (int)b.x, py = (int)i.pos.y - (int)b.y;
        if (px >= 0 && py >= 0 && px < (int)b.z && py < (int)b.w) {
            float4 cu = T1.Load(int3(px, py, 0));
            col = cu.rgb + (1 - cu.a) * col;
        }
    }
    return float4(col, 1);
}";

    static IntPtr Compile(string entry, string target) {
        byte[] src = Encoding.ASCII.GetBytes(Hlsl);
        IntPtr code, err;
        int hr = SvGpuNative.D3DCompile(src, new IntPtr(src.Length), "svgpu", IntPtr.Zero, IntPtr.Zero, entry, target, 0, 0, out code, out err);
        if (hr < 0) {
            throw new InvalidOperationException("shader " + entry + " did not compile (0x" + hr.ToString("X8") + ")");
        }
        if (err != IntPtr.Zero) { IntPtr e = err; Release(ref e); }
        return code;
    }
    static IntPtr BlobPtr(IntPtr blob) { IntPtr fn = Marshal.ReadIntPtr(Marshal.ReadIntPtr(blob), 3 * IntPtr.Size); return ((F0P)Marshal.GetDelegateForFunctionPointer(fn, typeof(F0P)))(blob); }
    static long BlobSize(IntPtr blob) { IntPtr fn = Marshal.ReadIntPtr(Marshal.ReadIntPtr(blob), 4 * IntPtr.Size); return ((F0P)Marshal.GetDelegateForFunctionPointer(fn, typeof(F0P)))(blob).ToInt64(); }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate IntPtr F0P(IntPtr s);

    // adapter: IDXGIAdapter to create the device on (IntPtr.Zero = default hardware adapter).
    public void Init(IntPtr adapter) {
        IntPtr fl = Alloc(4);
        int type = adapter == IntPtr.Zero ? 1 : 0;   // HARDWARE, or UNKNOWN when an adapter is given
        int hr = SvGpuNative.D3D11CreateDevice(adapter, type, IntPtr.Zero, 0x20, IntPtr.Zero, 0, 7, out Dev, out hr_unused, out Ctx);
        Marshal.FreeHGlobal(fl);
        Chk(hr, "D3D11CreateDevice");
        IntPtr b1 = Compile("VS", "vs_4_0"), b2 = Compile("PSH", "ps_4_0"), b3 = Compile("PSV", "ps_4_0");
        try {
            IntPtr o = Alloc(8);
            Chk(C(Dev, 12, BlobPtr(b1), I(BlobSize(b1)), IntPtr.Zero, o), "CreateVertexShader"); vs = Marshal.ReadIntPtr(o);
            Chk(C(Dev, 15, BlobPtr(b2), I(BlobSize(b2)), IntPtr.Zero, o), "CreatePixelShader"); psH = Marshal.ReadIntPtr(o);
            Chk(C(Dev, 15, BlobPtr(b3), I(BlobSize(b3)), IntPtr.Zero, o), "CreatePixelShader"); psV = Marshal.ReadIntPtr(o);
            IntPtr d = Alloc(24); Marshal.WriteInt32(d, 0, 64); Marshal.WriteInt32(d, 8, 4);   // ByteWidth, BIND_CONSTANT_BUFFER
            Chk(C(Dev, 3, d, IntPtr.Zero, o), "CreateBuffer"); cb = Marshal.ReadIntPtr(o);
            Marshal.FreeHGlobal(d); Marshal.FreeHGlobal(o);
        } finally { Release(ref b1); Release(ref b2); Release(ref b3); }
        s8 = Alloc(8); s16 = Alloc(16); vpBuf = Alloc(24);
    }
    int hr_unused;

    // Texture2D. fmt: 87 = B8G8R8A8_UNORM, 10 = R16G16B16A16_FLOAT. bind: 0x8 SRV, 0x20 RTV. usage 0 default, 3 staging.
    public IntPtr Tex(int w, int h, int fmt, uint bind, uint usage, uint cpu, byte[] init) {
        IntPtr d = Alloc(44), o = Alloc(8), sd = IntPtr.Zero, pin = IntPtr.Zero;
        try {
            Marshal.WriteInt32(d, 0, w); Marshal.WriteInt32(d, 4, h); Marshal.WriteInt32(d, 8, 1); Marshal.WriteInt32(d, 12, 1);
            Marshal.WriteInt32(d, 16, fmt); Marshal.WriteInt32(d, 20, 1); Marshal.WriteInt32(d, 24, 0);
            Marshal.WriteInt32(d, 28, (int)usage); Marshal.WriteInt32(d, 32, (int)bind); Marshal.WriteInt32(d, 36, (int)cpu);
            if (init != null) {
                pin = Marshal.AllocHGlobal(init.Length); Marshal.Copy(init, 0, pin, init.Length);
                sd = Alloc(16); Marshal.WriteIntPtr(sd, 0, pin); Marshal.WriteInt32(sd, 8, w * 4);
            }
            Chk(C(Dev, 5, d, sd, o), "CreateTexture2D");
            return Marshal.ReadIntPtr(o);
        } finally { Marshal.FreeHGlobal(d); Marshal.FreeHGlobal(o); if (sd != IntPtr.Zero) Marshal.FreeHGlobal(sd); if (pin != IntPtr.Zero) Marshal.FreeHGlobal(pin); }
    }
    public IntPtr Srv(IntPtr tex) { IntPtr o = Alloc(8); try { Chk(C(Dev, 7, tex, IntPtr.Zero, o), "CreateShaderResourceView"); return Marshal.ReadIntPtr(o); } finally { Marshal.FreeHGlobal(o); } }
    public IntPtr Rtv(IntPtr tex) { IntPtr o = Alloc(8); try { Chk(C(Dev, 9, tex, IntPtr.Zero, o), "CreateRenderTargetView"); return Marshal.ReadIntPtr(o); } finally { Marshal.FreeHGlobal(o); } }
    // Fills a whole BGRA texture from memory (the pointer's pixels).
    public void Upload(IntPtr tex, byte[] bgra, int pitch) {
        IntPtr p = Marshal.AllocHGlobal(bgra.Length);
        try { Marshal.Copy(bgra, 0, p, bgra.Length); C(Ctx, 48, tex, I(0), IntPtr.Zero, p, I(pitch), I(0)); }
        finally { Marshal.FreeHGlobal(p); }
    }

    void SetCb(float[] v) {
        IntPtr p = Marshal.AllocHGlobal(64);
        try { Marshal.Copy(v, 0, p, 16); C(Ctx, 48, cb, I(0), IntPtr.Zero, p, I(0), I(0)); } finally { Marshal.FreeHGlobal(p); }
    }
    void Viewport(int w, int h) {
        Marshal.Copy(new float[] { 0, 0, w, h, 0, 1 }, 0, vpBuf, 6);
        C(Ctx, 44, I(1), vpBuf);
    }
    void Bind(IntPtr srv0, IntPtr srv1) {
        Marshal.WriteIntPtr(s16, 0, srv0); Marshal.WriteIntPtr(s16, 8, srv1);
        C(Ctx, 8, I(0), I(2), s16);
    }
    void Target(IntPtr rtv) { Marshal.WriteIntPtr(s8, 0, rtv); C(Ctx, 33, I(1), s8, IntPtr.Zero); }
    // cbv: a = (srcW, srcH, dstW, dstH), b = (cursor x, y, w, h), c.x = cursor on
    public void Run(IntPtr deskSrv, IntPtr midRtv, IntPtr midSrv, IntPtr curSrv, IntPtr outRtv, int srcW, int srcH, int dstW, int dstH, float[] cbv) {
        C(Ctx, 24, I(4));                                  // IASetPrimitiveTopology(TRIANGLELIST)
        C(Ctx, 11, vs, IntPtr.Zero, I(0));                 // VSSetShader
        Marshal.WriteIntPtr(s8, 0, cb); C(Ctx, 16, I(0), I(1), s8);   // PSSetConstantBuffers
        // pass 1: horizontal, srcW x srcH -> dstW x srcH
        SetCb(cbv);
        Bind(deskSrv, IntPtr.Zero); Target(midRtv); Viewport(dstW, srcH);
        C(Ctx, 9, psH, IntPtr.Zero, I(0)); C(Ctx, 13, I(3), I(0));
        // pass 2: vertical, dstW x srcH -> dstW x dstH, pointer on top
        Target(outRtv); Bind(midSrv, curSrv); Viewport(dstW, dstH);
        C(Ctx, 9, psV, IntPtr.Zero, I(0)); C(Ctx, 13, I(3), I(0));
    }
    public static float[] Cb(int srcW, int srcH, int dstW, int dstH, int curX, int curY, int curW, int curH, bool curOn) {
        float[] v = new float[16]; v[0] = srcW; v[1] = srcH; v[2] = dstW; v[3] = dstH; v[4] = curX; v[5] = curY; v[6] = curW; v[7] = curH; v[8] = curOn ? 1 : 0; return v;
    }
    public void Dispose() { Release(ref vs); Release(ref psH); Release(ref psV); Release(ref cb); Release(ref Ctx); Release(ref Dev); }
}

public sealed class SvGpu {
    public string Error = "";
    public volatile bool Failed;
    public volatile bool PointerOn = true;
    public volatile bool Paused;
    public double Fps;                       // presented frames per second (last second)
    public long Frames;
    SvGpuCore g;
    IntPtr factory, adapter, output, dup, swap, rtv, backTex, deskTex, deskSrv, midTex, midRtv, midSrv, curTex, curSrv;
    int srcW, srcH, bbW, bbH, desktopX, desktopY;
    string devName; IntPtr hwnd;
    Thread th; volatile bool stop;
    readonly object sizeLock = new object(); int wantW, wantH;
    IntPtr curHandle; int curHotX, curHotY;
    const int CUR = 64;

    // ---- self test: shrink a bitmap on the GPU, no window, no screen ------------------------------
    // Returns BGRA bytes of dw x dh (the same two passes the live path runs).
    public static byte[] SelfRender(Bitmap src, int dw, int dh) {
        SvGpuCore c = new SvGpuCore();
        IntPtr deskTex = IntPtr.Zero, deskSrv = IntPtr.Zero, midTex = IntPtr.Zero, midRtv = IntPtr.Zero, midSrv = IntPtr.Zero, curTex = IntPtr.Zero, curSrv = IntPtr.Zero, outTex = IntPtr.Zero, outRtv = IntPtr.Zero, stage = IntPtr.Zero;
        try {
            c.Init(IntPtr.Zero);
            int sw = src.Width, sh = src.Height;
            byte[] px = new byte[sw * sh * 4];
            BitmapData bd = src.LockBits(new Rectangle(0, 0, sw, sh), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            Marshal.Copy(bd.Scan0, px, 0, px.Length); src.UnlockBits(bd);
            deskTex = c.Tex(sw, sh, 87, 0x8, 0, 0, px); deskSrv = c.Srv(deskTex);
            midTex = c.Tex(dw, sh, 10, 0x28, 0, 0, null); midRtv = c.Rtv(midTex); midSrv = c.Srv(midTex);
            curTex = c.Tex(CUR, CUR, 87, 0x8, 0, 0, null); curSrv = c.Srv(curTex);
            outTex = c.Tex(dw, dh, 87, 0x20, 0, 0, null); outRtv = c.Rtv(outTex);
            stage = c.Tex(dw, dh, 87, 0, 3, 0x20000, null);
            c.Run(deskSrv, midRtv, midSrv, curSrv, outRtv, sw, sh, dw, dh, SvGpuCore.Cb(sw, sh, dw, dh, 0, 0, 0, 0, false));
            SvGpuCore.C(c.Ctx, 47, stage, outTex);   // CopyResource
            IntPtr m = SvGpuCore.Alloc(16);
            SvGpuCore.Chk(SvGpuCore.C(c.Ctx, 14, stage, SvGpuCore.I(0), SvGpuCore.I(1), SvGpuCore.I(0), m), "Map");
            IntPtr data = Marshal.ReadIntPtr(m, 0); int pitch = Marshal.ReadInt32(m, 8);
            byte[] o = new byte[dw * dh * 4];
            for (int y = 0; y < dh; y++) Marshal.Copy(new IntPtr(data.ToInt64() + (long)y * pitch), o, y * dw * 4, dw * 4);
            SvGpuCore.C(c.Ctx, 15, stage, SvGpuCore.I(0));
            Marshal.FreeHGlobal(m);
            return o;
        } finally {
            SvGpuCore.Release(ref stage); SvGpuCore.Release(ref outRtv); SvGpuCore.Release(ref outTex); SvGpuCore.Release(ref curSrv); SvGpuCore.Release(ref curTex);
            SvGpuCore.Release(ref midSrv); SvGpuCore.Release(ref midRtv); SvGpuCore.Release(ref midTex); SvGpuCore.Release(ref deskSrv); SvGpuCore.Release(ref deskTex);
            c.Dispose();
        }
    }

    // ---- live: duplicate the screen `deviceName` into the window `hwnd` ---------------------------
    // Returns false (and sets Error) when anything is not available, so the caller can fall back.
    public bool Start(IntPtr window, string deviceName, int w, int h) {
        hwnd = window; devName = deviceName; bbW = Math.Max(1, w); bbH = Math.Max(1, h); wantW = bbW; wantH = bbH;
        try {
            g = new SvGpuCore();
            FindOutput();
            g.Init(adapter);
            OpenDuplication();
            MakeSwap();
            MakeTargets();
            th = new Thread(Loop); th.IsBackground = true; th.Name = "SvGpu"; th.Start();
            return true;
        } catch (Exception e) {
            Error = e.Message; Cleanup(); return false;
        }
    }
    public void Resize(int w, int h) { lock (sizeLock) { wantW = Math.Max(1, w); wantH = Math.Max(1, h); } }
    public void Stop() { stop = true; if (th != null) { th.Join(2000); th = null; } Cleanup(); }

    void FindOutput() {
        Guid f1 = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
        SvGpuCore.Release(ref factory);
        SvGpuCore.Chk(SvGpuNative.CreateDXGIFactory1(ref f1, out factory), "CreateDXGIFactory1");
        IntPtr o = SvGpuCore.Alloc(8), d = SvGpuCore.Alloc(96);
        try {
            for (int ai = 0; ; ai++) {
                int hr = SvGpuCore.C(factory, 12, SvGpuCore.I(ai), o);   // IDXGIFactory1::EnumAdapters1
                if (hr < 0) break;
                IntPtr ad = Marshal.ReadIntPtr(o);
                for (int oi = 0; ; oi++) {
                    hr = SvGpuCore.C(ad, 7, SvGpuCore.I(oi), o);          // IDXGIAdapter::EnumOutputs
                    if (hr < 0) break;
                    IntPtr op = Marshal.ReadIntPtr(o);
                    SvGpuCore.C(op, 7, d);                                 // IDXGIOutput::GetDesc
                    string name = Marshal.PtrToStringUni(d);
                    if (string.Equals(name, devName, StringComparison.OrdinalIgnoreCase)) {
                        desktopX = Marshal.ReadInt32(d, 64); desktopY = Marshal.ReadInt32(d, 68);
                        adapter = ad; output = op; return;
                    }
                    SvGpuCore.Release(ref op);
                }
                SvGpuCore.Release(ref ad);
            }
        } finally { Marshal.FreeHGlobal(o); Marshal.FreeHGlobal(d); }
        throw new InvalidOperationException("no DXGI output named " + devName + " (the screen is not driven by a GPU adapter that can be duplicated)");
    }
    void OpenDuplication() {
        SvGpuCore.Release(ref dup);
        IntPtr o1 = SvGpuCore.Query(output, SvGpuCore.IID_Output1);
        if (o1 == IntPtr.Zero) throw new InvalidOperationException("IDXGIOutput1 is not available");
        IntPtr o = SvGpuCore.Alloc(8), d = SvGpuCore.Alloc(40);
        try {
            SvGpuCore.Chk(SvGpuCore.C(o1, 22, g.Dev, o), "DuplicateOutput");   // IDXGIOutput1::DuplicateOutput
            dup = Marshal.ReadIntPtr(o);
            SvGpuCore.C(dup, 7, d);                                              // GetDesc
            int w = Marshal.ReadInt32(d, 0), h = Marshal.ReadInt32(d, 4);
            if (w != srcW || h != srcH || deskTex == IntPtr.Zero) {
                srcW = w; srcH = h;
                SvGpuCore.Release(ref deskSrv); SvGpuCore.Release(ref deskTex);
                deskTex = g.Tex(srcW, srcH, 87, 0x8, 0, 0, null); deskSrv = g.Srv(deskTex);
                SvGpuCore.Release(ref midSrv); SvGpuCore.Release(ref midRtv); SvGpuCore.Release(ref midTex);
                if (rtv != IntPtr.Zero) { midTex = g.Tex(bbW, srcH, 10, 0x28, 0, 0, null); midRtv = g.Rtv(midTex); midSrv = g.Srv(midTex); }
            }
        } finally { Marshal.FreeHGlobal(o); Marshal.FreeHGlobal(d); SvGpuCore.Release(ref o1); }
    }
    void MakeSwap() {
        IntPtr d = SvGpuCore.Alloc(72), o = SvGpuCore.Alloc(8);
        try {
            Marshal.WriteInt32(d, 0, bbW); Marshal.WriteInt32(d, 4, bbH); Marshal.WriteInt32(d, 16, 87);
            Marshal.WriteInt32(d, 28, 1);                       // SampleDesc.Count
            Marshal.WriteInt32(d, 36, 0x20); Marshal.WriteInt32(d, 40, 1);   // RENDER_TARGET_OUTPUT, 1 buffer
            Marshal.WriteIntPtr(d, 48, hwnd); Marshal.WriteInt32(d, 56, 1);  // windowed
            SvGpuCore.Chk(SvGpuCore.C(factory, 10, g.Dev, d, o), "CreateSwapChain");
            swap = Marshal.ReadIntPtr(o);
        } finally { Marshal.FreeHGlobal(d); Marshal.FreeHGlobal(o); }
    }
    void MakeTargets() {
        IntPtr o = SvGpuCore.Alloc(8), gd = SvGpuCore.Alloc(16);
        try {
            Marshal.Copy(SvGpuCore.IID_Texture2D.ToByteArray(), 0, gd, 16);
            SvGpuCore.Chk(SvGpuCore.C(swap, 9, SvGpuCore.I(0), gd, o), "GetBuffer");
            IntPtr back = Marshal.ReadIntPtr(o);
            SvGpuCore.Release(ref backTex); backTex = back; rtv = g.Rtv(back);
        } finally { Marshal.FreeHGlobal(o); Marshal.FreeHGlobal(gd); }
        SvGpuCore.Release(ref midSrv); SvGpuCore.Release(ref midRtv); SvGpuCore.Release(ref midTex);
        midTex = g.Tex(bbW, srcH, 10, 0x28, 0, 0, null); midRtv = g.Rtv(midTex); midSrv = g.Srv(midTex);
        if (curTex == IntPtr.Zero) { curTex = g.Tex(CUR, CUR, 87, 0x8, 0, 0, null); curSrv = g.Srv(curTex); }
    }
    void ResizeSwap(int w, int h) {
        SvGpuCore.Release(ref rtv); SvGpuCore.Release(ref backTex);
        SvGpuCore.Chk(SvGpuCore.C(swap, 13, SvGpuCore.I(0), SvGpuCore.I(w), SvGpuCore.I(h), SvGpuCore.I(0), SvGpuCore.I(0)), "ResizeBuffers");
        bbW = w; bbH = h; MakeTargets();
    }

    // Pointer image: drawn on black and on white to recover its alpha, whatever kind of cursor it is.
    void BuildCursor(IntPtr hc) {
        SvGpuNative.ICONINFO ii;
        curHotX = 0; curHotY = 0;
        if (SvGpuNative.GetIconInfo(hc, out ii)) {
            curHotX = ii.xHotspot; curHotY = ii.yHotspot;
            if (ii.hbmMask != IntPtr.Zero) SvGpuNative.DeleteObject(ii.hbmMask);
            if (ii.hbmColor != IntPtr.Zero) SvGpuNative.DeleteObject(ii.hbmColor);
        }
        byte[][] px = new byte[2][];
        for (int pass = 0; pass < 2; pass++) {
            using (Bitmap bmp = new Bitmap(CUR, CUR, PixelFormat.Format32bppRgb)) {
                using (Graphics gr = Graphics.FromImage(bmp)) {
                    gr.Clear(pass == 0 ? Color.Black : Color.White);
                    IntPtr hdc = gr.GetHdc();
                    SvGpuNative.DrawIconEx(hdc, 0, 0, hc, 0, 0, 0, IntPtr.Zero, 3);   // DI_NORMAL
                    gr.ReleaseHdc(hdc);
                }
                BitmapData bd = bmp.LockBits(new Rectangle(0, 0, CUR, CUR), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
                px[pass] = new byte[CUR * CUR * 4]; Marshal.Copy(bd.Scan0, px[pass], 0, px[pass].Length); bmp.UnlockBits(bd);
            }
        }
        byte[] o = new byte[CUR * CUR * 4];
        for (int i = 0; i < CUR * CUR; i++) {
            int a = 0;
            for (int c = 0; c < 3; c++) { int d = 255 - (px[1][i * 4 + c] - px[0][i * 4 + c]); if (d > a) a = d; }
            if (a < 0) a = 0; if (a > 255) a = 255;
            if (a == 0 && (px[0][i * 4] | px[0][i * 4 + 1] | px[0][i * 4 + 2]) != 0 && px[1][i * 4] != 255) a = 255;
            for (int c = 0; c < 3; c++) o[i * 4 + c] = px[0][i * 4 + c];   // already premultiplied (drawn on black)
            o[i * 4 + 3] = (byte)a;
        }
        g.Upload(curTex, o, CUR * 4);
        curHandle = hc;
    }

    // Test hook: the finished picture (BGRA, bbW x bbH), read back from the back buffer before it is presented.
    volatile bool grabReq; byte[] grabOut; readonly ManualResetEvent grabDone = new ManualResetEvent(false);
    public byte[] Grab(int timeoutMs) {
        grabDone.Reset(); grabOut = null; grabReq = true;
        if (!grabDone.WaitOne(timeoutMs)) { grabReq = false; return null; }
        return grabOut;
    }
    public int Width { get { return bbW; } }
    public int Height { get { return bbH; } }
    public int SourceWidth { get { return srcW; } }
    public int SourceHeight { get { return srcH; } }
    byte[] ReadBack() {
        IntPtr stage = g.Tex(bbW, bbH, 87, 0, 3, 0x20000, null), m = SvGpuCore.Alloc(16);
        try {
            SvGpuCore.C(g.Ctx, 47, stage, backTex);
            SvGpuCore.Chk(SvGpuCore.C(g.Ctx, 14, stage, SvGpuCore.I(0), SvGpuCore.I(1), SvGpuCore.I(0), m), "Map");
            IntPtr data = Marshal.ReadIntPtr(m, 0); int pitch = Marshal.ReadInt32(m, 8);
            byte[] o = new byte[bbW * bbH * 4];
            for (int y = 0; y < bbH; y++) Marshal.Copy(new IntPtr(data.ToInt64() + (long)y * pitch), o, y * bbW * 4, bbW * 4);
            SvGpuCore.C(g.Ctx, 15, stage, SvGpuCore.I(0));
            return o;
        } finally { Marshal.FreeHGlobal(m); SvGpuCore.Release(ref stage); }
    }

    void Loop() {
        System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
        long lastPresent = -1000, secStart = 0; long secFrames = 0;
        int lastCx = int.MinValue, lastCy = int.MinValue; bool lastOn = false, dirty = true;
        long failSince = -1;
        IntPtr info = SvGpuCore.Alloc(64), res = SvGpuCore.Alloc(8);
        try {
            while (!stop) {
                if (Paused || !SvGpuNative.IsWindowVisible(hwnd)) { Thread.Sleep(40); dirty = true; continue; }
                int wW, wH; lock (sizeLock) { wW = wantW; wH = wantH; }
                if (wW != bbW || wH != bbH) { try { ResizeSwap(wW, wH); dirty = true; } catch (Exception e) { Error = e.Message; Failed = true; return; } }
                int hr = SvGpuCore.C(dup, 8, SvGpuCore.I(12), info, res);   // AcquireNextFrame(12 ms)
                if (hr == 0) {
                    failSince = -1;
                    IntPtr r = Marshal.ReadIntPtr(res), t = SvGpuCore.Query(r, SvGpuCore.IID_Texture2D);
                    if (t != IntPtr.Zero) { SvGpuCore.C(g.Ctx, 47, deskTex, t); SvGpuCore.Release(ref t); dirty = true; }
                    SvGpuCore.Release(ref r);
                    SvGpuCore.C(dup, 14);                                    // ReleaseFrame
                } else if (unchecked((uint)hr) == 0x887A0027) {              // WAIT_TIMEOUT: nothing changed
                    failSince = -1;
                } else {                                                      // ACCESS_LOST (mode change, secure desktop, ...) and others
                    if (failSince < 0) failSince = clock.ElapsedMilliseconds;
                    if (clock.ElapsedMilliseconds - failSince > 4000) { Error = "screen duplication lost (0x" + hr.ToString("X8") + ")"; Failed = true; return; }
                    Thread.Sleep(100);
                    try { FindOutput(); OpenDuplication(); } catch (Exception) { }
                    continue;
                }
                // pointer: position and image (the duplicated frame never contains it)
                SvGpuNative.CURSORINFO ci = new SvGpuNative.CURSORINFO(); ci.cbSize = Marshal.SizeOf(typeof(SvGpuNative.CURSORINFO));
                bool on = false; int cx = 0, cy = 0;
                if (PointerOn && SvGpuNative.GetCursorInfo(ref ci) && (ci.flags & 1) != 0) {
                    if (ci.x >= desktopX && ci.y >= desktopY && ci.x < desktopX + srcW && ci.y < desktopY + srcH) {
                        if (ci.hCursor != curHandle) { try { BuildCursor(ci.hCursor); } catch (Exception) { } }
                        on = true;
                        cx = (int)Math.Round((double)(ci.x - desktopX) * bbW / srcW) - curHotX;
                        cy = (int)Math.Round((double)(ci.y - desktopY) * bbH / srcH) - curHotY;
                    }
                }
                if (on != lastOn || cx != lastCx || cy != lastCy) { dirty = true; lastOn = on; lastCx = cx; lastCy = cy; }
                long now = clock.ElapsedMilliseconds;
                if (!dirty && now - lastPresent < 500) continue;
                g.Run(deskSrv, midRtv, midSrv, curSrv, rtv, srcW, srcH, bbW, bbH, SvGpuCore.Cb(srcW, srcH, bbW, bbH, cx, cy, CUR, CUR, on));
                if (grabReq) { try { grabOut = ReadBack(); } catch (Exception) { grabOut = null; } grabReq = false; grabDone.Set(); }
                int phr = SvGpuCore.C(swap, 8, SvGpuCore.I(1), SvGpuCore.I(0));   // Present(vsync, 0)
                if (phr < 0 && unchecked((uint)phr) != 0x087A0001 && unchecked((uint)phr) != 0x087A0002) { Error = "Present failed (0x" + phr.ToString("X8") + ")"; Failed = true; return; }
                dirty = false; lastPresent = now; Frames++; secFrames++;
                if (now - secStart >= 1000) { Fps = secFrames * 1000.0 / (now - secStart); secStart = now; secFrames = 0; }
            }
        } catch (Exception e) {
            Error = e.Message; Failed = true;
        } finally {
            Marshal.FreeHGlobal(info); Marshal.FreeHGlobal(res);
        }
    }

    void Cleanup() {
        try {
            SvGpuCore.Release(ref curSrv); SvGpuCore.Release(ref curTex); SvGpuCore.Release(ref midSrv); SvGpuCore.Release(ref midRtv); SvGpuCore.Release(ref midTex);
            SvGpuCore.Release(ref deskSrv); SvGpuCore.Release(ref deskTex); SvGpuCore.Release(ref rtv); SvGpuCore.Release(ref backTex); SvGpuCore.Release(ref swap); SvGpuCore.Release(ref dup);
            SvGpuCore.Release(ref output); SvGpuCore.Release(ref adapter); SvGpuCore.Release(ref factory);
            if (g != null) { g.Dispose(); g = null; }
        } catch (Exception) { }
    }
}
'@
