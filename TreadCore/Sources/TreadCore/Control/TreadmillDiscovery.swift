import Foundation

/// Tri des appareils vus pendant la recherche de tapis et diagnostic d'un tapis inutilisable.
///
/// La recherche ne filtre plus sur le seul service FTMS annoncé : un tapis connu par son nom
/// (Domyos-TC…, URTM…) qui n'annonce pas 0x1826 reste visible, avec une explication, au lieu
/// de disparaître de la liste (cas d'un Domyos repassé en mode Decathlon).
public enum TreadmillDiscovery {
    public enum Kind: Equatable, Sendable {
        /// Annonce le service FTMS : utilisable.
        case ftms
        /// Nom d'un tapis connu mais FTMS non annoncé : connexion possible, probablement inutilisable.
        case knownNameWithoutFTMS
    }

    /// Préfixes de nom des tapis reconnus (profils dédiés).
    public static var knownNamePrefixes: [String] {
        TreadmillProfile.all.flatMap(\.namePrefixes).map { $0.uppercased() }
    }

    /// nil : appareil sans rapport (montre, écouteurs…), ignoré.
    public static func classify(name: String?, advertisedServices: [String]) -> Kind? {
        if advertisedServices.contains(where: { isFTMS($0) }) { return .ftms }
        guard let n = name?.uppercased(), !n.isEmpty else { return nil }
        return knownNamePrefixes.contains { n.hasPrefix($0) } ? .knownNameWithoutFTMS : nil
    }

    static func isFTMS(_ uuid: String) -> Bool {
        let u = uuid.uppercased()
        return u == GATTID.fitnessMachineService || u == "00001826-0000-1000-8000-00805F9B34FB"
    }

    /// Message quand le tapis connecté n'expose pas le service FTMS (nil s'il l'expose).
    public static func missingFTMSMessage(services: [String], name: String?) -> String? {
        guard !services.contains(where: { isFTMS($0) }) else { return nil }
        let isDomyos = name?.uppercased().hasPrefix("DOMYOS") == true
            || services.contains { $0.uppercased() == GATTID.domyosProprietaryService }
        if isDomyos {
            return "Ce tapis Domyos n'est pas en mode FTMS (mode Decathlon). Fermez l'app Domyos E-Connected, activez-y le FTMS s'il est proposé, puis éteignez et rallumez le tapis avant de relancer la recherche."
        }
        return "Ce périphérique n'expose pas le service FTMS (0x1826) : Foulée ne peut pas le piloter."
    }
}
