# Application road trip — MotoTrip

Application iPhone personnelle pour **créer** des road trips moto sur routes sinueuses (avec Claude, depuis ton PC)
et les **suivre en temps réel** (navigation 100 % locale, sans IA, sans dépendre du PC).

- Cahier des charges : [SPEC.md](SPEC.md)
- Consignes pour Claude Code : [CLAUDE.md](CLAUDE.md)
- Format des trips : [docs/trip-schema.md](docs/trip-schema.md)
- Avancement : [docs/STATUS.md](docs/STATUS.md)
- **Aperçu de l'app sans iPhone** : double-clic sur [preview/index.html](preview/index.html) (maquette interactive, données fictives)

```
app/          Application iOS (SwiftUI) — compilée dans le cloud (GitHub Actions)
core/         TripCore — toute la logique métier, testable sous Windows
companion/    Services du PC : planner Claude + moteur de routage GraphHopper (Docker)
scripts/      Outils CI (source SideStore)
distribution/ Source SideStore générée automatiquement
```

---

## Installation (une seule fois)

### 1. Prérequis
| Où | Quoi |
|---|---|
| PC Windows | [Git](https://git-scm.com/download/win), [Docker Desktop](https://www.docker.com/products/docker-desktop/) (option « Start when you sign in »), [Tailscale](https://tailscale.com/download/windows), [Claude Code](https://code.claude.com) |
| iPhone | iOS 17 ou plus récent, [Tailscale](https://apps.apple.com/app/tailscale/id1470499037), un identifiant Apple (gratuit) |
| En ligne | Un compte GitHub |

### 2. Publier le dépôt sur GitHub
Crée un dépôt **public** vide nommé `application-road-trip` (public = minutes de compilation macOS gratuites ; aucun secret n'est jamais dans le code), puis dans ce dossier :
```powershell
git remote add origin https://github.com/<ton-compte>/application-road-trip.git
git push -u origin main
```
Onglet **Actions** : les workflows `TripCore tests`, `Companion tests` et `iOS build` démarrent.
À la fin d'`iOS build` (≈ 15–25 min), une **Release** contient `MotoTrip-1.0.N.ipa` et `distribution/source.json` est créé automatiquement.

### 3. Installer l'app sur l'iPhone (sans Mac)
1. Installe **SideStore** sur l'iPhone en suivant le guide officiel : <https://docs.sidestore.io> (installation initiale depuis le PC Windows, iPhone branché en USB, avec ton identifiant Apple).
2. Dans SideStore › **Sources** › **+**, ajoute :
   `https://raw.githubusercontent.com/<ton-compte>/application-road-trip/main/distribution/source.json`
3. Installe **MotoTrip** depuis cette source. Chaque nouvelle version poussée sur `main` y apparaîtra automatiquement.

Alternative ponctuelle : télécharger l'IPA de la Release et l'installer avec [Sideloadly](https://sideloadly.io) (renouvellement à refaire tous les 7 jours).

> ⚠️ Compte Apple gratuit : l'app expire au bout de **7 jours** sans rafraîchissement. SideStore la re-signe depuis l'iPhone (VPN local de SideStore). iOS n'autorise qu'**un VPN à la fois** : rafraîchis SideStore, puis réactive Tailscale. **La navigation n'a besoin d'aucun des deux.** Avant un trip : rafraîchir la veille du départ.

### 4. Démarrer les services du PC (création de trips)
```powershell
cd companion
copy .env.example .env        # puis remplis PLANNER_TOKEN et CLAUDE_CODE_OAUTH_TOKEN (voir commentaires)
powershell -ExecutionPolicy Bypass -File jobs\update_osm.ps1     # 1er téléchargement des cartes OSM
docker compose up -d --build
curl http://localhost:8080/health
tailscale serve --bg 8080     # expose le planner en HTTPS sur ton réseau Tailscale privé
```
Dans l'app : **Réglages › Companion** → URL affichée par `tailscale serve` (ex. `https://mon-pc.xxxx.ts.net`) + le même jeton que `PLANNER_TOKEN` → **Tester la connexion**.

Mise à jour hebdomadaire automatique des cartes : voir l'en-tête de `companion/jobs/update_osm.ps1`.

---

## Utilisation
1. **Réglages › Garage** : ajoute ta ou tes motos avec leur autonomie réelle.
2. **Créer** : remplis le formulaire → **Vérifier la cohérence** → **Continuer avec Claude** (chat + carte).
   Ou **Trips › Importer** : un `trip.json` ou un GPX produit par ton projet Claude « MOTO _ road trip ».
3. Ouvre le trip → choisis l'étape → **Rouler**.

## Développer
```powershell
cd core; swift test                         # logique métier (Swift pour Windows : https://www.swift.org/install/windows/)
cd companion\planner; python -m pytest -q   # API du PC
claude                                      # Claude Code : « Lis CLAUDE.md et SPEC.md, puis continue le milestone suivant de docs/STATUS.md »
```
L'app iOS se compile uniquement dans GitHub Actions (`git push`).

## Attributions
Cartes © contributeurs OpenStreetMap (ODbL) · fond OpenFreeMap · rendu MapLibre · routage GraphHopper (Apache 2.0) · météo Open-Meteo (CC BY 4.0) · trafic TomTom.
