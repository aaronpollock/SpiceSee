public enum ChannelType: UInt8, Sendable {
    case main = 1, display = 2, inputs = 3, cursor = 4, playback = 5, record = 6
    case tunnel = 7, smartcard = 8, usbredir = 9, port = 10, webdav = 11
}

public enum CommonCap {
    public static let protocolAuthSelection: UInt32 = 0
    public static let authSpice: UInt32 = 1
    public static let authSasl: UInt32 = 2
    public static let miniHeader: UInt32 = 3
}

public enum DisplayCap {
    public static let sizedStream: UInt32 = 0, monitorsConfig: UInt32 = 1, composite: UInt32 = 2
    public static let a8Surface: UInt32 = 3, streamReport: UInt32 = 4, lz4: UInt32 = 5
    public static let prefCompression: UInt32 = 6, glScanout: UInt32 = 7, multiCodec: UInt32 = 8
    public static let codecMjpeg: UInt32 = 9, codecVp8: UInt32 = 10, codecH264: UInt32 = 11
    public static let prefVideoCodecType: UInt32 = 12, codecVp9: UInt32 = 13, codecH265: UInt32 = 14
}

public struct CapabilitySet: Sendable, Equatable {
    public private(set) var words: [UInt32]
    public init() { words = [] }
    public init(bits: [UInt32]) { words = []; bits.forEach { set($0) } }
    public init(words: [UInt32]) { self.words = words }
    public mutating func set(_ bit: UInt32) {
        let i = Int(bit / 32)
        while words.count <= i { words.append(0) }
        words[i] |= 1 << (bit % 32)
    }
    public func contains(_ bit: UInt32) -> Bool {
        let i = Int(bit / 32)
        return i < words.count && words[i] & (1 << (bit % 32)) != 0
    }
}

public enum Link {
    public static let magic: UInt32 = 0x51444552   // "REDQ" little-endian
    public static let major: UInt32 = 2
    public static let minor: UInt32 = 2
    public static let ticketPubkeyBytes = 162
    public static let ticketBytes = 128
    public static let maxPasswordLength = 60
}

public enum LinkError: UInt32, Sendable {
    case ok = 0, error, invalidMagic, invalidData, versionMismatch, needSecured
    case needUnsecured, permissionDenied, badConnectionID, channelNotAvailable
}
