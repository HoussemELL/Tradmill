# Foulée — pilotage de tapis FTMS pour iPhone et Apple Watch

Application iOS native personnelle (SwiftUI) qui se connecte en Bluetooth à un
tapis de course **FTMS**, enchaîne automatiquement les phases d'un programme
(durée, vitesse, inclinaison) et affiche cardio, zones, pas et distance.
Compagnon watchOS pour le cardio Apple Watch en direct.

Conçue et testée en simulation pour l'**UREVO FoldiMix 5L (nom BLE « URTM047 »)**.
Aucun serveur, compte, abonnement, publicité ni dépendance tierce ; tout
fonctionne hors ligne et les données restent sur l'appareil.

> ⚠️ Le bouton Arrêter de l'app **ne remplace pas la clé de sécurité** du tapis.
> Gardez-la attachée. En cas de perte Bluetooth, l'état réel du tapis est
> inconnu : arrêtez-le avec son bouton ou la clé.

---

## Sommaire

1. [Contenu du projet](#1-contenu-du-projet)
2. [Versions minimales](#2-versions-minimales)
3. [Installation sur iPhone et Apple Watch](#3-installation-sur-iphone-et-apple-watch)
4. [Autorisations](#4-autorisations)
5. [Premier appairage](#5-premier-appairage)
6. [Utilisation](#6-utilisation)
7. [Bluetooth FTMS et profil URTM047](#7-bluetooth-ftms-et-profil-urtm047)
8. [Cardio, zones, pas et énergie](#8-cardio-zones-pas-et-énergie)
9. [Historique et Apple Santé](#9-historique-et-apple-santé)
10. [Arrière-plan et robustesse](#10-arrière-plan-et-robustesse)
11. [Mode simulateur](#11-mode-simulateur)
12. [Ce qui compile, ce qui est testé, ce qui reste à valider](#12-ce-qui-compile-ce-qui-est-testé-ce-qui-reste-à-valider)
13. [Limites restantes](#13-limites-restantes)
14. [Dépannage](#14-dépannage)

---

## 1. Contenu du projet

```
Foulee.xcodeproj          Projet Xcode (targets Foulee + FouleeWatch, schemes partagés)
Config/                   Signing.xcconfig (à modifier), Info.plist, entitlements
TreadCore/                Paquet Swift local, sans dépendance Apple-only :
  FTMS/                     décodage/encodage des caractéristiques (octets)
  Control/                  file de commandes, profils matériels, contrôleur du tapis
  Program/                  programmes, validation, import/export JSON, moteur temporel
  Heart/                    zones, source cardio unique, temps par zone, alertes
  Metrics/                  compteurs cumulatifs, pas, estimation énergie
  Session/                  séance, enregistrement, export, reprise, plan Santé
  Diagnostics/              journal horodaté, test de démarrage
  Simulation/               tapis FTMS simulé au niveau des octets
  Tests/                    90 tests XCTest
Foulee/                   App iOS (SwiftUI, CoreBluetooth, HealthKit, SwiftData, Charts)
FouleeWatch/              App watchOS (HKWorkoutSession, HKLiveWorkoutBuilder, miroir)
docs/FTMS.md              Formats d'octets, règles de la file de commandes
docs/VALIDATION_MATERIELLE.md   Procédure de test à faible vitesse
.github/workflows/ci.yml  Tests Linux + macOS, build iOS/watchOS avec xcodebuild
```

Toute la logique sensible (protocole, séquences, moteur, compteurs, zones) est
dans **TreadCore**, testable sans iPhone. L'app ne fait que brancher
CoreBluetooth, HealthKit et l'interface.

## 2. Versions minimales

| Cible | Minimum | Raison |
|-------|---------|--------|
| iOS | **17.0** | SwiftData, framework Observation (`@Observable`), réception du miroir d'exercice Watch (`workoutSessionMirroringStartHandler`), `MainActor.assumeIsolated` |
| watchOS | **10.0** | `startMirroringToCompanionDevice()` et `sendToRemoteWorkoutSession(data:)` |
| Xcode | **16** ou plus récent | format de projet 77 (dossiers synchronisés : tout fichier ajouté dans `Foulee/` ou `FouleeWatch/` est compilé automatiquement) |

Le code est en Swift 5 (mode de langage), concurrence stricte minimale ; la CI
compile avec la version d'Xcode par défaut du runner `macos-15`.

## 3. Installation sur iPhone et Apple Watch

Prérequis : un Mac avec Xcode 16+, un identifiant Apple (compte gratuit
possible, voir plus bas), un câble pour l'iPhone, une Apple Watch jumelée.

1. **Cloner** le dépôt puis ouvrir `Foulee.xcodeproj`.
2. **Signature** — modifier une seule fois `Config/Signing.xcconfig` :
   ```
   BUNDLE_ID_PREFIX = com.votrenom.foulee   // unique pour vous
   DEVELOPMENT_TEAM = ABCDE12345             // ou laisser vide (étape 3)
   ```
   L'app Watch prend automatiquement l'identifiant `$(BUNDLE_ID_PREFIX).watchkitapp`.
3. Dans Xcode, *Settings › Accounts* : ajouter votre identifiant Apple. Si
   `DEVELOPMENT_TEAM` est vide, sélectionner l'équipe dans l'onglet
   *Signing & Capabilities* des targets **Foulee** et **FouleeWatch**.
4. **iPhone** : le brancher, activer *Réglages › Confidentialité et sécurité ›
   Mode développeur* (redémarrage demandé), puis choisir le scheme **Foulee** et
   l'iPhone comme destination, et lancer (⌘R). Au premier lancement, autoriser
   le développeur dans *Réglages › Général › VPN et gestion de l'appareil*.
5. **Apple Watch** : activer aussi le *Mode développeur* sur la Watch
   (*Réglages › Confidentialité et sécurité*). L'app Watch est intégrée à l'app
   iPhone : elle s'installe via l'app *Watch* de l'iPhone (section « Apps
   disponibles ») ou directement depuis Xcode avec le scheme **FouleeWatch** et
   la Watch comme destination (plus fiable pour la première installation).
6. Tests du cœur : scheme **Foulee** › *Product › Test* (⌘U), ou en ligne de
   commande `swift test --package-path TreadCore`.

**Compte gratuit (Personal Team)** : les profils expirent au bout de 7 jours
(il suffit de relancer depuis Xcode). Si Xcode refuse la capacité HealthKit
pour votre type de compte, voir [Dépannage](#14-dépannage).

## 4. Autorisations

| Autorisation | Où | Pourquoi |
|--------------|----|----------|
| Bluetooth | iPhone | se connecter au tapis (FTMS 0x1826) et à une ceinture (0x180D) |
| Santé — lecture des exercices | iPhone | vérifier qu'une séance n'est pas déjà enregistrée (pas de doublon) |
| Santé — écriture exercice, FC, distance, énergie | iPhone | seulement si vous activez Apple Santé dans les réglages |
| Santé — FC, pas, énergie, exercice | Watch | session d'exercice réelle et envoi en direct à l'iPhone |

Modes d'arrière-plan déclarés : `bluetooth-central` et `workout-processing`
(iPhone), `workout-processing` (Watch). L'app reste entièrement utilisable si
l'accès Santé est refusé.

## 5. Premier appairage

1. Fermer Kinni / Treadmill Assistant (un seul client FTMS à la fois).
2. *Réglages › Tapis › Rechercher un tapis* → choisir **URTM047**. Le profil
   « UREVO FoldiMix 5L (URTM047) » est sélectionné d'après le nom. Le tapis est
   mémorisé et le lien se reconnecte automatiquement aux prochains lancements
   (**sans jamais envoyer de commande**).
3. Vérifier *Capacités lues* : 1–12 km/h pas 0,1 et 0–9 % pas 1 attendus.
4. Cardio : *Réglages › Source cardio* — rechercher une ceinture, ou laisser
   « Lancer l'exercice Watch avec la séance » activé.
5. Suivre ensuite [la procédure de validation à faible vitesse](docs/VALIDATION_MATERIELLE.md).

## 6. Utilisation

**Séance** : choisir un programme (ou « Séance libre ») puis **Démarrer le
tapis**. Le chrono démarre quand le mouvement est réellement observé.
Pendant la séance : vitesse et inclinaison **réelles** (télémétrie), cibles et
écart, FC avec source et ancienneté, zone colorée, pas (avec provenance),
distance, temps actif et restant, phase actuelle et suivante.

- **Pause / Reprendre / Arrêter** toujours visibles en bas d'écran.
- **+ / −** : modification manuelle qui remplace la consigne jusqu'au prochain
  palier (bandeau « Consigne manuelle… »).
- **Phase suivante** : passe immédiatement au palier suivant.
- Écarts consigne/mesure affichés en bandeau ; une valeur demandée n'est jamais
  présentée comme une mesure.

**Programmes** : créer, modifier, dupliquer (balayage ou appui long),
supprimer, réorganiser (bouton Modifier). Phases avec nom, type (échauffement,
effort, récupération, allure stable, retour au calme), durée, vitesse,
inclinaison, zone cible facultative ; blocs répétés ; aperçu graphique et durée
totale. Import/export JSON versionné (`"format": "foulee.programs",
"formatVersion": 1`), validé à l'import. Les phases incompatibles avec le tapis
sont **signalées et bloquent le lancement** ; rien n'est corrigé en silence.

**Historique** : détail avec graphiques FC / vitesse / inclinaison (mesure et
cible), temps par zone, événements (pertes de connexion, écarts, phases…),
export JSON et CSV, « Enregistrer comme modèle ».

## 7. Bluetooth FTMS et profil URTM047

Détails des octets : [docs/FTMS.md](docs/FTMS.md).

- Connexion : lecture de *Feature* et des plages, activation des notifications
  (Treadmill Data, Status, Training Status) et des **indications du Control
  Point avant toute commande**.
- File série : une commande à la fois, réponse attendue avec délai ; aucune
  répétition automatique ; Stop/Pause prioritaires ; double démarrage impossible.
- Trois niveaux distincts pour chaque consigne : **demandée** → **acquittée**
  (réponse succès) → **mesurée** (télémétrie), plus la consigne **annoncée**
  par le tapis (statut). Visible dans *Réglages › Diagnostic*.
- Couche de **profils matériels** séparée (`TreadmillProfile`) : séquence de
  démarrage/reprise, vitesse initiale, délais, tolérances, nombre de renvois.

**Profil URTM047** — faits observés : 1–12 km/h pas 0,1 ; 0–9 % pas 1 ;
inclinaison fonctionnelle ; seule la séquence `Request Control → Set Target
Speed → Start` a produit un mouvement ; des consignes de vitesse peuvent être
acquittées sans effet ; Treadmill Assistant fonctionne sur ce tapis.

La séquence de démarrage n'est **pas** considérée comme la cause certaine du
problème de vitesse (hypothèses détaillées dans [docs/FTMS.md](docs/FTMS.md)).
Le profil applique donc les choix prudents :
`Request Control → Set Target Speed 1,0 km/h → Start` → attente du mouvement →
**attente d'une vitesse stable 2 s** (max 8 s) → consigne du palier. Le tapis
démarre toujours à 1,0 km/h : pendant ces quelques secondes, la vitesse réelle
(1,0) diffère normalement de la consigne affichée en bas d'écran.
Pas de nouveau Start lors des changements de vitesse. Si la vitesse n'est pas
observée dans le délai calculé, **un seul** renvoi de la consigne, puis écart
affiché et journalisé. Pas de séquences expérimentales pendant une séance :
les tests actifs du diagnostic (démarrage, **réponse en vitesse**) sont lancés
explicitement, hors du tapis, et utilisent le même code que les séances.

**Diagnostic** (*Réglages › Diagnostic et journaux*) : état du lien, consignes à
trois niveaux, exploration GATT passive, **test de démarrage actif** (confirmé
explicitement, hors du tapis), **test de réponse en vitesse** (trois
consignes en marche, avec ou sans Request Control préalable, résultat par
consigne), journal horodaté à la milliseconde (commandes,
octets, réponses, statuts, télémétrie) exportable en texte ou JSON.

## 8. Cardio, zones, pas et énergie

**Sources cardio** : ceinture/brassard BLE, Apple Watch (session d'exercice
watchOS réelle, envoyée en direct par miroir HealthKit, repli WatchConnectivity),
capteur du tapis. Une seule source active (choix manuel ou automatique
ceinture > Watch > tapis, sans mélange). Source et ancienneté affichées ; une
mesure périmée (> 5 s ceinture/tapis, > 10 s Watch) s'affiche « — ». L'iPhone
ne lit jamais d'anciens échantillons Santé pour simuler du direct.

**Zones** : 5 zones ; FC max 200 bpm par défaut ; % de FC max, réserve
cardiaque (Karvonen, si FC de repos renseignée) ou seuils en bpm ; méthode
affichée ; temps par zone ; alertes facultatives avec temporisation (séjour
continu hors zone, délai entre alertes). Pas de pilotage du tapis par la FC.

**Pas** : priorité au tapis (champ d'extension, s'il existe), puis Apple Watch,
puis estimation facultative marquée « estimée », sinon « — ». Pas de la séance
uniquement, jamais additionnés entre sources ; compteurs cumulatifs gérés
(référence initiale, remise à zéro par le tapis, débordement, reconnexion,
sauts aberrants ignorés). Même mécanisme pour la distance et l'énergie du tapis.

**Énergie** : calories du tapis, énergie active de la Watch et estimation ACSM
(si poids renseigné) conservées séparément.

## 9. Historique et Apple Santé

Chaque séance est sauvegardée localement (SwiftData) avec un identifiant
unique ; une sauvegarde répétée met à jour au lieu de dupliquer.

**Propriétaire unique de l'enregistrement Santé** :
- un exercice Apple Watch a tourné pendant la séance → **la Watch enregistre**
  l'exercice (FC, énergie, pas qu'elle mesure) ; l'iPhone n'écrit rien ;
- sinon, si activé → **l'iPhone enregistre** un exercice marche/course en
  intérieur : FC de la ceinture/du tapis, distance du tapis (option), énergie
  du tapis (option, désactivée par défaut).

Les pas ne sont jamais écrits (déjà comptés par l'iPhone/la Watch). Avant
écriture, l'app cherche un exercice portant `HKMetadataKeyExternalUUID` = id de
séance : jamais deux fois la même séance. Les séances simulées ne sont jamais
écrites.

## 10. Arrière-plan et robustesse

| Situation | Comportement |
|-----------|-------------|
| Programme en cours | écran maintenu allumé par défaut (réglable) |
| App en arrière-plan / écran verrouillé | iOS peut suspendre les timers. Le mode `bluetooth-central` maintient la réception des notifications du tapis, et **chaque paquet fait avancer le programme**. Base de temps monotone (`CLOCK_MONOTONIC`) : au réveil, la phase correcte est retrouvée ; les phases entièrement écoulées entre-temps sont journalisées et leurs consignes ne sont pas rejouées. Aucune garantie de régularité : gardez l'app au premier plan pendant un programme. |
| Perte Bluetooth | bandeau rouge, séance en pause, l'app **n'affirme jamais** avoir arrêté le tapis ; reconnexion du lien automatique, **aucune commande** sans action |
| Clé de sécurité / arrêt sur le tapis | séance en pause, reprise uniquement sur action |
| Fermeture forcée / plantage | point de sauvegarde toutes les 15 s et à chaque pause/mise en arrière-plan ; au relancement la séance est ajoutée à l'historique (« Interrompue »), **sans redémarrer le tapis** |
| Watch | session d'exercice watchOS, active écran éteint (`workout-processing`) |

## 11. Mode simulateur

*Réglages › Tapis › Mode simulateur* (ou depuis la recherche de tapis).
Un tapis FTMS est simulé **au niveau des octets** : mêmes décodeurs, même file
de commandes, même contrôleur que le BLE réel. Il reproduit les comportements
supposés de l'URTM047 (Start sans consigne préalable sans effet, consigne
pendant le compte à rebours acquittée mais ignorée). Pastille violette
« SIMULATEUR » partout ; séances marquées « Simulé » et jamais écrites dans Santé.

## 12. Ce qui compile, ce qui est testé, ce qui reste à valider

**Compile (CI GitHub Actions, `xcodebuild`, Xcode 16.4 / Swift 6.1.2, macOS 15)** —
voir l'onglet *Actions* du dépôt ; aucun avertissement du compilateur Swift :
- app iOS + app Watch embarquée pour le simulateur iOS ;
- app watchOS seule pour le simulateur watchOS ;
- app iOS pour appareil (Release, sans signature).

La signature réelle (votre équipe, profils, capacité HealthKit) n'est pas
vérifiable en CI : elle se fait dans Xcode sur votre Mac.

**Testé automatiquement** (90 tests, sous Linux et macOS) :
- décodage FTMS : flags optionnels, bit More Data inversé, valeurs « non
  disponible », paquets tronqués et octets en trop, plages, Feature, statuts,
  Control Point, FC (uint8/uint16, contact, RR) ;
- encodage et arrondi des consignes ;
- file de commandes : sérialisation, espacement, réponses négatives, délai sans
  répétition, réponses tardives/inattendues, fusion des consignes, priorité Stop,
  double Start, erreur d'écriture, perte de lien ;
- hypothèse « consigne ignorée pendant l'accélération » : avec l'attente de
  stabilisation aucune consigne n'est perdue, sans elle seul le renvoi la
  rattrape ; test de réponse en vitesse sur tapis sain et sur tapis qui ignore
  les consignes ;
- consigne sans réponse (cas réel URTM047 du 23/10) : démarrage qui continue et
  vitesse vérifiée par la télémétrie, profil générique strict, acquittement
  implicite par statut, acquittement tardif, absence de réponse + absence
  d'effet signalée comme écart ;
- séquence URTM047 (ordre exact, pas de Start supplémentaire), séquence
  générique sans mouvement, commande acquittée mais vitesse non observée (un
  seul renvoi puis écart), pause/reprise/arrêt confirmé par la télémétrie, clé
  de sécurité, perte BLE sans redémarrage automatique ;
- programmes : blocs, durées, pause/reprise, phases écoulées pendant une
  suspension, saut de phase, fin, validation contre les capacités, JSON ;
- zones (3 méthodes), temps par zone, alertes temporisées, FC périmée, source
  unique ;
- compteurs : remise à zéro, débordement, saut aberrant, reconnexion ; pas
  (priorité, pas d'addition, estimation) ;
- séance complète simulée, modification manuelle, perte de connexion, reprise
  après crash, export CSV/JSON, modèle depuis séance, plan Santé idempotent.

**Nécessite une validation physique** (non vérifiable sans votre matériel) :
- la séquence de démarrage et le comportement réel de l'URTM047 (délais,
  accélération, réponse aux consignes) ;
- l'interface et l'ergonomie sur iPhone réel ;
- le miroir d'exercice Apple Watch → iPhone et l'enregistrement Santé ;
- la connexion à votre ceinture cardio ;
- le comportement écran verrouillé.

Le rapport FTMS et les captures annoncés **n'étaient pas présents** dans le
dépôt au moment du développement : l'implémentation suit la spécification et
vos observations écrites. Exportez le journal de diagnostic après la
[procédure de validation](docs/VALIDATION_MATERIELLE.md) pour ajuster le profil.

## 13. Limites restantes

1. La cause du problème « consigne de vitesse acquittée sans effet » n'est pas
   établie ; le profil URTM047 réduit les risques connus mais ses délais,
   l'accélération (0,25 km/h/s supposée) et l'attente de stabilisation sont à
   ajuster d'après le journal et le test de réponse en vitesse.
2. Pas du tapis : uniquement via le champ d'extension bit 13 ; si le tapis
   expose ses pas autrement (service propriétaire), ce n'est pas décodé (le
   diagnostic GATT permet de le repérer).
3. Arrière-plan : progression du programme non garantie si iOS suspend l'app
   et que le tapis n'envoie plus de notifications.
4. Un Stop envoyé pendant qu'une autre commande attend sa réponse part après
   cette réponse ou son délai (4 s max) : la clé de sécurité reste la
   protection de référence.
5. Pas de restauration d'état CoreBluetooth après que iOS a tué l'app.
6. Zones calculées sur l'iPhone ; la Watch affiche la FC brute.
7. Pas de pilotage par la FC, pas de Live Activity/widget, pas de
   synchronisation iCloud (volontairement hors V1).
8. Énergie du tapis écrite dans Santé comme énergie active alors qu'il s'agit
   souvent d'une estimation brute : désactivé par défaut.
9. Interface en français uniquement ; textes non externalisés dans un catalogue.

## 14. Dépannage

- **« Ce périphérique n'expose pas le service FTMS 0x1826 »** : mauvais appareil
  ou tapis déjà connecté à une autre app.
- **Le tapis ne démarre pas** : exporter le journal ; vérifier `[REP] … → succès`
  et l'absence de `[DATA] v=` non nul. Essayer le profil « FTMS générique »
  (*Réglages › Tapis › Profil*) uniquement hors du tapis.
- **HealthKit refusé à la signature** (certains comptes gratuits) : dans les
  deux targets, onglet *Signing & Capabilities*, supprimer la capacité
  HealthKit (ou vider `Config/*.entitlements`). Le tapis, la ceinture, les
  programmes et l'historique fonctionnent ; Santé et le cardio Apple Watch sont
  alors indisponibles.
- **« Unable to launch watch app » / « App Foulée non installée »** : l'app
  n'est pas sur la montre. Activer le Mode développeur de la Watch, puis
  l'installer via l'app Watch de l'iPhone (*Mes montres › Apps disponibles*) ou
  depuis Xcode (scheme **FouleeWatch**, destination la Watch). Les deux
  identifiants partagent le même préfixe ; la CI vérifie que l'app Watch est
  bien embarquée dans l'app iPhone.
- **« Démarrage interrompu : Set Target Speed (initiale) sans réponse »** :
  comportement observé sur l'URTM047 avec une version antérieure de l'app ;
  le profil URTM047 tolère désormais une consigne sans réponse et la vérifie
  par la télémétrie. Mettez à jour (git pull) et recompilez.
- **Identifiant déjà utilisé** : changer `BUNDLE_ID_PREFIX`.
