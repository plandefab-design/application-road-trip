# Groupe Moto Road — mise en place du serveur (une fois, ~20 min)

Pour rouler à plusieurs : **voix en direct** (casque intercom), **position des amis** sur la carte, **messages rapides**,
**trips partagés**. Tout passe par deux services gratuits sur Internet — **ni ton PC, ni Claude** :

| Service | Sert à | Compte |
|---|---|---|
| [Supabase](https://supabase.com) | comptes, groupes, positions, messages, trips partagés | gratuit |
| [LiveKit Cloud](https://livekit.io) | la voix (WebRTC) | gratuit |

Les quotas gratuits changent : regarde leurs pages « Pricing » avant d'inviter beaucoup de monde (2–3 amis, c'est très
en dessous). Un projet Supabase gratuit peut se **mettre en pause après une période sans activité** : si le groupe ne
répond plus, ouvre le tableau de bord Supabase et clique **Restore**.

> L'app marche exactement comme avant sans tout ça. Le groupe est une couche en plus : en roulant, une panne ou une
> zone sans réseau ne change rien au guidage.

## 1. Supabase

1. Crée un compte et un **nouveau projet** (région Europe). Garde le mot de passe de base de données quelque part sûr.
2. **SQL Editor › New query** : colle tout le contenu de [`supabase/schema.sql`](supabase/schema.sql) › **Run**.
   (Relançable sans danger. Le message sur `pg_cron` est facultatif : c'est le nettoyage automatique des positions oubliées.)
3. **Authentication › Sign In / Providers › Email** : **désactive « Confirm email »**. Sans ça, chaque ami doit cliquer un
   lien reçu par e-mail, et l'envoi d'e-mails du forfait gratuit est très limité. Mot de passe minimum : 8 caractères.
4. **Project Settings › API** : note l'**URL** du projet (`https://xxxx.supabase.co`) et la **clé publique**
   (« anon » / « publishable »). Cette clé est faite pour être dans l'app ; **ne copie jamais** la clé `service_role`.

## 2. LiveKit (la voix)

1. Crée un compte LiveKit Cloud et un projet.
2. **Settings › Keys** : crée une clé. Note l'**URL** (`wss://xxxx.livekit.cloud`), la **clé API** et le **secret**.

## 3. Relier les deux : la fonction `livekit-token`

Le secret LiveKit ne doit jamais être dans l'app. Une petite fonction Supabase vérifie que tu es membre du groupe et te
donne un jeton de 6 h, valable pour **ce** salon seulement.

**Par le tableau de bord (le plus simple)** : Edge Functions › **Deploy a new function** › via l'éditeur › nom
`livekit-token` › colle [`supabase/functions/livekit-token/index.ts`](supabase/functions/livekit-token/index.ts) › Deploy.
Puis Edge Functions › **Secrets** › ajoute :

| Nom | Valeur |
|---|---|
| `LIVEKIT_URL` | `wss://xxxx.livekit.cloud` |
| `LIVEKIT_API_KEY` | la clé API LiveKit |
| `LIVEKIT_API_SECRET` | le secret LiveKit |

**Ou en ligne de commande** (Supabase CLI) :
```powershell
npx supabase login
npx supabase link --project-ref <identifiant-du-projet>
npx supabase secrets set LIVEKIT_URL=wss://xxxx.livekit.cloud LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=...
npx supabase functions deploy livekit-token
```
Laisse la vérification du jeton (« Verify JWT ») **activée**, c'est son réglage par défaut.

## 4. Dans l'app

1. Onglet **Groupe** › colle l'adresse du projet et la **clé publique** › **Enregistrer**.
2. **Créer un compte** (pseudo, e-mail, mot de passe) › **Créer un groupe**.
3. **Membres et invitation › Inviter un ami** : envoie le lien (Messages, WhatsApp…).
   Chez ton ami, après avoir installé l'app : un appui sur le lien règle le serveur et le code ; il n'a plus qu'à créer son
   compte. Si le lien n'est pas cliquable dans sa messagerie : il **copie le message** puis, dans l'onglet Groupe,
   **Coller** (il ne tape ni adresse ni clé).
4. **Voix** : onglet Groupe › **Rejoindre la voix** (iOS demande l'accès au micro la première fois, à l'arrêt). Branche le
   casque intercom en Bluetooth au téléphone *avant*. Ensuite, en roulant, un bouton micro apparaît sur la carte.
5. **Position** : active **Partager ma position en roulant** (désactivé par défaut). Elle n'est envoyée que pendant une
   navigation ou une balade libre, disparaît 5 minutes après la dernière mise à jour, et s'efface quand tu arrêtes.

## Ce qu'il faut savoir

- **Pas de notifications** quand l'app est fermée : iOS les réserve aux comptes développeur payants (hors périmètre
  « 0 € »). Les messages arrivent à l'ouverture de l'app et en direct pendant une balade (lus à voix haute).
- **L'intercom du casque (Sena, Cardo…)** reste un appareil Bluetooth du téléphone : micro et oreillettes. Son groupe
  « local » n'est pas relié à celui de l'app : l'app relie les motards éloignés.
- **Données** : sur le serveur, seulement ton e-mail, ton pseudo, ta dernière position (5 min), tes messages (90 jours,
  nettoyage automatique si `pg_cron` est actif) et les trips que tu partages. **Réglages du groupe › Mon compte ›
  Supprimer mon compte** efface tout.
- **Sécurité** : chaque table n'est lisible que par les membres du groupe (règles RLS dans `schema.sql`, vérifiées par un
  scénario de test : un intrus ne voit ni positions, ni messages, ni trips). La clé publique seule ne donne accès à rien.
  Un code d'invitation ouvre le groupe : change-le (**Changer le code**) si tu veux fermer l'accès.
- **Groupe plein** à 10 motards (limite volontaire, dans `join_group`).
