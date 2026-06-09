#!/usr/bin/env python3
"""Dump the raw-relevant tags of a DNG/TIFF: black/white level, CFA pattern, colour matrices,
as-shot neutral. Walks IFD0 + SubIFDs. No external dependencies.

Usage: dng-info.py <file.dng>
"""
import struct
import sys

TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8}
TAGS = {
    256: "ImageWidth", 257: "ImageLength", 258: "BitsPerSample", 259: "Compression",
    262: "PhotometricInterpretation", 271: "Make", 272: "Model", 330: "SubIFDs",
    33421: "CFARepeatPatternDim", 33422: "CFAPattern", 50706: "DNGVersion",
    50708: "UniqueCameraModel", 50714: "BlackLevel", 50717: "WhiteLevel",
    50721: "ColorMatrix1", 50722: "ColorMatrix2", 50728: "AsShotNeutral",
    50730: "BaselineExposure", 50778: "CalibrationIlluminant1", 50779: "CalibrationIlluminant2",
    50964: "ForwardMatrix1", 50965: "ForwardMatrix2", 51041: "NoiseProfile",
    34665: "ExifIFD", 33434: "ExposureTime", 34855: "ISOSpeedRatings",
}


def read_dng(path):
    with open(path, "rb") as f:
        data = f.read()
    bo = "<" if data[:2] == b"II" else ">" if data[:2] == b"MM" else None
    if bo is None:
        print("not a TIFF/DNG"); return
    (magic,) = struct.unpack(bo + "H", data[2:4])
    if magic != 42:
        print("bad TIFF magic"); return
    (ifd0,) = struct.unpack(bo + "I", data[4:8])

    def read_value(typ, count, off):
        size = TYPE_SIZE.get(typ, 1) * count
        raw = data[off:off + size]
        if typ in (1, 6, 7): return list(raw)
        if typ == 2: return raw.split(b"\0")[0].decode("ascii", "replace")
        if typ == 3: return list(struct.unpack(bo + "%dH" % count, raw))
        if typ == 4: return list(struct.unpack(bo + "%dI" % count, raw))
        if typ == 5:
            v = struct.unpack(bo + "%dI" % (count * 2), raw)
            return [v[i] / v[i + 1] if v[i + 1] else 0 for i in range(0, len(v), 2)]
        if typ == 10:
            v = struct.unpack(bo + "%di" % (count * 2), raw)
            return [v[i] / v[i + 1] if v[i + 1] else 0 for i in range(0, len(v), 2)]
        if typ == 12:
            return list(struct.unpack(bo + "%dd" % count, raw))
        return list(raw)

    def read_ifd(off):
        (n,) = struct.unpack(bo + "H", data[off:off + 2])
        entries = {}
        p = off + 2
        for _ in range(n):
            tag, typ, count = struct.unpack(bo + "HHI", data[p:p + 8])
            size = TYPE_SIZE.get(typ, 1) * count
            voff = p + 8 if size <= 4 else struct.unpack(bo + "I", data[p + 8:p + 12])[0]
            entries[tag] = (typ, count, voff)
            p += 12
        return entries

    def dump(entries, label):
        print(f"\n=== {label} ===")
        for tag, (typ, count, voff) in sorted(entries.items()):
            name = TAGS.get(tag, f"tag{tag}")
            if name.startswith("tag"):
                continue
            try:
                val = read_value(typ, count, voff)
            except Exception as exc:
                val = f"<err {exc}>"
            print(f"  {name:24} = {val}")

    ifd0_entries = read_ifd(ifd0)
    dump(ifd0_entries, "IFD0")
    if 330 in ifd0_entries:
        typ, count, voff = ifd0_entries[330]
        for i, sub in enumerate(read_value(typ, count, voff)):
            dump(read_ifd(int(sub)), f"SubIFD{i}")
    if 34665 in ifd0_entries:
        typ, count, voff = ifd0_entries[34665]
        dump(read_ifd(int(read_value(typ, count, voff)[0])), "ExifIFD")
    print("\n→ For Rawloom: use BlackLevel, WhiteLevel, CFAPattern from the IFD whose "
          "PhotometricInterpretation == 32803; ColorMatrix1/ForwardMatrix1 + AsShotNeutral from IFD0.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: dng-info.py <file.dng>"); sys.exit(2)
    read_dng(sys.argv[1])
