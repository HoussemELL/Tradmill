import Foundation

/// Problème détecté dans un programme. Rien n'est corrigé silencieusement :
/// toute erreur bloque le lancement jusqu'à correction par l'utilisateur.
public struct ProgramIssue: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable { case error, warning }

    public var id: String { "\(phaseID?.uuidString ?? "-")-\(message)" }
    public var severity: Severity
    public var phaseID: UUID?
    public var phaseName: String?
    public var message: String
}

public enum ProgramValidator {
    public static let maxPhaseSeconds = 4 * 3600
    public static let maxRepeat = 99
    public static let maxScheduledPhases = 500

    /// Validation structurelle (indépendante du tapis).
    public static func validateStructure(_ program: WorkoutProgram) -> [ProgramIssue] {
        var issues: [ProgramIssue] = []
        if program.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(severity: .error, phaseID: nil, phaseName: nil, message: "Le programme n'a pas de nom"))
        }
        if program.items.isEmpty {
            issues.append(.init(severity: .error, phaseID: nil, phaseName: nil, message: "Le programme ne contient aucune phase"))
        }
        func check(_ p: ProgramPhase) {
            if p.durationSeconds <= 0 || p.durationSeconds > maxPhaseSeconds {
                issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                    message: "Durée invalide (\(p.durationSeconds) s)"))
            }
            if !p.speedKmh.isFinite || p.speedKmh <= 0 || p.speedKmh > 30 {
                issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                    message: "Vitesse invalide (\(p.speedKmh) km/h)"))
            }
            if !p.inclinePercent.isFinite || p.inclinePercent < -20 || p.inclinePercent > 40 {
                issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                    message: "Inclinaison invalide (\(p.inclinePercent) %)"))
            }
            if let z = p.targetZone, !(1...5).contains(z) {
                issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                    message: "Zone cible invalide (\(z))"))
            }
            if let e = p.endSpeedKmh, !e.isFinite || e <= 0 || e > 30 {
                issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                    message: "Vitesse de fin invalide (\(e) km/h)"))
            }
            if let a = p.autoSpeed {
                if let m = a.validationError() {
                    issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name, message: m))
                } else if p.speedKmh < a.minKmh - 0.001 || p.speedKmh > a.maxKmh + 0.001 {
                    issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                        message: String(format: "Vitesse de départ %.1f hors des limites automatiques (%.1f–%.1f)",
                                                        p.speedKmh, a.minKmh, a.maxKmh)))
                }
                if p.isRamp {
                    issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                        message: "Une phase pilotée par la FC ne peut pas être progressive"))
                }
            }
        }
        for item in program.items {
            switch item {
            case let .phase(p): check(p)
            case let .block(b):
                if b.repeatCount < 1 || b.repeatCount > maxRepeat {
                    issues.append(.init(severity: .error, phaseID: b.id, phaseName: b.name,
                                        message: "Nombre de répétitions invalide (\(b.repeatCount))"))
                }
                if b.phases.isEmpty {
                    issues.append(.init(severity: .error, phaseID: b.id, phaseName: b.name, message: "Bloc vide"))
                }
                b.phases.forEach(check)
            }
        }
        if program.schedule.count > maxScheduledPhases {
            issues.append(.init(severity: .error, phaseID: nil, phaseName: nil,
                                message: "Trop de phases une fois les blocs déroulés (\(program.schedule.count))"))
        }
        return issues
    }

    /// Compatibilité avec les capacités réelles du tapis.
    public static func validate(_ program: WorkoutProgram, against caps: TreadmillCapabilities) -> [ProgramIssue] {
        var issues = validateStructure(program)
        var seen = Set<UUID>()
        for sp in program.schedule where !seen.contains(sp.phase.id) {
            seen.insert(sp.phase.id)
            let p = sp.phase
            let s = caps.speed
            if p.speedKmh < s.minKmh - 0.001 {
                issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                    message: String(format: "Vitesse %.1f km/h inférieure au minimum du tapis (%.1f)", p.speedKmh, s.minKmh)))
            } else if p.speedKmh > s.maxKmh + 0.001 {
                issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                    message: String(format: "Vitesse %.1f km/h supérieure au maximum du tapis (%.1f)", p.speedKmh, s.maxKmh)))
            } else if !TreadmillCapabilities.isOnIncrement(p.speedKmh, min: s.minKmh, step: s.incrementKmh) {
                issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                    message: String(format: "Vitesse %.2f km/h hors incrément du tapis (pas %.2f)", p.speedKmh, s.incrementKmh)))
            }
            if let e = p.endSpeedKmh, p.isRamp {
                if e < s.minKmh - 0.001 || e > s.maxKmh + 0.001 {
                    issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                        message: String(format: "Vitesse de fin %.1f km/h hors plage du tapis (%.1f–%.1f)", e, s.minKmh, s.maxKmh)))
                } else if !TreadmillCapabilities.isOnIncrement(e, min: s.minKmh, step: s.incrementKmh) {
                    issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                        message: String(format: "Vitesse de fin %.2f km/h hors incrément du tapis (pas %.2f)", e, s.incrementKmh)))
                }
            }
            if let a = p.autoSpeed {
                if a.minKmh < s.minKmh - 0.001 || a.maxKmh > s.maxKmh + 0.001 {
                    issues.append(.init(severity: .warning, phaseID: p.id, phaseName: p.name,
                                        message: String(format: "Limites automatiques %.1f–%.1f ramenées à celles du tapis (%.1f–%.1f)",
                                                        a.minKmh, a.maxKmh, s.minKmh, s.maxKmh)))
                }
                if a.stepKmh < s.incrementKmh - 0.001 {
                    issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                        message: String(format: "Palier automatique %.2f inférieur à l'incrément du tapis (%.2f)", a.stepKmh, s.incrementKmh)))
                }
            }
            if let r = caps.inclination, caps.supportsInclinationControl {
                if p.inclinePercent < r.minPercent - 0.001 || p.inclinePercent > r.maxPercent + 0.001 {
                    issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                        message: String(format: "Inclinaison %.1f %% hors plage du tapis (%.0f–%.0f %%)", p.inclinePercent, r.minPercent, r.maxPercent)))
                } else if !TreadmillCapabilities.isOnIncrement(p.inclinePercent, min: r.minPercent, step: r.incrementPercent) {
                    issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                        message: String(format: "Inclinaison %.1f %% hors incrément du tapis (pas %.1f)", p.inclinePercent, r.incrementPercent)))
                }
            } else if abs(p.inclinePercent) > 0.001 {
                issues.append(.init(severity: .error, phaseID: p.id, phaseName: p.name,
                                    message: "Ce tapis ne permet pas de régler l'inclinaison"))
            }
        }
        return issues
    }
}
