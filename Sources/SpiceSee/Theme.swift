import SwiftUI

/// The single tint token. Everything else in the app is a macOS semantic color.
extension Color {
    static let chiliRed = Color("ChiliRed")
}

/// Dimensions from the design, in logical points. Named so screens never hardcode a number twice.
enum Metric {
    enum Window {
        static let connectionManager = CGSize(width: 760, height: 520)
        static let preferences = CGSize(width: 580, height: 380)
        static let acknowledgements = CGSize(width: 620, height: 460)
        static let session = CGSize(width: 900, height: 600)
        static let titlebar: CGFloat = 52
    }

    enum Sidebar {
        static let width: CGFloat = 232
        static let minWidth: CGFloat = 200
        static let maxWidth: CGFloat = 280
        static let rowSize = CGSize(width: 216, height: 40)
        static let rowInsetV: CGFloat = 6
        static let rowInsetH: CGFloat = 8
        static let rowRadius: CGFloat = 6
        static let rowTitle: CGFloat = 13
        static let rowSubtitle: CGFloat = 11
        /// Secondary text in a selected row sits at 78% so it reads against the accent fill.
        static let selectedSecondaryOpacity: CGFloat = 0.78
    }

    enum Form {
        static let labelColumn: CGFloat = 78
        static let labelGap: CGFloat = 10
        static let rowRhythm: CGFloat = 12
        static let fieldHeight: CGFloat = 24
        static let fieldRadius: CGFloat = 6
        static let primaryButtonWidth: CGFloat = 28
    }

    enum Toolbar {
        static let height: CGFloat = 52
        static let itemSize = CGSize(width: 28, height: 22)
        static let itemRadius: CGFloat = 6
        static let itemGap: CGFloat = 6
        static let dividerHeight: CGFloat = 18
        static let glyph: CGFloat = 15
        /// Breathing room between the toolbar content and the edges of the bar it sits in.
        static let contentInsetH: CGFloat = 4
        static let contentInsetV: CGFloat = 2
        /// At or below this window width the secondary items collapse into an overflow menu.
        static let collapseWidth: CGFloat = 700
    }

    enum HUD {
        static let capsuleHeight: CGFloat = 34
        static let text: CGFloat = 11.5
        static let bottomInset: CGFloat = 44
        static let stroke: CGFloat = 0.5
        static let visibleDuration: Duration = .seconds(2.0)
        static let fadeDuration: Duration = .milliseconds(250)
        static let cueHeight: CGFloat = 22
        static let cueInset: CGFloat = 14
        static let cueOpacity: CGFloat = 0.6
    }

    enum Sheet {
        static let failureWidth: CGFloat = 420
        static let alertWidth: CGFloat = 380
        static let insetV: CGFloat = 20
        static let insetH: CGFloat = 22
        static let stackGap: CGFloat = 10
        static let iconSize: CGFloat = 52
        static let badgeSize: CGFloat = 24
        static let title: CGFloat = 13
        static let message: CGFloat = 11
        static let detailRadius: CGFloat = 7
        static let mono: CGFloat = 10.5
    }

    enum Settings {
        static let tabWidth: CGFloat = 64
        static let tabSymbol: CGFloat = 17
        static let tabLabel: CGFloat = 10
        static let labelColumn: CGFloat = 140
        static let rowRhythm: CGFloat = 14
        static let generalHeight: CGFloat = 340
        static let keyboardHeight: CGFloat = 340
        static let updatesHeight: CGFloat = 230
        static let keycapSize = CGSize(width: 34, height: 26)
        static let keycapGap: CGFloat = 5
    }

    enum Acknowledgements {
        static let listWidth: CGFloat = 200
        static let componentName: CGFloat = 12
        static let spdx: CGFloat = 10
        static let title: CGFloat = 15
        static let summary: CGFloat = 11
        static let licenseMono: CGFloat = 10.5
        static let licenseLineSpacing: CGFloat = 1.6
    }

    enum EmptyState {
        static let glyph: CGFloat = 56
        static let gap: CGFloat = 14
        static let title: CGFloat = 17
        static let body: CGFloat = 13
        static let maxBodyWidth: CGFloat = 340
        static let illustration = CGSize(width: 96, height: 64)
    }
}

extension Font {
    /// SF Mono for the technical detail boxes and license text.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
