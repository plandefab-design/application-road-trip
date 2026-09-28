# Avancement

Dernière mise à jour : 2026-09-28 — app 1.0.4 installée via SideStore ; companion en service sur le PC (Docker + Tailscale Serve), test de connexion depuis l'iPhone OK.

| Milestone | État | Détail |
|---|---|---|
| M0 — CI → IPA → SideStore | 🟢 CI verte, **installation iPhone à valider** | `ios-build.yml` → release v1.0.2 (IPA 3,7 Mo), source SideStore à jour (macos-15, Xcode 16.4, IPA non signée, Release, source SideStore). Carte en ligne OpenFreeMap ; carte hors ligne (S2) à faire. |
| M1 — TripCore | 🟢 Tests verts en CI (Linux + Windows) | Modèle trip.json v1 (décodage tolérant), validateur, géo (distance, cap, projection, rééchantillonnage), ETA à l'allure (§5.1), pleins (§5.2), sinuosité (§5.6), hors tracé (§5.7), cohérence du formulaire, GPX lecture/écriture, calcul du bandeau de navigation. |
| M2 — Companion | 🟢 En service sur le PC (Alpes importées, joignable depuis l'iPhone) | API FastAPI (health, trips, chat, route), planner Agent SDK, GraphHopper 11.0 + modèles `moto_curvy` / `moto_fast`. 12 tests Python OK. Profil sinueux à calibrer (S4). |
| M3 — App : écrans | 🟡 Installée sur iPhone | Édition des motos et des trips, reprise du chat depuis un trip (1.0.4). Trips (import GPX/JSON), détail (carte, étapes, adresses avec statut vérifié, export GPX), Réglages (garage, SOS, companion, TomTom), Créer (formulaire 13 paramètres + cohérence), chat planner. |
| M4 — Navigation | 🟠 Mode « suivre le tracé » | Local : bandeaux plein / arrêt / fin avec heure d'arrivée à l'allure, avance/retard, hors tracé + cap de retour, voix, écran allumé, SOS SMS, trace réelle. **Guidage virage par virage Ferrostar : à intégrer (S3).** |
| M5 — Hors ligne, radars, stations | 🟠 Partiel | Radars (OSM `highway=speed_camera`, ~3 700 sur la zone) et dangers (OSM `hazard=*`) intégrés au trip par le PC, annoncés hors ligne (radars 500 m, dangers 300 m). Carte hors ligne (A7/A8) : packs MapLibre du même style (aperçu z0–11 + couloir des étapes z12–14), contrôle d'intégrité, bouton sur la fiche du trip. Stations : OSM `amenity=fuel` à moins de 3 km intégrées par le PC, pleins placés par TripCore `FuelPlanner` sur l'iPhone, alerte si tronçon sans station. |
| M6 — Météo sur la route, TomTom | 🟠 Partiel | Incidents TomTom (v5) en navigation : toutes les 5 min si clé + réseau (délai 5 s), filtrés sur les 50 km du tracé à venir, annoncés (à la découverte puis à 1 km), bandeau d'état. Météo sur la route (Open-Meteo, §5.3) : point tous les 15 km à l'heure de passage, alertes pluie/rafales/froid/visibilité, toutes les 20 min en navigation (« météo du HH:MM » hors ligne), vérification avant départ sur la fiche du trip. |
| M7 — Création complète | 🟠 Partiel | Chat branché (tâches suivies, progression). Finalisation : lieux localisés via OSM Nominatim (cache, 1 req/s) + route GraphHopper par jour, automatique après chaque réponse de Claude ou bouton « Calculer le tracé ». Couverture carte : Alpes + PACA + Languedoc-Roussillon fusionnés (osmium). PDF à faire. |
| M8 — Automatisations restantes | ⚪ À faire | Checklist + notifications locales, sync, purge des packs. |
| M9 — Recette | ⚪ À faire | |

## Vérifications faites
- Tests Python du companion : 12/12 ✅ (exécutés localement).
- Options du Claude Agent SDK 0.2.160 vérifiées contre le paquet installé.
- Noms des valeurs GraphHopper 11.0 (`curvature`, `road_class`, `surface`, `toll`…) et endpoints `/health`, `/navigate` vérifiés dans le code source de la release 11.0.
- Versions épinglées réelles : MapLibre iOS 6.31.0, GraphHopper 11.0, (Ferrostar 0.57.0 prévu).

## Non vérifié (pas de Swift ni de Mac dans l'environnement de création)
- Comportement réel de l'app sur iPhone (installation SideStore, import GPX, mode « Rouler », arrière-plan) : pas encore testé.

## Prochaines tâches pour Claude Code (dans l'ordre)
1. ~~Pousser, lire les logs, corriger jusqu'au vert~~ ✅ (seule erreur : `Polyline` non `Hashable`).
2. Installer l'IPA via SideStore, tester l'import d'un GPX et le mode « Rouler » en conditions réelles (S7 : écran verrouillé 2 h).
3. S2 : carte hors ligne (PMTiles ou MBTiles servi par le companion).
4. S3 : Ferrostar (`FerrostarCore` 0.57.0) derrière un protocole `NavigationEngine`, itinéraire `/navigate` GraphHopper.
5. S4 : calibrer `moto_curvy.json` et `Curvature.saturationDegPerKm` sur les routes de référence.
