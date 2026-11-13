// dd.cpp: does DXGI Desktop Duplication give the desktop's picture? For each output: duplicate it,
// take frames, copy each to a staging texture, map it and count the pixels that are not black.
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
int main() {
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
            for (int i = 0; i < 8; i++) {
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
                unsigned long long lit = 0, all = 0;
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
                        ctx->Unmap(st, 0);
                    }
                    st->Release();
                }
                printf(" frame %d: %ux%u format %d misc %x, frames %u, present %lld, create %08lx map %08lx, lit %llu of %llu\n",
                       i, td.Width, td.Height, td.Format, td.MiscFlags, fi.AccumulatedFrames,
                       fi.LastPresentTime.QuadPart, hc, hm, lit, all);
                tex->Release(); res->Release(); dup->ReleaseFrame();
            }
            dup->Release();
        }
    }
    return 0;
}
