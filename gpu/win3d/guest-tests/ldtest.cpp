// ldtest.exe [preload-path] : does a bare-name load of d3d12.dll resolve to a module that is
// already loaded from elsewhere, in a process that takes only Microsoft-signed DLLs?
#include <windows.h>
#include <stdio.h>
static void show(const char *what, HMODULE h, DWORD err) {
    wchar_t path[MAX_PATH] = L"";
    if (h) GetModuleFileNameW(h, path, MAX_PATH);
    printf("%s: %s error %lu %ls\n", what, h ? "loaded" : "FAILED", h ? 0 : err, path);
}
int wmain(int argc, wchar_t **argv) {
    if (argc > 1) {
        HMODULE h = LoadLibraryExW(argv[1], NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        show("preload", h, GetLastError());
    }
    PROCESS_MITIGATION_BINARY_SIGNATURE_POLICY p = {};
    p.MicrosoftSignedOnly = 1;
    BOOL ok = SetProcessMitigationPolicy(ProcessSignaturePolicy, &p, sizeof p);
    printf("MicrosoftSignedOnly: %s error %lu\n", ok ? "on" : "FAILED", ok ? 0 : GetLastError());
    HMODULE a = LoadLibraryExA("d3d12.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    show("LoadLibraryEx(d3d12.dll, SEARCH_SYSTEM32)", a, GetLastError());
    HMODULE b = LoadLibraryExA("d3d12.dll", NULL, 0);
    show("LoadLibraryEx(d3d12.dll, 0)", b, GetLastError());
    wchar_t sys[MAX_PATH]; GetSystemDirectoryW(sys, MAX_PATH); wcscat_s(sys, L"\\d3d12.dll");
    HMODULE c = LoadLibraryExW(sys, NULL, 0);
    show("LoadLibraryEx(full System32 path)", c, GetLastError());
    return 0;
}
