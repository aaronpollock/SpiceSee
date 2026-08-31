import Foundation
import Testing
import SpiceCore
@testable import SpiceSee

/// The proxy's trip through the app layer: file → saved row → connect target. The engine-side
/// trip (config → transport → CONNECT) is covered in SpiceKitTests.
struct ProxyPlumbingTests {
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
