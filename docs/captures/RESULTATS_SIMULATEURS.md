# Résultats simulateurs

Simulateurs : iPhone 17 Pro (iOS 26.2) + Apple Watch Series 10 (46mm) (watchOS 26.2), appairés : True

## 01-iphone-ecrans — OK
iPhone : navigation dans tous les onglets et écrans principaux (sombre, clair, grand texte).
- ✅ rapport écrit, app sans crash → `screens`

## 02-zone2auto-fc-simulee — OK
iPhone + tapis simulé : programme « Test Zone 2 Auto » avec FC simulée dépendant de la vitesse ; perte de FC 45 s, reprise manuelle puis réactivation du pilote.
- ✅ séance terminée → `['starting', 'running', 'finished']`
- ✅ phase pilotée atteinte → `['Échauffement progressif', 'Zone 2 pilotée', 'Retour au calme']`
- ✅ retour au calme atteint → `['Échauffement progressif', 'Zone 2 pilotée', 'Retour au calme']`
- ✅ au moins 2 ajustements automatiques → `[{'bpm': 129, 'from': 5.8, 'kind': 'increase', 't': 95.17393200000015, 'to': 6}, {'bpm': 134, 'from': 6, 'kind': 'increase', 't': 155.42554200000018, 'to': 6.2}, {'from': 6.2, 'kind': 'safety', 't': 224.92381100000011, 'to': 6}, {'from': 6, 'kind': 'safety', 't': 230.17554500000006, 'to': 5.8}, {'from': 5.8, 'kind': 'safety', 't': 235.42595700000015, 'to': 5.6}, {'from': 5.6, 'kind': 'safety', 't': 240.6812050000001, 'to': 5.4}, {'from': 5.4, 'kind': 'safety', 't': 245.92252000000008, 'to': 5.2}]`
- ✅ perte de FC détectée → `['warmingUp', 'regulating', 'heartRateGap', 'heartRateLost', 'warmingUp', 'regulating', 'manual', 'regulating']`
- ✅ alerte perte de FC → `['FC indisponible : accélérations automatiques désactivées, retour progressif à 4.5 km/h']`
- ✅ contrôle manuel prioritaire → `['warmingUp', 'regulating', 'heartRateGap', 'heartRateLost', 'warmingUp', 'regulating', 'manual', 'regulating']`
- ✅ jamais au-delà de 7 km/h (limite auto) → `6.2`
- ✅ ajustements enregistrés dans la séance → `7`

## 03-pause-deconnexion — OK
iPhone + tapis simulé : transitions par paliers, pause/reprise, coupure Bluetooth pendant la séance puis reconnexion (aucun redémarrage automatique), reprise explicite, arrêt.
- ✅ transition 4 → 7 km/h par paliers (6 km/h) → `[4, 5, 6, 7, 6, 5, 6, 7, 6, 5]`
- ✅ pause utilisateur → `['starting', 'running', 'paused(user)', 'resuming', 'running', 'paused(connectionLost)', 'running', 'finished']`
- ✅ pause sur perte de connexion → `['starting', 'running', 'paused(user)', 'resuming', 'running', 'paused(connectionLost)', 'running', 'finished']`
- ✅ reconnexion : reste en pause → `paused(connectionLost)`
- ✅ aucune accélération pendant la coupure → `False`
- ✅ aucun Start automatique après reconnexion → `0`
- ✅ arrêt final → `['starting', 'running', 'paused(user)', 'resuming', 'running', 'paused(connectionLost)', 'running', 'finished']`

## 04-watch-lance-zone2auto — OK
Scénario complet : la montre lance « Test Zone 2 Auto », l'iPhone démarre le tapis simulé, la montre envoie sa FC (simulée) par WatchConnectivity et le pilote l'utilise ; pause, reprise et arrêt depuis la montre.
- ✅ demande de démarrage envoyée → `True`
- ✅ démarrage accepté par l'iPhone → `True`
- ✅ état en direct reçu de l'iPhone → `107`
- ✅ pause visible sur la montre → `['starting', 'running', 'paused', 'finished']`
- ✅ fin visible sur la montre → `['starting', 'running', 'paused', 'finished']`
- ✅ FC envoyée par la montre → `154`
- ✅ phase affichée sur la montre → `['Échauffement progressif', 'Zone 2 pilotée']`
- ✅ exercice de la montre terminé → `True`
- ✅ demande reçue par l'iPhone → `1`
- ✅ FC Apple Watch reçue → `84`
- ✅ source FC = Apple Watch → `['Apple Watch']`
- ✅ pause depuis la montre → `['Commande depuis la Watch : pause', 'Commande depuis la Watch : resume', 'Commande depuis la Watch : stop']`
- ✅ arrêt depuis la montre → `['Commande depuis la Watch : pause', 'Commande depuis la Watch : resume', 'Commande depuis la Watch : stop']`
- ✅ séance mise en pause → `['starting', 'running', 'paused(user)', 'finished']`
- ✅ séance terminée → `['starting', 'running', 'paused(user)', 'finished']`
- ✅ pilote FC : ajustement avec la FC de la montre → `[{'bpm': 114, 'from': 5.8, 'kind': 'increase', 't': 95.54462899999999, 'to': 6}, {'bpm': 122, 'from': 6, 'kind': 'increase', 't': 155.79671099999996, 'to': 6.2}]`

## 05-watch-ecrans — ÉCHEC
Apple Watch : accueil Mes programmes (catalogue reçu de l'iPhone), détail d'un programme, pages de séance (démo).
- ✅ catalogue de l'iPhone reçu (programmes de test inclus) → `['Cardio Baseline', 'Zone 2 Endurance', 'Interval Run 9/11', 'HIIT Run 11', 'Incline Walk', 'Post-Meal Walk', 'Zone 2 Auto', 'Test Zone 2 Auto', 'Test enchaînement']`
- ✅ tous les programmes (7 prédéfinis + 2 personnels) → `9`
- note : lancement watch échoué : ceErrorDomain, code=1):
	The request to open "com.example.foulee.watchkitapp" failed.
	The request was denied by service delegate (IOSSHLMainWorkspace) for reason: Unspecified ("Scene update failed").

Crashs : aucun