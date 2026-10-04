# CLAUDE.md — Consignes pour Claude Code

Lire **SPEC.md** et **docs/STATUS.md** avant toute tâche. SPEC.md est la source de vérité fonctionnelle ; ce fichier fixe la manière de travailler.

## Contexte de développement
- Machine de dev : **PC Windows, pas de Mac**. Pas de simulateur iOS, pas de Xcode local.
- Compilation iOS : **uniquement via GitHub Actions** (runner macOS, dépôt public).
- Utilisateur final unique : FAB, iPhone, installation via SideStore (identifiant Apple gratuit).
- Langue : code, identifiants, commits en **anglais** ; docs utilisateur et textes de l'app en **français**.

## Règles impératives
1. **La navigation n'appelle jamais d'IA ni le companion comme dépendance.** Tout appel réseau en navigation est optionnel, avec délai d'expiration (≤ 5 s), repli local et bandeau d'état.
2. **Toute logique métier va dans `core/` (package `TripCore`)**, sans import de `CoreLocation`, `MapKit`, `SwiftUI`, `UIKit`, `AVFoundation`. Types géographiques maison (`GeoPoint`, `Polyline`…). Objectif : `swift test` passe **sous Windows**.
3. L'app (`app/`) ne contient que : UI, adaptateurs capteurs (GPS, voix), adaptateurs MapLibre/Ferrostar, persistance, réseau.
4. **Ferrostar, MapLibre, GraphHopper** : versions épinglées, accès uniquement via des protocoles internes (`NavigationEngine`, `MapRenderer`, `RoutingClient`). Aucune API tierce appelée directement depuis les vues.
5. **Aucun secret dans le dépôt** (dépôt public) : clé TomTom et jeton companion saisis dans l'app (trousseau iOS) ; côté PC dans `companion/.env` (ignoré par git, modèle fourni `.env.example`).
6. **Ne rien inventer** : le planner force `verification: "unverified"` sur toute POI sans source. Ne jamais générer de données factuelles en dur (adresses, horaires de cols) dans le code ou les tests hors fixtures explicites.
7. **Pas de `.xcodeproj` versionné** : le projet est généré par XcodeGen depuis `app/project.yml`.
8. Toute nouvelle fonction de `TripCore` arrive avec ses tests. Les algorithmes de SPEC §5 ont des tests de propriétés/invariants (ex. distance entre pleins ≤ autonomie utile).
9. Pendant la navigation : aucune alerte modale, aucune demande de permission, aucune saisie texte.

## Structure du dépôt
```
.
├─ SPEC.md / CLAUDE.md / README.md (installation pas à pas pour FAB)
├─ core/                      Package.swift → TripCore (+ Tests)
│  └─ Sources/TripCore/{Model,Geo,Planning,ETA,Fuel,Weather,Traffic,Radar,Curvature,OffRoute,Checklist}
│  └─ Sources/TripCore/Resources/{regions.json, cols.json, bikes.json}
├─ app/
│  ├─ project.yml             XcodeGen
│  └─ Sources/{App,Features/{Trips,Create,Trip,Navigate,Settings},Adapters,Persistence,Networking}
├─ companion/
│  ├─ docker-compose.yml      planner + graphhopper + jobs, restart: unless-stopped
│  ├─ planner/                API + Claude Agent SDK + system_prompt.md + schéma trip.json
│  ├─ graphhopper/            config.yml + modèle personnalisé moto sinueuse
│  ├─ jobs/                   OSM (hebdo), radars (hebdo), extraction PMTiles par trip
│  └─ .env.example
├─ distribution/source.json   Source SideStore (générée par la CI, ne pas éditer à la main)
└─ .github/workflows/{core-tests.yml, ios-build.yml, companion-tests.yml}
```

## Commandes
```bash
# Logique métier (Windows, local)
cd core && swift build && swift test

# Companion (Windows, Docker Desktop + WSL2)
cd companion && docker compose up -d --build
curl http://localhost:8080/health

# Build iOS : uniquement en CI
git push origin main        # déclenche ios-build.yml
```

## Pipeline CI/CD (à implémenter tôt — milestone M0)
`ios-build.yml` sur push `main` et déclenchement manuel :
1. `runs-on` macOS **épinglé** (jamais `macos-latest`), version Xcode épinglée, `timeout-minutes: 45`.
2. `core` : `swift test`.
3. `brew install xcodegen` → `xcodegen generate` dans `app/`.
4. `xcodebuild archive` **sans signature** (`CODE_SIGNING_ALLOWED=NO`), cache SPM.
5. Empaquetage `Payload/*.app` → `MotoRoad-<version>.ipa` (app affichée « Moto Road » ; cible Xcode, bundle id et données inchangés).
6. GitHub Release `v<version>` avec l'IPA.
7. Mise à jour de `distribution/source.json` (version, date, URL de l'IPA, taille) + commit par le bot.
Numéro de version : `1.2.<run_number − 71>` (1.2.0 au run 71, puis +1 par run) injecté dans `Info.plist` ; le numéro de build reste le `run_number`.

## Ordre de réalisation (milestones)
| # | Livrable | Dépend de |
|---|---|---|
| M0 | Spikes S1 (CI → IPA → SideStore) et S2 (carte hors ligne) + README d'installation | — |
| M1 | `TripCore` : modèle `trip.json` v1 + validation de schéma + géo (distance, projection sur tracé, rééchantillonnage) + tests | — |
| M2 | Companion : docker-compose, GraphHopper + profil sinueux (S4), `/health`, `/route`, `/match`, démarrage auto | M1 |
| M3 | App : Trips, Réglages, garage, État du système, import `trip.json` + GPX, carte du trip | M0, M1 |
| M4 | Navigation locale : Ferrostar (S3), bandeaux, voix, arrière-plan (S7), hors tracé, ETA (§5.1), pleins (§5.2), trace réelle, SOS | M3 |
| M5 | Pack hors ligne (A7/A8), radars, stations, limitation de vitesse | M2, M4 |
| M6 | Enrichissements en ligne : météo sur route (§5.3), TomTom (§5.4) | M4 |
| M7 | Création : formulaire guidé + contrôles de cohérence, planner Agent SDK (S6), chat + carte en direct, finalisation, GPX/PDF | M2, M3 |
| M8 | Automatisations restantes : checklist + notifications locales (A9/A10/A14), sync (A11), jobs hebdo (A5/A6), purge des packs | M5, M7 |
| M9 | Recette : critères d'acceptation SPEC §12, dont test complet en mode avion | tout |

La navigation (M4) passe **avant** la création assistée (M7) : un trip importé depuis le projet Claude existant doit être navigable le plus tôt possible.

## Définition de « terminé » pour chaque tâche
- Tests `TripCore` verts sous Windows ; build CI vert.
- Aucun secret, aucune donnée factuelle inventée.
- Comportement hors ligne vérifié pour toute fonction utilisée en navigation.
- README mis à jour si une action manuelle de FAB change.
- Commit atomique, message en anglais au format `type(scope): summary`.

## Quand s'arrêter et demander
- Une limite Apple/iOS rend une automatisation (SPEC §3) impossible → documenter et demander, ne pas contourner par des moyens non officiels.
- Un service externe exige un paiement ou une clé non prévue.
- Un choix changerait le schéma `trip.json` (incrémenter `schemaVersion` + migration).
