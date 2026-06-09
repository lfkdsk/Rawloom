import Foundation
import simd
import RawloomCore

/// The real sensor parameters for the current capture, parsed from the photo's own DNG
/// (`AVCapturePhoto.fileDataRepresentation()`). Using these instead of hardcoded defaults is what
/// keeps real raw from coming out magenta: the true **black level** must be subtracted before white
/// balance, or WB amplifies the per-channel pedestal into a pink cast.
struct SensorRawInfo {
    var blackLevel: SIMD4<Float>      // [R, Gr, Gb, B] in raw code units
    var whiteLevel: Float
    var cfa: CFAPattern?
    var asShotNeutral: SIMD3<Float>?  // camera-native neutral (→ white balance)
    var forwardMatrix: [Float]?       // white-balanced camera → XYZ(D50), 9 row-major (→ CCM)
    var colorMatrix: [Float]?         // XYZ → camera, 9 row-major (CCM fallback when no ForwardMatrix)
}

/// A minimal little/big-endian TIFF/DNG reader: walks IFD0 + SubIFDs, finds the CFA image, and pulls
/// the handful of tags the pipeline needs. Fully optional — returns nil on anything unexpected so the
/// caller falls back to defaults.
enum DNGMetadata {

    static func parse(_ data: Data) -> SensorRawInfo? {
        let b = [UInt8](data)
        guard b.count > 8 else { return nil }
        let little: Bool
        if b[0] == 0x49, b[1] == 0x49 { little = true }
        else if b[0] == 0x4D, b[1] == 0x4D { little = false }
        else { return nil }

        func u16(_ o: Int) -> Int {
            guard o + 2 <= b.count else { return 0 }
            return little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])
        }
        func u32(_ o: Int) -> Int {
            guard o + 4 <= b.count else { return 0 }
            return little
                ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
                : Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }
        guard u16(2) == 42 else { return nil }

        func typeSize(_ t: Int) -> Int {
            switch t { case 1, 2, 6, 7: return 1; case 3, 8: return 2; case 4, 9, 11: return 4
            case 5, 10, 12: return 8; default: return 1 }
        }

        struct Entry { let type: Int; let count: Int; let valueOffset: Int }
        func readIFD(_ off: Int) -> (entries: [Int: Entry], next: Int)? {
            guard off > 0, off + 2 <= b.count else { return nil }
            let n = u16(off)
            var entries = [Int: Entry]()
            var p = off + 2
            for _ in 0..<n {
                guard p + 12 <= b.count else { break }
                let tag = u16(p), type = u16(p + 2), count = u32(p + 4)
                let valSize = typeSize(type) * count
                let voff = valSize <= 4 ? p + 8 : u32(p + 8)
                entries[tag] = Entry(type: type, count: count, valueOffset: voff)
                p += 12
            }
            return (entries, u32(p))
        }
        func numbers(_ e: Entry) -> [Double] {
            var out = [Double](); var o = e.valueOffset; let ts = typeSize(e.type)
            for _ in 0..<e.count {
                guard o + ts <= b.count else { break }
                switch e.type {
                case 3: out.append(Double(u16(o)))
                case 4: out.append(Double(u32(o)))
                case 1, 6: out.append(Double(b[o]))
                case 5: let n = u32(o), d = u32(o + 4); out.append(d != 0 ? Double(n) / Double(d) : 0)
                case 10:
                    let n = Int32(bitPattern: UInt32(u32(o) & 0xFFFFFFFF))
                    let d = Int32(bitPattern: UInt32(u32(o + 4) & 0xFFFFFFFF))
                    out.append(d != 0 ? Double(n) / Double(d) : 0)
                default: out.append(Double(b[o]))
                }
                o += ts
            }
            return out
        }

        guard let first = readIFD(u32(4)) else { return nil }
        var ifds = [first.entries]
        if let sub = first.entries[330] { for v in numbers(sub) { if let r = readIFD(Int(v)) { ifds.append(r.entries) } } }
        if first.next > 0, let r = readIFD(first.next) { ifds.append(r.entries) }

        var info = SensorRawInfo(blackLevel: SIMD4(repeating: 0), whiteLevel: 16383, cfa: nil, asShotNeutral: nil)

        // AsShotNeutral lives in IFD0.
        if let n = first.entries[50728] {
            let v = numbers(n)
            if v.count >= 3 { info.asShotNeutral = SIMD3(Float(v[0]), Float(v[1]), Float(v[2])) }
        }

        // ForwardMatrix (camera→XYZ D50) lives in IFD0; prefer illuminant 2 (usually daylight/D65).
        for tag in [50965, 50964] {
            if let e = first.entries[tag] {
                let v = numbers(e)
                if v.count >= 9 { info.forwardMatrix = v.prefix(9).map { Float($0) }; break }
            }
        }
        // ColorMatrix (XYZ→camera) — the CCM fallback. Apple's DNGs include this (DNG-required) but
        // often omit ForwardMatrix. Prefer illuminant 2 (daylight/D65).
        for tag in [50722, 50721] {
            if let e = first.entries[tag] {
                let v = numbers(e)
                if v.count >= 9 { info.colorMatrix = v.prefix(9).map { Float($0) }; break }
            }
        }

        // Find the CFA image IFD (PhotometricInterpretation == 32803).
        for e in ifds where numbers(e[262] ?? Entry(type: 3, count: 0, valueOffset: 0)).first == 32803 {
            if let bl = e[50714] { info.blackLevel = broadcast4(numbers(bl)) }
            if let wl = e[50717], let w = numbers(wl).first { info.whiteLevel = Float(w) }
            if let cf = e[33422] { info.cfa = cfaFrom(numbers(cf)) }
            return info
        }
        // Some DNGs put these on IFD0 directly.
        if let bl = first.entries[50714] { info.blackLevel = broadcast4(numbers(bl)) }
        if let wl = first.entries[50717], let w = numbers(wl).first { info.whiteLevel = Float(w) }
        if let cf = first.entries[33422] { info.cfa = cfaFrom(numbers(cf)) }
        return info
    }

    private static func broadcast4(_ v: [Double]) -> SIMD4<Float> {
        guard !v.isEmpty else { return SIMD4(repeating: 0) }
        if v.count == 1 { return SIMD4(repeating: Float(v[0])) }
        func at(_ i: Int) -> Float { Float(v[min(i, v.count - 1)]) }
        return SIMD4(at(0), at(1), at(2), at(3))
    }

    private static func cfaFrom(_ v: [Double]) -> CFAPattern? {
        guard v.count >= 4 else { return nil }
        let p = v.prefix(4).map { Int($0) } // 0=R,1=G,2=B
        switch (p[0], p[1], p[2], p[3]) {
        case (0, 1, 1, 2): return .rggb
        case (2, 1, 1, 0): return .bggr
        case (1, 0, 2, 1): return .grbg
        case (1, 2, 0, 1): return .gbrg
        default: return nil
        }
    }
}
