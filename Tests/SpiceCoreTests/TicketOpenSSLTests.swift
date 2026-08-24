import Testing
import Foundation
@testable import SpiceCore

/// spice-server decrypts the ticket with OpenSSL's `RSA_private_decrypt(..., RSA_PKCS1_OAEP_PADDING)`.
/// `TicketTests` only proves Security.framework can read back its own ciphertext, so this pins the
/// cross-implementation half: what we send must be decryptable by OpenSSL.
private let openssl = ["/opt/homebrew/bin/openssl", "/usr/bin/openssl"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

@discardableResult
private func run(_ tool: String, _ args: [String]) throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw SpiceError(.auth, underlying: "\(tool) \(args.joined(separator: " ")) exited \(p.terminationStatus)") }
    return data
}

@Test(.enabled(if: openssl != nil))
func ticketDecryptsWithOpenSSL() throws {
    let tool = try #require(openssl)
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spicesee-ticket-\(getpid())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let priv = dir.appendingPathComponent("priv.pem").path
    let pub = dir.appendingPathComponent("pub.der").path
    let cipher = dir.appendingPathComponent("cipher.bin").path

    try run(tool, ["genrsa", "-out", priv, "1024"])
    try run(tool, ["rsa", "-in", priv, "-pubout", "-outform", "DER", "-out", pub])

    // The server sends exactly this: a 162-byte SubjectPublicKeyInfo for a 1024-bit key.
    let der = [UInt8](try Data(contentsOf: URL(fileURLWithPath: pub)))
    #expect(der.count == 162)

    let ticket = try Ticket.encrypt(password: "hunter2", publicKey: der)
    #expect(ticket.count == 128)
    try Data(ticket).write(to: URL(fileURLWithPath: cipher))

    let plain = try run(tool, ["pkeyutl", "-decrypt", "-inkey", priv,
                               "-pkeyopt", "rsa_padding_mode:oaep", "-in", cipher])
    #expect(plain == Data("hunter2".utf8) + [0])
}
