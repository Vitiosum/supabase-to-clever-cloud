# Déroulé de démo — 15 minutes

Runbook pour présenter la migration Supabase → Clever Cloud à un client
technique. Jouable par n'importe qui : chaque acte donne la commande exacte,
ce qu'on voit, et la phrase qui porte.

## Avant la réunion — 5 vérifications, 3 minutes

```bash
cd supabase-to-clever-cloud && ./scripts/verifier-produit.sh
```

1. La CI est verte (le script ci-dessus la rejoue en local).
2. La cible répond : `curl https://app-791a9278-5850-440f-94eb-7b0aaf1b7ae4.cleverapps.io/sante` → `{"etat":"ok"}`.
3. Le projet Supabase source est `ACTIVE_HEALTHY` (console Supabase).
4. Vous avez la valeur d'`API_SERVICE_TOKEN` sous la main (`clever env --alias cible`).
5. **Demandé au client en amont** : sa chaîne *Session pooler* (console
   Supabase → Connect), s'il veut voir son propre rapport en acte 2. Sinon,
   l'application de référence fait l'affaire.

---

## Acte 1 — Le constat (3 min)

**La phrase d'ouverture** : *« On ne migre pas Supabase. On migre votre
application. Et ce n'est pas un slogan — tout ce que je vais vous montrer a
été mesuré sur une application réelle, déployée des deux côtés. »*

Montrer [MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md), section 3 :

- cinq composants **sans équivalent** — ils se réécrivent, pas ne se portent ;
- **pgvector et PostGIS fournis par défaut** — la crainte n°1 des projets IA
  tombe en une ligne ;
- la contrainte de rôles qui décide de l'architecture.

**Si le client objecte** « et l'analyse statique de notre code ? » — section 5 :
93 risques identifiés par lecture, 68 réfutés à l'exécution. *« Ne validez
aucun plan qui n'a rien exécuté — pas même le nôtre. »*

---

## Acte 2 — Son rapport, en direct (4 min)

Le moment qui différencie : l'outil tourne sur **sa** base, en lecture seule,
devant lui.

```bash
SUPABASE_DB_URL='<sa chaîne Session pooler>' ./scripts/analyser-migration.sh
```

Lire `RAPPORT-MIGRATION.md` ensemble, dans cet ordre : **ses** extensions
classées (reprises / ticket / à remplacer), **ses** points structurants, et la
section 4 — *« vos demandes au support, prêtes à envoyer »*.

**La phrase** : *« Ce rapport est à vous. Il liste ce qui se reprend tel quel
chez vous, ce qui se demande, et ce qui se réécrit — avec la raison à chaque
ligne. »*

Sans chaîne client : montrer [RAPPORT-EXEMPLE.md](RAPPORT-EXEMPLE.md) en
expliquant qu'il a été généré par la même commande.

---

## Acte 3 — La preuve vivante (5 min)

La cible tourne. Six commandes, une histoire.

```bash
B=https://app-791a9278-5850-440f-94eb-7b0aaf1b7ae4.cleverapps.io
```

```bash
curl -s $B/sante
```

*« Une application Node ordinaire, un add-on PostgreSQL managé, un Cellar.
Aucun conteneur Supabase. »*

```bash
curl -s -H 'x-utilisateur-id: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' $B/patients
```

```bash
curl -s -H 'x-utilisateur-id: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' $B/patients
```

*« A ne voit que Yann. B ne voit qu'Anne. Ce sont les mêmes policies RLS que
chez Supabase — `auth.uid()` est devenu `current_setting`, c'est tout. »*

```bash
curl -s $B/patients
```

```bash
curl -s -H "x-utilisateur-id: '; drop table medical.patients; --" $B/patients
```

*« Anonyme : rien. Injection : rien. La base reste le garde-fou. »*

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST $B/taches/battement
```

*« 401 — et cette route est appelée toutes les 15 minutes par le cron de la
plateforme, qui remplace pg_cron. »*

**L'anecdote qui reste** : pendant la construction de cette cible, c'est
notre propre seed qui a été bloqué par `FORCE ROW LEVEL SECURITY` — le
propriétaire de la table lui-même ne contourne pas les policies. *« La
contrainte qu'on vous documente, on l'a vécue. »*

---

## Acte 4 — Conclure (3 min)

1. **Laisser le lien** : <https://github.com/Vitiosum/supabase-to-clever-cloud>
   — *« tout ce que je vous ai montré y est public, sourcé et daté »*.
2. **Laisser son rapport** (`RAPPORT-MIGRATION.md`), s'il a donné sa chaîne.
3. **Poser le calendrier** : les demandes support de son rapport partent cette
   semaine ; réponses écrites avant tout engagement de planning.
4. Contexte santé → [MIGRER-DEPUIS-SUPABASE-HDS.md](MIGRER-DEPUIS-SUPABASE-HDS.md),
   et l'argument en une phrase : *« le référentiel n'impose ni le chiffrement
   au repos ni la MFA — nous vous aidons à dimensionner sur ce que le texte
   impose vraiment. »*

## Les trois questions qui reviennent

| Question | Réponse tenable |
|---|---|
| « C'est moins cher ? » | *« Pas automatiquement — et je préfère vous le dire. On chiffre sur votre relevé, pas sur une grille. Ce qui change : le plafond se règle, la facturation est à la seconde, et vous sortez de cinq composants sans équivalent. »* |
| « Et notre Realtime ? » | *« Broadcast et Presence : un WebSocket ordinaire. Postgres Changes : pas sur l'add-on managé sans accord écrit — on vérifie d'abord lequel vous utilisez vraiment. »* |
| « Combien de temps la bascule ? » | *« Sur la référence : 1 min 42 d'extraction pour 20 000 vecteurs, 45 s de reconstruction d'index. On mesure la vôtre avec le même script, à vide, et on annonce une fourchette. »* |

**Ne jamais dire** : « déployé en région HDS donc conforme », « le support
ouvrira les rôles » (c'est *ni garanti ni exclu*), ou un prix de tête.
