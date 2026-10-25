#!/usr/bin/env python3
"""Rebuild an APK with a replacement classes.dex, or 4-byte-align a signed APK.

  repack.py strip  <in.apk> <classes.dex> <out.apk>   replace dex, drop old v1 signature
  repack.py put    <in.apk> <entry> <file> <out.apk>  replace one entry (e.g. the signature block)
  repack.py align  <in.apk> <out.apk>                 zipalign -p 4 equivalent for STORED entries
"""
import struct
import sys
import zipfile

OLD_SIG = ("META-INF/MANIFEST.MF", "META-INF/KOREADER.SF", "META-INF/KOREADER.RSA")


def strip(src, dex, dst):
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
        for info in zin.infolist():
            if info.filename in OLD_SIG:
                continue
            data = open(dex, "rb").read() if info.filename == "classes.dex" else zin.read(info)
            out = zipfile.ZipInfo(info.filename, info.date_time)
            out.compress_type = info.compress_type
            out.external_attr = info.external_attr
            zout.writestr(out, data)


def put(src, entry, path, dst):
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
        for info in zin.infolist():
            data = open(path, "rb").read() if info.filename == entry else zin.read(info)
            out = zipfile.ZipInfo(info.filename, info.date_time)
            out.compress_type = info.compress_type
            out.external_attr = info.external_attr
            zout.writestr(out, data)


def align(src, dst):
    # Copy each entry's raw (already compressed) bytes, padding the local header's
    # extra field so STORED data starts on a 4-byte boundary. Signature-neutral:
    # v1 signatures cover entry contents, not header layout.
    with zipfile.ZipFile(src) as z, open(src, "rb") as raw, open(dst, "wb") as out:
        central = []
        for info in z.infolist():
            raw.seek(info.header_offset)
            hdr = raw.read(30)
            sig, ver, flag, meth, mt, md, crc, csz, usz, nlen, xlen = struct.unpack("<IHHHHHIIIHH", hdr)
            assert sig == 0x04034B50
            name = raw.read(nlen)
            raw.read(xlen)
            data = raw.read(info.compress_size)
            if flag & 0x08:  # data descriptor follows
                flag &= ~0x08
                crc, csz, usz = info.CRC, info.compress_size, info.file_size
            offset = out.tell()
            extra = b""
            if meth == 0:
                pad = (-(offset + 30 + nlen)) % 4
                extra = b"\0" * pad
            out.write(struct.pack("<IHHHHHIIIHH", sig, ver, flag, meth, mt, md, crc, csz, usz, nlen, len(extra)))
            out.write(name + extra + data)
            central.append((info, name, flag, meth, mt, md, crc, csz, usz, offset))
        cd_start = out.tell()
        for info, name, flag, meth, mt, md, crc, csz, usz, offset in central:
            out.write(struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, info.create_version | (info.create_system << 8),
                                  info.extract_version, flag, meth, mt, md, crc, csz, usz, len(name), 0, 0, 0,
                                  info.internal_attr, info.external_attr, offset))
            out.write(name)
        cd_end = out.tell()
        out.write(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(central), len(central),
                              cd_end - cd_start, cd_start, 0))


if __name__ == "__main__":
    {"strip": strip, "put": put, "align": align}[sys.argv[1]](*sys.argv[2:])
