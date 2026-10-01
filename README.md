# Application road trip — Moto Road

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
| iPhone | iOS 17 ou plus récent avec code de verrouillage, [Tailscale](https://apps.apple.com/app/tailscale/id1470499037), LocalDevVPN (App Store), un identifiant Apple (gratuit) |
| PC (installation de SideStore) | iTunes, [iloader](https://docs.sidestore.io/docs/installation/prerequisites) |
| En ligne | Un compte GitHub |

### 2. Dépôt GitHub (déjà fait)
Le dépôt public est <https://github.com/plandefab-design/application-road-trip> (public = minutes de compilation macOS gratuites ; aucun secret n'est jamais dans le code). Pour un nouveau PC :
```powershell
git clone https://github.com/plandefab-design/application-road-trip.git
```
Chaque `git push` sur `main` lance les workflows (onglet **Actions**). À la fin d'`iOS build` (quelques minutes), une **Release** contient `MotoRoad-1.0.N.ipa` et `distribution/source.json` est mis à jour automatiquement.
Toutes les versions : <https://github.com/plandefab-design/application-road-trip/releases>

### 3. Installer l'app sur l'iPhone (sans Mac)
Résumé du guide officiel <https://docs.sidestore.io> (s'y référer en cas de doute : il évolue). Il faut du **Wi-Fi** (pas la 4G/5G) et un code de verrouillage sur l'iPhone.

**A. Préparer**
1. iPhone : installe **LocalDevVPN** (App Store), ouvre-la › **Connect** › autorise la configuration VPN.
2. PC : iTunes (version téléchargée chez Apple de préférence ; sinon l'app « Apple Devices »), puis **iloader** (installateur MSI, lien sur la page « Prerequisites » du guide).

**B. Installer SideStore depuis le PC**

3. Branche l'iPhone en USB › **Se fier à cet ordinateur** › code.
4. Ouvre **iloader** › connecte-toi avec ton identifiant Apple (sensible à la casse) › choisis l'iPhone › **Install SideStore (Stable)**.

**C. Sur l'iPhone**

5. Réglages › Général › **VPN et gestion de l'appareil** › « App de développeur » › ton identifiant › **Faire confiance** › **Autoriser et redémarrer**.
6. Réglages › **Confidentialité et sécurité** › tout en bas › **Mode développeur** (l'iPhone redémarre).
7. **LocalDevVPN** › **Connect**, puis ouvre **SideStore** et connecte-toi avec le même identifiant Apple.
8. **My Apps** › touche le compteur **« 7 DAYS »** de SideStore ; si on te propose de révoquer/créer un certificat : **Oui** / **Refresh Now**.

**D. Installer Moto Road**

9. LocalDevVPN connecté, SideStore › **Sources** › **+**, ajoute :
   `https://raw.githubusercontent.com/plandefab-design/application-road-trip/main/distribution/source.json`
10. Installe **Moto Road** depuis cette source (anciennement MotoTrip : même app, mise à jour normale, tes données sont gardées). Chaque nouvelle version poussée sur `main` y apparaîtra automatiquement.

Alternative ponctuelle : télécharger l'IPA de la Release et l'installer avec [Sideloadly](https://sideloadly.io) (renouvellement à refaire tous les 7 jours).

> ⚠️ Compte Apple gratuit : l'app expire au bout de **7 jours** sans rafraîchissement. SideStore la re-signe depuis l'iPhone ; **LocalDevVPN doit être connecté** pour installer, mettre à jour ou rafraîchir. iOS n'autorise qu'**un VPN à la fois** : coupe Tailscale, rafraîchis dans SideStore, puis réactive Tailscale. **La navigation n'a besoin d'aucun des deux.** Avant un trip : rafraîchir la veille du départ.
>
> Si SideStore n'arrive plus à rafraîchir après une mise à jour ou une réinitialisation de l'iPhone, le fichier d'appairage a expiré : le remplacer en suivant le guide officiel.

### 4. Démarrer les services du PC (création de trips)
Préalables (une fois) :
- **WSL** pour Docker : Terminal **administrateur** › `wsl --install --no-distribution`, puis redémarrer. Docker Desktop › ⚙️ › General › cocher « Start Docker Desktop when you sign in ».
- **Tailscale** connecté avec le même compte que l'iPhone. Au premier `tailscale serve`, Tailscale affiche un lien pour activer « Serve » (et HTTPS) sur ton compte : l'ouvrir et valider.
- **Jeton Claude** : `claude setup-token` (si `claude` n'est pas reconnu : `& "$env:USERPROFILE\.local\bin\claude.exe" setup-token`). Le coller dans `.env` sur `CLAUDE_CODE_OAUTH_TOKEN=`, sans le partager.

```powershell
cd companion
copy .env.example .env        # puis remplis PLANNER_TOKEN et CLAUDE_CODE_OAUTH_TOKEN (voir commentaires)
powershell -ExecutionPolicy Bypass -File jobs\update_osm.ps1     # 1er téléchargement des cartes OSM
docker compose up -d --build
curl http://localhost:8080/health
tailscale serve --bg 8080     # expose le planner en HTTPS sur ton réseau Tailscale privé
```
Dans l'app : **Réglages › Companion** → URL affichée par `tailscale serve` (ex. `https://mon-pc.xxxx.ts.net`) + le même jeton que `PLANNER_TOKEN` → **Tester la connexion**.

Couverture : **France**, **Italie** et **Espagne**. Les cartes sont listées dans `companion\maps.txt` : pour ajouter un pays ou une région, ajoute sa ligne Geofabrik (ex. `europe/spain`) puis lance le script ci-dessous. Hors de ces cartes, le calcul du tracé l'indique clairement ; les radars, eux, couvrent déjà l'Europe. Mise à jour automatique toutes les 4 semaines, le dimanche à 13 h (ou dès que le PC est allumé) : tâche Windows « MotoTrip - mise a jour cartes et radars » (cartes, radars, dangers, stations, pauses, puis nouveau calcul du routage construit à côté de l'ancien : le calcul de route reste disponible pendant ce temps). Journal : `companion\data\update_osm.log`. Lancement manuel : `powershell -ExecutionPolicy Bypass -File companion\jobs\update_osm.ps1`.

---

## Utilisation
L'app a 4 onglets : **Rouler**, **Favoris**, **Trips**, **Réglages**.

1. **Une fois** — Réglages › **Garage** : ta moto, son **type** et son **autonomie réelle**. Réglages › **Pilote** : contact SOS.
   Optionnel : Réglages › Navigation › **Trafic TomTom** (clé gratuite developer.tomtom.com).
2. **Rouler tout de suite** — onglet Rouler › gros bouton **Rouler** : radars, dangers, accidents et bouchons annoncés,
   km comptés pour l'entretien, trace enregistrée. **Où tu vas ?** : tape une adresse, suggestions en direct, itinéraire
   simple avec les mêmes annonces. Les ⭐ favoris se lancent d'un appui.
3. **Préparer un road trip** — Trips › **Nouveau** : formulaire (envie, niveau, budget, routes…) → **Continuer avec Claude**.
   Le PC calcule la route de chaque étape (profil moto), le guidage, les radars, les dangers, les stations et les pauses ;
   l'iPhone place les pleins. Chaque étape affiche distance, **temps de conduite**, arrêts et **heure d'arrivée**.
   Ou Trips › importer un `trip.json` / GPX.
4. **Cahier des charges** — fiche du trip › **Cahier des charges** : relis le cahier, les étapes et les lieux,
   coche **trajet / étapes / lieux**, **Valider**, puis **Créer le PDF** (cartes, horaires, adresses) à garder ou envoyer.
   Si le trip change ensuite (Claude, tracé, paramètres), l'app te demande de revalider.
5. **Le jour J** — fiche du trip › **Préparer** : tracé, trafic, météo, carte hors ligne, entretien, rappels, en un appui
   (Wi-Fi + Tailscale). Puis **Rouler — Étape N**.
6. **En roulant** — la voix annonce virages, radars (500 m puis « maintenant »), dangers (300 m), accidents et bouchons
   (20 km puis 1 km), limitation dépassée, pleins, pauses, météo. Un radar ou un virage passe toujours avant un message
   trafic, et ta musique reprend son volume après chaque annonce. Rien ne dépend du PC en roulant.
   **SOS** : appui long = appel ; bouton message = SMS avec ta position ; 👍 = « petit point » (tout va bien + ta ville).
7. **Entretien** — Réglages › Entretien : choisis **Ma moto**, recopie le compteur une fois ; chaque sortie ajoute ses km
   et l'accueil te prévient (vidange, chaîne, pneus, freins, révision…).

## Développer
```powershell
cd core; swift test                         # logique métier (Swift pour Windows : https://www.swift.org/install/windows/)
cd companion\planner; python -m pytest -q   # API du PC
claude                                      # Claude Code : « Lis CLAUDE.md et SPEC.md, puis continue le milestone suivant de docs/STATUS.md »
```
L'app iOS se compile uniquement dans GitHub Actions (`git push`).

## Attributions
Cartes © contributeurs OpenStreetMap (ODbL) · fond OpenFreeMap · rendu MapLibre · routage GraphHopper (Apache 2.0) · météo Open-Meteo (CC BY 4.0) · trafic TomTom · radars Sécurité routière (Etalab), DGT (CC BY), MapAtlas (CC BY 4.0) · événements Bison Futé (Licence Ouverte), DGT (CC BY).
