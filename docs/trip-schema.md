# trip.json — schéma v1 (format exact)

Source de vérité : `core/Sources/TripCore/Model/Trip.swift`. Ce document est inclus dans la consigne du planner.

Écart volontaire avec l'exemple de SPEC §6 : les coordonnées sont regroupées dans un objet `point`
(`{"lat", "lon", "ele?"}`), et les repas/hébergements d'une étape référencent les POI par `poiId`.

## Règles
- Dates : `"yyyy-MM-dd"`. Distances en km, durées en minutes, altitudes en mètres.
- `status` : `draft | proposed | validated | ready | active | done`.
- `pois[].type` : `meal | lodging | fuel | pass | viewpoint`.
- `pois[].verification` : `verified` **uniquement** si `source` contient une URL vérifiable ; sinon `unverified` (forcé par le PC et par l'iPhone).
- Champs facultatifs : peuvent être omis. Listes absentes = listes vides.
- `days[].index` commence à 1 et se suit.
- `days[].fuelStops[].kmFromStart` : distance depuis le départ de l'étape ; écart entre deux pleins ≤ `params.maxFuelIntervalKm` et ≤ autonomie utile de la moto la plus limitante.
- `days[].track` : géométrie de l'étape (liste de points) quand elle est connue ; sinon omis (le PC la calcule avec GraphHopper).
- `days[].instructions` (**v2**) : guidage virage par virage calculé par le PC avec la route, `[{"along": mètres depuis le début du tracé, "maneuver": depart|straight|slightLeft|slightRight|turnLeft|turnRight|sharpLeft|sharpRight|keepLeft|keepRight|uTurn|roundabout|via|arrive, "text": "Tournez à gauche sur D943", "street"?, "exit"?}]`. Jamais écrit par Claude.
- `days[].alerts` (**v3**) : radars et dangers à moins de 40 m du tracé, issus d'OpenStreetMap (`highway=speed_camera`, `hazard=*`), `[{"along": mètres, "kind": speedCamera|redLightCamera|sectionCamera|hazard, "label": "chutes de pierres", "maxspeed"?: 80, "point"?}]`. Annonces : radars à 500 m puis « maintenant », dangers à 300 m, toujours actives. Jamais écrit par Claude.
- `days[].stations` (**v4**) : stations-service OSM (`amenity=fuel`) à moins de 3 km du tracé, `[{"id", "name", "point"}]`. L'iPhone y place les `fuelStops` (SPEC §5.2, plein complet au départ de chaque jour) et signale les tronçons sans station. Jamais écrit par Claude.

### Versions
- **v7** : `days[].instructions[].ref` (numéro de route, « D 543 ») et `days[].instructions[].toward` (direction indiquée, « Cadenet »), optionnels : le guidage vocal dit « tournez à gauche sur la D543, direction Cadenet ». Annonces radar et danger toujours actives.
- **v6** : `days[].speedLimits` (`[{"from", "to", "kmh"}]`, limites légales connues, OSM via GraphHopper ; tronçons inconnus absents), `days[].pauses` (`[{"along", "kind": cafe|viewpoint|water, "name", "point"}]`, un par type tous les 3 km), `updatedAt` (ISO 8601 UTC, le plus récent gagne à la synchro iPhone ↔ PC).
- **v5** : `params.bikes[].category` (sport|roadster|touring|trail|enduro|custom), `params.tripStyle` (balade|kiff|rapide|tourisme), `params.level` (debutant|intermediaire|confirme|expert), tous optionnels. Ils choisissent le profil de route du PC (moto_curvy, moto_fast, moto_adventure, moto_enduro : la moto la plus « routière » du groupe décide) et guident Claude.
- **v4** : ajout de `days[].stations` (optionnel).
- **v3** : ajout de `days[].alerts` (optionnel).
- **v2** : ajout de `days[].instructions` (optionnel). Un fichier v1 est lu tel quel et passe en v2 (aucun champ supprimé ni renommé).
- v1 : version initiale.

## Exemple complet (valeurs fictives)
```json
{
  "schemaVersion": 7,
  "id": "3F2A0C1E-0000-0000-0000-000000000001",
  "name": "Exemple",
  "status": "proposed",
  "params": {
    "start": {"name": "Ville A", "point": {"lat": 43.50, "lon": 5.40}},
    "end": null,
    "dateStart": "2027-06-01",
    "dateEnd": "2027-06-03",
    "zone": ["FR-ALPES-SUD"],
    "bikes": [{"id": "b1", "model": "Suzuki GSX-S1000", "rangeKm": 230, "reserveMarginPct": 15}],
    "riders": "solo",
    "luggage": false,
    "maxKmPerDay": 300,
    "style": 0.2,
    "budgetPerDayEur": 150,
    "mandatoryStops": [],
    "constraints": "",
    "roads": {"avoidMotorway": true, "avoidTrunk": true, "curvinessLevel": 5},
    "maxFuelIntervalKm": 200
  },
  "days": [
    {
      "index": 1,
      "date": "2027-06-01",
      "distanceKm": 240,
      "drivingTimeMin": 330,
      "curvinessScore": 70,
      "ascentM": 3500,
      "highlights": [{"name": "Col X", "type": "pass", "point": {"lat": 44.1, "lon": 6.8}}],
      "fuelStops": [{"name": "Station Y", "point": {"lat": 44.0, "lon": 6.5}, "kmFromStart": 150}],
      "planBRefs": [],
      "meals": [{"poiId": "poi-meal-1", "selected": false}],
      "lodging": [{"poiId": "poi-hotel-1", "selected": false}]
    }
  ],
  "pois": [
    {"id": "poi-meal-1", "type": "meal", "name": "Auberge Z", "address": "…", "phone": "…",
     "website": "https://…", "point": {"lat": 44.2, "lon": 6.7},
     "source": "https://… (page consultée)", "verification": "verified", "verifiedAt": "2026-09-28",
     "note": "horaires non confirmés"},
    {"id": "poi-hotel-1", "type": "lodging", "name": "Hôtel W", "verification": "unverified"}
  ],
  "checklist": [{"id": "c1", "label": "Vérifier l'ouverture du col X", "due": "J-15", "done": false, "auto": true}],
  "offlinePack": {"integrity": "unknown"}
}
```
