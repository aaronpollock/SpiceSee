import SwiftUI
import AppKit

/// A third-party component listed in the Acknowledgements window.
private struct AcknowledgementComponent: Identifiable {
    let id: String
    let name: String
    let spdx: String
    let title: String
    let summary: String
    let licenseFileName: String
    let showsFrameworkCallout: Bool

    static let all: [AcknowledgementComponent] = [
        AcknowledgementComponent(
            id: "spice-common",
            name: "spice-common codecs",
            spdx: "LGPL-2.1-or-later",
            title: "QUIC, LZ and GLZ decoders",
            summary: "From spice-common / spice-gtk, used decode-only. Licensed under the GNU Lesser General Public License, version 2.1 or later.",
            licenseFileName: "LGPL-2.1",
            showsFrameworkCallout: true
        ),
        AcknowledgementComponent(
            id: "spice-protocol",
            name: "spice-protocol",
            spdx: "BSD-3-Clause",
            title: "spice-protocol",
            summary: "Wire format headers defining SPICE messages and drawing primitives. Used unmodified — the format is unencumbered.",
            licenseFileName: "BSD-3-Clause",
            showsFrameworkCallout: false
        ),
        AcknowledgementComponent(
            id: "libopus",
            name: "libopus",
            spdx: "BSD-3-Clause",
            title: "libopus",
            summary: "Audio codec used to decode SPICE audio streams, linked as a static library.",
            licenseFileName: "BSD-3-Clause",
            showsFrameworkCallout: false
        ),
        AcknowledgementComponent(
            id: "sparkle",
            name: "Sparkle",
            spdx: "MIT",
            title: "Sparkle",
            summary: "Framework used to check for, download, and install app updates.",
            licenseFileName: "MIT",
            showsFrameworkCallout: false
        ),
    ]
}

// TODO(release): final source URL
private let acknowledgementsSourceURL = URL(string: "https://github.com/spicesee/spicesee")!

private let placeholderLicenseText = "PLACEHOLDER — populated by the orchestrator"

private func loadLicenseText(fileName: String) -> String? {
    // The build flattens Sources/SpiceSee/Licenses into Resources/, so the subdirectory lookup
    // misses; fall back to the bundle root rather than shipping without the licence text.
    let url = Bundle.main.url(forResource: fileName, withExtension: "txt", subdirectory: "Licenses")
        ?? Bundle.main.url(forResource: fileName, withExtension: "txt")
    guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
        return nil
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines) == placeholderLicenseText {
        return nil
    }
    return text
}

struct AcknowledgementsView: View {
    @State private var selectedID: String
    @Environment(\.openURL) private var openURL

    init(initialSelection: String = AcknowledgementComponent.all[0].id) {
        _selectedID = State(initialValue: initialSelection)
    }

    private var selected: AcknowledgementComponent {
        AcknowledgementComponent.all.first { $0.id == selectedID } ?? AcknowledgementComponent.all[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                componentList
                Divider()
                detailPane
            }
            Divider()
            footer
        }
        .frame(
            minWidth: Metric.Window.acknowledgements.width,
            minHeight: Metric.Window.acknowledgements.height
        )
    }

    // MARK: - Component list

    private var componentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AcknowledgementComponent.all) { component in
                componentRow(component)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Metric.Acknowledgements.listWidth)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func componentRow(_ component: AcknowledgementComponent) -> some View {
        let isSelected = component.id == selectedID
        return Button {
            selectedID = component.id
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(component.name)
                    .font(.system(size: Metric.Acknowledgements.componentName, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Color.primary)
                Text(component.spdx)
                    .font(.system(size: Metric.Acknowledgements.spdx))
                    .foregroundStyle(
                        isSelected
                            ? .white.opacity(Metric.Sidebar.selectedSecondaryOpacity)
                            : Color.secondary
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.chiliRed : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // Without this only the text is clickable; the whitespace beside it must select too.
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(selected.title)
                    .font(.system(size: Metric.Acknowledgements.title, weight: .semibold))
                Text(selected.summary)
                    .font(.system(size: Metric.Acknowledgements.summary))
                    .foregroundStyle(.secondary)

                if selected.showsFrameworkCallout {
                    frameworkCallout
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Divider()
            }

            licensePane
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var frameworkCallout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You can replace this framework")
                .font(.system(size: Metric.Acknowledgements.summary, weight: .semibold))
            (
                Text("These decoders ship as ")
                    + Text("CSpiceCodec.framework").font(Font.mono(Metric.Acknowledgements.summary))
                    + Text(" inside the app bundle, and library validation is disabled so you can substitute your own build. Source and the written offer are linked below.")
            )
            .font(.system(size: Metric.Acknowledgements.summary))
            .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Button("Get the source…") {
                    openURL(acknowledgementsSourceURL)
                }
                Button("Show in Finder") {
                    showFrameworkInFinder()
                }
            }
            .buttonStyle(.link)
            .font(.system(size: Metric.Acknowledgements.summary))
            .padding(.top, 2)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var licensePane: some View {
        ScrollView {
            if let text = loadLicenseText(fileName: selected.licenseFileName) {
                Text(text)
                    .font(Font.mono(Metric.Acknowledgements.licenseMono))
                    .lineSpacing(Metric.Acknowledgements.licenseMono * (Metric.Acknowledgements.licenseLineSpacing - 1))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("License text unavailable.")
                    .font(.system(size: Metric.Acknowledgements.summary))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(AcknowledgementComponent.all.count) components")
                .font(.system(size: Metric.Acknowledgements.summary))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy License Text") {
                copyLicenseText()
            }
            .disabled(loadLicenseText(fileName: selected.licenseFileName) == nil)
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
    }

    // MARK: - Actions

    private func copyLicenseText() {
        guard let text = loadLicenseText(fileName: selected.licenseFileName) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func showFrameworkInFinder() {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("CSpiceCodec.framework") else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

#Preview("LGPL component") {
    AcknowledgementsView()
}

#Preview("BSD component") {
    AcknowledgementsView(initialSelection: "spice-protocol")
}
