/// Line-ending and terminator normalisation for `VD_AGENT_CLIPBOARD_UTF8_TEXT`.
///
/// The guest announces which convention it uses (`VD_AGENT_CAP_GUEST_LINEEND_CRLF`), and spice-gtk
/// converts on that basis in both directions. Callers above this layer deal only in LF.
enum ClipboardText {
    private static let cr: UInt8 = 0x0D, lf: UInt8 = 0x0A

    /// LF → CRLF, leaving any CRLF already present alone.
    static func toCRLF(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 16)
        var previous: UInt8 = 0
        for c in bytes {
            if c == lf, previous != cr { out.append(cr) }
            out.append(c)
            previous = c
        }
        return out
    }

    /// CRLF → LF. A lone CR is left as it is; it is not a line ending on either side.
    static func toLF(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if bytes[i] == cr, i + 1 < bytes.endIndex, bytes[i + 1] == lf { i += 1; continue }
            out.append(bytes[i])
            i += 1
        }
        return out
    }

    /// Some agents include the C terminator, which pastes as a visible NIL in a lot of apps.
    static func trimmingTrailingNULs(_ bytes: [UInt8]) -> [UInt8] {
        var end = bytes.endIndex
        while end > bytes.startIndex, bytes[end - 1] == 0 { end -= 1 }
        return Array(bytes[bytes.startIndex ..< end])
    }
}
