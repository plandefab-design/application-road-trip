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
| iPhone | iOS 17 ou plus récent avec code de verrouillage, [Tailscale](https://apps.apple.com/app/tailscale/id1470499037), LocalDevVPN (App Store), un identifiant Apple (gratuit) |
| PC (installation de SideStore) | iTunes, [iloader](https://docs.sidestore.io/docs/installation/prerequisites) |
| En ligne | Un compte GitHub |

### 2. Dépôt GitHub (déjà fait)
Le dépôt public est <https://github.com/plandefab-design/application-road-trip> (public = minutes de compilation macOS gratuites ; aucun secret n'est jamais dans le code). Pour un nouveau PC :
```powershell
git clone https://github.com/plandefab-design/application-road-trip.git
```
Chaque `git push` sur `main` lance les workflows (onglet **Actions**). À la fin d'`iOS build` (quelques minutes), une **Release** contient `MotoTrip-1.0.N.ipa` et `distribution/source.json` est mis à jour automatiquement.
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

**D. Installer MotoTrip**

9. LocalDevVPN connecté, SideStore › **Sources** › **+**, ajoute :
   `https://raw.githubusercontent.com/plandefab-design/application-road-trip/main/distribution/source.json`
10. Installe **MotoTrip** depuis cette source. Chaque nouvelle version poussée sur `main` y apparaîtra automatiquement.

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

Couverture : environ 4 000 km autour de Salon-de-Provence (Europe, Russie, Maghreb, Égypte, Proche-Orient), soit ~43 Go de cartes OSM. Mise à jour automatique toutes les 4 semaines, le dimanche à 13 h (ou dès que le PC est allumé) : tâche Windows « MotoTrip - mise a jour cartes et radars » (cartes, radars, dangers, stations, pauses, puis nouvel import GraphHopper de plusieurs heures construit à côté de l'ancien : le calcul de route reste disponible pendant ce temps). Journal : `companion\data\update_osm.log`. Lancement manuel : `powershell -ExecutionPolicy Bypass -File companion\jobs\update_osm.ps1`.

---

## Utilisation
1. **Réglages › Garage** : ajoute ta ou tes motos avec leur **type** (sportive, roadster, routière, trail, enduro, custom) et leur autonomie réelle.
   Optionnel : **Réglages › Navigation › Trafic TomTom** : colle la clé gratuite (developer.tomtom.com), **Tester la clé**, **Enregistrer**.
   Dans **Créer**, choisis l'**envie** (balade, kiff, rapide, tourisme) et ton **niveau** : Claude et le calcul de route s'adaptent (bitume sinueux, pistes trail, chemins enduro ouverts aux motos, ou rapide).
2. **Créer** : remplis le formulaire → **Vérifier la cohérence** → **Continuer avec Claude** (chat + carte).
   Le PC calcule ensuite automatiquement la route de chaque jour (routes sinueuses), le guidage virage par virage,
   les radars, les dangers et les stations ; l'iPhone place les pleins.
   Ou **Trips › Importer** : un `trip.json` ou un GPX produit par ton projet Claude « MOTO _ road trip ».
3. **Le jour du départ** : fiche du trip › **Préparer le départ** (tout est remis à jour d'un coup) ou, étape par étape (Tailscale actif pour le PC, Wi-Fi pour la carte) :
   - **Calculer le tracé et le guidage** si le bouton apparaît (trips créés avant ces fonctions) ;
   - **Télécharger la carte hors ligne** (la carte s'affiche ensuite sans réseau) ;
   - **Vérifier la météo sur la route** ;
   - **Préparation › Programmer les rappels** (cols, réservations, SideStore, batterie…).
4. Touche l'étape voulue → **Rouler — Jour N**. Annonces vocales : virages, radars à 500 m (interrupteur dans Réglages),
   dangers à 300 m, pleins, pauses, météo et trafic si réseau. Rien de tout ça n'a besoin du PC en roulant.
   En quittant : résumé de la sortie (trace réelle, km, virages…), gardé dans **Mes sorties** et sauvegardé sur le PC.
5. **Entretien** : Réglages › Entretien › choisis **Ma moto (compteur)**, ouvre son carnet et recopie le compteur une fois.
   Chaque sortie ajoute ensuite ses kilomètres ; l'accueil, une notification et « Préparer le départ » te préviennent
   des opérations à faire (vidange, chaîne, pneus, freins, révision…). Règle les intervalles selon le carnet de ta moto.

## Développer
```powershell
cd core; swift test                         # logique métier (Swift pour Windows : https://www.swift.org/install/windows/)
cd companion\planner; python -m pytest -q   # API du PC
claude                                      # Claude Code : « Lis CLAUDE.md et SPEC.md, puis continue le milestone suivant de docs/STATUS.md »
```
L'app iOS se compile uniquement dans GitHub Actions (`git push`).

## Attributions
Cartes © contributeurs OpenStreetMap (ODbL) · fond OpenFreeMap · rendu MapLibre · routage GraphHopper (Apache 2.0) · météo Open-Meteo (CC BY 4.0) · trafic TomTom.
