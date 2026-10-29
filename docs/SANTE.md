# Apple Santé — ce que Foulée écrit

Ce document répond au cahier des charges « Foulée × Rythme ». Le code est dans
`TreadCore/Sources/TreadCore/Session/HealthSyncPlan.swift` (règles, testées sous
Linux et macOS) et `Foulee/Services/HealthService.swift` (appels HealthKit).

## 1. Propriétaire unique

| Situation | Qui écrit | L'iPhone écrit |
|-----------|-----------|----------------|
| Un exercice Apple Watch a tourné pendant la séance (lancé par Foulée ou relié à elle) | **la Watch** (FC, énergie, pas, distance) | rien ; il envoie à la Watch les métadonnées Foulée, posées sur son `HKLiveWorkoutBuilder` |
| Pas d'exercice Watch | **l'iPhone** | une seule séance `HKWorkoutBuilder` + échantillons |
| Une autre séance Santé (Watch, Exercice, app « UR »…) couvre > 50 % du créneau | personne | rien ; l'historique affiche « Déjà enregistrée par … » |
| Moins d'1 minute hors pauses, ou séance simulée | personne | rien (exercice Watch annulé si < 1 min) |

**Lancement de l'exercice Watch.** Au démarrage d'une séance sur l'iPhone, l'app Watch est lancée
(`startWatchApp`) ; si l'exercice ne tourne toujours pas 12 s puis 40 s après, nouvel essai, puis
bandeau « ouvrez Foulée sur la montre ». Ouvrir l'app Watch pendant une séance de l'iPhone sans
exercice en cours démarre l'enregistrement tout seul, aligné sur le démarrage de la bande (jamais
pour une séance dont l'exercice montre a déjà été terminé).

**Exercice Watch d'une seule pièce.** Si l'app Watch est fermée pendant la séance (plantage,
mémoire), watchOS la relance et elle **reprend le même exercice**
(`handleActiveWorkoutRecovery`, `recoverActiveWorkoutSession`) ; un démarrage ultérieur reprend
aussi l'exercice encore actif au lieu d'en créer un second. Si un nouvel exercice démarre malgré
tout en cours de séance, son début est aligné sur le démarrage de la bande et les pauses déjà
faites y sont reportées (`WatchWorkoutAlignment`) : avec le même identifiant de synchronisation,
il remplace dans Santé le morceau précédent par la séance entière. (Cas observé le 24/10 : seule
la partie après la 2ᵉ pause était dans Santé.)

**Vérification automatique** : à la fin d'une séance enregistrée par la Watch (état « terminé »
reçu, au plus ~3 min, puis 20 s), l'iPhone vérifie la séance Santé de la montre. Si elle ne
couvre qu'une partie de la séance, elle est remplacée automatiquement par la séance complète
(même procédure que ci-dessous). Si Santé n'a encore aucune séance de la montre, rien n'est écrit
automatiquement (pas de doublon) : le bouton de l'historique reste disponible.

**Récupérer une séance Watch incomplète** (*Historique › séance › Récupérer la séance complète
dans Santé*, séances enregistrées par la Watch) : si Santé ne contient qu'une partie de la séance
(moins de 90 % du créneau), l'iPhone écrit **d'abord** la séance complète à partir des données
Foulée (bande réelle, pauses, phases, distance, pas, énergie ; la FC de la montre est déjà dans
Santé), avec une version supérieure (`HealthRecoveryDecision`), **puis** supprime la séance
partielle. Les autorisations sont vérifiées (et demandées si besoin) avant toute modification ;
un échec d'écriture ne supprime rien. Si Santé refuse que l'iPhone supprime la séance de la
montre, supprimez-la dans l'app Santé pour éviter le doublon.

Identifiant stable sur chaque séance (iPhone **et** Watch) :
`HKMetadataKeySyncIdentifier` = `HKMetadataKeyExternalUUID` = UUID Foulée,
`HKMetadataKeySyncVersion` = révision (1, puis +1 à chaque correction).

Avant d'écrire, l'iPhone lit les séances du créneau et celles portant ce
SyncIdentifier (`HealthWriteDecision`) :
- même identifiant, version ≥ → **rien n'est réécrit** ;
- même identifiant, version < (correction) → l'ancienne séance **et ses échantillons**
  sont supprimés, puis la nouvelle version est écrite ;
- autre séance chevauchant > 50 % → rien n'est écrit.

## 2. La séance (iPhone propriétaire)

- Type : `.highIntensityIntervalTraining` pour un programme d'intervalles (bloc répété
  effort/récupération, ou nom contenant HIIT/intervalle/fractionné) ; sinon
  `.running` si la vitesse mesurée est ≥ 6,5 km/h plus de la moitié du temps actif ;
  sinon `.walking`. Modifiable dans *Historique › Corriger*.
- `HKMetadataKeyIndoorWorkout = true`, `locationType = .indoor`.
- `startDate` = premier mouvement observé de la bande ; `endDate` = vitesse nulle
  observée après l'arrêt (à défaut, l'instant de la commande d'arrêt, signalé).
- Pauses : `HKWorkoutEvent .pause` / `.resume` aux instants réels (pause demandée →
  bande repartie) : la durée de la séance les exclut.
- Phases : un `HKWorkoutEvent .segment` par phase exécutée, métadonnées
  `FouleePhaseName`, `FouleePhaseIndex`, `FouleeTargetSpeedKmh`,
  `FouleeTargetInclinePercent`.

## 3. Échantillons (iPhone propriétaire)

Tous portent `FouleeSessionID` (pour les retrouver et les supprimer).

| Type | Source | Découpage | Associé à la séance |
|------|--------|-----------|---------------------|
| `distanceWalkingRunning` | compteur de distance du tapis | tranches ≤ 60 s | oui |
| `stepCount` | compteur de pas du tapis uniquement (jamais inventé) | tranches ≤ 60 s | oui |
| `activeEnergyBurned` | ACSM (vitesse + pente) − repos, avec le **poids le plus récent de Santé** ; sinon énergie du tapis ; jamais les deux | tranches ≤ 60 s | oui |
| `heartRate` | ceinture/brassard BLE (ou capteur du tapis) | ~1 mesure / 5 s, heure réelle de la mesure | oui pendant la séance ; **les 2 minutes après l'arrêt** sont enregistrées à part (hors intervalle de la séance) avec `FouleeSessionID` |

Une tranche dont la valeur est nulle ou inconnue n'est pas écrite (jamais 0 à la
place d'une donnée manquante). Après « Arrêter », Foulée continue d'enregistrer la FC
pendant 2 minutes avant d'écrire dans Santé (même si vous fermez l'écran de résumé).

## 4. Métadonnées Foulée sur la séance

`FouleeSessionID`, `FouleeProgram` (« Séance libre » par défaut),
`FouleeAverageSpeedKmh`, `FouleeMaxSpeedKmh`, `FouleeAverageInclinePercent`,
`FouleeElevationGainM` (nombres), `FouleeEnergySource` (« acsm » ou « tapis », absent
si l'iPhone n'écrit pas d'énergie, donc absent quand la Watch est propriétaire). Une
valeur inconnue est omise.

## 5. Zones (identiques à Rythme)

Méthode par défaut « Automatique (comme Rythme et l'Apple Watch) » :
- FC max = valeur saisie dans Foulée, sinon max(220 − âge, FC tenue la plus haute sur
  12 mois) — une mesure ≥ 170 bpm n'est retenue que si une autre mesure, dans les
  2 minutes, est au plus 5 bpm en dessous ; > 230 ignoré ;
- FC repos = moyenne des `restingHeartRate` sur 30 jours, ignorée si < 30 ou > FC max − 40 ;
- bornes basses Z2…Z5 = repos + 60/70/80/90 % × (max − repos) ; sans FC de repos,
  60/70/80/90 % de la FC max ; tout ce qui est sous Z2 compte en Z1.

Calcul refait au lancement et via *Réglages › FC max et zones › Recalculer depuis Santé*.

## 6. Corrections et suppressions

- *Historique › … › Corriger la séance* : nom du programme, type d'activité, fin de
  séance. Révision +1 ; si Foulée avait écrit la séance, elle est réécrite (ancienne
  séance et ses échantillons supprimés, SyncVersion supérieure).
- Supprimer dans Foulée (balayage ou menu) supprime aussi de Santé la séance et tous les
  échantillons `FouleeSessionID`.
- **Limite** : une séance écrite par la Watch ne peut être supprimée que par l'app qui
  l'a écrite (règle HealthKit). Foulée tente la suppression depuis l'iPhone et, en cas de
  refus, l'indique (« à supprimer dans Santé »). Corriger une séance Watch ne modifie que
  Foulée : HealthKit ne permet pas de changer après coup les métadonnées d'une séance.

## 7. Autorisations

Écriture : séances, distance, pas, énergie active, FC. Lecture : séances, poids, date de
naissance, FC, FC de repos. Demandées au premier lancement. *Réglages › Apple Santé*
indique ce qui ne sera pas enregistré si une écriture est refusée (un refus de lecture
n'est pas détectable : la valeur lue est simplement absente).

## 8. Exemples

Les exemples ci-dessous sont **calculés par le moteur à partir de séances simulées**
(`FOULEE_PRINT_EXAMPLES=1 swift test --package-path TreadCore --filter HealthExamples`).
Les exemples réels se lisent dans l'app : *Historique › séance › « Ce qui a été écrit
dans Santé »*, exportable via *… › Exporter le rapport Santé*.

### iPhone seul + ceinture

```
Propriétaire : phone — aucun exercice Apple Watch : l'iPhone enregistre la séance
Résultat : simulé (plan calculé, non écrit)
Type : Marche · intérieur
Début (bande) : 2023-11-14T22:13:24Z · fin : 2023-11-14T22:18:10Z
Durée hors pauses : 255 s · pauses : 1
SyncIdentifier = ExternalUUID = B03512E1-9184-46B5-952E-0C2CCC76B3AD · SyncVersion = 1
FouleeAverageInclinePercent = 0
FouleeAverageSpeedKmh = 2.9
FouleeElevationGainM = 0
FouleeEnergySource = acsm
FouleeMaxSpeedKmh = 3
FouleeProgram = Séance libre
FouleeSessionID = B03512E1-9184-46B5-952E-0C2CCC76B3AD
distanceWalkingRunning : 5 échantillons (5 associés), total 203.0 m, tranche max 60 s
stepCount : 5 échantillons (5 associés), total 290.0 pas, tranche max 60 s
activeEnergyBurned : 5 échantillons (5 associés), total 7.2 kcal, tranche max 60 s
heartRate : 78 échantillons (54 associés), moyenne 120 bpm, tranche max 0 s
```

### Watch propriétaire

```
Propriétaire : watch — l'Apple Watch enregistre la séance ; Foulée ajoute ses métadonnées, l'iPhone n'écrit rien
Résultat : simulé (plan calculé, non écrit)
Type : Marche · intérieur
Début (bande) : 2023-11-14T22:13:24Z · fin : 2023-11-14T22:18:10Z
Durée hors pauses : 255 s · pauses : 1
SyncIdentifier = ExternalUUID = B03512E1-9184-46B5-952E-0C2CCC76B3AD · SyncVersion = 1
FouleeAverageInclinePercent = 0
FouleeAverageSpeedKmh = 2.9
FouleeElevationGainM = 0
FouleeMaxSpeedKmh = 3
FouleeProgram = Séance libre
FouleeSessionID = B03512E1-9184-46B5-952E-0C2CCC76B3AD
```

### HIIT avec phases

```
Propriétaire : phone — aucun exercice Apple Watch : l'iPhone enregistre la séance
Résultat : simulé (plan calculé, non écrit)
Type : Entraînement fractionné (HIIT) · intérieur
Début (bande) : 2023-11-14T22:13:24Z · fin : 2023-11-14T22:22:31Z
Durée hors pauses : 548 s · pauses : 0
SyncIdentifier = ExternalUUID = BF2E541C-D6E5-4C37-A63F-34B3EA5E83C9 · SyncVersion = 1
FouleeAverageInclinePercent = 0
FouleeAverageSpeedKmh = 5.89
FouleeElevationGainM = 0
FouleeEnergySource = acsm
FouleeMaxSpeedKmh = 8.5
FouleeProgram = Intervalles marche/course
FouleeSessionID = BF2E541C-D6E5-4C37-A63F-34B3EA5E83C9
Segment 1 « Échauffement » 120 s · 4.5 km/h · 0 %
Segment 2 « Sprint · 1/3 » 60 s · 8.5 km/h · 0 %
Segment 3 « Récupération · 1/3 » 60 s · 5.0 km/h · 0 %
Segment 4 « Sprint · 2/3 » 60 s · 8.5 km/h · 0 %
Segment 5 « Récupération · 2/3 » 60 s · 5.0 km/h · 0 %
Segment 6 « Sprint · 3/3 » 60 s · 8.5 km/h · 0 %
Segment 7 « Récupération · 3/3 » 60 s · 5.0 km/h · 0 %
Segment 8 « Retour au calme » 60 s · 4.0 km/h · 0 %
distanceWalkingRunning : 9 échantillons (9 associés), total 884.0 m, tranche max 60 s
stepCount : 9 échantillons (9 associés), total 1086.0 pas, tranche max 60 s
activeEnergyBurned : 9 échantillons (9 associés), total 46.4 kcal, tranche max 60 s
heartRate : 130 échantillons (106 associés), moyenne 126 bpm, tranche max 0 s
```

## 9. Vérification sur l'iPhone (preuves à capturer)

Pour chaque cas, capturer *Santé › Parcourir › Activité › Exercices* et le rapport Santé
de la séance dans Foulée.

1. **iPhone seul + ceinture** : Watch retirée (ou réglage « Lancer l'exercice Watch »
   désactivé), ceinture connectée, séance libre de 3 min avec une pause, puis attendre
   2 min après Arrêter. Attendu : 1 séance Marche intérieure, distance/pas/énergie par
   minute, FC ~5 s, FC des 2 min après l'arrêt.
2. **Watch propriétaire** : exercice Watch lancé avec la séance. Attendu : 1 seule séance
   (source : Foulée sur la Watch) avec les métadonnées Foulée ; rien de l'iPhone.
3. **HIIT** : programme « Intervalles marche/course ». Attendu : type Entraînement
   fractionné, un segment par phase.
4. **Même séance deux fois** : *Historique › Enregistrer dans Santé* sur une séance déjà
   enregistrée (bouton masqué ; via un second appareil ou après réinstallation) → rapport
   « déjà présente avec cette version : rien réécrit ».
5. **Séance corrigée** : *Corriger* (changer le nom) → toujours 1 seule séance dans Santé,
   SyncVersion 2, nom à jour.
6. **Séance supprimée** : supprimer dans Foulée → la séance et ses échantillons
   disparaissent de Santé (et de Rythme).
7. **Watch et iPhone en même temps** : lancer un exercice dans l'app Exercice de la Watch
   sans Foulée Watch, puis une séance Foulée sur le même créneau → historique
   « Déjà enregistrée par … », aucune seconde séance.
