// dd.cpp: does DXGI Desktop Duplication give the desktop's picture? For each output: duplicate it,
// take 8 frames, copy each to a staging texture, map it and count the pixels that are not black.
// A small window at 300,300 changes colour before each frame, so every frame is a new one: "window
// pixel" must follow RGB(40i+20, 255-30i, 128) from frame 1 on, and "lit" must stay near the full
// count (frame 0 is the only copy of the whole desktop; later frames copy what changed).
// With a file name as argument, frame 1 of the first output is written there as a 32-bit BMP.
// Run it in the desktop session: C:\vmlab\run-interactive.ps1.
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
static void save_bmp(const char* path, const void* data, UINT pitch, UINT w, UINT h) {
    BITMAPFILEHEADER fh = {}; BITMAPINFOHEADER ih = {};
    fh.bfType = 0x4d42; fh.bfOffBits = sizeof fh + sizeof ih; fh.bfSize = fh.bfOffBits + w * h * 4;
    ih.biSize = sizeof ih; ih.biWidth = w; ih.biHeight = -(LONG)h; ih.biPlanes = 1; ih.biBitCount = 32;
    FILE* f = fopen(path, "wb"); if (!f) return;
    fwrite(&fh, sizeof fh, 1, f); fwrite(&ih, sizeof ih, 1, f);
    for (UINT y = 0; y < h; y++) fwrite((const char*)data + (size_t)y * pitch, 4, w, f);
    fclose(f);
}
int main(int argc, char** argv) {
    IDXGIFactory1* f = 0;
    CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&f);
    IDXGIAdapter1* ad = 0;
    for (UINT a = 0; f->EnumAdapters1(a, &ad) == S_OK; a++) {
        DXGI_ADAPTER_DESC1 d; ad->GetDesc1(&d);
        wprintf(L"adapter %u: %s\n", a, d.Description);
        IDXGIOutput* out = 0;
        for (UINT o = 0; ad->EnumOutputs(o, &out) == S_OK; o++) {
            IDXGIOutput1* o1 = 0; out->QueryInterface(&o1);
            ID3D11Device* dev = 0; ID3D11DeviceContext* ctx = 0; D3D_FEATURE_LEVEL fl = (D3D_FEATURE_LEVEL)0;
            HRESULT hr = D3D11CreateDevice(ad, D3D_DRIVER_TYPE_UNKNOWN, 0, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                           0, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx);
            printf(" output %u: D3D11CreateDevice %08lx level %x\n", o, hr, fl);
            if (FAILED(hr)) continue;
            IDXGIOutputDuplication* dup = 0;
            hr = o1->DuplicateOutput(dev, &dup);
            printf(" DuplicateOutput %08lx\n", hr);
            if (FAILED(hr)) continue;
            DXGI_OUTDUPL_DESC dd; dup->GetDesc(&dd);
            printf(" %ux%u format %d in system memory %d\n", dd.ModeDesc.Width, dd.ModeDesc.Height,
                   dd.ModeDesc.Format, dd.DesktopImageInSystemMemory);
            HWND w = CreateWindowExA(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, "STATIC", "", WS_POPUP | WS_VISIBLE,
                                     300, 300, 400, 300, 0, 0, 0, 0);
            for (int i = 0; i < 8; i++) {
                if (w) {
                    HDC dc = GetDC(w); RECT r = {0, 0, 400, 300};
                    HBRUSH b = CreateSolidBrush(RGB(40 * i + 20, 255 - 30 * i, 128));
                    FillRect(dc, &r, b); DeleteObject(b); ReleaseDC(w, dc); GdiFlush();
                    MSG m; while (PeekMessageA(&m, 0, 0, 0, PM_REMOVE)) DispatchMessageA(&m);
                    Sleep(150);
                }
                DXGI_OUTDUPL_FRAME_INFO fi; IDXGIResource* res = 0;
                hr = dup->AcquireNextFrame(700, &fi, &res);
                if (hr == DXGI_ERROR_WAIT_TIMEOUT) { printf(" frame %d: no change\n", i); continue; }
                if (FAILED(hr)) { printf(" AcquireNextFrame %08lx\n", hr); break; }
                ID3D11Texture2D* tex = 0; res->QueryInterface(&tex);
                D3D11_TEXTURE2D_DESC td; tex->GetDesc(&td);
                D3D11_TEXTURE2D_DESC sd = td;
                sd.Usage = D3D11_USAGE_STAGING; sd.BindFlags = 0; sd.MiscFlags = 0;
                sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                ID3D11Texture2D* st = 0;
                HRESULT hc = dev->CreateTexture2D(&sd, 0, &st);
                unsigned long long lit = 0, all = 0; unsigned px_win = 0, px_bg = 0;
                HRESULT hm = E_FAIL;
                if (st) {
                    ctx->CopyResource(st, tex);
                    D3D11_MAPPED_SUBRESOURCE m;
                    hm = ctx->Map(st, 0, D3D11_MAP_READ, 0, &m);
                    if (SUCCEEDED(hm)) {
                        for (UINT y = 0; y < td.Height; y++) {
                            const unsigned* p = (const unsigned*)((const char*)m.pData + (size_t)y * m.RowPitch);
                            for (UINT x = 0; x < td.Width; x++) { all++; if (p[x] & 0xffffff) lit++; }
                        }
                        if (argc > 1 && i == 1) { save_bmp(argv[1], m.pData, m.RowPitch, td.Width, td.Height); argc = 1; }
                        px_win = ((const unsigned*)((const char*)m.pData + (size_t)450 * m.RowPitch))[500];
                        px_bg = ((const unsigned*)((const char*)m.pData + (size_t)900 * m.RowPitch))[1500];
                        ctx->Unmap(st, 0);
                    }
                    st->Release();
                }
                printf(" frame %d: %ux%u format %d misc %x, frames %u, present %lld, create %08lx map %08lx, lit %llu of %llu, window pixel %08x, background pixel %08x\n",
                       i, td.Width, td.Height, td.Format, td.MiscFlags, fi.AccumulatedFrames,
                       fi.LastPresentTime.QuadPart, hc, hm, lit, all, px_win, px_bg);
                tex->Release(); res->Release(); dup->ReleaseFrame();
            }
            dup->Release();
        }
    }
    return 0;
}
