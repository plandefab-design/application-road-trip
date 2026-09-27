# SPEC — MotoTrip (nom de travail)

Application iPhone personnelle de **création** et de **navigation** de road trips moto sur routes sinueuses.
Utilisateur unique : FAB. Coût cible : **0 €** (hors abonnement Claude déjà existant).

---

## 0. Principes directeurs (non négociables)

1. **Deux modes, deux mondes**
   - **Création** : assistée par Claude (via le PC, à travers Tailscale). Formulaire guidé + chat + carte en direct.
   - **Navigation** : **100 % code déterministe, 100 % local sur l'iPhone.** Aucune IA, aucune dépendance au PC.
2. **La navigation ne doit jamais s'arrêter** à cause d'un service externe (PC éteint, Tailscale coupé, pas de réseau en montagne, API en panne). Les services en ligne (météo, trafic) sont des *enrichissements* : leur absence est signalée, jamais bloquante.
3. **Tout ce qui n'est pas « créer un trip » ou « rouler » est automatique** : compilation, distribution, mises à jour, re-signature, rafraîchissement des données, téléchargement hors ligne, préparation du départ.
4. **Ne rien inventer** : toute donnée factuelle produite en création (adresse, contact, ouverture de col) porte une **source** et un **statut de vérification** (`verified` / `unverified`) affiché dans l'app.
5. **Tout gratuit** : aucune dépendance payante. Chaque service externe doit avoir une offre gratuite suffisante pour un usage solo.

---

## 1. Décisions d'architecture

| Sujet | Décision | Justification |
|---|---|---|
| Plateforme | iOS natif, Swift 5.10+/SwiftUI, iOS 17+ | GPS arrière-plan fiable, voix, écran permanent |
| Build | GitHub Actions `macos` (dépôt **public**, minutes gratuites) | Pas de Mac disponible |
| Projet Xcode | Généré par **XcodeGen** (`project.yml`) | Pas d'édition de `.xcodeproj` sous Windows |
| Signature/installation | IPA non signée → **SideStore** (re-signature sur l'iPhone, identifiant Apple gratuit). Installation initiale via **Sideloadly** (Windows) | 0 €, sans Mac |
| Mises à jour app | **Source SideStore** (`distribution/source.json`) mise à jour par la CI | L'iPhone voit et installe les nouvelles versions tout seul |
| Carte | **MapLibre Native iOS** + tuiles vectorielles **Protomaps (PMTiles)** stockées sur l'iPhone | Hors ligne, gratuit |
| Guidage | **Ferrostar** (SwiftUI) — version épinglée, encapsulée derrière un protocole | Open source, compatible GraphHopper `/navigate` |
| Routage | **GraphHopper** auto-hébergé sur le PC (Docker), profil personnalisé « moto sinueuse » | Gratuit, Apache 2.0 |
| IA création | **Claude Agent SDK** sur le PC, authentifié avec le compte Claude de FAB | Usage perso, crédits Agent SDK de l'abonnement |
| Liaison iPhone ↔ PC | **Tailscale** (réseau privé), service jamais exposé sur Internet | Sécurité |
| Météo | **Open-Meteo** (sans clé, usage non commercial, attribution CC BY 4.0) | Gratuit |
| Trafic / accidents | **TomTom Traffic API** (offre gratuite, clé saisie dans l'app) | Officiel, gratuit |
| Radars fixes | **data.gouv.fr** (France) + **OSM** `highway=speed_camera` (autres pays), embarqués | Gratuit, hors ligne |
| Carburant | **OSM / Overpass** (stations), embarqué par trip | Gratuit, hors ligne |
| Logique métier | Package Swift **`TripCore`** sans framework Apple → testable sous **Windows** (`swift test`) | Boucle de dev rapide sans Mac |

---

## 2. Composants

```
repo/
├─ app/            Application iOS (SwiftUI) — UI, capteurs, carte, guidage
├─ core/           Package Swift TripCore — logique pure, testée sous Windows
├─ companion/      Service PC (Docker) : API création, Claude Agent SDK, GraphHopper, jobs de données
├─ distribution/   source.json SideStore (généré par la CI)
└─ .github/        Workflows CI/CD
```

### 2.1 App iPhone
Écrans : **Trips** (liste) · **Créer** (formulaire → chat + carte) · **Trip** (étapes, préparation) · **Naviguer** · **Réglages**.

### 2.2 Companion (PC Windows, Docker Desktop + WSL2)
- `planner` : API HTTP (FastAPI ou Node), orchestre Claude Agent SDK + GraphHopper, produit `trip.json` + itinéraire navigable.
- `graphhopper` : moteur de routage + map matching + `/navigate`.
- `jobs` : tâches planifiées de mise à jour des données (OSM, radars, cols).
- Démarrage automatique au boot, redémarrage automatique en cas de crash (`restart: unless-stopped`), endpoint `/health`.

### 2.3 CI/CD
Push sur `main` → tests `TripCore` → build IPA non signée → GitHub Release → mise à jour `distribution/source.json` → SideStore propose la mise à jour sur l'iPhone.

---

## 3. Automatisations (exigence FAB : l'utilisateur ne fait que créer et rouler)

| # | Automatisation | Déclencheur | Composant |
|---|---|---|---|
| A1 | Build + tests + publication de l'app | Push `main` | GitHub Actions |
| A2 | Mise à jour de l'app sur l'iPhone | Nouvelle release dans la source SideStore | SideStore |
| A3 | Re-signature avant expiration des 7 jours | Rafraîchissement arrière-plan SideStore | SideStore |
| A4 | Démarrage des services PC | Boot Windows / crash | Docker (`restart: unless-stopped`) + Tailscale en service Windows |
| A5 | Mise à jour données OSM + ré-import GraphHopper | Hebdomadaire (nuit) | `jobs` |
| A6 | Mise à jour base radars (data.gouv + OSM) | Hebdomadaire | `jobs` → publiée via API, récupérée par l'app |
| A7 | Téléchargement hors ligne complet du trip (tuiles, itinéraires, radars, stations, fiches) | Validation du trip | App |
| A8 | Contrôle d'intégrité du pack hors ligne (tout présent, pas de trou de tuiles sur le tracé) | Après A7 + la veille du départ | App |
| A9 | Checklist J-15 / J-1 générée + notifications locales (ouverture cols, météo, réservations, rafraîchissement SideStore) | Dates du trip | App (notifications **locales**, pas de push) |
| A10 | Revérification des cols et de la météo sur toute la période | J-15, J-3, J-1 si PC joignable | App → `planner` |
| A11 | Synchronisation des trips iPhone ↔ PC (sauvegarde) | À chaque ouverture si PC joignable | App ↔ `planner` |
| A12 | Pendant la navigation : changement d'étape, météo, trafic, heure d'arrivée, alertes | Continu | App |
| A13 | Enregistrement de la trace réelle + stats | Continu pendant la navigation | App |
| A14 | Alerte « app expire bientôt » si la signature expire avant la fin d'un trip planifié | Dates du trip vs date d'expiration | App |

### Ce qui reste manuel (limites Apple/iOS, à documenter dans le README)
- **Installation initiale** : une fois, iPhone branché en USB au PC (Sideloadly → SideStore), avec double authentification Apple.
- **Un seul VPN actif sur iOS** : la re-signature SideStore utilise un VPN local, incompatible simultanément avec Tailscale. À automatiser si possible via une **automatisation Raccourcis iOS** (bascule de VPN à heure fixe, ex. 7 h) — faisabilité à valider (spike S5). La navigation n'a besoin d'aucun des deux.
- Saisie unique de la clé TomTom et de l'adresse Tailscale du PC dans Réglages.

---

## 4. Fonctions de l'application

### 4.1 Réglages & garage
- Garage : modèle (liste + saisie libre), **autonomie réelle (km)**, consommation, marge de sécurité essence (par défaut 15 %).
- Profil pilote : contact SOS (nom + téléphone), km/jour par défaut, budget par défaut, style par défaut.
- Réglages : adresse companion (Tailscale), clé TomTom, unités, voix (on/off, volume), **interrupteur « annonces radar »** (désactivé par défaut), thème (auto jour/nuit).
- Écran « État du système » : companion joignable ?, date d'expiration de la signature, date des données radars/OSM, espace disque utilisé par les packs hors ligne.

### 4.2 Création d'un trip
**Étape 1 — Formulaire guidé** (questions successives, listes déroulantes, pas de bloc de texte) couvrant les 13 paramètres du cahier des charges :

| Champ | Contrôle UI | Source des valeurs |
|---|---|---|
| Nom court | Texte | — |
| Départ / arrivée (ou boucle) | Recherche + carte | Géocodage (Photon via companion, ou recherche locale) |
| Période | Sélecteur de dates (début/fin) | — ; durée calculée automatiquement |
| Zone | Liste : pays / régions / massifs + sélection sur carte | `core/Resources/regions.json` (maintenu dans le dépôt) |
| Moto(s) | Liste du garage + « ajouter » | Garage |
| Pilote(s) & bagagerie | Liste | Solo / duo ; sacoches oui/non |
| Km/jour max | Curseur (100–500) | — |
| Style | Curseur « conduite pure ↔ contemplatif » | — |
| Budget | Par jour ou global, € | — |
| Points de passage obligatoires | Carte + date/heure optionnelle | — |
| Contraintes particulières | Texte libre | — |
| Routes | Interrupteurs : exclure autoroutes / voies rapides / nationales rectilignes ; niveau de sinuosité (1–5) | Valeurs par défaut = cahier des charges |

**Contrôles de cohérence automatiques** (dans `TripCore`, avant d'appeler Claude) :
- km/jour × jours ≥ distance minimale estimée départ → arrivée ;
- période compatible avec l'ouverture des cols connus de la zone (`cols.json`, champ `source` + `lastVerified`) ;
- autonomie du groupe = autonomie de la moto la plus limitante.
Une incohérence déclenche une question, jamais une supposition.

**Étape 2 — Chat + carte en direct**
- Le formulaire est envoyé au `planner` comme contexte structuré ; le chat démarre avec une **proposition d'itinéraire jour par jour** (format « Étape 1 » du cahier des charges : distance, temps, tronçons remarquables, pleins, 2–3 repas, 2–3 hébergements).
- Chaque réponse du `planner` contient **du texte + un `trip.json` partiel** ; l'app redessine la carte immédiatement (tracé par jour, marqueurs typés).
- Interactions carte → chat : toucher un marqueur pour « remplacer ce restaurant », glisser un point de passage, « éviter cette route ». L'action est traduite en message structuré au `planner`.
- Chaque suggestion affiche sa source et son statut (`verified` / `unverified`).
- Sinuosité et dénivelé affichés par étape (calculés par `TripCore` à partir de la géométrie).

**Étape 3 — Validation**
- L'utilisateur choisit repas et hébergements (sélection parmi les propositions).
- Le `planner` produit la **feuille de route finale** (`trip.json` complet + itinéraires navigables par jour + plans B) + **export GPX** + **export PDF**.
- Déclenche **A7** (téléchargement hors ligne) puis **A8** (contrôle d'intégrité). Le trip passe au statut `ready` seulement si A8 est OK.

### 4.3 Préparation du départ (automatique)
- Checklist générée (A9) : ouverture effective des cols, statut des tunnels/passages, météo période, état post-hivernal, réservations (cases à cocher manuelles), rafraîchissement SideStore, charge batterie / câble.
- Revérifications automatiques (A10) avec historique « vérifié le … par … ».
- Alerte A14 si la signature de l'app expire pendant le trip.

### 4.4 Navigation (100 % locale)
**Écran principal** (lisible en un coup d'œil, utilisable avec des gants) :
- Carte orientée cap, tracé du jour, position.
- Bandeau haut : prochaine manœuvre (flèche + distance), nom de la route.
- Bandeau bas, 3 cases fixes : **prochain plein**, **prochain arrêt planifié** (repas/hôtel), **fin d'étape** — pour chacun : distance + **heure d'arrivée ajustée à l'allure**.
- Indicateur avance/retard sur le planning ; alerte si arrivée estimée après le coucher du soleil.
- Limitation de vitesse (OSM `maxspeed`).
- Bandeau météo : prochaine dégradation sur la route (lieu + heure de passage).
- Incidents trafic sur la route à venir (TomTom), si réseau.
- Radars fixes (si interrupteur activé) : type, limite, distance.
- Boutons larges : pause, recentrer, SOS (appui long), bascule 2D/3D.

**Comportements** :
- Guidage vocal (voix système), fonctionne écran verrouillé et app en arrière-plan.
- Écran maintenu allumé pendant la navigation.
- Passage automatique à l'étape suivante (arrivée à l'hôtel = fin de journée ; reprise le lendemain).
- **Hors tracé** : guidage local vers le point du tracé le plus proche dans le sens de marche ; recalcul en ligne via GraphHopper **uniquement si** le companion est joignable, sinon mode local.
- **Plan B** : activable en un appui pour les points critiques définis dans le trip (ex. tunnel fermé).
- **Carburant d'urgence** : stations OSM embarquées les plus proches dans le sens de marche.
- **SOS** : SMS pré-rempli (position GPS + lien carte) au contact SOS ; ne nécessite aucun serveur.
- Enregistrement de la trace réelle (A13).

### 4.5 Après le trip
- Trace réelle vs prévue, km, dénivelé, cols franchis, vitesse moyenne en mouvement.
- Export GPX de la trace réelle.
- Les coefficients d'allure appris (voir 5.1) sont conservés pour les trips suivants.
- Duplication d'un trip comme modèle.

---

## 5. Algorithmes (dans `TripCore`, entièrement testés)

### 5.1 Heure d'arrivée selon l'allure
```
Classes de route c ∈ {col_sinueux, departementale, liaison}
Pour chaque tronçon restant i de classe c :
  t_i = d_i / (v_routage_i × k_c)
k_c = moyenne mobile exponentielle (α = 0.2) du ratio v_réelle / v_routage,
      calculée uniquement moto en mouvement (v > 8 km/h), fenêtres de 60 s
Initialisation k_c : historique des trips précédents, sinon 1.0
Temps restant = Σ t_i + Σ arrêts planifiés restants (plein 10 min, repas selon plan, pauses)
```
Tests : trajets synthétiques, pauses exclues, convergence de `k_c`, bornes (0.4 ≤ k ≤ 1.6).

### 5.2 Placement des pleins
- Autonomie utile = autonomie la plus faible du groupe × (1 − marge).
- Balayage du tracé : dès que la distance depuis le dernier plein atteint l'autonomie utile moins 20 km, choisir la station OSM la plus proche du tracé (détour ≤ 3 km) en amont.
- Si aucune station : **alerte bloquante** à la création (« zone sans station entre X et Y »).
- Invariant testé : distance entre deux pleins ≤ autonomie utile, et ≤ 200 km par défaut (cahier des charges).

### 5.3 Météo sur la route
- Échantillonnage : un point tous les 15 km + chaque col + chaque arrêt.
- Pour chaque point : heure d'arrivée estimée (5.1) → prévision horaire Open-Meteo à cette heure.
- Alerte si : précipitations > 0,5 mm/h, rafales > 60 km/h, température < 5 °C, visibilité faible.
- Rafraîchissement : toutes les 20 min en navigation (si réseau), cache local ; affichage « météo du HH:MM » si données anciennes.
- Budget d'appels bien inférieur à la limite gratuite (10 000/jour).

### 5.4 Incidents trafic
- Toutes les 5 min (si réseau) : requête TomTom `incidentDetails` sur la boîte englobante des 50 prochains km.
- Filtrage : incident à moins de 50 m du tracé à venir → affichage + ajout du retard à l'heure d'arrivée.

### 5.5 Radars
- Base embarquée par trip (radars à < 100 m du tracé).
- Annonce à 500 m hors agglomération / 200 m en agglomération, si interrupteur activé.

### 5.6 Sinuosité
- Score par tronçon = Σ |Δcap| / distance, sur géométrie rééchantillonnée à 10 m ; normalisé 0–100. Affiché par étape à la création.

### 5.7 Détection hors tracé
- Écart latéral > 40 m pendant > 5 s ou > 3 points GPS consécutifs → mode hors tracé ; hystérésis pour éviter les faux positifs en lacets.

---

## 6. Modèle de données — `trip.json` (schéma v1)

```jsonc
{
  "schemaVersion": 1,
  "id": "uuid",
  "name": "Aix-Stelvio",
  "status": "draft | proposed | validated | ready | active | done",
  "params": {
    "start": {"name": "Aix-en-Provence", "lat": 43.53, "lon": 5.45},
    "end": {"name": "boucle"},
    "dateStart": "2027-05-24", "dateEnd": "2027-06-01",
    "zone": ["IT-Lombardia", "FR-Alpes"],
    "bikes": [{"model": "GSX1000S", "rangeKm": 250, "reserveMarginPct": 15}],
    "riders": "solo", "luggage": false,
    "maxKmPerDay": 300, "style": 0.7, "budgetPerDayEur": 200,
    "mandatoryStops": [], "constraints": "",
    "roads": {"avoidMotorway": true, "avoidTrunk": true, "curvinessLevel": 4}
  },
  "days": [
    {
      "index": 1, "date": "2027-05-24",
      "distanceKm": 250, "drivingTimeMin": 330, "curvinessScore": 78, "ascentM": 3200,
      "highlights": [{"name": "Col d'Izoard", "type": "pass", "lat": 0, "lon": 0}],
      "routeRef": "routes/day1.json",
      "planBRefs": [{"label": "Tunnel fermé", "routeRef": "routes/day1_planB.json"}],
      "fuelStops": [{"name": "…", "lat": 0, "lon": 0, "kmFromStart": 180}],
      "meals": [{"poi": {"$ref": "#/pois/…"}, "selected": true}],
      "lodging": [{"poi": {"$ref": "#/pois/…"}, "selected": true}]
    }
  ],
  "pois": [
    {
      "id": "…", "type": "meal | lodging | fuel | pass | viewpoint",
      "name": "…", "address": "…", "phone": "…", "website": "…",
      "lat": 0, "lon": 0,
      "source": "https://…", "verification": "verified | unverified", "verifiedAt": "2026-09-28"
    }
  ],
  "checklist": [{"id": "…", "label": "…", "due": "J-15", "done": false, "auto": true}],
  "offlinePack": {"tiles": "packs/trip.pmtiles", "radars": "packs/radars.json", "integrity": "ok | missing | unknown"}
}
```
**Format exact et à jour : [docs/trip-schema.md](docs/trip-schema.md)** (coordonnées regroupées dans `point`, repas/hébergements référencés par `poiId`).
Les itinéraires navigables (`routes/*.json`) sont au format attendu par Ferrostar (réponse GraphHopper `/navigate`), stockés tels quels.

---

## 7. API companion (Tailscale uniquement, jeton d'accès)

| Méthode | Route | Rôle |
|---|---|---|
| GET | `/health` | État des services (planner, graphhopper, dates des données) |
| POST | `/trips/{id}/chat` | Message utilisateur (+ action carte structurée) → texte + `trip.json` partiel (réponse en streaming) |
| POST | `/trips/{id}/finalize` | Feuille de route finale, itinéraires navigables, plans B, GPX, PDF |
| POST | `/route` | Calcul d'itinéraire (profil moto sinueuse) |
| POST | `/match` | GPX → itinéraire navigable (map matching) |
| GET | `/trips/{id}/offline-pack` | Pack hors ligne (tuiles extraites + radars + stations) |
| POST | `/trips/{id}/recheck` | Revérification cols/météo (A10) |
| GET/PUT | `/trips/{id}` | Sauvegarde/synchronisation (A11) |

**Planner (Claude Agent SDK)** :
- Consigne système = instructions du projet road trip (dans `companion/planner/system_prompt.md`), paramétrées par le formulaire.
- Outils exposés à Claude : recherche web, `route` / `match` GraphHopper, `stations_near(route)`, `radars_near(route)`, `cols_status(zone, dates)`.
- **Sortie validée par schéma JSON** (rejet et nouvelle tentative si `trip.json` invalide).
- Toute POI sans source → `verification: "unverified"` forcé côté serveur.

---

## 8. Sources de données

| Donnée | Source | Licence / condition | Mode |
|---|---|---|---|
| Fond de carte | Protomaps (PMTiles, dérivé OSM) | ODbL — attribution OSM | Hors ligne |
| Routage | GraphHopper + OSM | Apache 2.0 / ODbL | PC |
| Guidage | Ferrostar | BSD-3 | Local |
| Météo | Open-Meteo | CC BY 4.0, non commercial, < 10 000 appels/j | En ligne |
| Trafic | TomTom Traffic API | Offre gratuite, clé personnelle | En ligne |
| Radars FR | data.gouv.fr « Liste des radars fixes en France » | Licence ouverte | Hors ligne |
| Radars hors FR | OSM `highway=speed_camera` | ODbL | Hors ligne |
| Stations | OSM `amenity=fuel` (Overpass) | ODbL | Hors ligne |
| Limitations de vitesse | OSM `maxspeed` (dans l'itinéraire GraphHopper) | ODbL | Hors ligne |
| POI repas/hôtels | Recherche web via Claude | Source citée par POI | Création |

Écran « À propos » : toutes les attributions obligatoires.

---

## 9. Exigences non fonctionnelles

- **Sûreté de navigation** : aucune modale bloquante pendant la conduite ; toute erreur de service externe = bandeau discret ; le guidage survit à : perte réseau, appel entrant, verrouillage, passage en arrière-plan.
- **Hors ligne** : un trip `ready` doit être entièrement navigable en mode avion (test d'acceptation obligatoire).
- **Batterie** : GPS haute précision uniquement en navigation ; hors navigation, localisation coupée. Cible : < 15 %/h écran allumé (à mesurer).
- **Stockage** : pack hors ligne par trip, suppression automatique 30 jours après la fin du trip (paramétrable).
- **Sécurité** : companion accessible uniquement via Tailscale + jeton ; aucune clé dans le dépôt public (clés dans le trousseau iOS / `.env` local PC hors dépôt).
- **Robustesse** : versions de Ferrostar, MapLibre et GraphHopper épinglées ; mise à jour volontaire uniquement.

---

## 10. Risques et spikes (à traiter en premier)

| # | Spike | Question | Critère de sortie |
|---|---|---|---|
| S1 | CI iOS | IPA non signée XcodeGen + MapLibre + Ferrostar compile sur GitHub Actions et s'installe via Sideloadly/SideStore | App vide avec carte installée sur l'iPhone |
| S2 | PMTiles | MapLibre Native iOS lit un `.pmtiles` local ; sinon, alternative (pack hors ligne MBTiles servi par le companion) | Carte hors ligne en mode avion |
| S3 | Ferrostar + GraphHopper | Guidage sur itinéraire GraphHopper `/navigate` issu d'un GPX (map matching) | Guidage simulé sur l'étape Izoard |
| S4 | Profil sinueux | Modèle personnalisé GraphHopper donnant des tracés comparables à Kurviger sur 5 itinéraires de référence (Lourmarin, Bonnette…) | Validation visuelle par FAB |
| S5 | VPN | Bascule automatique Tailscale ↔ VPN SideStore via Raccourcis iOS | Procédure documentée ou limite actée |
| S6 | Agent SDK | Authentification abonnement sur le PC, consommation par trip mesurée | Coût en crédits d'un trip complet connu |
| S7 | Arrière-plan | Guidage vocal + GPS écran verrouillé 2 h sur iPhone signé gratuitement | Test terrain OK |

---

## 11. Hors périmètre V1
Fonctions de groupe · signalements communautaires (Waze/Coyote : pas d'accès légal/gratuit) · réservation automatique · détection de chute · CarPlay · Android · publication App Store.

## 12. Critères d'acceptation V1
1. Création d'un trip de 3 jours via formulaire + chat, carte mise à jour à chaque réponse.
2. Chaque POI affiche source et statut de vérification.
3. Pleins placés avec l'invariant 5.2 respecté sur tout le trip.
4. Validation → pack hors ligne téléchargé et vérifié automatiquement.
5. Navigation complète d'une étape **en mode avion** : guidage vocal, heure d'arrivée, prochain plein, changement d'étape.
6. Avec réseau : météo sur la route et incidents TomTom affichés.
7. Nouvelle version poussée sur `main` → disponible dans SideStore sans intervention sur le PC.
8. Redémarrage du PC → companion de nouveau joignable sans intervention.
