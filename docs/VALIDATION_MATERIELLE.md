# Procédure de validation matérielle — UREVO FoldiMix 5L (URTM047)

Objectif : vérifier sur votre tapis, **à faible vitesse et sans personne dessus**
pour les étapes 1 à 4, que la séquence de démarrage, les consignes et l'arrêt
fonctionnent comme prévu, puis valider une courte séance réelle.

Durée : environ 20 minutes. Gardez la **clé de sécurité attachée** pendant tout
le test et restez à portée du bouton d'arrêt physique.

## Préparation

1. Tapis branché, déplié, clé de sécurité en place, **personne sur la bande**.
2. iPhone à moins de 2 m du tapis. Fermez Kinni, Treadmill Assistant et toute
   autre app susceptible de se connecter au tapis (un seul client FTMS à la fois).
3. Dans Foulée : *Réglages › Diagnostic et journaux › Exporter › Effacer le journal*
   pour repartir d'un journal propre.

## 1. Connexion et capacités (passif, aucune commande)

1. *Réglages › Tapis › Rechercher un tapis* → choisir **URTM047**.
2. Vérifier que le profil affiché est « UREVO FoldiMix 5L (URTM047) ».
3. Dans *Réglages › Tapis*, section « Capacités lues », noter :
   - Vitesse : attendu **1,0–12,0 km/h, pas 0,10**, source « tapis » ;
   - Inclinaison : attendu **0–9 %, pas 1,0**, source « tapis ».
   Si la source indique « profil (non lue) », le tapis n'a pas répondu à la
   lecture : le noter, c'est une information importante.
4. *Diagnostic › Explorer les services GATT* (cocher « Écouter aussi les
   caractéristiques hors FTMS »). Cela liste tous les services et caractéristiques
   sans rien commander. Utile pour savoir si le tapis expose un compteur de pas
   propriétaire.

✅ Attendu : « Lien FTMS prêt (indications/notifications actives) » dans le
journal, et des lignes `[DATA] v=0.00 …` environ une fois par seconde.

## 2. Test de démarrage automatique (actif, hors du tapis)

1. *Diagnostic › Test de démarrage (hors du tapis)* → confirmer.
2. Le test exécute exactement la séquence des séances :
   `Request Control → Set Target Speed 1,5 km/h → Start → attente du mouvement →
   Set Target Speed 2,5 km/h → observation 8 s → Stop`.
3. Observer le tapis : il doit démarrer lentement, accélérer vers 2,5 km/h, puis
   s'arrêter.

✅ Attendu : « Test réussi » avec les lignes Mouvement, Consigne, Stabilité, Arrêt
en vert.

❌ Si « Start acquitté mais aucune vitesse observée » : le tapis n'a pas démarré
avec cette séquence. **Ne relancez pas en boucle** : exportez le journal (étape 6).

❌ Si « Consigne : 2,5 km/h acquittée mais mesure 1,5 » (ou 1,0) : le tapis
acquitte la commande sans l'appliquer — c'est le symptôme rapporté avec Kinni.
L'app a fait **un seul** renvoi de la consigne, sans nouveau Start. Exportez le
journal.

## 3. Consignes manuelles à basse vitesse (actif, hors du tapis)

1. *Séance › Programme : Séance libre* (départ 3,0 km/h par défaut ; vous pouvez
   le baisser dans *Réglages › Séance*).
2. **Démarrer le tapis**, sans monter dessus.
3. Après le démarrage, appuyer deux fois sur **+** (vitesse) : la tuile
   « Vitesse réelle » doit suivre la cible ; l'écart affiché doit revenir vers 0.
4. Appuyer une fois sur **+** (inclinaison) puis une fois sur **−** : vérifier
   que l'inclinaison réelle suit.
5. **Pause** : la bande doit s'arrêter ; l'état passe à « En pause » seulement
   quand la vitesse mesurée est nulle.
6. **Reprendre** : la séquence de reprise (Set Speed → Start) est envoyée une
   fois ; la vitesse doit revenir à la cible.
7. **Arrêter** : la séance se termine ; vérifier que le tapis s'arrête.

## 4. Perte de connexion (actif, hors du tapis)

1. Démarrer une séance libre à basse vitesse, sans monter sur le tapis.
2. Désactiver le Bluetooth de l'iPhone (Centre de contrôle).
3. ✅ Attendu : bandeau rouge « Connexion perdue : l'état du tapis est inconnu… »,
   séance en pause. **Le tapis continue probablement de tourner** : l'arrêter
   avec son bouton ou la clé.
4. Réactiver le Bluetooth : le lien se reconnecte, mais **aucune commande n'est
   envoyée** tant que vous n'appuyez pas sur Reprendre.

## 5. Courte séance réelle

1. Créer un programme de test : 2 min à 3,0 km/h, 2 min à 4,0 km/h et 2 %,
   1 min à 3,0 km/h.
2. Lancer, monter sur le tapis après le démarrage (ou selon votre habitude de
   sécurité), vérifier les changements de phase automatiques.
3. Tester une modification manuelle pendant une phase : bandeau
   « Consigne manuelle jusqu'au prochain palier », puis retour aux consignes du
   programme à la phase suivante.
4. Si vous utilisez une ceinture ou l'Apple Watch : vérifier la source et
   l'ancienneté affichées, puis retirer la ceinture 10 s : la FC doit passer en
   « — » (mesure périmée).

## 6. Exporter et transmettre le diagnostic

*Réglages › Diagnostic et journaux › Exporter le journal (texte)*. Le fichier
contient l'en-tête (modèle, capacités, informations appareil) puis chaque
commande (`[TX]` avec octets), réponse (`[REP]`), statut (`[STATUT]`) et paquet
de télémétrie (`[DATA]`), horodatés à la milliseconde.

Points à relever pour ajuster le profil URTM047 :

- délai entre `[REP] Start/Resume → succès` et la première vitesse non nulle ;
- accélération observée (km/h par seconde) ;
- `[STATUT] Consigne vitesse du tapis : …` après une consigne (le tapis
  annonce-t-il la valeur demandée ?) ;
- octets non interprétés (`[ALERTE] … octet(s) non interprété(s)`) ;
- présence éventuelle du champ d'extension « Step Count ».
