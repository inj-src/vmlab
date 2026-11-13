// d12.cpp: does a native Direct3D 12 program get a device? For each adapter: D3D12CreateDevice at
// feature level 11_0, and which d3d12.dll the process has loaded.
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>
#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")
int main() {
    wchar_t path[MAX_PATH] = L"?";
    GetModuleFileNameW(GetModuleHandleW(L"d3d12.dll"), path, MAX_PATH);
    wprintf(L"d3d12.dll: %s\n", path);
    IDXGIFactory4* f = 0;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory4), (void**)&f))) { puts("no DXGI factory"); return 1; }
    IDXGIAdapter1* ad = 0;
    for (UINT a = 0; f->EnumAdapters1(a, &ad) == S_OK; a++) {
        DXGI_ADAPTER_DESC1 d; ad->GetDesc1(&d);
        ID3D12Device* dev = 0;
        HRESULT hr = D3D12CreateDevice(ad, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void**)&dev);
        wprintf(L"adapter %u: %s (flags %x): D3D12CreateDevice %08lx\n", a, d.Description, d.Flags, hr);
        if (dev) {
            ID3D12CommandQueue* q = 0; D3D12_COMMAND_QUEUE_DESC qd = {};
            HRESULT hq = dev->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), (void**)&q);
            printf("  command queue %08lx\n", hq);
            if (q) q->Release();
            dev->Release();
        }
        ad->Release();
    }
    return 0;
}
