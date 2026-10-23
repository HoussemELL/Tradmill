# Programmes prédéfinis, pilotage Zone 2 et Apple Watch

Toutes les vitesses sont en km/h. Les programmes sont installés au premier lancement (et
ajoutés à une installation existante). Ils restent modifiables et duplicables ; *Programmes ›
+ › Restaurer / Réinitialiser les programmes prédéfinis* les remet en place.

## 1. Les 7 programmes

| Programme | Durée | Étapes (durée · vitesse · inclinaison) |
|---|---|---|
| **Cardio Baseline** 🔒 | 30 min | 5 min · 4,0 · 0 % → 20 min · 6,0 · 0 % → 5 min · 3,8 · 0 % |
| **Zone 2 Endurance** | 35 min | 5 min · 4,0 · 0 % → 5 min · 5,5 · 0 % → 20 min · 6,0 · 1 % → 5 min · 3,8 · 0 % |
| **Interval Run 9/11** | 30 min | 3 min · 4,0 → 3 min · 5,0 → 2 min · 6,0 → 6 × (1 min · 9,0 + 1 min · 5,0) → 2 min · 11,0 → 3 min · 4,0 → 5 min · 3,8 (0 %) |
| **HIIT Run 11** | 35 min | 4 min · 4,0 → 4 min · 5,5 → 2 min · 7,0 → 4 × (2 min · 11,0 + 3 min · 4,5) → 5 min · 3,8 (0 %) — progression ultérieure |
| **Incline Walk** | 30 min | 5 min · 4,0 · 0 % → 5 min · 5,5 · 1 % → 15 min · 5,5 · 2 % → 5 min · 3,8 · 0 % |
| **Post-Meal Walk** | 15 min | 2 min · 3,5 → 10 min · 4,5 → 3 min · 3,5 (0 %) |
| **Zone 2 Auto** ❤️ | 35 min | 5 min · 4,0 → 5,5 progressif → 25 min pilotées par la FC (départ 5,8, limites 4–7) → 5 min · 4,0 → 3,5 progressif (0 %) |

- **Seul Zone 2 Auto règle la vitesse selon la FC.** Dans les six autres, la zone cible d'une
  phase sert à l'affichage et aux alertes (désactivées par défaut), jamais à accélérer.
- **Zone 2 Endurance** : les 6 km/h sont un réglage de départ, à ajuster avec +/−
  selon votre FC (à 5,5 km/h vous êtes souvent en haut de la zone 1).
- **Cardio Baseline est verrouillé** : ses étapes ne se modifient qu'après « Déverrouiller »
  (avec avertissement). Pour une variante, dupliquez-le. Pendant la séance, une consigne
  manuelle ou une phase passée marque la séance « non comparable » (bandeau).

## 2. Transitions et limites du tapis

- Toutes les consignes sont validées contre les capacités lues sur le tapis (plage et
  incrément) avant le départ ; une valeur hors limites bloque le lancement, rien n'est corrigé
  en silence.
- **Transitions progressives** (activées par défaut, *Réglages › Séance*) : un écart de plus
  de 1 km/h entre deux phases est franchi par paliers de 1 km/h ; chaque palier part quand la
  vitesse mesurée a rejoint le précédent (6 s au plus). Exemple 6 → 9 km/h : 7, 8, 9.
  *Pause* et *Arrêter* restent immédiats ; +/− s'appliquent tout de suite.
- Phases progressives (rampes) : la consigne suit la droite début → fin par incréments du
  tapis (4,0 → 5,5 en 5 min : +0,1 toutes les 20 s).

## 3. Pilotage Zone 2 (programme Zone 2 Auto)

Réglages par défaut (modifiables dans l'éditeur de phase, *Vitesse › Pilotée par la FC*) :

| Paramètre | Défaut |
|---|---|
| Zone visée | 2 (bornes de *Réglages › FC max et zones*) |
| Limites automatiques | 4,0–7,0 km/h (plus celles du tapis) |
| Départ | 5,8 km/h |
| Palier | 0,2 km/h |
| FC filtrée | moyenne glissante sur 18 s (≥ 3 mesures sur au moins 9 s) |
| Entre deux accélérations | 60 s (et 60 s après tout changement) |
| Ralentissement | FC ≥ limite haute − 3 bpm pendant 20 s → −0,2 ; puis toutes les 20 s ; −0,4 si FC > limite haute + 5 |
| Dans la zone | vitesse maintenue ; dans le quart bas de la zone, +0,2 toutes les 120 s au plus (viser le milieu, désactivable) |
| Sans FC | aucune accélération, −0,2 toutes les 5 s jusqu'à 4,5 km/h |

**Sécurité**
- FC indisponible (ceinture/Watch muette, Watch déconnectée → mesure périmée après 5 à 10 s) :
  les accélérations sont désactivées immédiatement, alerte (bandeau + vibration), retour
  progressif à l'allure de sécurité tant que le tapis est pilotable. Quand la FC revient, le
  pilotage reprend, sans accélération avant 60 s.
- Tapis non pilotable (connexion BLE perdue) : la séance se met en pause, le pilotage est
  suspendu, rien ne redémarre sans votre action.
- **Contrôle manuel prioritaire** : un appui sur +/− (iPhone) retire immédiatement le pilote ;
  *Réactiver le pilotage FC* (iPhone ou Watch) le relance depuis la vitesse actuelle, sans saut.
- *Arrêter* reste accessible en permanence (iPhone et Watch) ; la clé de sécurité reste la
  protection de référence.

## 4. Bilans et progression

Après chaque séance (écran de fin et *Historique*) :
- FC moyenne et maximale, vitesse moyenne et maximale ;
- **courbes superposées vitesse / FC** (vitesse à gauche, FC à droite, bande de la zone visée) ;
- **par intervalle** : vitesse moyenne, FC moyenne et maximale, récupération (baisse de FC
  dans les 60 s qui suivent un intervalle suivi d'une phase plus lente), % du temps en zone cible ;
- récupération après l'arrêt de la bande (1 et 2 min, avec une ceinture) ;
- Zone 2 Auto : % de la séance et de la phase pilotée en zone 2, **vitesse moyenne nécessaire
  pour rester en zone 2**, nombre d'ajustements (+, −, sécurité).

*Historique › Progression* regroupe les séances **de protocole identique** (même empreinte :
durées, vitesses, rampes, inclinaisons, réglages du pilote ; le nom ne compte pas) :
- programmes à vitesse fixe (Cardio Baseline…) : **FC de référence** = FC moyenne des
  10 dernières minutes de la phase principale (20 min à 6 km/h pour Cardio Baseline) ;
  une baisse à vitesse identique indique un progrès ;
- Zone 2 Auto : vitesse en zone 2 ; une hausse indique que vous allez plus vite pour la même
  intensité cardiaque ;
- une séance n'est **comparable** que si elle est complète, sans consigne manuelle ni phase
  passée, non interrompue, non simulée et avec assez de FC. Les autres sont affichées, grisées,
  avec la raison.

## 5. Apple Watch

App watchOS avec `HKWorkoutSession` + `HKLiveWorkoutBuilder`, en miroir vers l'iPhone
(WatchConnectivity en secours). L'iPhone pilote le tapis en FTMS ; la montre fournit la FC.

Pages (balayage vertical) :
1. **FC** en direct, **zone** colorée, **bornes** en bpm, **position dans la zone**, indication
   par rapport à la zone cible, durée ;
2. **Tapis** : durée, vitesse mesurée, consigne, inclinaison, **étape en cours, temps restant**,
   étape suivante, état du pilotage FC ;
3. **Temps par zone** ;
4. **Commandes** : *Arrêter* (arrête le tapis via l'iPhone, qui termine ensuite l'exercice ;
   sans réponse en 8 s, l'exercice est terminé sur la montre), *Pause/Reprendre*, *Pilotage FC*.

**Zones** : HealthKit ne donne pas accès aux zones personnalisées réglées dans l'app Exercice.
Foulée calcule par défaut les mêmes zones que l'Apple Watch (réserve cardiaque, FC max et de
repos lues dans Santé). Si vous avez modifié vos zones sur la montre, recopiez-les dans
*Réglages › FC max et zones › Partir de ces zones pour saisir mes seuils*. Les bornes sont
envoyées à la montre à chaque seconde de séance et mémorisées pour une séance sans iPhone.

**Doublons Santé** : la séance est enregistrée une seule fois — par la Watch si son exercice
tourne (l'iPhone n'écrit rien et ajoute ses métadonnées), sinon par l'iPhone (voir
[SANTE.md](SANTE.md)).

## 6. Ce qui est testé / à valider

Testé automatiquement (TreadCore, Linux et macOS) : segments exacts des 7 programmes et
validité sur le profil URTM047, empreinte de protocole, rampes, transitions par paliers (et
désactivation), filtre de FC, toutes les règles du pilote (accélération ≤ 1/min, maintien,
ralentissement, bornes, perte de FC, contrôle manuel, suspension), séance Zone 2 Auto complète
sur tapis simulé (FC simulée dépendant de la vitesse : > 50 % de la phase pilotée en zone 2),
programmes fixes jamais accélérés par la FC, statistiques par intervalle, récupération,
comparabilité et tendance Cardio Baseline, calcul des zones côté Watch identique à l'iPhone,
encodage des messages Watch.

À valider sur le matériel :
1. *Interval Run 9/11* en simulateur puis sur le tapis : vérifier les paliers 6 → 7 → 8 → 9 et
   9 → 8 → 7 → 6 → 5 dans le journal ; si le tapis accélère lui-même lentement, réduire ou
   désactiver les transitions progressives.
2. *Zone 2 Auto* avec la ceinture : retirer la ceinture 30 s pendant la phase pilotée →
   bandeau « FC indisponible », plus d'accélération, descente vers 4,5 km/h.
3. Watch : vérifier les 4 pages, *Pause* et *Arrêter* depuis la montre (le tapis doit
   s'arrêter), puis une seule séance dans Santé.
