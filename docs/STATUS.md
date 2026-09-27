# Avancement

Dernière mise à jour : 2026-09-28 — ébauche initiale.

| Milestone | État | Détail |
|---|---|---|
| M0 — CI → IPA → SideStore | 🟡 Écrit, **à valider au 1er push** | `ios-build.yml` (macos-15, Xcode 16.4, IPA non signée, Release, source SideStore). Carte en ligne OpenFreeMap ; carte hors ligne (S2) à faire. |
| M1 — TripCore | 🟡 Écrit + tests, **à valider en CI** | Modèle trip.json v1 (décodage tolérant), validateur, géo (distance, cap, projection, rééchantillonnage), ETA à l'allure (§5.1), pleins (§5.2), sinuosité (§5.6), hors tracé (§5.7), cohérence du formulaire, GPX lecture/écriture, calcul du bandeau de navigation. |
| M2 — Companion | 🟡 Squelette testé | API FastAPI (health, trips, chat, route), planner Agent SDK, GraphHopper 11.0 + modèles `moto_curvy` / `moto_fast`. 12 tests Python OK. Profil sinueux à calibrer (S4). |
| M3 — App : écrans | 🟡 Ébauche | Trips (import GPX/JSON), détail (carte, étapes, adresses avec statut vérifié, export GPX), Réglages (garage, SOS, companion, TomTom), Créer (formulaire 13 paramètres + cohérence), chat planner. |
| M4 — Navigation | 🟠 Mode « suivre le tracé » | Local : bandeaux plein / arrêt / fin avec heure d'arrivée à l'allure, avance/retard, hors tracé + cap de retour, voix, écran allumé, SOS SMS, trace réelle. **Guidage virage par virage Ferrostar : à intégrer (S3).** |
| M5 — Hors ligne, radars, stations | ⚪ À faire | |
| M6 — Météo sur la route, TomTom | ⚪ À faire | |
| M7 — Création complète | 🟠 Partiel | Chat branché ; finalisation (itinéraires GraphHopper par jour, GPX/PDF) à faire. |
| M8 — Automatisations restantes | ⚪ À faire | Checklist + notifications locales, sync, purge des packs. |
| M9 — Recette | ⚪ À faire | |

## Vérifications faites
- Tests Python du companion : 12/12 ✅ (exécutés localement).
- Options du Claude Agent SDK 0.2.160 vérifiées contre le paquet installé.
- Noms des valeurs GraphHopper 11.0 (`curvature`, `road_class`, `surface`, `toll`…) et endpoints `/health`, `/navigate` vérifiés dans le code source de la release 11.0.
- Versions épinglées réelles : MapLibre iOS 6.31.0, GraphHopper 11.0, (Ferrostar 0.57.0 prévu).

## Non vérifié (pas de Swift ni de Mac dans l'environnement de création)
- Compilation de `core/` et de l'app, exécution des tests Swift → **premier push = premier vrai test**. Corriger les erreurs signalées par la CI avant d'aller plus loin.

## Prochaines tâches pour Claude Code (dans l'ordre)
1. Pousser, lire les logs `TripCore tests` et `iOS build`, corriger jusqu'au vert.
2. Installer l'IPA via SideStore, tester l'import d'un GPX et le mode « Rouler » en conditions réelles (S7 : écran verrouillé 2 h).
3. S2 : carte hors ligne (PMTiles ou MBTiles servi par le companion).
4. S3 : Ferrostar (`FerrostarCore` 0.57.0) derrière un protocole `NavigationEngine`, itinéraire `/navigate` GraphHopper.
5. S4 : calibrer `moto_curvy.json` et `Curvature.saturationDegPerKm` sur les routes de référence.
