# Tests dans les simulateurs iPhone + Apple Watch

Le workflow GitHub Actions **Simulateurs** (`.github/workflows/simulator.yml`) :
1. compile l'app iPhone (avec l'app Watch embarquée) pour le simulateur ;
2. crée un iPhone et une Apple Watch simulés **appairés**, installe les deux apps ;
3. exécute les scénarios de `scripts/sim/scenarios.json` (lancements avec arguments, captures,
   rapports JSON écrits par les apps, vérifications) ;
4. publie captures, rapports et `RESULTATS.md` sur la branche `ci-sim-results`.

Sur votre Mac (Xcode installé) :

```bash
xcodebuild -project Foulee.xcodeproj -scheme Foulee -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
python3 scripts/sim/run_scenarios.py build/dd/Build/Products/Debug-iphonesimulator/Foulee.app sim-out
open sim-out/RESULTATS.md
```

## Mode scénario (sans effet en usage normal)

Activé uniquement par l'argument `-FouleeScenario`. iPhone : tapis simulé, pas de demande Santé,
zones de test (FC max 185, repos 60 → Z2 = 135–148 bpm), programmes courts « Test Zone 2 Auto »
(30 s + 5 min pilotées + 30 s) et « Test enchaînement », FC simulée dépendant de la vitesse
(`-FouleeSimHR`), script d'actions (`-FouleeScript "pause@45,resume@60,linkloss@95,…"`).
Watch : exercice simulé sans HealthKit (`-FouleeSimulated`) dont la FC, calculée depuis la vitesse
reçue de l'iPhone, part par le **même chemin WatchConnectivity** qu'une vraie mesure ;
`-FouleeAutoStart <programme>` reproduit « choisir → Démarrer → confirmer ».

## Ce que le simulateur ne permet pas de vérifier

- le Bluetooth FTMS réel et le comportement du tapis URTM047 ;
- le capteur cardiaque de la montre et une ceinture Bluetooth réelle ;
- le miroir d'exercice HealthKit (`startMirroringToCompanionDevice`) et l'enregistrement Santé :
  dans les scénarios, la montre passe par WatchConnectivity ;
- l'arrière-plan (écran verrouillé, app suspendue), la portée Bluetooth/Wi-Fi entre les appareils.
