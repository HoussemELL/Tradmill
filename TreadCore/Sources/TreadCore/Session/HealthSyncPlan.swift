import Foundation

/// Réglages Apple Santé choisis par l'utilisateur.
public struct HealthSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Écrire la distance mesurée par le tapis (sinon seule la durée et la FC sont enregistrées).
    public var writeDistance = true
    /// Écrire l'énergie annoncée par le tapis (souvent approximative : désactivé par défaut).
    public var writeTreadmillEnergy = false
    public init() {}
}

/// Qui enregistre l'exercice dans Santé, et quoi. Une seule source par séance.
///
/// Règles :
/// - Si un exercice Apple Watch a tourné pendant la séance, la Watch est propriétaire :
///   elle enregistre l'exercice (FC, énergie, pas qu'elle mesure). L'iPhone n'écrit rien.
/// - Sinon l'iPhone enregistre un HKWorkout (marche/course en intérieur) avec :
///   FC uniquement si elle vient d'une ceinture BLE ou du tapis (pas déjà dans Santé),
///   distance du tapis (option), énergie du tapis (option).
/// - Les pas ne sont jamais écrits : l'iPhone et la Watch les enregistrent déjà d'eux-mêmes.
/// - Une séance déjà enregistrée (statut `saved`) n'est jamais réécrite.
public struct HealthSyncPlan: Equatable, Sendable {
    public enum Owner: Equatable, Sendable { case none, phone, watch }

    public var owner: Owner
    public var writeHeartRate: Bool
    public var writeDistance: Bool
    public var writeEnergy: Bool
    public let writeSteps = false
    public var reason: String

    public static func make(record: SessionRecord, settings: HealthSettings, watchWorkoutUsed: Bool) -> HealthSyncPlan {
        if case .saved = record.healthStatus {
            return HealthSyncPlan(owner: .none, writeHeartRate: false, writeDistance: false, writeEnergy: false,
                                  reason: "déjà enregistrée")
        }
        if watchWorkoutUsed || record.healthStatus == .ownedByWatch {
            return HealthSyncPlan(owner: .watch, writeHeartRate: false, writeDistance: false, writeEnergy: false,
                                  reason: "exercice enregistré par l'Apple Watch")
        }
        guard settings.enabled else {
            return HealthSyncPlan(owner: .none, writeHeartRate: false, writeDistance: false, writeEnergy: false,
                                  reason: "Santé désactivé")
        }
        guard record.activeSeconds >= 60 else {
            return HealthSyncPlan(owner: .none, writeHeartRate: false, writeDistance: false, writeEnergy: false,
                                  reason: "séance trop courte (< 1 min)")
        }
        let hrFromExternal = record.samples.contains { $0.hr != nil && ($0.hrSource == .bleSensor || $0.hrSource == .treadmill) }
        return HealthSyncPlan(owner: .phone,
                              writeHeartRate: hrFromExternal,
                              writeDistance: settings.writeDistance && record.distanceSource == .treadmill && record.distanceMeters > 0,
                              writeEnergy: settings.writeTreadmillEnergy && (record.calories.treadmillKcal ?? 0) > 0,
                              reason: "exercice enregistré par l'iPhone")
    }
}
