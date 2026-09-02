import Foundation
import Testing
@testable import SpiceSee

/// The acknowledgements window is the LGPL written offer and the credits; it must describe the
/// bundle that ships, not the one that was planned.
@Suite struct AcknowledgementsTests {
    /// `Bundle(for:)` needs a class; the test bundle carries the licence files as resources.
    private final class Marker {}

    /// M6 decodes Opus through AudioToolbox; libopus is only the fixture generator and never ships.
    @Test func libopusIsNotCredited() {
        #expect(!AcknowledgementComponent.all.contains { $0.id == "libopus" })
        #expect(AcknowledgementComponent.all.contains { $0.id == "sparkle" })
    }

    @Test func everyLicenceFileShipsAndIsNotATemplate() {
        let bundle = Bundle(for: Marker.self)
        for component in AcknowledgementComponent.all {
            let text = loadLicenseText(fileName: component.licenseFileName, in: bundle)
            #expect(text != nil, "\(component.licenseFileName).txt missing from the bundle")
            #expect(text?.contains("<year>") == false, "\(component.licenseFileName).txt is still the template")
            #expect(text?.contains("PLACEHOLDER") == false)
        }
    }

    @Test func theSourceLinkIsTheRealRepository() {
        #expect(acknowledgementsSourceURL.absoluteString == "https://github.com/aaronpollock/SpiceSee")
    }
}
