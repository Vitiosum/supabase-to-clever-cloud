# Votre rapport de migration Supabase → Clever Cloud

> **Ceci est un exemple de sortie de l'outil**, généré sur l'application de
> référence de ce dépôt. Lancez
> `SUPABASE_DB_URL='…' ./scripts/analyser-migration.sh` sur **votre** projet
> pour obtenir le vôtre — en lecture seule, rien n'est modifié.

*Généré le 2026-08-24 par `analyser-migration.sh` — relevé du 2026-08-24T07:32:00Z. Lecture seule : rien n'a été modifié.*

**Votre projet** : PostgreSQL 17.6, 365 MB, 16 extensions, 57 policies RLS.

## 1. Vos extensions, une par une

**Se reprennent telles quelles** (9) — `CREATE EXTENSION` suffit :

`btree_gist` 1.7, `pg_stat_statements` 1.11, `pg_trgm` 1.6, `pgcrypto` 1.3, `plpgsql` 1.0, `postgis` 3.3.7, `unaccent` 1.1, `uuid-ossp` 1.1, `vector` 0.8.2

**À demander au support** (2) — un ticket, comptez le délai :

- `pg_cron` 1.6.4
- `pg_net` 0.20.4

**Sans équivalent — à remplacer** (5) :

| Extension | Remplacement |
|---|---|
| `pg_graphql` 1.6.1 | le plus souvent : ne pas porter (verifiez vos appels /graphql/v1) |
| `pgjwt` 0.2.0 | signature JWT cote application |
| `pgmq` 1.5.1 | add-on Pulsar, ou table de file + tache planifiee |
| `pgsodium` 3.1.8 | chiffrement applicatif, ou pgcrypto (fourni par defaut) |
| `supabase_vault` 0.3.1 | variables d'environnement (clever env import) |

## 2. Les points qui décident de votre architecture

- **Chiffrement transparent pgsodium : 2 `SECURITY LABEL`.** Ne se restaure pas par `pg_dump`/`pg_restore`. À remplacer par du chiffrement applicatif — décision à prendre AVANT la bascule, elle touche au format des données.
- **`FORCE ROW LEVEL SECURITY` sur 2 table(s)** (`medical.consultations`, `medical.documents`). Vos scripts d'import doivent en tenir compte : ce qui passait avec `postgres` (BYPASSRLS chez Supabase) peut échouer ailleurs.
- **Realtime : 3 table(s) publiée(s).** Si vous utilisez *Postgres Changes*, le décodage logique n'est pas ouvert par défaut sur un add-on managé (demande support, jamais sans accord écrit). *Broadcast*/*Presence* : un WebSocket applicatif suffit.
- **1 Database Webhook(s)** (`rdv_confirme_webhook`) : surcouche propre à Supabase, à réécrire en appel HTTP applicatif.
- **5 tâche(s) `pg_cron`** → `clevercloud/cron.json`. Piège : les crons tournent sur CHAQUE instance — dédupliquez sur `INSTANCE_NUMBER` (voir `exemple-cible/clevercloud/tache.sh`).
- **3 secret(s) dans le Vault** → variables d'environnement (`clever env import`). Gain net : plus de secret déchiffré au fil des requêtes.
- **4 bucket(s) Storage** → Cellar (S3). 4 imposent des types MIME : cette contrainte est portée par la base chez Supabase, Cellar ne filtre pas — à réimplémenter côté application. Et une clé Cellar donne accès à tous les buckets de l'add-on.

## 3. Vos policies RLS : elles se conservent

Vos **57 policies** sont du PostgreSQL standard. Ce qui change, ce sont les rôles (`anon`, `authenticated`) — pas créables par défaut sur un add-on managé, mais on peut s'en passer entièrement :

```sql
-- remplacer            auth.uid()
-- par                  current_setting('app.utilisateur_id', true)::uuid
-- et poser le contexte par transaction depuis l'application :
--   select set_config('app.utilisateur_id', $1, true);
```

Motif complet et sûr sur pool de connexions : `exemple-cible/db.js`.

## 4. Vos demandes au support, prêtes à envoyer

1. activation des extensions : `pg_cron`, `pg_net`
2. **nombre maximal de connexions** du plan visé (non publié — il borne votre autoscaling : pool × instances ≤ ce chiffre)
3. chiffrement au repos (plans dédiés uniquement, non actif par défaut)
4. **PITR** si votre RPO l'exige — prestation facturée (setup task, sur devis), à budgéter au provisionnement
5. ouverture du décodage logique, si *Postgres Changes* est réellement utilisé — réponse écrite avant tout engagement

## 5. Pour continuer

- [MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md) — ce qui se passe, mesuré
- [ATTERRIR-SUR-CLEVER-CLOUD.md](ATTERRIR-SUR-CLEVER-CLOUD.md) — le chemin, commande par commande
- [exemple-cible/](exemple-cible/) — le squelette du backend cible
- `scripts/mesures-cout.sh` — chronométrez VOTRE fenêtre de bascule (à vide !)
- `scripts/recette-generique.py` — la matrice d'accès par identité qui prouvera que la reprise est fidèle. Paramétrez `recette.config.json` avec VOS ressources et VOS comptes (voir recette.config.exemple.json) ; `recette-rls.py` est la version instanciée pour l'application de référence.

*Généré à partir de votre base, en lecture seule. Les correspondances datent d'août 2026 : revérifiez la documentation avant de vous engager.*
