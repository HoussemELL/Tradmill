import Foundation

/// Programmes prédéfinis. Toutes les vitesses en km/h. Ils restent modifiables (sauf Cardio
/// Baseline, verrouillé pour garder des tests comparables, déverrouillable explicitement).
public enum ProgramTemplateID {
    public static let cardioBaseline = "foulee.cardio-baseline"
    public static let zone2Endurance = "foulee.zone2-endurance"
    public static let intervalRun911 = "foulee.interval-run-9-11"
    public static let hiitRun11 = "foulee.hiit-run-11"
    public static let inclineWalk = "foulee.incline-walk"
    public static let postMealWalk = "foulee.post-meal-walk"
    public static let zone2Auto = "foulee.zone2-auto"
}

public extension WorkoutProgram {
    /// Programmes installés au premier lancement, puis ajoutés s'ils manquent (par `templateID`).
    static var templates: [WorkoutProgram] {
        [cardioBaseline, zone2Endurance, intervalRun911, hiitRun11, inclineWalk, postMealWalk, zone2Auto]
    }

    static func template(id: String) -> WorkoutProgram? {
        templates.first { $0.templateID == id }
    }

    private static func min(_ m: Int) -> Int { m * 60 }

    static var cardioBaseline: WorkoutProgram {
        WorkoutProgram(name: "Cardio Baseline", notes: """
            Test de référence (30 min) : comparer la FC à effort identique au fil des semaines. \
            Gardez-le strictement identique : toute modification de vitesse pendant la séance la rend non comparable.
            """, items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(5), speedKmh: 4.0, inclinePercent: 0)),
                .phase(.init(name: "Allure de référence", kind: .steady, durationSeconds: min(20), speedKmh: 6.0, inclinePercent: 0)),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 3.8, inclinePercent: 0)),
            ], templateID: ProgramTemplateID.cardioBaseline, locked: true)
    }

    static var zone2Endurance: WorkoutProgram {
        WorkoutProgram(name: "Zone 2 Endurance", notes: """
            Endurance aérobie (35 min). À 5,5 km/h vous êtes généralement en haut de la zone 1, parfois au début \
            de la zone 2 : les 6 km/h sont un réglage de départ à ajuster selon votre FC (boutons +/−), pas une \
            garantie d'être en zone 2. La FC ne pilote pas le tapis dans ce programme.
            """, items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(5), speedKmh: 4.0, inclinePercent: 0, targetZone: 1)),
                .phase(.init(name: "Montée en allure", kind: .steady, durationSeconds: min(5), speedKmh: 5.5, inclinePercent: 0, targetZone: 1)),
                .phase(.init(name: "Zone 2", kind: .steady, durationSeconds: min(20), speedKmh: 6.0, inclinePercent: 1, targetZone: 2)),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 3.8, inclinePercent: 0, targetZone: 1)),
            ], templateID: ProgramTemplateID.zone2Endurance)
    }

    static var intervalRun911: WorkoutProgram {
        WorkoutProgram(name: "Interval Run 9/11", notes: "Fractionné basé sur votre séance réelle (30 min). Inclinaison 0 %.", items: [
            .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(3), speedKmh: 4.0)),
            .phase(.init(name: "Marche rapide", kind: .warmup, durationSeconds: min(3), speedKmh: 5.0)),
            .phase(.init(name: "Footing", kind: .steady, durationSeconds: min(2), speedKmh: 6.0)),
            .block(.init(name: "Intervalles 9 km/h", repeatCount: 6, phases: [
                .init(name: "Course 9", kind: .work, durationSeconds: min(1), speedKmh: 9.0, targetZone: 4),
                .init(name: "Récupération", kind: .recovery, durationSeconds: min(1), speedKmh: 5.0),
            ])),
            .phase(.init(name: "Course 11", kind: .work, durationSeconds: min(2), speedKmh: 11.0, targetZone: 5)),
            .phase(.init(name: "Marche", kind: .recovery, durationSeconds: min(3), speedKmh: 4.0)),
            .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 3.8)),
        ], templateID: ProgramTemplateID.intervalRun911)
    }

    static var hiitRun11: WorkoutProgram {
        WorkoutProgram(name: "HIIT Run 11", notes: "Fractionné avancé (35 min), inclinaison 0 %. À réserver à une progression ultérieure.", items: [
            .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(4), speedKmh: 4.0)),
            .phase(.init(name: "Marche rapide", kind: .warmup, durationSeconds: min(4), speedKmh: 5.5)),
            .phase(.init(name: "Footing", kind: .steady, durationSeconds: min(2), speedKmh: 7.0)),
            .block(.init(name: "Intervalles 11 km/h", repeatCount: 4, phases: [
                .init(name: "Course 11", kind: .work, durationSeconds: min(2), speedKmh: 11.0, targetZone: 5),
                .init(name: "Récupération", kind: .recovery, durationSeconds: min(3), speedKmh: 4.5),
            ])),
            .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 3.8)),
        ], templateID: ProgramTemplateID.hiitRun11)
    }

    static var inclineWalk: WorkoutProgram {
        WorkoutProgram(name: "Incline Walk", notes: "Marche cardiovasculaire inclinée (30 min).", items: [
            .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(5), speedKmh: 4.0, inclinePercent: 0)),
            .phase(.init(name: "Marche 1 %", kind: .steady, durationSeconds: min(5), speedKmh: 5.5, inclinePercent: 1)),
            .phase(.init(name: "Marche 2 %", kind: .work, durationSeconds: min(15), speedKmh: 5.5, inclinePercent: 2)),
            .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 3.8, inclinePercent: 0)),
        ], templateID: ProgramTemplateID.inclineWalk)
    }

    static var postMealWalk: WorkoutProgram {
        WorkoutProgram(name: "Post-Meal Walk", notes: "Marche douce après les repas (15 min), inclinaison 0 %.", items: [
            .phase(.init(name: "Mise en route", kind: .warmup, durationSeconds: min(2), speedKmh: 3.5)),
            .phase(.init(name: "Marche", kind: .steady, durationSeconds: min(10), speedKmh: 4.5)),
            .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(3), speedKmh: 3.5)),
        ], templateID: ProgramTemplateID.postMealWalk)
    }

    static var zone2Auto: WorkoutProgram {
        WorkoutProgram(name: "Zone 2 Auto", notes: """
            35 min pour maximiser le temps en zone 2 : la vitesse suit votre FC filtrée (≈ 18 s), par paliers \
            de 0,2 km/h, au plus une accélération par minute, ralentissement plus rapide si la FC reste trop haute. \
            Limites automatiques 4–7 km/h. Sans FC : plus d'accélération et retour progressif à 4,5 km/h. \
            Vos réglages manuels sont prioritaires.
            """, items: [
                .phase(.init(name: "Échauffement progressif", kind: .warmup, durationSeconds: min(5), speedKmh: 4.0,
                             inclinePercent: 0, targetZone: 1, endSpeedKmh: 5.5)),
                .phase(.init(name: "Zone 2 pilotée", kind: .steady, durationSeconds: min(25), speedKmh: 5.8,
                             inclinePercent: 0, targetZone: 2, autoSpeed: AutoSpeedSettings())),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 4.0,
                             inclinePercent: 0, targetZone: 1, endSpeedKmh: 3.5)),
            ], templateID: ProgramTemplateID.zone2Auto)
    }
}
