#!/usr/bin/env python3
"""Tool-independent DEFINED global symbol reader for static archives / objects (Mach-O, ELF64,
fat/universal wrappers). Prints '<slice> <symbol>' per defined external symbol, one per line.
Fails closed (exit 2, message on stderr) on anything it cannot fully parse, on zero parsed
object members, or on zero symbols: inability to inspect is never an empty success.
Usage: defined-symbols.py FILE      (leading underscore on Mach-O names is stripped)"""
import struct, sys

def fail(msg):
    print("defined-symbols: " + msg, file=sys.stderr); sys.exit(2)

def macho_symbols(b, off=0):
    magic = struct.unpack_from('<I', b, off)[0]
    if magic != 0xfeedfacf: fail("unsupported Mach-O magic %#x (only 64-bit little-endian)" % magic)
    ncmds = struct.unpack_from('<I', b, off + 16)[0]
    p = off + 32; out = []; found = False
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', b, p)
        if cmd == 0x2:  # LC_SYMTAB
            found = True
            symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', b, p + 8)
            for i in range(nsyms):
                strx, ntype, nsect, ndesc, nvalue = struct.unpack_from('<IBBHQ', b, off + symoff + 16 * i)
                if (ntype & 0x01) and (ntype & 0x0e) == 0x0e and not (ntype & 0xe0):  # N_EXT, N_SECT, not stab
                    e = b.index(b'\0', off + stroff + strx)
                    name = b[off + stroff + strx:e].decode('latin1')
                    out.append(name[1:] if name.startswith('_') else name)
        p += size
    if not found: fail("Mach-O object without LC_SYMTAB")
    return out

def elf_symbols(b, off=0):
    if b[off + 4] != 2 or b[off + 5] != 1: fail("unsupported ELF class/endianness")
    shoff, = struct.unpack_from('<Q', b, off + 0x28)
    shentsize, shnum = struct.unpack_from('<HH', b, off + 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', b, off + shoff + i * shentsize) for i in range(shnum)]
    out = []; found = False
    for s in secs:
        if s[1] == 2:  # SHT_SYMTAB
            found = True
            strsec = secs[s[6]]
            for i in range(s[5] // 24):
                name, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', b, off + s[4] + 24 * i)
                if (info >> 4) in (1, 2) and shndx != 0 and name:  # GLOBAL/WEAK, defined
                    st = off + strsec[4] + name
                    out.append(b[st:b.index(b'\0', st)].decode('latin1'))
    if not found: fail("ELF object without .symtab")
    return out

def object_symbols(b, off=0):
    m = b[off:off + 4]
    if m == b'\xcf\xfa\xed\xfe': return macho_symbols(b, off)
    if m == b'\x7fELF': return elf_symbols(b, off)
    return None

def archive_symbols(b):
    p = 8; syms = []; objs = 0
    while p < len(b):
        if p + 60 > len(b): fail("truncated archive header")
        hdr = b[p:p + 60]
        if hdr[58:60] != b'`\n': fail("bad archive member header at %d" % p)
        name = hdr[0:16].decode('latin1').rstrip(); size = int(hdr[48:58].decode().strip())
        body = p + 60
        if name.startswith('#1/'):  # BSD long name inside the data
            n = int(name[3:]); name = b[body:body + n].rstrip(b'\0').decode('latin1'); body += n; size -= n
        data_end = body + size
        if not name.startswith(('__.SYMDEF', '/', '//', '__.')) :
            s = object_symbols(b, body)
            if s is not None: syms += s; objs += 1
        p = data_end + (data_end & 1)
    if objs == 0: fail("archive contains zero parsable object members")
    return syms

def slices(b):
    if b[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        big = b[:4] == b'\xca\xfe\xba\xbf'
        n, = struct.unpack_from('>I', b, 4); p = 8; out = []
        for i in range(n):
            if big: cpu, sub, off, size, al = struct.unpack_from('>iiQQI', b, p); p += 32
            else: cpu, sub, off, size, al = struct.unpack_from('>iIIII', b, p); p += 20
            out.append(('cpu%#x' % (cpu & 0xffffffff), b[off:off + size]))
        if not out: fail("empty fat file")
        return out
    return [('thin', b)]

def main():
    if len(sys.argv) != 2: fail("usage: defined-symbols.py FILE")
    try: raw = open(sys.argv[1], 'rb').read()
    except OSError as e: fail("cannot read: %s" % e)
    if not raw: fail("empty file")
    total = 0
    for label, b in slices(raw):
        if b[:8] == b'!<arch>\n': s = archive_symbols(b)
        else:
            s = object_symbols(b)
            if s is None: fail("slice %s is neither archive nor Mach-O/ELF object" % label)
        if not s: fail("slice %s has zero defined global symbols" % label)
        for x in sorted(set(s)): print(label, x)
        total += len(s)
    if total == 0: fail("no symbols")

try: main()
except (struct.error, IndexError, ValueError) as e: fail("parse error: %r" % (e,))
