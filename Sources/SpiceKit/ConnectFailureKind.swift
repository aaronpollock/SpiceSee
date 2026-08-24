import SpiceCore
import SpiceWire

/// Which failure the user is shown. Deciding *this* is engine knowledge, so it lives here and is
/// tested; the wording that goes with it is the app's, and the raw `SpiceError` never reaches it —
/// the design is explicit that the SPICE error code goes to the log, not to the sheet.
public enum ConnectFailureKind: Sendable, Equatable {
    case passwordRejected
    case refused
    case hostSubjectMismatch(expected: String, presented: String)
    case other

    public static func of(_ error: SpiceError) -> ConnectFailureKind {
        switch error.kind {
        case .auth, .link(.permissionDenied): .passwordRejected
        case .connect: .refused
        case let .tls(.subjectMismatch(expected, presented)): .hostSubjectMismatch(expected: expected, presented: presented)
        default: .other
        }
    }
}
