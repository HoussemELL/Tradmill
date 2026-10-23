# Temps par zone : règle commune Foulée / Rythme

## Décision (accord avec Rythme)

Rythme a retenu l'**option 1** : pour les séances Foulée, il affiche directement
`zones.secondsPerZone` du fichier partagé et utilise `zones.bounds` du fichier pour ses mesures
de zone 2 (temps en zone, vitesse tenue en zone). Ces deux champs sont donc **figés** : même
nom, même sens, même règle (`foulee.zones.v1`). Tout changement passe par `formatVersion` 2.

**Bornes** (identiques à Rythme et à l'Apple Watch) :
- une FC entière est dans une zone si FC ≥ borne exacte ;
- `zones.bounds` contient le **premier bpm entier** de chaque zone, c'est-à-dire l'arrondi
  supérieur de la borne exacte. Exemple : 139,4 → 140, donc 139 en Z1 et 140 en Z2 ;
- la FC de repos est la **moyenne décimale** Santé sur 30 jours, non arrondie
  (`zones.restingHRExact`). Une FC de repos saisie dans Foulée est entière ;
- à l'écran, Foulée affiche les bpm compris dans chaque zone : « Z1 ≤ 139 · Z2 140–152 · … ».

---

Message d'origine transmis à Rythme :

---

Bonjour,

Sur une même séance Cardio Baseline, Foulée affichait environ 8 min 14 s en zone 2 et Rythme
6 min. Trois causes peuvent produire cet écart. Foulée a corrigé ce qui dépendait d'elle ;
pour obtenir le même chiffre, il faut que Rythme applique la même règle sur les mêmes données.

## 1. Les trois sources d'écart

1. **Les bornes.** Autour de la limite Z1/Z2 (≈ 140 bpm sur cette séance), 1 ou 2 bpm d'écart
   déplacent plusieurs minutes d'une zone à l'autre. Foulée calcule FC max et FC de repos avec
   les règles de Rythme, mais la FC de repos est la moyenne Santé sur 30 jours au moment du
   calcul : elle peut différer de celle de Rythme.
2. **La période.** Foulée compte la bande en mouvement uniquement : du démarrage réel à l'arrêt
   réel, pauses exclues (30:00 sur cette séance). La séance Santé de la montre durait 28 min :
   l'exercice Watch avait démarré après la bande. C'est corrigé côté Foulée : l'exercice Watch
   est maintenant aligné sur le démarrage de la bande.
3. **La façon de compter.** Foulée comptait en continu tant qu'une FC « fraîche » existait (une
   mesure de la montre restait valable 10 s). Rythme compte probablement à partir des
   échantillons de FC de Santé, avec sa propre durée par échantillon.

## 2. La règle de Foulée (identifiant `foulee.zones.v1`)

Implémentée dans `SessionAnalysis.zoneSeconds` (TreadCore, testée). Elle est utilisée pour
l'affichage, l'historique, la progression et le fichier partagé.

- **Données :** `heartRate[]` du fichier `foulee.rythme.session` (`t` en secondes depuis
  `session.startDate`, `bpm`).
- **Période :** de `session.beltStartDate` à `session.beltStopDate`, moins les pauses
  (`events` de type `pause` → `resume`). Pas de compte à rebours, pas de récupération après
  l'arrêt.
- **Durée d'une mesure :** chaque mesure compte jusqu'à la mesure suivante, au plus **10 s**.
  Au-delà, le trou n'est pas compté. Seule la partie qui tombe dans la période est comptée.
- **Zone d'une mesure :** avec les 6 bornes `zones.bounds` (début Z1 … FC max), borne basse
  incluse, borne haute exclue, Z5 au-dessus.
  - Méthode `rythme` : tout ce qui est sous Z2 compte en Z1.
  - Autres méthodes : sous le début de Z1, index 0.
- **Résultat :** `zones.secondsPerZone` (index 0 = sous Z1, 1…5). `zones.rule` contient
  l'identifiant de la règle, et `zones.maxHRSource` / `zones.restingHRSource` l'origine des valeurs.

## 3. Ce que je te demande

1. **Choisis l'une des deux options :**
   - afficher directement `zones.secondsPerZone` pour les séances Foulée ;
   - ou recalculer avec la règle ci-dessus, à partir de `heartRate[]` et de **`zones.bounds` du
     fichier**, pas des bornes de Rythme.
2. **Si tu préfères garder tes propres bornes,** dis-moi ce qui diffère : FC max, FC de repos
   et leur méthode de calcul. Je les alignerai dans Foulée.
3. **Si ta règle diffère de la mienne,** décris-la (période, durée par échantillon, trous) :
   l'une des deux apps s'alignera, et la règle commune passera en `foulee.zones.v2`.

Merci !
