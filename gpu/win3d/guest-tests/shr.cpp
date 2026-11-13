// shr.cpp: a shared BGRA render target between two Direct3D 11 devices, the ordinary use of the
// kind of texture that guest-patches/9003 makes a display image. Device A clears it to a colour,
// device B opens it and must read that colour; then B clears it and A must read B's colour. Once
// with a legacy shared handle, once with a keyed mutex.
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
static unsigned read_pixel(ID3D11Device* dev, ID3D11DeviceContext* ctx, ID3D11Texture2D* tex) {
    D3D11_TEXTURE2D_DESC d; tex->GetDesc(&d);
    d.Usage = D3D11_USAGE_STAGING; d.BindFlags = 0; d.MiscFlags = 0; d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D* st = 0; if (FAILED(dev->CreateTexture2D(&d, 0, &st))) return 0xdead0001;
    ctx->CopyResource(st, tex);
    D3D11_MAPPED_SUBRESOURCE m; unsigned v = 0xdead0002;
    if (SUCCEEDED(ctx->Map(st, 0, D3D11_MAP_READ, 0, &m))) {
        v = ((const unsigned*)((const char*)m.pData + (size_t)(d.Height / 2) * m.RowPitch))[d.Width / 2];
        ctx->Unmap(st, 0);
    }
    st->Release(); return v;
}
static void clear(ID3D11Device* dev, ID3D11DeviceContext* ctx, ID3D11Texture2D* tex, float r, float g, float b) {
    ID3D11RenderTargetView* rtv = 0; dev->CreateRenderTargetView(tex, 0, &rtv);
    if (!rtv) { puts("  no render target view"); return; }
    const float c[4] = {r, g, b, 1}; ctx->ClearRenderTargetView(rtv, c); ctx->Flush(); rtv->Release();
}
static int run(bool keyed) {
    ID3D11Device *a = 0, *b = 0; ID3D11DeviceContext *ca = 0, *cb = 0;
    if (FAILED(D3D11CreateDevice(0, D3D_DRIVER_TYPE_HARDWARE, 0, D3D11_CREATE_DEVICE_BGRA_SUPPORT, 0, 0, D3D11_SDK_VERSION, &a, 0, &ca)) ||
        FAILED(D3D11CreateDevice(0, D3D_DRIVER_TYPE_HARDWARE, 0, D3D11_CREATE_DEVICE_BGRA_SUPPORT, 0, 0, D3D11_SDK_VERSION, &b, 0, &cb))) { puts("no device"); return 1; }
    D3D11_TEXTURE2D_DESC d = {}; d.Width = 640; d.Height = 360; d.MipLevels = 1; d.ArraySize = 1;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM; d.SampleDesc.Count = 1;
    d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    d.MiscFlags = keyed ? D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX : D3D11_RESOURCE_MISC_SHARED;
    ID3D11Texture2D *ta = 0, *tb = 0;
    HRESULT hr = a->CreateTexture2D(&d, 0, &ta);
    if (FAILED(hr)) { printf("  CreateTexture2D %08lx\n", hr); return 1; }
    IDXGIResource* res = 0; ta->QueryInterface(&res); HANDLE h = 0; res->GetSharedHandle(&h);
    hr = b->OpenSharedResource(h, __uuidof(ID3D11Texture2D), (void**)&tb);
    if (FAILED(hr)) { printf("  OpenSharedResource %08lx\n", hr); return 1; }
    IDXGIKeyedMutex *ka = 0, *kb = 0;
    if (keyed) { ta->QueryInterface(&ka); tb->QueryInterface(&kb); }
    if (ka) ka->AcquireSync(0, 1000);
    clear(a, ca, ta, 1.0f, 0.5f, 0.25f);                    // BGRA ffff8040
    if (ka) ka->ReleaseSync(1);
    if (kb) kb->AcquireSync(1, 1000);
    unsigned v1 = read_pixel(b, cb, tb);
    clear(b, cb, tb, 0.0f, 1.0f, 0.5f);                     // BGRA ff00ff80
    if (kb) kb->ReleaseSync(0);
    if (ka) ka->AcquireSync(0, 1000);
    unsigned v2 = read_pixel(a, ca, ta);
    if (ka) ka->ReleaseSync(0);
    bool ok = v1 == 0xffff8040 && v2 == 0xff00ff80;
    printf("  %s: B reads A's %08x (want ffff8040), A reads B's %08x (want ff00ff80): %s\n",
           keyed ? "keyed mutex" : "shared handle", v1, v2, ok ? "ok" : "WRONG");
    return ok ? 0 : 1;
}
int main() { int r = run(false); r |= run(true); puts(r ? "FAILED" : "PASSED"); return r; }
