# Avancement

Dernière mise à jour : 2026-10-02 — app Moto Road 1.0.53+ (SideStore) ; companion en service sur le PC (Docker + Tailscale Serve).

| Milestone | État | Détail |
|---|---|---|
| M0 — CI → IPA → SideStore | 🟢 | `ios-build.yml` (macos-15, Xcode 16.4, IPA non signée) → release `v1.0.N` + `distribution/source.json` mis à jour par le bot. Installé et utilisé sur l'iPhone. |
| M1 — TripCore | 🟢 162 tests (Linux + Windows) | trip.json v8 (migration v1→v8), validateur, géo, ETA recalé sur le temps GraphHopper + allure apprise, temps par étape (conduite, pleins, pauses, repas, arrivée), pleins sur vraies stations, hors tracé + retour « au plus logique », guidage vocal façon GPS routier (annonce anticipée, préparation, ordre, « puis », sorties de rond-point en toutes lettres, « continuez pendant… », direction), radars/dangers (500 m / 150 m / 300 m), trafic (20 km puis 1 km, max 2 annonces), météo sur la route, pauses, limitations, résumé de sortie, carnet d'entretien, cahier des charges (contenu, empreinte de validation), arrêts validés annoncés comme des étapes (5 km, 500 m, arrivée), passage ajouté sur la carte placé dans l'ordre de la route. |
| M2 — Companion | 🟢 58 tests Python | FastAPI + planner Claude Agent SDK (recherche web uniquement), GraphHopper 11.0 (4 profils moto, LM), graphe dans le volume Docker `mototrip-graphs`. `/live-events` (Bison Futé + DGT, toutes les 5 min). `/ride-route` (balade à plusieurs étapes : sinueuse, sans autoroute, la plus rapide). Restaurants choisis et pleins insérés comme étapes du tracé. Radars : Sécurité routière (24 h), DGT (24 h), OSM, MapAtlas (30 j) → ~60 600 radars fusionnés. |
| M3 — App : écrans | 🟢 | 4 onglets : Rouler (gros bouton, « Où tu vas ? », favoris), Favoris, Trips (+ Nouveau), Réglages (garage, entretien, SOS, PC, TomTom, état). Accueil : carte moto, « En cours · Reprendre », ROULER, SOS. Création en 6 étapes (départ, point de chute, passages obligatoires : adresses ou points sur la carte). Réglages en sections avec icônes. Fiche trip : Rouler, Préparer, Cahier des charges, Modifier le tracé (toucher la carte, aussi depuis le chat Claude), Claude ; feuille de route PDF lisible dans l'app (enregistrer dans Fichiers, partager). |
| M4 — Navigation | 🟢 | Locale, sans réseau requis : directions vocales (bouton « Alertes uniquement »), alertes toujours actives, radars/dangers (recalés sur le tracé), limitation affichée + alerte vocale, voix prioritaire (radar/virage coupent trafic/météo, musique rendue après chaque annonce), un seul bandeau à la fois, hors tracé + itinéraire de retour, détours « autour de moi », balade libre (radars, dangers, trafic devant ; itinéraire à plusieurs étapes, route sinueuse / sans autoroute / la plus rapide), pleins, restaurant et hôtel validés annoncés et affichés comme des étapes, SOS (appel, SMS position), petit point. Ferrostar non utilisé (guidage maison testé). |
| M5 — Hors ligne, radars, stations | 🟢 | Carte hors ligne MapLibre par trip, pack radars/dangers sur l'iPhone, stations OSM à ≤ 3 km. |
| M6 — Météo, trafic | 🟢 | Open-Meteo à l'heure de passage (20 min), TomTom (clé) + Bison Futé/DGT via le PC, fusionnés sans doublon. |
| M7 — Création | 🟢 | Formulaire 13 paramètres + cohérence, chat Claude (tâche + suivi), tracé GraphHopper, GPX, **cahier des charges validé + PDF** (cartes Apple Maps, étapes, lieux, checklist). |
| M8 — Automatisations | 🟡 | Checklist + rappels, sync iPhone ↔ PC (suppressions comprises), radars quotidiens, cartes toutes les 4 semaines d'après `companion/maps.txt` (France, Italie, Espagne, Suisse, Allemagne, Portugal, Pays-Bas ; un pays s'ajoute par une ligne). Purge des packs : à faire. |
| M9 — Recette | 🟡 | Tests sur route par FAB en cours. Test complet en mode avion à faire. |

## Sources de données (vérifiées le 2026-09-28)
- Radars : [Sécurité routière](https://radars.securite-routiere.gouv.fr) (Etalab), [DGT](https://nap.dgt.es/dataset/radares-fijos-dgt) (CC BY), OpenStreetMap (ODbL), [MapAtlas](https://mapatlas.eu/tools/speed-camera-map) (CC BY 4.0, instantané 2024).
- Événements en direct : [Bison Futé](https://www.bison-fute.gouv.fr/acces-aux-donnees.html) (routes nationales FR, Licence Ouverte), DGT DATEX II (Espagne, CC BY), TomTom (clé du pilote).
- Écartés : Waze, Coyote, SCDB (fermés ou payants, pas d'API individuelle), Lufop (bloque l'accès automatisé).

## Points ouverts
1. Couverture du routage : France, Italie, Espagne, Suisse, Allemagne, Portugal, Pays-Bas (choix de FAB) : autres pays ajoutés un par un dans `companion/maps.txt` le moment venu.
2. `cols.json` vide : la vérification « col fermé à la période » ne se déclenche pas tant qu'aucun col n'est sourcé.
3. Purge des cartes hors ligne des trips terminés.
4. Recette en mode avion (SPEC §12).
