# AUDIT — Moto Road (Phase 1, lecture seule)

Date : 2026-10-04 · branche `main` · commit de départ `2a55343` · aucun fichier de code modifié.

## 1. Cartographie

| Couche | Techno | Taille | Rôle |
|---|---|---|---|
| `core/` (TripCore) | Swift 5.10, SwiftPM, **0 dépendance** | 36 fichiers (5 100 lignes) + 31 fichiers de tests (2 360 lignes), 200 tests | Toute la logique métier (géo, ETA, guidage, alertes, météo, saisons, road book, sync). Pur Swift, testé sous Linux + Windows. |
| `app/` | Swift/SwiftUI iOS 17, XcodeGen, **1 dépendance** : MapLibre 6.31.0 (épinglée) | 58 fichiers (9 300 lignes), 1 fichier de tests (PDF) | UI, capteurs, MapLibre, persistance (fichiers JSON + UserDefaults + trousseau), réseau. |
| `companion/` | Python 3.12, FastAPI, Claude Agent SDK, GraphHopper 11 (Docker) | 9 modules (1 900 lignes), 68 tests | Création de trips uniquement (chat Claude, tracés, sync). Jamais requis en navigation. |
| CI | GitHub Actions | 4 workflows | `ios-build` (macOS 15, Xcode 16.4), `core-tests` (Linux+Windows), `companion-tests`, `data-pack` (quotidien). |

**Points d'entrée** : `MotoTripApp` (app) ; `app.main:app` (companion) ; `swift test` (core).
**Flux de navigation (chemin critique)** : `LocationService.$lastFix` → `NavigationSession.handle(fix)` (1 Hz) → `NavigationComputer.snapshot` (projection `Polyline.locate` avec fenêtre) → `TurnGuide` / `AlertGuide` / `StopGuide` / `OffRouteDetector` → `VoiceService` + `@Published` → vues. Aucun réseau bloquant (météo/trafic en `Task` avec timeout).
**Flux de création** : app → `CompanionClient` (Tailscale, jeton Bearer) → job FastAPI (planner Claude + GraphHopper + radars/saisons) → polling 3 s → `trip.json` v9.

## 2. Baseline mesurée

Limites : **aucun Swift, SwiftLint ni appareil iOS sur ce PC** (cf. règle CLAUDE.md : build iOS = CI uniquement). Les mesures Swift viennent donc de la CI ; le temps de démarrage et la couverture Swift **n'ont pas pu être mesurés** (voir §5).

| Métrique | Valeur | Source |
|---|---|---|
| IPA publiée (1.0.65) | **5 347 150 octets (≈ 5,1 Mo)** | release v1.0.65 |
| Dépendances Swift | 1 tierce (MapLibre, épinglée) + TripCore local | `app/project.yml`, `core/Package.swift` |
| Dépendances Python directes | 5 (fastapi, uvicorn, httpx, pydantic, claude-agent-sdk), toutes épinglées | `requirements.txt` |
| Vulnérabilités connues (Python) | **0** (`pip-audit`) | exécuté ici |
| Images Docker | planner 649 Mo, graphhopper 557 Mo | `docker images` |
| Poids du dépôt suivi | 182 fichiers, 1,45 Mo (dont 2 icônes PNG identiques de 158 Ko) | `git ls-files` |
| Build iOS complet (run 37213608218) | **≈ 7 min 05** : tests core 33 s · archive Release 105 s · **tests simulateur 247 s (58 %)** · reste < 30 s | API Actions |
| Tests TripCore | **200 verts**, 0,74 s (Linux) ; job Windows vert (1 m 52) | run 37213608249 |
| Tests companion | **68 verts**, 1,4 s | exécuté ici (conteneur) |
| Couverture Python | **79 %** global : `planner.py` 49 %, `radar_sources.py` 63 %, `finalize.py` 77 %, `main.py` 83 %, `alerts.py` 93 % | `coverage` |
| Couverture Swift | non mesurée (aucun outil local ; `swift test --enable-code-coverage` possible en CI) | — |
| Linter Python (ruff, règles par défaut) | **42 constats, tous de style** (15 auto-corrigeables : tri d'imports, `list.extend`…). **0 erreur réelle** (règle F) | exécuté ici |
| Linter Swift | aucun configuré dans le dépôt | — |
| Secrets en clair | **aucun** (grep motifs clés/jetons, aucun `.env` suivi) | `git grep` |
| Code mort | **aucun symbole inutilisé** hors surcharges de protocoles/UIKit (script d'analyse sur tous les `.swift`) | script |

## 3. Constats

Légende : impact / risque de la correction / effort (S < 1 h, M ≈ 2-3 h, L > 1 journée).

### 3.1 Qualité et robustesse

| # | Fichier:ligne | Constat | Impact | Risque | Effort |
|---|---|---|---|---|---|
| Q1 | `app/Sources/Persistence/RideStore.swift:60-70` | `save`/`delete` avalent toute erreur (`try?`) : si l'écriture d'une sortie terminée échoue (disque plein), la sortie est perdue **sans message**. `TripStore` expose déjà `lastError`. | Moyen | Faible* | S |
| Q2 | `companion/planner/app/main.py:85-91, 113-117`, `planner.py:71-75` | Écritures non atomiques (`write_text`) des trips, sorties et sessions : une coupure du PC pendant l'écriture laisse un JSON tronqué (le trip disparaît du sync via `except JSONDecodeError: continue`). L'app, elle, écrit déjà en `.atomic`. | Moyen | Faible | S |
| Q3 | `companion/planner/app/main.py:181` | `JOBS` (jobs avec leur trip complet) n'est jamais purgé : fuite mémoire lente tant que le conteneur vit. | Faible | Faible | S |
| Q4 | `app/.../PlannerChatView.swift:151-190` vs `app/.../CompanionClient.swift:118-135` | **Duplication** : deux boucles de polling de job (délais 45 min vs 20 min, URL `/chat/` vs `/jobs/`, messages différents). | Moyen (maintenance) | Moyen (textes affichés, reprise de job) | M |
| Q5 | `app/.../CompanionClient.swift:83-109, 141-145` | **Duplication** : le bloc « requête → code HTTP → `Failure.http` » est copié 5 fois (`getTrip`, `putTrip`, `putRide`, `deleteTrip`, `send`). | Faible | Faible | S |
| Q6 | `core/Sources/TripCore/**` (9 sites : `StageTiming:54`, `Sun:9`, `MaintenanceBook:114`, `TripValidator:96/106/117`, `RoadBook:228`, …) | `Calendar(identifier: .gregorian)` + fuseau UTC reconstruits à l'identique 9 fois. | Faible | Faible | S |
| Q7 | `companion/planner/app/main.py:300-312` | Endpoint `POST /route` : **aucun appelant** (l'app utilise `/ride-route` et `/finalize`) ; seuls 2 tests le touchent. Prévu en SPEC M2. | Faible | — | S |
| Q8 | `core/.../FuelPlanner.swift:31` (`isFeasible`), `core/.../GeoPoint.swift:62` (`Geo.toLocal`) | Utilisés **uniquement par les tests**. | Faible | Faible | S |
| Q9 | Fichiers volumineux : `TripDetailView.swift` (737 l., plusieurs vues), `Trip.swift` (668 l., modèle + codec + migration), `CreateTripView.swift` (630 l.), `TripMapView.swift` (496 l.) | Lisibilité : plusieurs types par fichier. Découpage = déplacement pur, sans changement de logique. | Moyen (maintenance) | Faible | M |
| Q10 | `main.py:126` | Commentaire d'en-tête orphelin « offline alert pack (free ride) » au-dessus de `get_trip` (reste d'un ancien endpoint). | Faible | Nul | S |
| Q11 | `.github/workflows/core-tests.yml:23` | Job Windows toujours `continue-on-error: true` « tant que non éprouvé », alors qu'il est vert (run ci-dessus) et que l'objectif CLAUDE.md est « `swift test` passe sous Windows ». Il ne protège donc rien. | Faible | Faible | S |
| Q12 | Python : 42 constats ruff, pas de `pyproject.toml`/config de lint | Pas de garde-fou de style ; les constats sont cosmétiques. | Faible | Faible | S |

\* Q1 change un comportement visible (un message d'erreur apparaît) → à valider.

### 3.2 Performance (justifiée par la complexité, à confirmer par mesure)

| # | Fichier:ligne | Constat | Impact estimé | Risque | Effort |
|---|---|---|---|---|---|
| P1 | `TripStore.swift:17-22`, `RideStore.swift:50-58` | Au lancement, **tous** les trips (tracés complets) et toutes les sorties sont lus et décodés **sur le thread principal**, avant le premier affichage. Coût en O(octets totaux), croissant avec le nombre de trips. Contre-exemple déjà bon dans le code : `AlertPackStore` décode hors thread principal. | Moyen à élevé (démarrage) — **non mesuré** | Moyen (liste vide un instant ; course avec la synchro) | M |
| P2 | `core/.../NavigationProgress.swift:146-150` (`SegmentCache.Key`) | La clé de cache hache **toute la polyligne** (`Polyline: Hashable` synthétisé = `points` **et** `cumulative`, soit ≈ 4 × n doubles) à chaque consultation ; `StageTimer.estimate` l'appelle depuis `TripDetailView.body` (l. 405, 511) pour chaque jour à chaque rendu. O(n) par appel là où O(1) suffirait avec une clé d'identité. | Moyen (écran Trip) — **à mesurer** | Moyen (le cache ne doit jamais servir un résultat périmé) | M |
| P3 | `NavigationSession.swift:226-231` | `SegmentBuilder.remaining` est calculé 2× par fix (snapshot + apprentissage d'allure), 1 Hz, quelques centaines de segments. | Négligeable (< 5 %) | — | — |
| P4 | `NavigationSession.handle` | ≈ 10 `@Published` réassignés à chaque fix sans test d'égalité (invalidations SwiftUI). SwiftUI les fusionne par tour de boucle. | Négligeable | — | — |
| P5 | `companion/.../main.py:94-103` (`list_trips`) | Chaque synchro relit et parse **tous** les trips complets pour n'en sortir que `id/name/updatedAt`. | Faible (usage mono-utilisateur, PC) | Faible | S |
| P6 | `TripSync.timestamp` (`RideCompanion.swift:175`) | Un `ISO8601DateFormatter` créé par appel (une fois par sauvegarde). | Négligeable | — | — |

Le chemin critique de navigation est **déjà optimisé** (projection plate sans trigonométrie, fenêtre autour de `hint`, recherches binaires, `MapContent` diffé, pack radars décodé hors thread principal). Je ne propose rien de plus dessus.

### 3.3 Sécurité

Aucune faille exploitable trouvée. Points positifs : aucun secret versionné ; jeton comparé en temps constant (`compare_digest`) ; ids de trip/sortie validés par regex (pas de traversée de chemin) ; entrées de coordonnées validées ; clés TomTom/jeton dans le trousseau ; dépendances Python sans CVE connue ; services exposés en `127.0.0.1` uniquement + Tailscale.

| # | Constat | Impact | Risque correction | Effort |
|---|---|---|---|---|
| S1 | Le conteneur planner tourne en **root**, sans `.dockerignore`. Passer en utilisateur non-root peut casser l'écriture dans `./data` (bind mount Windows). | Faible | **Moyen** (impossible à vérifier sans lancer le PC) | S |
| S2 | `PUT /rides/{id}` et `/trips/{id}` : corps de taille non bornée (derrière jeton + Tailscale). | Faible | Faible | S |
| S3 | `radar_sources.py:79` : `xml.etree` sur le XML de la DGT (source officielle HTTPS). `defusedxml` ajouterait une dépendance pour un risque quasi nul. **Non recommandé.** | Très faible | — | — |
| S4 | `DataPack.download` décompresse sans limite de taille (source = notre propre release GitHub). | Très faible | Faible | S |

### 3.4 Dépendances et empreinte

- Swift : déjà minimal (MapLibre seule). Rien à retirer ; Ferrostar est commenté dans `project.yml` (aucun poids).
- Python : 5 dépendances directes toutes utilisées ; rien à remplacer.
- Images Docker 649 / 557 Mo : dominées par le SDK Claude et GraphHopper ; pas de gain raisonnable sans changer d'architecture.
- IPA 5,1 Mo : rien d'évident (pas de ressource inutilisée dans l'app ; `Resources/*.json` du core = 2,6 Ko, tous lus par `Catalog.swift`).
- `distribution/moto-road-icon.png` et `AppIcon/icon-1024.png` sont **identiques** (SHA-1 `5bdc3994…`, 158 Ko) : le premier est référencé par `source.json` (`update_source.py:25`) → **je ne le supprime pas**.
- Temps de CI : les tests simulateur (4 min) pèsent 58 % du build ; `swift test` du core tourne aussi dans `core-tests` (même commit) — redondance voulue (retour rapide) mais coûteuse en temps de build iOS.

## 4. Plan d'action priorisé (gain élevé / risque faible d'abord)

Chaque étape = 1 commit atomique, tests + CI verts avant la suivante.

| Ordre | Élément | Gain | Remarque |
|---|---|---|---|
| 1 | **Q2** écritures atomiques côté PC (+ test) | Intégrité des données | Faible risque |
| 2 | **Q3** purge des jobs terminés (> 1 h) (+ test) | Mémoire | |
| 3 | **Q5** `CompanionClient` : helper unique de contrôle HTTP | −25 lignes dupliquées | Pure refactorisation |
| 4 | **Q6** `Calendar.utc` partagé dans TripCore | −18 lignes, 1 seule définition | Couvert par les tests de dates existants |
| 5 | **Q10**, **Q11** commentaire orphelin ; retirer `continue-on-error` du job Windows | Clarté / garde-fou réel | Q11 : si le job rougit un jour, il bloquera — c'est le but |
| 6 | **P2** clé du cache de segments en O(1) — **après micro-benchmark** (test de perf dans `PolylinePerformanceTests`) | Écran Trip plus fluide | Je ne le fais que si la mesure montre ≥ 5 % |
| 7 | **P1** décodage des trips hors thread principal — **après mesure** (signposts) | Démarrage | Nécessite un retour de ta part sur le délai constaté à l'ouverture |
| 8 | **Q9** découpage de `TripDetailView` et `Trip.swift` en fichiers par type | Lisibilité | Déplacement pur, vérifié par la CI |
| 9 | **Q12** config ruff minimale (E, F, B) + étape dans `companion-tests` | Garde-fou | |
| 10 | **P5**, **S2** | Marginal | Seulement si tu le souhaites |

## 5. Zones sans test à couvrir avant toute modification (Phase 2)

| Zone | État | Tests de caractérisation prévus |
|---|---|---|
| `SegmentBuilder/SegmentCache` (P2) | testé indirectement | Test d'égalité de résultat avec/sans cache + benchmark (core, Linux/Windows) |
| `TripStore`, `RideStore`, `SyncService`, `CompanionClient`, `DataPack`, `AlertPackStore`, `OfflineMapStore`, `NavigationSession` | **0 test** (seul `RoadBookPDFTests` existe côté app, et ces types dépendent d'UIKit/MapLibre/réseau) | Impossibles sous Windows. Pour Q5 : tester la fonction de contrôle HTTP isolée dans le simulateur CI, ou l'extraire dans `core/` (sans `URLSession`) pour la tester sous Windows. Pour P1/Q1 : tests simulateur en CI. |
| Companion `planner.py` (49 %), `radar_sources.py` (63 %), `finalize.py` (77 %) | partiel | Q2/Q3 : tests ciblés `store_trip`, `put_ride`, purge des jobs (le reste n'est pas touché) |
| Couverture Swift | inconnue | Ajouter `--enable-code-coverage` à `core-tests` pour une vraie baseline (proposition, hors audit) |

## 6. Décisions qui t'appartiennent (j'attends ta réponse)

1. **Q1** : afficher un message d'erreur si l'enregistrement d'une sortie échoue (comportement visible nouveau). Oui / non ?
2. **Q7** : supprimer l'endpoint `POST /route` (jamais appelé) et ses 2 tests ? Ou le garder tel quel ? *(suppression de code → je ne fais rien sans ton accord)*
3. **Q8** : supprimer `FuelPlan.isFeasible` et `Geo.toLocal` (tests seulement) en adaptant les tests ? Ou les garder ?
4. **Q4** : unifier les deux boucles de polling (touche les messages affichés dans le chat) ? Je recommande **non** : gain faible, risque d'effet visible.
5. **P1 / P2** : tu valides la démarche « mesurer d'abord, corriger seulement si ≥ 5 % » ? Pour P1, as-tu constaté une attente à l'ouverture de l'app ?
6. **S1** (conteneur non-root) : je recommande **de ne pas le faire** sans pouvoir le tester sur ton PC. D'accord ?
7. **Q9** : découpage des gros fichiers : oui pour `TripDetailView` et `Trip.swift`, ou rien ?

Aucun changement de format de données (`trip.json` v9), d'API publique ou de comportement n'est prévu hors décisions 1, 2, 3 ci-dessus.

---

## 7. Bilan (Phases 3 et 4)

Décisions de FAB : Q1 oui, Q7 oui, Q8 oui, Q4 non, Q9 oui (sans toucher à la vue d'accueil), P1 abandonné (aucune latence constatée à l'ouverture), S1 non fait. Mesure-d'abord appliquée à P2.

### Avant / après

| Métrique | Avant | Après |
|---|---|---|
| Tests TripCore | 200 verts | 200 verts (Linux + Windows, le job Windows est désormais bloquant) |
| Tests companion | 68 | 69 (+ écriture atomique, − endpoint retiré, + purge des jobs) |
| Lint Python | aucun (ruff « tout » : 42 constats de style) | ruff E/F/B : 0 constat, vérifié en CI |
| IPA | 5 347 150 o (1.0.65) | 5 351 655 o (1.0.67) : +0,08 %, sans effet voulu (nouveau message d'erreur) |
| Build iOS complet | 7 min 05 | 6 min 02 (variation du runner, pas un effet des changements) |
| Tests simulateur | 247 s | 163 s (idem : variation du runner) |
| Code dupliqué retiré | | calendrier UTC ×6, contrôle HTTP ×4 |
| Plus gros fichier core | `Trip.swift` 668 lignes | 447 lignes (+ `TripDay.swift` 197, `TripCodec.swift` 26) |

Aucun gain de performance d'exécution n'était attendu ni revendiqué : le chemin critique était déjà optimisé.

### Changements effectués (branche `main`, poussés, CI verte)

| Commit | Élément | Objet |
|---|---|---|
| `7340ae6` | Q7 | retrait de `POST /route` (aucun appelant) et de son test |
| `3a10c0f` | Q2, Q10 | écritures atomiques côté PC (`fsutil.write_atomic`, test) ; commentaire orphelin corrigé |
| `6ac91b3` | Q3 | purge des jobs terminés depuis plus d'une heure (test) |
| `2e86e04` | Q6 | `Calendar.utc` partagé (6 copies supprimées ; `RoadBook.utcCalendar` repris) |
| `49c9a8a` | Q8 | retrait de `FuelPlan.isFeasible` et `Geo.toLocal` (tests adaptés) |
| `30ec01f` | Q5 | `CompanionClient.fetch` : un seul contrôle de statut HTTP |
| `6d5cab8` | Q1 | message d'erreur si une sortie ne peut pas être enregistrée |
| `31df731` | Q12 | `ruff.toml` minimal + étape CI |
| `628bf85` | Q11 | job Windows de `core-tests` bloquant |
| `8bc278d` | Q9 | `Trip.swift` découpé (déplacement pur) |
| `3fb86c4` | Q9 | `DayRow` / `POIRow` déplacées dans `TripRows.swift` |

### Non traité, et pourquoi

- **P2** (clé du cache de segments) : mesuré, 0,09 ms par consultation pour 300 km en Release. Sous le seuil de 5 % et hors chemin critique : non modifié.
- **P1** (décodage des trips hors thread principal) : aucune latence à l'ouverture. Abandonné.
- **P3, P4, P5, P6, S2, S4** : négligeables ou marginaux, non demandés.
- **Q4** (deux boucles d'interrogation des tâches) : refusé par FAB (messages visibles).
- **Q9, suite** : la section « extension » de `TripDetailView` (≈ 670 lignes restantes) utilise des membres `private` ; la déplacer exigerait de changer leur visibilité, sans test possible hors CI. Laissée telle quelle. `CreateTripView` et `TripMapView` non découpés.
- **S1** (conteneur non-root) : risque de casser l'écriture dans `./data` sur Windows, non testable ici.
- **S3** (`defusedxml`) : dépendance ajoutée pour un risque quasi nul.
- Phase 2 : aucun test de caractérisation de l'app n'a été possible hors CI ; les refactorisations app (Q5, Q1, déplacement des lignes) ont été validées par le build et les tests simulateur de la CI.

### Recommandations restantes

1. Activer la couverture Swift en CI (`swift test --enable-code-coverage`) pour disposer d'une baseline.
2. Les couches `TripStore`, `RideStore`, `SyncService`, `NavigationSession` n'ont aucun test : extraire dans `core/` la logique pure qu'elles contiennent (par exemple le plan de sync, déjà dans `TripSync`) avant de les modifier.
3. Couvrir `planner.py` (49 %) et `radar_sources.py` (63 %) par des tests avec réponses simulées.
4. `TripDetailView` : transformer les sections en sous-vues indépendantes plutôt qu'en extension pour pouvoir les déplacer.
