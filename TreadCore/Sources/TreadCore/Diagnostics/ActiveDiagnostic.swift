import Foundation

public struct DiagnosticStep: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let ok: Bool
    public let detail: String

    public init(id: Int, title: String, ok: Bool, detail: String) {
        self.id = id
        self.title = title
        self.ok = ok
        self.detail = detail
    }
}

public enum DiagnosticRunState: Equatable, Sendable {
    case idle
    case running(String)
    case finished(success: Bool)
}

/// Diagnostic actif : toujours lancé explicitement, hors du tapis, jamais pendant une séance.
public protocol ActiveDiagnostic: AnyObject {
    var title: String { get }
    var state: DiagnosticRunState { get }
    var steps: [DiagnosticStep] { get }
    func begin() -> Result<Void, ControllerError>
    func tick()
    func abort()
}
