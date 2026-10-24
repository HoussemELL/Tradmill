# Notes d'implémentation FTMS

Références : *Fitness Machine Service 1.0* (Bluetooth SIG, 2017) et *GATT
Specification Supplement* pour les formats de champs. Les formats ci-dessous
ont été recoupés avec l'implémentation open source **pyftms 0.4.15**
(Apache-2.0). Toutes les valeurs multi-octets sont **little-endian**.

Le code correspondant est dans `TreadCore/Sources/TreadCore/FTMS/` et chaque
format est couvert par `FTMSDecodingTests`.

## Treadmill Data (0x2ACD) — notification

`Flags` uint16, puis les champs présents dans cet ordre :

| Bit | Champ | Format | Résolution |
|----:|-------|--------|-----------|
| 0 | **More Data** — logique inversée : la vitesse instantanée est présente si le bit vaut **0** | uint16 | 0,01 km/h |
| 1 | Average Speed | uint16 | 0,01 km/h |
| 2 | Total Distance | **uint24** | 1 m |
| 3 | Inclination + Ramp Angle Setting | sint16 + sint16 | 0,1 % / 0,1° (0x7FFF = non disponible) |
| 4 | Positive + Negative Elevation Gain | uint16 + uint16 | 0,1 m |
| 5 | Instantaneous Pace | uint8 | 0,1 km/min |
| 6 | Average Pace | uint8 | 0,1 km/min |
| 7 | Total Energy + Energy/Hour + Energy/Minute | uint16 + uint16 + uint8 | kcal (0xFFFF / 0xFF = non disponible) |
| 8 | Heart Rate | uint8 | bpm (0 traité comme « pas de mesure ») |
| 9 | Metabolic Equivalent | uint8 | 0,1 |
| 10 | Elapsed Time | uint16 | s |
| 11 | Remaining Time | uint16 | s |
| 12 | Force on Belt + Power Output | sint16 + sint16 | N / W |
| 13 | *(réservé en FTMS 1.0)* — **extension Step Count** | uint24 | pas |

**Pas** : FTMS 1.0 ne définit pas de nombre de pas pour un tapis (bits 13–15
réservés). Certaines implémentations (dont pyftms) décodent un `Step Count`
uint24 au bit 13. Foulée le décode **uniquement si le bit est présent** et le
signale dans le journal comme extension. S'il est absent, les pas viennent de
l'Apple Watch ou d'une estimation facultative marquée « estimée ».

Paquets tronqués : les champs complets lus avant la troncature sont conservés,
l'erreur (nom du champ, octets attendus/disponibles) est journalisée. Octets en
trop : journalisés comme « non interprétés ».

Paquets « More Data » : un enregistrement peut être réparti sur plusieurs
notifications ; les valeurs sont fusionnées champ par champ
(`TreadmillTelemetry.merge`).

## Fitness Machine Feature (0x2ACC) — lecture

Deux uint32 : *Fitness Machine Features* (mesures disponibles) et *Target
Setting Features* (bit 0 vitesse, bit 1 inclinaison…).

## Plages — lecture

- Supported Speed Range (0x2AD4) : uint16 min, uint16 max, uint16 incrément — 0,01 km/h.
- Supported Inclination Range (0x2AD5) : sint16 min, sint16 max, uint16 incrément — 0,1 %.

Si une lecture échoue, les valeurs du profil sont utilisées et l'interface
l'indique (« profil (non lue) »).

## Fitness Machine Control Point (0x2AD9) — écriture avec réponse + indications

Les **indications doivent être activées avant toute écriture**. Foulée ne
déclare le lien « prêt » qu'après confirmation (`didUpdateNotificationStateFor`)
des indications du Control Point et des notifications de Treadmill Data.

| Op | Commande | Paramètre |
|---:|----------|-----------|
| 0x00 | Request Control | — |
| 0x01 | Reset | — |
| 0x02 | Set Target Speed | uint16, 0,01 km/h (7 km/h → `02 BC 02`) |
| 0x03 | Set Target Inclination | sint16, 0,1 % (3 % → `03 1E 00`) |
| 0x07 | Start or Resume | — |
| 0x08 | Stop or Pause | uint8 : 0x01 Stop, 0x02 Pause |

Réponse (indication) : `80 <op de la requête> <résultat>` avec résultat
0x01 succès, 0x02 non supporté, 0x03 paramètre invalide, 0x04 échec,
0x05 contrôle non autorisé.

### File de commandes (`CommandQueue`)

- une seule commande en vol, réponse associée par op code ;
- espacement minimal entre commandes et délai d'expiration (profil) ;
- **aucune répétition automatique** : un échec remonte à l'appelant ;
- consignes vitesse/inclinaison non envoyées fusionnées (la plus récente gagne) ;
- Stop/Pause prioritaires, annulent consignes et Start en attente ;
- Start refusé si un Start est déjà en attente ou en vol.

## Fitness Machine Status (0x2ADA) — notification

0x02 arrêt/pause par l'utilisateur (paramètre 0x01/0x02 — sert aussi à
confirmer nos propres Stop/Pause), 0x03 clé de sécurité, 0x04 démarré/repris,
0x05 consigne vitesse modifiée (uint16 0,01 km/h), 0x06 consigne inclinaison
modifiée (sint16 0,1 %), 0xFF contrôle perdu.

Une consigne « annoncée » par le tapis n'est **jamais** affichée comme mesure
réelle et n'est pas interprétée comme une modification manuelle (le symptôme
« retour à 1 km/h » pourrait sinon être adopté silencieusement).

## Heart Rate Measurement (0x2A37)

Flags uint8 : bit 0 format FC (uint8/uint16), bits 1–2 contact capteur,
bit 3 énergie (uint16 kJ), bit 4 intervalles RR (uint16, 1/1024 s).

## Profil URTM047 : faits observés et hypothèses

**Faits** (diagnostic FTMS de l'utilisateur) : plages 1–12 km/h pas 0,1 et
0–9 % pas 1 ; l'inclinaison répond à toutes les valeurs testées ;
`Request Control → Set Target Speed → Start` produit un mouvement ;
`Request Control → Start` et `Request Control → Start → Set Target Speed` n'en
ont pas produit ; une consigne de vitesse peut être acquittée sans changement
observé ; avec Kinni, 7 km/h revient à 1 km/h ; **Treadmill Assistant pilote
correctement ce tapis**, donc le firmware accepte bien un pilotage FTMS.

**Essai Foulée (23/10)** : `Request Control` acquitté, puis `Set Target Speed`
(vitesse initiale, tapis arrêté) **sans aucune réponse en 4 s** ; la séquence
stricte s'arrêtait avant `Start`. Un client qui n'attend pas la réponse (ce que
fait vraisemblablement Kinni) enchaîne quand même sur `Start`.

**Essai Foulée suivant (23/10, 11:07)** : avec la tolérance, le tapis démarre —
**à 1,0 km/h, quelle que soit la consigne initiale envoyée à l'arrêt** — puis
applique les consignes envoyées en marche (mesure 3,4 km/h pour une consigne de
3,4). Le profil envoie donc 1,0 km/h comme vitesse initiale et la stabilisation
porte sur une vitesse stable, plus sur la consigne initiale.

Conséquence dans le profil URTM047 (`tolerateUnansweredSetpoints`) : une
consigne vitesse/inclinaison **sans réponse n'est plus bloquante** ; elle est
affichée « sans réponse » (jamais « acquittée ») et son effet est vérifié par la
télémétrie (puis un renvoi unique, puis écart signalé). Un statut 0x05/0x06 du
tapis annonçant exactement la consigne en attente vaut acquittement implicite ;
une réponse arrivée après le délai la fait passer à « acquittée ».
`Request Control`, `Start`, `Stop` et `Pause` restent stricts. Le profil FTMS
générique reste strict partout.

**La cause du problème de vitesse n'est pas établie.** La séquence de démarrage
n'est qu'une hypothèse parmi d'autres :

| # | Hypothèse | Ce que fait Foulée | Comment la vérifier |
|---|-----------|--------------------|---------------------|
| H1 | Start exige une consigne de vitesse préalable | vitesse initiale explicite (1,0 km/h) avant Start | test de démarrage |
| H2 | une consigne reçue pendant le compte à rebours ou l'accélération est acquittée mais ignorée | consigne du palier envoyée seulement quand la bande tourne à la vitesse initiale (URTM047 : dès qu'elle est mesurée, plus d'attente de 2 s depuis le 25/10 ; autres tapis : stable 2 s ; max 8 s) ; un seul renvoi si non observée | test de réponse en vitesse : renvoi nécessaire ? |
| H3 | consigne mal encodée par le client (résolution 0,1 au lieu de 0,01 → 7 km/h = 0,70 km/h, ramené au minimum 1 km/h) | encodage 0,01 km/h conforme à la spécification, octets visibles dans chaque `[TX]` | journal : `[TX] Set Target Speed 7.00 km/h | 02 BC 02` |
| H4 | le contrôle doit être redemandé avant certaines commandes | Request Control au démarrage/reprise ; option du test : Request Control avant chaque consigne | comparer le test avec et sans l'option |
| H5 | le tapis annonce la consigne (statut 0x05) sans l'appliquer | consigne « annoncée » affichée séparément de la mesure | colonne « tapis annonce » du test |
| H6 | le tapis ne répond pas (ou tard) à Set Target Speed, au moins tapis arrêté ; un client qui attend la réponse abandonne | consigne sans réponse vérifiée par la télémétrie, acquittement implicite/tardif accepté | journal : `[TX] Set Target Speed` sans `[REP]`, `Réponse tardive`, `acquittement implicite` |

La comparaison la plus décisive reste une capture du trafic de Treadmill
Assistant (voir docs/VALIDATION_MATERIELLE.md, étape 7).

Paramètres du profil (dans `TreadmillProfile.urtm047`) : vitesse initiale
1,0 km/h, attente du mouvement 15 s, consigne du palier dès que 1,0 km/h est mesuré
(`initialSpeedSettleDwell` = 0 ; auparavant vitesse stable 2 s)
(max 8 s, quelle que soit la valeur atteinte), tolérance
0,15 km/h, accélération supposée 0,25 km/h/s pour le délai d'atteinte,
1 renvoi maximum, espacement des commandes 0,4 s, délai de réponse 4 s.
