# Export des séances pour Rythme

*Historique › séance › … › Exporter pour Rythme (JSON)* (une séance) ou *Historique › ⬆ › Tout
exporter pour Rythme* (toutes). Format : `foulee.rythme.session`, version 1, JSON trié, dates ISO 8601.
Un fichier d'une séance contient un objet ; l'export de tout l'historique, un tableau d'objets.
Défini dans `TreadCore/Sources/TreadCore/Session/RythmeExport.swift` (testé).

## Partage automatique (sans export)

Foulée et Rythme partagent l'App Group `group.com.houssemelloumi.rythme` (même équipe de
signature, `Config/Foulee.entitlements`, app iPhone). Foulée y tient à jour, dans
`Foulee/sessions/`, **un fichier `<session.id>.json` par séance** : un objet
`foulee.rythme.session`, même encodage que l'export manuel, écriture atomique
(`Foulee/Services/RythmeShare.swift`).

| Quand | Effet |
|---|---|
| Séance enregistrée (`DataStore.upsert`) : fin, FC de récupération, ressenti saisi après coup, correction, séance lancée depuis la Watch | fichier (ré)écrit |
| Séance supprimée (`DataStore.delete`) | fichier supprimé |
| Lancement de Foulée | fichiers manquants écrits (historique) ; fichiers de séances supprimées retirés |
| Méthode de zones ou FC max modifiée | tous les fichiers réécrits (zones = réglages actuels, comme à l'écran) |
| Séance simulée | jamais écrite |

La base SwiftData de Foulée reste dans le conteneur **privé** de l'app, à URL explicite
(`Foulee/Persistence/StoreLocation.swift`) : sans cela, SwiftData la placerait dans l'App Group.
Seuls les fichiers JSON ci-dessus vont dans le dossier commun.

Contrat : ajouter des champs optionnels est permis ; renommer ou supprimer un champ demande
`formatVersion` 2 (à coordonner avec Rythme). `templateID` et `protocolSignature` sont stables.

**Règle** : les champs `target…` sont des **consignes** (programme, pilote FC ou utilisateur), les
champs `measured…` des **mesures** du tapis. Une mesure indisponible vaut `null`, jamais la
consigne ni 0. Les heures relatives `t` sont en secondes depuis `session.startDate`.

| Clé | Contenu |
|---|---|
| `format`, `formatVersion`, `exportedAt` | identification du format |
| `session` | `id` (stable), `startDate`, `endDate`, `beltStartDate` / `beltStopDate` (mouvement réel), `activeSeconds`, `pausedSeconds`, `simulated`, `interrupted`, tapis et profil |
| `program` | `id` (stable, identique dans Foulée et sur la Watch), `templateID`, `name`, `level`, `protocolVersion`, `protocolSignature` (deux séances de même empreinte ont suivi le même protocole), `advanced`, `plannedSeconds` |
| `plannedSegments[]` | étapes prévues : `index`, `name`, `kind`, `plannedStartSeconds`, `durationSeconds`, `targetSpeedKmh`, `targetEndSpeedKmh` (rampe), `targetInclinePercent`, `targetZone`, `autoSpeedRangeKmh` (phase pilotée), `repetition` |
| `executedSegments[]` | étapes exécutées : `start`, `end`, consignes, `autoSpeed`, `measuredAvgSpeedKmh`, `measuredMaxSpeedKmh`, `avgHR`, `maxHR`, `hrAtEnd` (FC en fin d'intervalle), `hrDrop60` (baisse 60 s après, si l'étape suivante est plus lente ou à l'arrêt), `secondsInTargetZone` |
| `samples[]` (≈ 1 Hz) | `measuredSpeedKmh`, `measuredInclinePercent`, `targetSpeedKmh`, `targetInclinePercent`, `hr`, `zone`, `distanceMeters`, `paused` |
| `heartRate[]` | FC horodatée (`t`, `date`, `bpm`, `source` : `bleSensor`, `appleWatch`, `treadmill`), y compris 2 min après l'arrêt |
| `zones` | méthode, FC max, FC repos, 6 bornes (début Z1 … FC max), secondes par zone, `rule` (règle de calcul, [ZONES.md](ZONES.md)), `maxHRSource`, `restingHRSource`, `restingHRExact` (repos décimal). `bounds` = premier bpm entier de chaque zone ; `bounds` et `secondsPerZone` sont lus tels quels par Rythme : champs figés |
| `autoAdjustments[]` | pilote FC : `t`, `fromKmh`, `toKmh`, `filteredBPM`, `kind` (`increase`, `decrease`, `safety`), `reason` |
| `interruptions` | nombre de pauses, pertes de connexion, arrêts par le tapis, consignes manuelles, phases passées, reprise après fermeture |
| `recovery` | FC à l'arrêt de la bande, après 60 s et 120 s |
| `perceivedExertion` | ressenti saisi après la séance, échelle CR10 de Borg 0–10 (`null` si non renseigné) |
| `events[]` | journal de séance (pauses, reprises, phases, consignes manuelles, écarts, déconnexions, pilote FC) |
| `distanceMeters`, `steps`, `avgHR`, `maxHR` | totaux (distance du tapis ou intégrée, voir `events`) |

Comparaisons cardiovasculaires : ne comparer que des séances de même `protocolSignature`. Le
Cardio Baseline à 1 % (`protocolVersion` 2) a une empreinte différente de l'ancien protocole à 0 %.
