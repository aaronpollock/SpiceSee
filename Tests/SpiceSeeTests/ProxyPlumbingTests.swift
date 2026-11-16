import Foundation
import Testing
import SpiceCore
@testable import SpiceSee

/// The proxy's trip through the app layer: file → saved row → connect target. The engine-side
/// trip (config → transport → CONNECT) is covered in SpiceKitTests.
struct ProxyPlumbingTests {
    @Test(arguments: [false, true]) @MainActor
    func certificateFailureGuidanceMatchesTheConnection(hasEmbeddedCA: Bool) {
        let target = ConnectionTarget(host: "spice.test", tlsPort: 61000,
                                      caPEM: hasEmbeddedCA ? "embedded CA" : nil)
        for kind: TLSFailure in [.untrusted("server certificate is expired."), .badCertificate("invalid CA.")] {
            let failure = SpiceKitBackend.failure(for: SpiceError(.tls(kind)), target: target)
            #expect(failure.title == "The server's certificate is not trusted")
            #expect(!failure.message.contains(".."))
            #expect(failure.message.contains("download a fresh console file") == hasEmbeddedCA)
            if !hasEmbeddedCA { #expect(failure.message.contains("configured host name")) }
        }
        let expired = SpiceKitBackend.failure(for: SpiceError(.tls(.untrusted("server certificate is expired."))),
                                              target: target)
        #expect(expired.message.contains("server certificate is expired."))
    }

    @Test @MainActor func proxyFailureDoesNotClaimTheOpaqueHostIsUnreachable() {
        let token = "pvespiceproxy:aa:1:n:61001::bb"
        let target = ConnectionTarget(host: token, tlsPort: 61001, proxy: "p.example:3128")
        let failure = SpiceKitBackend.failure(for: SpiceError(.connect), target: target)
        #expect(failure.title == "Could not connect through the SPICE proxy")
        #expect(failure.message.contains("p.example:3128"))
        #expect(failure.message.contains("guest’s SPICE server"))
        #expect(failure.message.contains("TLS settings"))
        #expect(failure.message.contains("ticket may have expired"))
        #expect(!failure.message.contains(token))
        #expect(SpiceKitBackend.failure(for: SpiceError(.connect), target: ConnectionTarget(host: "h", port: 5900))
                == .refused(endpoint: "h:5900"))
        #expect(SpiceKitBackend.failure(for: SpiceError(.auth), target: target) == .passwordRejected)
        #expect(SpiceKitBackend.failure(for: SpiceError(.tls(.subjectMismatch(expected: "expected", presented: "actual"))),
                                        target: target)
                == .hostSubjectMismatch(expected: "expected", presented: "actual", host: target.endpoint))
        let certificate = SpiceKitBackend.failure(for: SpiceError(.tls(.untrusted("expired"))), target: target)
        #expect(certificate.message.contains("download a fresh console file"))
    }

    @Test @MainActor func reimportRefreshesProxyAndSingleUseState() throws {
        let old = SavedConnection(name: "My console", host: "pvespiceproxy:aa:1:n:61001::bb",
                                  port: 0, tlsPort: 61001)
        let store = ConnectionStore(connections: [old])
        let vv = try VVFile.parse("[virt-viewer]\nhost=\(old.host)\ntls-port=61001\nproxy=http://p.example:3128")
        let refreshed = store.addImported(SavedConnection(vv: vv, name: "Downloaded name"))
        #expect(refreshed.id == old.id)
        #expect(refreshed.name == old.name)
        #expect(refreshed.proxy == "p.example:3128")
        #expect(refreshed.isSingleUse == true)
        #expect(store.connections.count == 1)

        var direct = vv
        direct.proxy = nil
        let reusable = store.addImported(SavedConnection(vv: direct, name: "Downloaded name"))
        #expect(reusable.proxy == nil)
        #expect(reusable.isSingleUse == false)
    }

    @Test func savedConnectionCarriesTheVVProxy() throws {
        let vv = try VVFile.parse(
            "[virt-viewer]\nhost=pvespiceproxy:aa:1:n::bb\ntls-port=61000\nproxy=http://p.example:3128")
        let c = SavedConnection(vv: vv, name: "x")
        #expect(c.proxy == "p.example:3128")
        #expect(try HTTPConnectProxy(parsing: #require(c.proxy))
                == HTTPConnectProxy(host: "p.example", port: 3128))
    }

    /// Rows saved before the field existed must keep decoding — the reason every added field is
    /// optional (see `nameIsCustom`).
    @Test func aStoreWrittenBeforeProxySupportStillDecodes() throws {
        let legacy = """
        [{"host":"192.168.50.6","id":"50D16CDB-2B01-4330-8228-35F356C7BC23",
          "savePasswordInKeychain":false,"name":"pve","port":5930,
          "advanced":{"hiDPI":false,"commandMapsTo":"super","optionMapsTo":"alt",
                      "releaseChord":{"modifiers":["control","option"]}},
          "agentWasPresent":false}]
        """
        let rows = try JSONDecoder().decode([SavedConnection].self, from: Data(legacy.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].proxy == nil)
    }
}
