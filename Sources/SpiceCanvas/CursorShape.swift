import SpiceWire

/// A decoded cursor: BGRA, straight (non-premultiplied) alpha, `width * 4` bytes per row.
public struct CursorShape: Sendable, Equatable {
    public var width: Int, height: Int, hotX: Int, hotY: Int
    public var pixels: [UInt8]
    public init(width: Int, height: Int, hotX: Int, hotY: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY; self.pixels = pixels
    }
}

public enum CursorDecoder {
    public static func decode(_ h: CursorHeader, data: [UInt8]) throws -> CursorShape {
        let w = Int(h.width), ht = Int(h.height), n = w * ht
        var out = [UInt8](repeating: 0, count: n * 4)
        func need(_ bytes: Int) throws {
            guard data.count >= bytes else { throw CanvasError.decode("cursor \(h.type): need \(bytes) bytes, have \(data.count)") }
        }
        // Colour cursors trail a 1-bit AND mask indexed linearly over pixels, MSB first (spice-gtk's get_pix_mask).
        func masked(_ i: Int, at offset: Int) -> Bool { data[offset + i >> 3] & (0x80 >> (i & 7)) != 0 }
        let maskBytes = (n + 7) / 8

        switch h.type {
        case .alpha:
            try need(n * 4)
            out = Array(data[0 ..< n * 4])
        case .mono:
            let bpl = (w + 7) / 8
            try need(bpl * ht * 2)
            for y in 0 ..< ht {
                for x in 0 ..< w {
                    let byte = y * bpl + x >> 3, bit: UInt8 = 0x80 >> (x & 7)
                    let and = data[byte] & bit != 0, xor = data[bpl * ht + byte] & bit != 0
                    let o = (y * w + x) * 4
                    switch (and, xor) {
                    case (false, false): out[o + 3] = 0xFF                                       // black
                    case (false, true): out[o] = 0xFF; out[o + 1] = 0xFF; out[o + 2] = 0xFF; out[o + 3] = 0xFF   // white
                    case (true, false): break                                                    // transparent
                    case (true, true): out[o + 3] = 0x80                                         // "invert": spice-gtk draws half-black
                    }
                }
            }
        case .color32:
            try need(n * 4 + maskBytes)
            for i in 0 ..< n {
                let s = i * 4, o = i * 4
                out[o] = data[s]; out[o + 1] = data[s + 1]; out[o + 2] = data[s + 2]
                if masked(i, at: n * 4) {
                    // spice-gtk: a masked-out pure-white pixel is an XOR (inverting) pixel; draw it half-black.
                    if data[s] == 0xFF, data[s + 1] == 0xFF, data[s + 2] == 0xFF { out[o] = 0; out[o + 1] = 0; out[o + 2] = 0; out[o + 3] = 0x80 }
                } else {
                    out[o + 3] = 0xFF
                }
            }
        case .color24:
            try need(n * 3 + maskBytes)
            for i in 0 ..< n {
                let s = i * 3, o = i * 4
                out[o] = data[s]; out[o + 1] = data[s + 1]; out[o + 2] = data[s + 2]
                out[o + 3] = masked(i, at: n * 3) ? 0 : 0xFF
            }
        case .color16:
            try need(n * 2 + maskBytes)
            for i in 0 ..< n {
                let v = UInt16(data[i * 2]) | UInt16(data[i * 2 + 1]) << 8, o = i * 4
                out[o] = UInt8((v & 0x1F) << 3); out[o + 1] = UInt8(((v >> 5) & 0x1F) << 3); out[o + 2] = UInt8(((v >> 10) & 0x1F) << 3)
                out[o + 3] = masked(i, at: n * 2) ? 0 : 0xFF
            }
        case .color4, .color8:
            // Paletted cursors: no modern QXL driver emits them and spice-gtk does not decode them either.
            throw CanvasError.unsupported("cursor type \(h.type)")
        }
        return CursorShape(width: w, height: ht, hotX: Int(h.hotX), hotY: Int(h.hotY), pixels: out)
    }
}
