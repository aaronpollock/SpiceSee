import SwiftUI

// MARK: - Dimensions not covered by Theme.Metric

private let connectingCropSize = CGSize(width: 528, height: 210)
private let connectingHeaderHeight: CGFloat = 52
private let connectingSpinnerSize: CGFloat = 13
private let connectingContentPaddingH: CGFloat = 18
private let connectingContentPaddingV: CGFloat = 16
private let connectingRowGap: CGFloat = 4
private let connectingStepIconSize: CGFloat = 11
private let progressBarHeight: CGFloat = 4

private let detailLabelWidth: CGFloat = 76

private let migrationLabelWidth: CGFloat = 56
private let migrationPortWidth: CGFloat = 64
private let migrationFieldHeight: CGFloat = 22
private let migrationFieldRadius: CGFloat = 6
private let migrationFieldFont: CGFloat = 12

// MARK: - Connecting progress (inline, never a modal)

struct ConnectingProgressView: View {
    let vmName: String
    let endpoint: String
    let usesTLS: Bool
    let completed: Set<ConnectStep>
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: connectingCropSize.width, height: connectingCropSize.height)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.chiliRed)
                .frame(width: connectingSpinnerSize, height: connectingSpinnerSize)
            Text(vmName)
                .font(.system(size: 13, weight: .semibold))
            Text("Connecting…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: connectingHeaderHeight)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Metric.Sheet.stackGap) {
            connectingLine
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(.chiliRed)
                .frame(height: progressBarHeight)
            VStack(alignment: .leading, spacing: connectingRowGap) {
                ForEach(ConnectStep.allCases) { step in
                    stepRow(step)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, connectingContentPaddingH)
        .padding(.vertical, connectingContentPaddingV)
    }

    private var connectingLine: some View {
        (Text("Connecting to ") + Text(endpoint).bold() + Text(usesTLS ? " over TLS" : ""))
            .font(.system(size: 13))
    }

    private var progressFraction: Double {
        Double(completed.count) / Double(ConnectStep.allCases.count)
    }

    private func stepRow(_ step: ConnectStep) -> some View {
        let isDone = completed.contains(step)
        return HStack(spacing: 7) {
            // A completed step is green, per the artboard. Green is a status colour, not a brand
            // tint — chili red stays reserved for the accent.
            Image(systemName: isDone ? "checkmark" : "circle")
                .font(.system(size: connectingStepIconSize, weight: isDone ? .semibold : .regular))
                .foregroundStyle(isDone ? Color.green : Color.secondary)
            Text(step.label)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
    }
}

// MARK: - Failure sheet

struct FailureSheet: View {
    let failure: ConnectFailure
    @Binding var password: String
    var onCancel: () -> Void
    var onRetry: () -> Void
    var onSecondary: () -> Void

    var body: some View {
        VStack(spacing: Metric.Sheet.stackGap) {
            AppIconGlyph(size: Metric.Sheet.iconSize, badgeSize: Metric.Sheet.badgeSize)
            Text(failure.title)
                .font(.system(size: Metric.Sheet.title, weight: .bold))
                .multilineTextAlignment(.center)
            Text(failure.message)
                .font(.system(size: Metric.Sheet.message))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            technicalDetail
            buttons
        }
        .padding(.horizontal, Metric.Sheet.insetH)
        .padding(.vertical, Metric.Sheet.insetV)
        .frame(width: Metric.Sheet.failureWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var technicalDetail: some View {
        if case let .hostSubjectMismatch(expected, presented, host) = failure {
            VStack(alignment: .leading, spacing: 4) {
                detailRow(label: "expected", value: expected, tinted: false)
                detailRow(label: "presented", value: presented, tinted: true)
                detailRow(label: "host", value: host, tinted: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metric.Sheet.detailRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
        }
    }

    private func detailRow(label: String, value: String, tinted: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: detailLabelWidth, alignment: .leading)
            Text(value)
                .foregroundStyle(tinted ? Color.chiliRed : Color.primary)
                // A real Proxmox subject is far wider than the sheet, and the element that differs
                // is not always last — truncating it would defeat the row's only purpose.
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Font.mono(Metric.Sheet.mono))
    }

    @ViewBuilder
    private var buttons: some View {
        switch failure {
        case .hostSubjectMismatch:
            HStack(spacing: 8) {
                Button("Download a fresh .vv from the console", action: onSecondary)
                    .buttonStyle(.plain)
                    .font(.system(size: Metric.Sheet.message))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                retryButton
            }
        case .refused:
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Edit Connection…", action: onSecondary)
                    .buttonStyle(.bordered)
                retryButton
            }
        case .passwordRejected:
            VStack(alignment: .leading, spacing: Metric.Sheet.stackGap) {
                HStack(spacing: 8) {
                    Text("Password:")
                        .font(.system(size: Metric.Sheet.message))
                        .foregroundStyle(.secondary)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.chiliRed, lineWidth: 1)
                        )
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                    retryButton
                }
            }
        case .other:
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                retryButton
            }
        }
    }

    private var retryButton: some View {
        Button("Retry", action: onRetry)
            .buttonStyle(.borderedProminent)
            .tint(.chiliRed)
            .keyboardShortcut(.defaultAction)
    }
}

/// The app-icon concept — a dark screen with a red chili on it — with an optional warning badge.
private struct AppIconGlyph: View {
    var size: CGFloat
    var badgeSize: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // The real app icon, so this never drifts from Assets.xcassets/AppIcon.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: badgeSize * 0.62))
                .frame(width: badgeSize, height: badgeSize)
                .offset(x: badgeSize * 0.12, y: badgeSize * 0.12)
        }
    }
}

// MARK: - Migration sheet

struct MigrationSheet: View {
    let offer: MigrationOffer
    /// Prefilled from the MAIN_MIGRATE_SWITCH_HOST message, but editable — the cluster's advertised
    /// address is not always the one reachable from the client's network.
    @Binding var host: String
    @Binding var port: String
    @Binding var reconnectAutomatically: Bool
    var onCancel: () -> Void
    var onReconnect: () -> Void

    var body: some View {
        VStack(spacing: Metric.Sheet.stackGap) {
            Text("“\(offer.vmName)” moved to another host")
                .font(.system(size: Metric.Sheet.title, weight: .bold))
                .multilineTextAlignment(.center)
            Text("The cluster migrated this VM while it was running. Reconnect to keep using the console — the guest keeps running either way.")
                .font(.system(size: Metric.Sheet.message))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                newHostRow
                Toggle("Reconnect automatically next time", isOn: $reconnectAutomatically)
                    .toggleStyle(.checkbox)
                    .font(.system(size: Metric.Sheet.message))
                    .tint(.chiliRed)
                    .padding(.leading, migrationLabelWidth + 8)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Reconnect", action: onReconnect)
                    .buttonStyle(.borderedProminent)
                    .tint(.chiliRed)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Metric.Sheet.insetH)
        .padding(.vertical, Metric.Sheet.insetV)
        .frame(width: Metric.Sheet.alertWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var newHostRow: some View {
        HStack(spacing: 8) {
            Text("New host:")
                .font(.system(size: Metric.Sheet.message))
                .foregroundStyle(.secondary)
                .frame(width: migrationLabelWidth, alignment: .trailing)
            migrationField($host)
                .frame(maxWidth: .infinity)
            migrationField($port)
                .frame(width: migrationPortWidth)
        }
    }

    private func migrationField(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: migrationFieldFont))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: migrationFieldHeight)
            .background(
                RoundedRectangle(cornerRadius: migrationFieldRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: migrationFieldRadius, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
            )
    }
}

// MARK: - Previews

#Preview("Connecting progress") {
    ConnectingProgressView(
        vmName: "win11-desk",
        endpoint: "192.168.1.20:5901",
        usesTLS: true,
        completed: [.tls, .ticket],
        onCancel: {}
    )
}

#Preview("Cert mismatch · light") {
    FailureSheet(
        failure: .hostSubjectMismatch(
            expected: "CN=pve1,O=PVE Cluster Manager CA",
            presented: "CN=pve3,O=PVE Cluster Manager CA",
            host: "192.168.1.20:5901"
        ),
        password: .constant(""),
        onCancel: {},
        onRetry: {},
        onSecondary: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Connection refused · light") {
    FailureSheet(
        failure: .refused(endpoint: "10.0.0.4:5900"),
        password: .constant(""),
        onCancel: {},
        onRetry: {},
        onSecondary: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Wrong password · dark") {
    FailureSheet(
        failure: .passwordRejected,
        password: .constant(""),
        onCancel: {},
        onRetry: {},
        onSecondary: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("VM migrated") {
    MigrationSheet(
        offer: MigrationOffer(vmName: "win11-desk", newHost: "pve3.lan", newPort: 5904),
        host: .constant("pve3.lan"),
        port: .constant("5904"),
        reconnectAutomatically: .constant(false),
        onCancel: {},
        onReconnect: {}
    )
}
