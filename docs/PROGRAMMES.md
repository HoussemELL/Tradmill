# Programmes prédéfinis, pilotage Zone 2 et Apple Watch

Toutes les vitesses sont en km/h. Les programmes sont installés au premier lancement (et
ajoutés à une installation existante). Ils sont tous **verrouillés** (révision 5) : chaque
séance est comparée aux précédentes du même programme (*Historique › Progression*). Pour une
variante, dupliquez-le ; *Programmes › + › Réinitialiser les programmes prédéfinis* les remet en place.

## 1. La bibliothèque (révision 5)

Inclinaison minimale **1 %** dans toutes les phases (Incline Walk monte à 2 %). Les programmes
déjà installés sont **mis à jour en place** (mêmes identifiants, aucun doublon) ; un programme
prédéfini que vous aviez supprimé n'est pas réinstallé ; vos programmes personnels ne changent pas.

| Programme | Durée | Étapes (durée · km/h · %) |
|---|---|---|
| **Zone 2 Auto** ❤️ | 35 min | 5 min 4,0 → 5,5 progressif · 1 → 25 min pilotées par la FC (départ : vitesse tenue en zone 2 la dernière fois, sinon 5,8 ; limites 4–8,5) · 1 → 5 min 4,0 → 3,5 · 1 |
| **Cardio Baseline** | 30 min | 5 min · 4,0 · 1 → 20 min · 6,0 · 1 → 5 min · 3,8 · 1 |
| **Zone 2 Endurance** | 35 min | 5 min · 4,0 · 1 → 5 min · 5,5 · 1 → 20 min · 6,0 · 1 → 5 min · 3,8 · 1 |
| **Interval Run 9/11** | 30 min | 3 min · 4,0 → 3 min · 5,0 → 2 min · 6,0 → 6 × (1 min · 9,0 + 1 min · 5,0) → 2 min · 11,0 → 3 min · 4,0 → 5 min · 3,8 (tout à 1 %) |
| **Football Endurance · Niveau 1** | 35 min | échauffement 4 min · 4,5 + 4 min · 5,5 + 2 min · 6,5 → 3 × 3 min · 8,5 avec 3 min · 5,0 **entre** les efforts → 5 min · 6,0 → 5 min · 4,0 (1 %) |
| **Football Endurance · Niveau 2** | 41 min | même échauffement → 4 × 3 min · 8,5, 3 min · 5,0 entre → 5 min · 6,0 → 5 min · 4,0 (1 %) |
| **Football Endurance · Niveau 3** ⚠️ | 45 min | même échauffement → 4 × 4 min · 9,0, 3 min · 5,0 entre → 5 min · 6,0 → 5 min · 4,0 (1 %) |
| **HIIT Run 11** ⚠️ | 35 min | 4 min · 4,0 → 4 min · 5,5 → 2 min · 7,0 → 4 × (2 min · 11,0 + 3 min · 4,5) → 5 min · 3,8 (1 %) |
| **Incline Walk** | 30 min | 5 min · 4,0 · 1 → 5 min · 5,5 · 1 → 15 min · 5,5 · 2 → 5 min · 3,8 · 1 |
| **Post-Meal Walk** | 15 min | 2 min · 3,5 → 10 min · 4,5 → 3 min · 3,5 (1 %) |

⚠️ **Avancé** : jamais sélectionné par défaut ni proposé comme progression automatique ; le
départ (iPhone ou Watch) demande une confirmation explicite. Football Endurance : niveau 1 par
défaut, niveaux 2 et 3 affichés comme progressions.

- **Seul Zone 2 Auto règle la vitesse selon la FC**, jamais l'inclinaison (1 % fixe).
- **Cardio Baseline** : verrouillé, aucun ajustement automatique. Le protocole à 1 % est la nouvelle
  référence : son empreinte diffère de l'ancien protocole à 0 %, les anciens tests forment donc une
  série distincte dans *Progression* et ne lui sont jamais comparés.
- Interval Run 9/11, HIIT Run 11 : les blocs répétés gardent une récupération après le dernier
  effort (comme demandé). Football Endurance : récupération uniquement **entre** les efforts
  (étapes explicites, donc modifiables une à une).

### Organisation (bibliothèque d'alternatives, pas un plan hebdomadaire)

| Rôle | Programme |
|---|---|
| Endurance principale | Zone 2 Auto |
| Test de référence (toutes les 2 semaines, à la place de Zone 2) | Cardio Baseline |
| Fractionné principal | Interval Run 9/11 |
| Alternative au fractionné, préparation football | Football Endurance (niveau 1, puis 2, puis 3) |
| Progression avancée | HIIT Run 11 |
| Alternative de marche | Incline Walk |
| Activité légère complémentaire | Post-Meal Walk |

Foulée ne recommande aucune séance automatiquement. Une semaine avec un match intense, trois
séances de musculation et une cheville à ménager, privilégiez Zone 2 Auto ou une marche plutôt
qu'un second fractionné intense.

### Unités d'inclinaison

Foulée envoie et lit l'inclinaison en **%** (champ FTMS *Inclination*, résolution 0,1 %) et
vérifie chaque valeur contre la plage et le pas annoncés par le tapis (UREVO URTM047 : 0–9 %,
pas 1 d'après le diagnostic). Si le tapis affiche des **niveaux** plutôt que des pourcentages,
la correspondance n'est pas garantie : voir le contrôle dans
[VALIDATION_MATERIELLE.md](VALIDATION_MATERIELLE.md).

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

**Protocole 3 (révision 5, 25/10) : pilotage centré sur la zone.** Constat sur une séance réelle :
plafond de 7,0 km/h atteint avec une FC encore sous la zone 2 ; la zone n'était atteinte qu'en fin
de séance. Désormais :

| Paramètre | Zone 2 Auto (protocole 3) |
|---|---|
| Limites automatiques | **4,0–8,5 km/h** (plus celles du tapis) |
| Départ | **vitesse mesurée pendant que la FC était en zone 2 lors de la dernière séance Zone 2 Auto** (≥ 2 min en zone), sinon 5,8 km/h |
| Sous la zone | palier selon l'écart : **+0,5** si ≥ 15 bpm sous la zone, **+0,3** si ≥ 8, sinon +0,2 ; au plus une accélération par minute ; **aucune** si la FC monte déjà assez vite pour entrer dans la zone dans la minute (tendance sur 60 s) |
| Dans la zone | vitesse maintenue ; **−0,2 anticipé** si la FC monte vite vers la limite haute ; +0,2 vers le milieu si elle reste dans le bas de la zone sans monter |
| Au-dessus | inchangé (ci-dessous) |

Nouvelle empreinte : les séances Zone 2 Auto suivantes forment une nouvelle série de comparaison.
Un plafond automatique ≥ 8 km/h ne fait pas passer l'exercice Watch en « course » (allure prévue
= vitesse de départ).

Réglages du pilotage d'origine (programmes personnels, éditeur de phase, *Vitesse › Pilotée par la FC*) :

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
| Sans FC | aucune accélération, immédiatement ; vitesse figée 15 s (mesure retardée de la montre), puis −0,2 toutes les 5 s jusqu'à 4,5 km/h |

**Sécurité**
- FC indisponible (ceinture/Watch muette, Watch déconnectée → mesure périmée après 5 à 10 s) :
  les accélérations sont désactivées immédiatement et la vitesse est figée ; si la FC ne revient
  pas dans les 15 s, alerte (bandeau + vibration) et retour progressif à l'allure de sécurité tant
  que le tapis est pilotable. (Les tests simulateur ont montré que la FC de la montre arrive par
  à-coups : sans ce délai, un seul message retardé faisait ralentir le tapis.) Quand la FC revient, le
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

L'app Watch est une télécommande et un écran de suivi de vos programmes ; l'iPhone reste le
seul à piloter le tapis (FTMS), la montre fournit la FC (HKWorkoutSession + HKLiveWorkoutBuilder).

**Accueil** :
- état de l'iPhone et du tapis (« URTM047 prêt », « Tapis non connecté », « iPhone injoignable ») ;
- **Mes programmes** : tous les programmes de l'iPhone (prédéfinis et personnels, dans le même
  ordre), avec durée, vitesse max, frise des étapes, badges *FC auto* et *verrouillé* ;
- une séance en cours sur l'iPhone peut être **suivie** depuis la montre ;
- *Autres* (secondaire) : séance libre sur le tapis, exercice sans tapis (marche/course, FC seule).

**Détail d'un programme** : durée, vitesse et inclinaison max, toutes les étapes (blocs
répétés compris) avec durée, vitesse (fixe, progressive ou automatique) et inclinaison, notes,
bouton **Démarrer** (désactivé avec la raison si le tapis n'est pas prêt).

**Lancement depuis la montre** : *Démarrer* → confirmation → la montre demande à l'iPhone de
démarrer ce programme. L'iPhone vérifie (tapis connecté — il tente le tapis mémorisé pendant 12 s —,
pas d'autre séance, programme compatible, demande de moins de 20 s ; la montre attend 30 s avant d'annoncer l'échec), démarre le tapis puis répond ;
la montre ne lance son exercice qu'après l'acceptation. En cas de refus, la raison s'affiche et
rien ne démarre.

**Séance en cours** (pages horizontales, comme l'app Exercice) :
1. *Commandes* (à gauche) : Arrêter, Pause/Reprendre, Pilotage FC ;
2. *Mesures* : phase et temps restant, FC, zone colorée et bornes, position dans la zone,
   vitesse, inclinaison, durée ;
3. *Programme* : étape en cours, reste, progression du programme, consignes, étape suivante,
   état du pilotage FC, alertes ;
4. *Temps par zone*.

**Synchronisation** :
- catalogue + état du tapis publiés par l'iPhone via `applicationContext` (dernier état gagnant,
  livré même si la montre était hors de portée ; vérifié toutes les 2 s, republié s'il change) ;
- état de séance envoyé chaque seconde (miroir HealthKit, sinon WatchConnectivity) ;
- commandes de la montre **liées à la séance et horodatées** : l'iPhone ignore une commande
  pour une autre séance, une pause de plus de 30 s, et **ne rejoue jamais une reprise retardée**
  (> 8 s) ; un arrêt non remis est mis en file (appliqué s'il arrive dans les 2 min) ;
- pause ou arrêt sur l'iPhone → la montre suit (état en direct + commande de l'exercice) ;
- iPhone injoignable pendant un arrêt depuis la montre : l'exercice se termine et la montre
  demande d'arrêter le tapis avec son bouton ou la clé de sécurité ;
- aucune déconnexion ne provoque d'accélération ni de redémarrage : perte de FC → plus
  d'accélération et retour progressif à 4,5 km/h ; perte du tapis → pause, rien ne redémarre.

**Zones** : HealthKit ne donne pas accès aux zones personnalisées réglées dans l'app Exercice.
Foulée calcule par défaut les mêmes zones que l'Apple Watch (réserve cardiaque, FC max et de
repos lues dans Santé). Si vous avez modifié vos zones sur la montre, recopiez-les dans
*Réglages › FC max et zones › Partir de ces zones pour saisir mes seuils*. Les bornes sont
envoyées à la montre et mémorisées pour une séance sans iPhone.

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
