import Foundation

/// Programmes prédéfinis. Vitesses en km/h, inclinaisons en % (unité FTMS : Inclination,
/// résolution 0,1 %) ; **inclinaison minimale 1 %** dans toutes les phases.
/// Ils restent modifiables (sauf Cardio Baseline, verrouillé pour garder des tests comparables,
/// déverrouillable explicitement).
public enum ProgramTemplateID {
    public static let cardioBaseline = "foulee.cardio-baseline"
    public static let zone2Endurance = "foulee.zone2-endurance"
    public static let intervalRun911 = "foulee.interval-run-9-11"
    public static let hiitRun11 = "foulee.hiit-run-11"
    public static let inclineWalk = "foulee.incline-walk"
    public static let postMealWalk = "foulee.post-meal-walk"
    public static let zone2Auto = "foulee.zone2-auto"
    public static let footballEndurance1 = "foulee.football-endurance-1"
    public static let footballEndurance2 = "foulee.football-endurance-2"
    public static let footballEndurance3 = "foulee.football-endurance-3"
}

public extension WorkoutProgram {
    /// Révision de la bibliothèque. À chaque hausse, l'app met à jour les programmes prédéfinis
    /// déjà installés (même identifiant) et ajoute les nouveaux.
    /// 2 : inclinaison minimale 1 % partout, Football Endurance (3 niveaux), HIIT avancé.
    /// 3 : retrait des anciens programmes de la première version, s'ils n'ont pas été modifiés.
    /// 4 : tous les programmes prédéfinis verrouillés (comparables au fil des séances).
    /// 5 : Zone 2 Auto v3 — plafond 8,5 km/h, pilotage centré sur la zone (paliers selon l'écart,
    ///     tendance de la FC anticipée), départ à la vitesse apprise.
    static let templatesRevision = 5

    /// Programmes installés par la toute première version (avant les identifiants de modèle),
    /// remplacés par la bibliothèque actuelle. Retirés seulement s'ils sont restés intacts.
    static var legacyTemplates: [WorkoutProgram] {
        [
            WorkoutProgram(name: "Marche active 30 min", items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: 300, speedKmh: 3.5, inclinePercent: 0, targetZone: 1)),
                .phase(.init(name: "Marche", kind: .steady, durationSeconds: 600, speedKmh: 5.0, inclinePercent: 1, targetZone: 2)),
                .phase(.init(name: "Côte", kind: .work, durationSeconds: 600, speedKmh: 5.0, inclinePercent: 4, targetZone: 3)),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 300, speedKmh: 3.5, inclinePercent: 0, targetZone: 1)),
            ]),
            WorkoutProgram(name: "Intervalles marche/course", items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: 300, speedKmh: 4.5, targetZone: 2)),
                .block(.init(name: "Intervalles", repeatCount: 6, phases: [
                    .init(name: "Course", kind: .work, durationSeconds: 60, speedKmh: 8.5, targetZone: 4),
                    .init(name: "Marche", kind: .recovery, durationSeconds: 120, speedKmh: 5.0, targetZone: 2),
                ])),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 300, speedKmh: 4.0, targetZone: 1)),
            ]),
            WorkoutProgram(name: "Collines", items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: 300, speedKmh: 4.0)),
                .block(.init(name: "Montées", repeatCount: 3, phases: [
                    .init(name: "Montée", kind: .work, durationSeconds: 180, speedKmh: 5.0, inclinePercent: 6, targetZone: 3),
                    .init(name: "Plat", kind: .recovery, durationSeconds: 120, speedKmh: 5.0, inclinePercent: 1, targetZone: 2),
                ])),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 300, speedKmh: 3.5)),
            ]),
        ]
    }

    /// Inclinaison minimale de tous les programmes prédéfinis.
    static let minimumTemplateIncline = 1.0

    /// Ordre d'affichage : programme principal d'endurance d'abord, progressions ensuite.
    static var templates: [WorkoutProgram] {
        [zone2Auto, cardioBaseline, zone2Endurance, intervalRun911, footballEndurance1, footballEndurance2,
         footballEndurance3, hiitRun11, inclineWalk, postMealWalk]
    }

    static func template(id: String) -> WorkoutProgram? {
        templates.first { $0.templateID == id }
    }

    private static func min(_ m: Int) -> Int { m * 60 }
    private static let i1 = 1.0

    static var cardioBaseline: WorkoutProgram {
        WorkoutProgram(name: "Cardio Baseline", notes: """
            Test de référence (30 min, 1 %) : FC à effort identique au fil des semaines, une fois toutes les \
            deux semaines à la place de Zone 2. Protocole strictement identique, aucun ajustement automatique ; \
            toute modification pendant la séance la rend non comparable. Les tests faits avec l'ancien protocole \
            à 0 % forment une série distincte.
            """, items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(5), speedKmh: 4.0, inclinePercent: i1)),
                .phase(.init(name: "Allure de référence", kind: .steady, durationSeconds: min(20), speedKmh: 6.0, inclinePercent: i1)),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 3.8, inclinePercent: i1)),
            ], templateID: ProgramTemplateID.cardioBaseline, locked: true, protocolVersion: 2)
    }

    static var zone2Endurance: WorkoutProgram {
        WorkoutProgram(name: "Zone 2 Endurance", notes: """
            Endurance aérobie (35 min, 1 %). À 5,5 km/h vous êtes généralement à la limite supérieure de la \
            zone 1 : les 6 km/h sont un point de départ à ajuster selon votre FC (boutons +/−), pas une garantie \
            d'être en zone 2. La FC ne pilote pas le tapis dans ce programme.
            """, items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(5), speedKmh: 4.0, inclinePercent: i1, targetZone: 1)),
                .phase(.init(name: "Montée en allure", kind: .steady, durationSeconds: min(5), speedKmh: 5.5, inclinePercent: i1, targetZone: 1)),
                .phase(.init(name: "Zone 2", kind: .steady, durationSeconds: min(20), speedKmh: 6.0, inclinePercent: i1, targetZone: 2)),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 3.8, inclinePercent: i1, targetZone: 1)),
            ], templateID: ProgramTemplateID.zone2Endurance, locked: true, protocolVersion: 2)
    }

    static var intervalRun911: WorkoutProgram {
        WorkoutProgram(name: "Interval Run 9/11", notes: "Fractionné principal, fondé sur vos essais réels (30 min, 1 %).", items: [
            .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(3), speedKmh: 4.0, inclinePercent: i1)),
            .phase(.init(name: "Marche rapide", kind: .warmup, durationSeconds: min(3), speedKmh: 5.0, inclinePercent: i1)),
            .phase(.init(name: "Footing", kind: .steady, durationSeconds: min(2), speedKmh: 6.0, inclinePercent: i1)),
            .block(.init(name: "Intervalles 9 km/h", repeatCount: 6, phases: [
                .init(name: "Course 9", kind: .work, durationSeconds: min(1), speedKmh: 9.0, inclinePercent: i1, targetZone: 4),
                .init(name: "Récupération", kind: .recovery, durationSeconds: min(1), speedKmh: 5.0, inclinePercent: i1),
            ])),
            .phase(.init(name: "Course 11", kind: .work, durationSeconds: min(2), speedKmh: 11.0, inclinePercent: i1, targetZone: 5)),
            .phase(.init(name: "Marche", kind: .recovery, durationSeconds: min(3), speedKmh: 4.0, inclinePercent: i1)),
            .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 3.8, inclinePercent: i1)),
        ], templateID: ProgramTemplateID.intervalRun911, locked: true, protocolVersion: 2)
    }

    static var hiitRun11: WorkoutProgram {
        WorkoutProgram(name: "HIIT Run 11", notes: """
            Avancé — à débloquer après validation (35 min, 1 %). Jamais proposé automatiquement comme progression ; \
            le lancement demande une confirmation.
            """, items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(4), speedKmh: 4.0, inclinePercent: i1)),
                .phase(.init(name: "Marche rapide", kind: .warmup, durationSeconds: min(4), speedKmh: 5.5, inclinePercent: i1)),
                .phase(.init(name: "Footing", kind: .steady, durationSeconds: min(2), speedKmh: 7.0, inclinePercent: i1)),
                .block(.init(name: "Intervalles 11 km/h", repeatCount: 4, phases: [
                    .init(name: "Course 11", kind: .work, durationSeconds: min(2), speedKmh: 11.0, inclinePercent: i1, targetZone: 5),
                    .init(name: "Récupération", kind: .recovery, durationSeconds: min(3), speedKmh: 4.5, inclinePercent: i1),
                ])),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 3.8, inclinePercent: i1)),
            ], templateID: ProgramTemplateID.hiitRun11, locked: true, protocolVersion: 2, advanced: true)
    }

    static var inclineWalk: WorkoutProgram {
        WorkoutProgram(name: "Incline Walk", notes: "Alternative de marche cardiovasculaire inclinée (30 min).", items: [
            .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(5), speedKmh: 4.0, inclinePercent: i1)),
            .phase(.init(name: "Marche 1 %", kind: .steady, durationSeconds: min(5), speedKmh: 5.5, inclinePercent: i1)),
            .phase(.init(name: "Marche 2 %", kind: .work, durationSeconds: min(15), speedKmh: 5.5, inclinePercent: 2)),
            .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 3.8, inclinePercent: i1)),
        ], templateID: ProgramTemplateID.inclineWalk, locked: true, protocolVersion: 2)
    }

    static var postMealWalk: WorkoutProgram {
        WorkoutProgram(name: "Post-Meal Walk", notes: "Marche douce après les repas (15 min, 1 %), activité légère complémentaire.", items: [
            .phase(.init(name: "Mise en route", kind: .warmup, durationSeconds: min(2), speedKmh: 3.5, inclinePercent: i1)),
            .phase(.init(name: "Marche", kind: .steady, durationSeconds: min(10), speedKmh: 4.5, inclinePercent: i1)),
            .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(3), speedKmh: 3.5, inclinePercent: i1)),
        ], templateID: ProgramTemplateID.postMealWalk, locked: true, protocolVersion: 2)
    }

    static var zone2Auto: WorkoutProgram {
        WorkoutProgram(name: "Zone 2 Auto", notes: """
            Programme d'endurance principal (35 min, 1 % fixe). Pendant 25 min, la vitesse suit votre FC filtrée \
            (≈ 18 s) pour vous amener puis vous garder dans votre zone 2 (Réglages › FC max et zones). Départ à la \
            vitesse qui vous a maintenu en zone 2 la dernière fois. Sous la zone : accélération d'autant plus nette \
            que la FC est loin (0,2 à 0,5 km/h, au plus une par minute), sauf si la FC monte déjà vers la zone. \
            Dans la zone : vitesse maintenue, léger ralentissement anticipé si la FC monte vite vers la limite haute. \
            Au-dessus : ralentissement. Limites automatiques 4–8,5 km/h. Sans FC : accélérations coupées, puis retour \
            progressif à 4,5 km/h. Vos réglages manuels sont prioritaires. L'inclinaison ne change jamais \
            automatiquement.
            """, items: [
                .phase(.init(name: "Échauffement progressif", kind: .warmup, durationSeconds: min(5), speedKmh: 4.0,
                             inclinePercent: i1, targetZone: 1, endSpeedKmh: 5.5)),
                .phase(.init(name: "Zone 2 pilotée", kind: .steady, durationSeconds: min(25), speedKmh: 5.8,
                             inclinePercent: i1, targetZone: 2,
                             autoSpeed: AutoSpeedSettings(maxKmh: 8.5, adaptive: true))),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 4.0,
                             inclinePercent: i1, targetZone: 1, endSpeedKmh: 3.5)),
            ], templateID: ProgramTemplateID.zone2Auto, locked: true, protocolVersion: 3)
    }

    // MARK: - Football Endurance (3 niveaux)

    /// Échauffement commun (10 min).
    private static var footballWarmup: [ProgramItem] {
        [.phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: min(4), speedKmh: 4.5, inclinePercent: i1)),
         .phase(.init(name: "Marche rapide", kind: .warmup, durationSeconds: min(4), speedKmh: 5.5, inclinePercent: i1)),
         .phase(.init(name: "Footing", kind: .steady, durationSeconds: min(2), speedKmh: 6.5, inclinePercent: i1))]
    }

    /// Efforts répétés avec récupération **uniquement entre** les répétitions (pas après la dernière).
    private static func footballEfforts(_ count: Int, minutes: Int, speed: Double) -> [ProgramItem] {
        var out: [ProgramItem] = []
        for i in 1...count {
            out.append(.phase(.init(name: "Effort \(i)/\(count)", kind: .work, durationSeconds: min(minutes),
                                    speedKmh: speed, inclinePercent: i1, targetZone: 4)))
            if i < count {
                out.append(.phase(.init(name: "Récupération \(i)/\(count - 1)", kind: .recovery, durationSeconds: min(3),
                                        speedKmh: 5.0, inclinePercent: i1)))
            }
        }
        return out
    }

    private static var footballCooldown: [ProgramItem] {
        [.phase(.init(name: "Allure modérée", kind: .steady, durationSeconds: min(5), speedKmh: 6.0, inclinePercent: i1)),
         .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: min(5), speedKmh: 4.0, inclinePercent: i1))]
    }

    static var footballEndurance1: WorkoutProgram {
        WorkoutProgram(name: "Football Endurance · Niveau 1", notes: """
            Niveau par défaut (35 min, 1 %) : répéter des efforts soutenus pour tenir des matchs de 60 à 90 min. \
            Alternative au fractionné ; à éviter la même semaine qu'un match intense. 3 × 3 min à 8,5 km/h, \
            récupération 3 min à 5 km/h entre les efforts.
            """, items: footballWarmup + footballEfforts(3, minutes: 3, speed: 8.5) + footballCooldown,
            templateID: ProgramTemplateID.footballEndurance1, locked: true, protocolVersion: 1, level: 1)
    }

    static var footballEndurance2: WorkoutProgram {
        WorkoutProgram(name: "Football Endurance · Niveau 2", notes: """
            Progression (41 min, 1 %), après plusieurs séances de niveau 1 bien tolérées (cheville comprise). \
            4 × 3 min à 8,5 km/h, récupération 3 min à 5 km/h entre les efforts.
            """, items: footballWarmup + footballEfforts(4, minutes: 3, speed: 8.5) + footballCooldown,
            templateID: ProgramTemplateID.footballEndurance2, locked: true, protocolVersion: 1, level: 2)
    }

    static var footballEndurance3: WorkoutProgram {
        WorkoutProgram(name: "Football Endurance · Niveau 3", notes: """
            Progression avancée (45 min, 1 %), jamais imposée : lancement après confirmation. \
            4 × 4 min à 9 km/h, récupération 3 min à 5 km/h entre les efforts.
            """, items: footballWarmup + footballEfforts(4, minutes: 4, speed: 9.0) + footballCooldown,
            templateID: ProgramTemplateID.footballEndurance3, locked: true, protocolVersion: 1, level: 3, advanced: true)
    }
}

/// Mise à jour de la bibliothèque installée, sans doublon :
/// - un programme prédéfini déjà présent (même `templateID`) est remplacé **en gardant son
///   identifiant** et sa date de création ;
/// - un programme prédéfini jamais proposé est ajouté ;
/// - un programme prédéfini supprimé par l'utilisateur n'est pas réinstallé ;
/// - les programmes personnels et les copies ne sont jamais touchés.
public enum TemplateLibrary {
    public struct Plan: Equatable {
        public var upserts: [WorkoutProgram]
        /// Anciens programmes de la première version, intacts, à retirer.
        public var removals: [UUID] = []
        public var seededIDs: [String]
        public var revision: Int
        public var updatedNames: [String]
        public var addedNames: [String]
    }

    public static func plan(installed: [WorkoutProgram], seededIDs: [String], installedRevision: Int,
                            templates: [WorkoutProgram] = WorkoutProgram.templates,
                            revision: Int = WorkoutProgram.templatesRevision, now: Date = Date()) -> Plan {
        var seeded = Set(seededIDs)
        var upserts: [WorkoutProgram] = []
        var updated: [String] = []
        var added: [String] = []
        for t in templates {
            guard let id = t.templateID else { continue }
            if let current = installed.first(where: { $0.templateID == id }) {
                if installedRevision < revision {
                    var fresh = t
                    fresh.id = current.id
                    fresh.createdAt = current.createdAt
                    fresh.updatedAt = now
                    upserts.append(fresh)
                    updated.append(t.name)
                }
            } else if !seeded.contains(id) {
                upserts.append(t)
                added.append(t.name)
            }
            seeded.insert(id)
        }
        // Anciens programmes de la première version : retirés seulement si nom et déroulé sont
        // exactement ceux d'origine (une version modifiée par l'utilisateur est conservée).
        var removals: [UUID] = []
        if installedRevision < 3 {
            let legacy = Dictionary(uniqueKeysWithValues: WorkoutProgram.legacyTemplates.map { ($0.name, $0.protocolSignature) })
            for p in installed where p.templateID == nil && legacy[p.name] == p.protocolSignature {
                removals.append(p.id)
            }
        }
        return Plan(upserts: upserts, removals: removals, seededIDs: Array(seeded).sorted(),
                    revision: max(installedRevision, revision), updatedNames: updated, addedNames: added)
    }
}
