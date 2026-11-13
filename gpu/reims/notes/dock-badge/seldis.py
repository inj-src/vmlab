"""seldis.py: an lldb command, `seldis NAME`, that disassembles a function of a library in the
dyld shared cache without a process, and names what its rip-relative operands point at: a
selector, a C string, or a pointer to one. Without a process lldb reads a cache library from its
own mapping of the cache, so the addresses and the pointers it shows are live ones in lldb.

  lldb -b -o 'target create ./app' -o 'command script import seldis.py' -o 'seldis CA::Foo::bar'
"""
import re
import lldb



def read(target, addr, n):
    a = target.ResolveFileAddress(addr)
    if not a.IsValid():
        return None
    err = lldb.SBError()
    data = target.ReadMemory(a, n, err)
    return data if err.Success() and data else None


CACHE = None


def own(addr, n):
    """Bytes at a pointer lldb read out of the shared cache. Without a process lldb reads a cache
    library's data from its own mapping of the cache, so such a pointer is already slid: a live
    address in this process, where the selector strings (in no module of the target) lie too."""
    global CACHE
    import ctypes
    if CACHE is None:
        libc = ctypes.CDLL(None)
        libc._dyld_get_image_name.restype = ctypes.c_char_p
        libc._dyld_get_image_vmaddr_slide.restype = ctypes.c_long
        libc._dyld_get_shared_cache_range.restype = ctypes.c_void_p
        size = ctypes.c_size_t(0)
        base = libc._dyld_get_shared_cache_range(ctypes.byref(size)) or 0
        slide = 0
        for i in range(libc._dyld_image_count()):
            if (libc._dyld_get_image_name(i) or b"").startswith(b"/usr/lib/system/"):
                slide = libc._dyld_get_image_vmaddr_slide(i)
                break
        CACHE = (slide, base, base + size.value)
    slide, lo, hi = CACHE
    if not lo <= addr < hi - n:
        return None
    return ctypes.string_at(addr, n)


def text_at(target, addr):
    data = read(target, addr, 120)
    if not data:
        return None
    s = data.split(b"\0")[0]
    if not 2 <= len(s) < 119 or any(c < 32 or c > 126 for c in s):
        return None
    return s.decode()


def describe(target, addr, deref):
    if deref:
        data = read(target, addr, 8)
        if not data or len(data) < 8:
            return None
        ptr = int.from_bytes(data, "little")
        live = own(ptr, 120)
        if live:
            t = live.split(b"\0")[0]
            if 2 <= len(t) < 119 and all(32 <= c < 127 for c in t):
                return '"%s"' % t.decode()
        s = text_at(target, ptr)
        if s:
            return '"%s"' % s
        sym = target.ResolveFileAddress(ptr).GetSymbol()
        return sym.GetName() if sym.IsValid() else None
    return None


def seldis(debugger, command, result, internal_dict):
    target = debugger.GetSelectedTarget()
    found = target.FindFunctions(command.strip())
    if found.GetSize() == 0:
        result.AppendMessage("no function " + command)
        return
    for n in range(found.GetSize()):
        sym = found.GetContextAtIndex(n).GetSymbol()
        result.AppendMessage("== " + sym.GetName())
        insts = sym.GetInstructions(target)
        start = sym.GetStartAddress().GetFileAddress()
        for i in range(insts.GetSize()):
            ins = insts.GetInstructionAtIndex(i)
            at = ins.GetAddress().GetFileAddress()
            ops = ins.GetOperands(target)
            note = ins.GetComment(target) or ""
            m = re.search(r"(-?0x[0-9a-f]+)\(%rip\)", ops)
            if m:
                where = at + ins.GetByteSize() + int(m.group(1), 16)
                got = describe(target, where, True)
                if got:
                    note = got
            result.AppendMessage("<+%d> %s %s%s" % (at - start, ins.GetMnemonic(target), ops, "   ; " + note if note else ""))


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -o -f seldis.seldis seldis")
