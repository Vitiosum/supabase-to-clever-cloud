# Leaving Supabase, measured — Node.js, PostgreSQL and Cellar on Clever Cloud

> A complete Supabase application, a teleconsultation platform that leans on PostgREST, GoTrue, Storage, Realtime, Edge Functions, `pg_cron`, `pg_net`, Vault, `pgmq`, PostGIS and pgvector, actually deployed on Supabase Cloud, measured, then moved to Clever Cloud. **Every figure here comes from that run, not from an estimate.** On the Clever Cloud side an ordinary **Node.js** backend replaces PostgREST, GoTrue and Realtime, the **PostgreSQL add-on** keeps the same RLS policies (`auth.uid()` becomes `current_setting`), **Cellar** takes the buckets and the platform **cron** replaces `pg_cron` and `pg_net`. The full data migration ended with a per-identity access matrix identical to the source: 36 cells out of 36.

![Migration map: each Supabase component on the left, its Clever Cloud replacement on the right, the five extensions with no equivalent, and the measured figures (36/36 identical matrix, pg_dump 1 min 42 s for 324 MB, vector index rebuilt in 45 s, 68 of 93 static-analysis risks refuted)](docs/migration.png)

**Run it yourself.** The hosted demo was taken down after the presales review (November 2026). The steps in [Deploy on Clever Cloud](#deploy-on-clever-cloud) recreate the Clever Cloud target from scratch in about 10 minutes; filling it with the reference data needs the Supabase source (see [Run locally](#run-locally)) and `scripts/reprise-cible.sh`.

In one sentence: **you don't migrate Supabase, you migrate your application.** Five components have no equivalent anywhere else, and a standard managed database cannot host the Supabase stack. The simplest path is not to rebuild it, it is to replace it with an ordinary backend.

## What Clever Cloud does here

| Supabase piece | On Clever Cloud | Where |
|---|---|---|
| PostgREST, GoTrue, Realtime | One **Node.js** app (`APP_FOLDER=exemple-cible`): explicit routes, the user identity set per transaction | `exemple-cible/serveur.js` |
| RLS policies | **PostgreSQL add-on**, same policies: `auth.uid()` becomes `nullif(current_setting('app.utilisateur_id', true), '')::uuid`, plus `FORCE ROW LEVEL SECURITY` on every protected table, since the add-on role owns the tables and an owner bypasses RLS otherwise | `exemple-cible/db.js` |
| Storage buckets | **Cellar**, pre-signed URLs with the AWS SDK; the app checks rights *before* signing, since Cellar has no per-row policy | `exemple-cible/stockage.js` |
| `pg_cron` + `pg_net` | **Clever Cloud cron**: `clevercloud/cron.json` calls `clevercloud/tache.sh` every 15 minutes, which posts to `/taches/battement`; it runs on instance 0 only (`INSTANCE_NUMBER`), because crons run on every instance | `clevercloud/` at the repo root |
| Vault secrets | Environment variables | `API_SERVICE_TOKEN` |
| The data | `pg_dump` in three sections (pre-data, data, post-data, the only order that needs no superuser), with ten catalogued adaptations | `scripts/reprise-cible.sh` |
| The proof | The resource × identity matrix, replayed on the add-on and compared with the source | `scripts/recette-cible.sh` |

Measured on the real run (August 2026):

- **The source**: PostgreSQL 17.6, 16 extensions, 16 business tables, 55 RLS policies, 5 roles carrying `BYPASSRLS`, 5 `pg_cron` jobs, 3 Vault secrets, 4 buckets, 3 tables published to Realtime, 5 Edge Functions.
- **Cutover costs**, on 20,000 records each carrying a 1536-dimension vector: `pg_dump` schema only 7 s (73 KB), data only **1 min 42 s (324 MB)**, `auth` and `storage` 7 s (143 KB); rebuilding the vector index **45 s** (158 MB). The same dump took 102 s, then 495 s, depending on whether another workload was running. The index rebuild needs 65 MB of `maintenance_work_mem`: an instance offering only 32 MB cannot rebuild it.
- **Static analysis**: 93 risks identified by reading the repository, 68 refuted once executed.
- **The data migration** (24 August 2026): the 285 MB of the source moved to the add-on with ten adaptations; the identity matrix came out identical, 36/36 cells, the practitioner's 20,003 appointments included. Converting the service-role policies to `TO public` instead of dropping them published a `USING(true)`: 501 patients visible to everyone. They are dropped.
- **The cron replacement**, proven online (`HTTP 200` in `clever logs`). Three real runs, three traps: a `clevercloud/` folder inside an `APP_FOLDER` sub-folder is not read (`No cron to setup`); the crontab does not carry the application's variables (the script died in 5 ms); the fix is the `#!/bin/bash -l` shebang, never prefixed with `/bin/bash` in `cron.json`.
- **pgvector is missing from the shared DEV cluster (PG 15)**, where the migration ran: the extension catalogue depends on the plan, not on the product page.

## The documents

| Document | What it answers |
|---|---|
| **[MIGRATING-FROM-SUPABASE.md](MIGRATING-FROM-SUPABASE.md)** | What carries over, what has **no equivalent**, what the cutover costs in time, and how to prove the migration is faithful. **Start here.** |
| **[LANDING-ON-CLEVER-CLOUD.md](LANDING-ON-CLEVER-CLOUD.md)** | The concrete path: target architecture, commands, component-by-component mapping, and how to price it. |
| [MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md), [ATTERRIR-SUR-CLEVER-CLOUD.md](ATTERRIR-SUR-CLEVER-CLOUD.md) | The same two documents in French. |
| [MIGRER-DEPUIS-SUPABASE-HDS.md](MIGRER-DEPUIS-SUPABASE-HDS.md) | French health data hosting (HDS): what the framework actually requires, and the four received ideas that lead to wrong sizing. French only, its subject being French law. |
| [DEMO.md](DEMO.md) | The 15-minute customer demo: checks before the meeting, four acts with their exact commands, answers to the three recurring questions (French). |
| [RAPPORT-EXEMPLE.md](RAPPORT-EXEMPLE.md) | Sample output of the analyser below, generated on this repository's reference application. |
| [exemple-cible/README.md](exemple-cible/README.md) | The backend skeleton that replaces PostgREST, GoTrue and Realtime, and keeps RLS without the Supabase roles. |
| [CONSTATS-DEPLOIEMENT.md](CONSTATS-DEPLOIEMENT.md) | What deploying the reference app revealed, that reading the code did not (French). |
| [PROCEDURE-MIGRATION.md](PROCEDURE-MIGRATION.md) | The full method, applied to this case (French). |
| [DEPLOIEMENT.md](DEPLOIEMENT.md) | Deploying the reference app on a fresh Supabase project (French). |

*AI agents: see [llms.txt](llms.txt) for a structured index and the key facts.*

**Analyse your own project**, read-only:

```bash
SUPABASE_DB_URL='postgresql://…' ./scripts/analyser-migration.sh
```

It inventories your Supabase project (take the *Session pooler* string, IPv4) and crosses it with the verified mapping. The report, `RAPPORT-MIGRATION.md`, only talks about what *you* use: your extensions sorted into carried over / by ticket / to replace, your structural points, and your support requests ready to send.

## Deploy on Clever Cloud

You need [clever-tools](https://www.clever.cloud/developers/doc/cli/) (`clever login` done) and the ID of the organisation that will own the resources (`orga_…`, shown in the Console). Run the commands from the repo root: `clever create` links the folder to the new app. The app code lives in `exemple-cible/`; the cron stays in `clevercloud/` at the root, because a sub-folder's `clevercloud/` is not read.

```bash
# 1. The app and its size
clever create --type node supabase-demo-cible --org <org_id> --region par
clever scale --min-flavor nano --max-flavor XS --min-instances 1 --max-instances 2

# 2. PostgreSQL and Cellar, linked to the app
clever addon create postgresql-addon supabase-demo-pg --plan xxs_sml --option encryption=true --region par --org <org_id> --yes
clever service link-addon supabase-demo-pg
clever addon create cellar-addon supabase-demo-cellar --region par --org <org_id> --yes
clever service link-addon supabase-demo-cellar

# 3. Variables (the token is generated in the command and never printed)
clever env set APP_FOLDER exemple-cible
clever env set API_SERVICE_TOKEN "$(openssl rand -hex 32)"
clever env set CC_HEALTH_CHECK_PATH /sante

# 4. Deploy
clever deploy
curl -s https://<your-app>.cleverapps.io/sante        # {"etat":"ok"}
```

The target then runs, with an empty database: `/sante` answers, `/taches/*` answers 401 without the token, `/patients` fails until the schema is there. **The data** comes from the Supabase source, with PostgreSQL 17 client tools (`pg_dump` at least as recent as the source server) and `python3`:

```bash
read -rs SOURCE_URL && export SOURCE_URL   # paste the Supabase "Session pooler" URI; nothing is echoed
read -rs CIBLE_URL && export CIBLE_URL     # paste the add-on's POSTGRESQL_ADDON_URI (Console, add-on dashboard)
./scripts/reprise-cible.sh                 # phases A to F: target prep, schema, data, vector index, FORCE RLS, state
./scripts/recette-cible.sh                 # the identity matrix, printed next to the source reference
```

`reprise-cible.sh` is the migration that was actually played on the reference app, phase by phase, each adaptation commented. As written, it was run on the shared DEV cluster, which has no pgvector: it always loads the `vector(1536)` columns as text, so on a plan that has pgvector its index step (D) reports a failure and semantic search is left to rebuild. For your own project, start from `scripts/analyser-migration.sh` instead.

## Variables

| Variable | Set by | Role |
|---|---|---|
| `POSTGRESQL_ADDON_URI` | PostgreSQL add-on | Connection string (falls back to `DATABASE_URL`) |
| `CELLAR_ADDON_HOST` | Cellar add-on | **Bare hostname, no scheme**: the app prefixes `https://`. Required at start-up |
| `CELLAR_ADDON_KEY_ID`, `CELLAR_ADDON_KEY_SECRET` | Cellar add-on | S3 credentials; one key opens every bucket of the add-on |
| `API_SERVICE_TOKEN` | you, generated in the command | Required at start-up; protects `/taches/*`, sent by the cron as `Bearer` |
| `APP_FOLDER` | you | `exemple-cible` |
| `CC_HEALTH_CHECK_PATH` | you | `/sante`, which runs `select 1` on the add-on |
| `DB_POOL_MAX` | optional | Pool size, default 5. Rule: pool × max instances ≤ the plan's max connections, a number not published per plan: ask support before raising `--max-instances` |
| `INSTANCE_NUMBER` | Clever Cloud | The cron task runs on instance 0 only |
| `PORT` | Clever Cloud | 8080 |

Check the injected variable names in the Console (the app's environment variables) rather than guessing them.

## Routes

| Route | Replaces | What it does |
|---|---|---|
| `GET /sante` | | `{"etat":"ok"}`, or 503 if the database is unreachable |
| `GET /patients` | `GET /rest/v1/patients` | The rows the RLS policies let through for the identity in `x-utilisateur-id` (a UUID; anything else sets no context, so the policies return nothing) |
| `POST /rendez-vous` | `POST /rest/v1/rendez_vous` | `{praticienId, patientId, debut, fin}` → 201 with the id; `creneau` is a `tstzrange` |
| `GET /documents/:id/url` | `createSignedUrl()` | 60-second pre-signed Cellar URL (bucket `documents-medicaux`), 404 if the policy hides the row |
| `POST /taches/:nom` | `pg_cron` + `pg_net` → Edge Function | Needs `Authorization: Bearer $API_SERVICE_TOKEN`, 401 otherwise |

The skeleton trusts the `x-utilisateur-id` header: authentication is deliberately left out. Plug a JWT check, or a Keycloak add-on, in front of it before exposing it.

## Code tour

```
exemple-cible/            the Clever Cloud target (Node.js, Express, pg, AWS SDK)
  serveur.js              routes, and what each one replaces
  db.js                   RLS without the Supabase roles: set_config per transaction
  stockage.js             Cellar client, with the bare-hostname trap
  clevercloud/            the cron as you would write it for your own app
clevercloud/              the cron of the deployed target (repo root: APP_FOLDER hides sub-folders)
scripts/                  analyser, inventory, cost measures, data migration, identity matrices, CI check
app/, lib/, middleware.ts the reference app's Next.js 14 front (Supabase side)
supabase/                 the reference app's migrations, Edge Functions and config.toml
```

The reference app, on **Supabase Cloud**: Next.js 14, PostgREST called straight from the browser, no backend in between. It is **deliberately dense**, so the demonstration covers a wide surface; yours probably uses less. Three business roles share one base: the **patient** books, uploads documents, talks to the practitioner and reads closed reports; the **practitioner** runs the calendar, writes reports, prescribes and searches the history, with a second factor required for any medical content; the **front desk** sees the calendar and patient identities, never medical content. The table `medical.prises_en_charge` is the pivot: it decides which practitioner reaches which record, and every RLS policy derives from it.

```
Browser (Next.js)
   │
   ├── @supabase/supabase-js ──► PostgREST      (tables, views, RPC, RLS)
   │                          ├► GoTrue         (magic link, OIDC, MFA)
   │                          ├► Storage API    (4 buckets)
   │                          ├► Realtime       (postgres_changes, broadcast, presence)
   │                          └► Edge Functions (5 Deno functions)
   │
   └── Server Components ──► PostgREST via cookies (@supabase/ssr)

PostgreSQL
   ├── schema medical    → exposed through PostgREST
   ├── schema audit      → never exposed
   ├── schema auth_hooks → called by GoTrue
   ├── pg_cron → 5 scheduled jobs
   └── pg_net  → outgoing call to the antivirus on every upload
```

**Database, `supabase/migrations/`**

| File | Content |
|---|---|
| `..._extensions.sql` | 13 extensions, 7 of them specific to the Supabase image |
| `..._roles_et_schemas.sql` | 3 business schemas, roles `anon` / `authenticated` / `service_role` / `batch_runner`, default GRANTs |
| `..._tables.sql` | 14 tables, 4 enum types, `gist` exclusion constraint on the calendar, `pgsodium`-encrypted column (NIR), `ivfflat` index |
| `..._fonctions_triggers.sql` | 5 authorisation helpers, trigger `on auth.users`, audit log, 4 exposed RPCs, 1 `security_invoker` view |
| `..._rls.sql` | 34 policies, `force row level security` on the sensitive tables |
| `..._auth_hook_claims.sql` | GoTrue `custom_access_token` hook: business claims in the JWT |
| `..._storage.sql` | 3 buckets, 9 `storage.objects` policies |
| `..._realtime.sql` | Logical publication, `replica identity full`, policies on `realtime.messages` |
| `..._vault_cron_net.sql` | 3 Vault secrets, `pg_net` trigger, 3 `pg_cron` jobs (5 in all after post-deployment) |
| `..._geolocalisation.sql` | PostGIS, `geography(point)` on the practices, gist index, radius-search RPC, service areas as polygons |
| `..._webhooks_et_files.sql` | Database Webhook (`supabase_functions.http_request`), 3 `pgmq` queues, enqueue trigger |
| `..._storage_avance.sql` | `imagerie` bucket of 5 GB, TUS upload tracking, volume view |

**Edge Functions, `supabase/functions/`**: `rappel-rdv` (fired by `pg_cron`, sends the day-before reminders, `verify_jwt = false`), `ordonnance-pdf` (generates the PDF, stores it, computes its hash), `document-scan` (antivirus webhook, HMAC-authenticated), `recherche-semantique` (OpenAI embedding then `pgvector` through an RPC), `traiter-files` (consumes the `pgmq` queues, recomputes embeddings).

**Front, `app/` and `lib/`**: `lib/supabase/{client,server,admin}.ts` the three key levels · `middleware.ts` session refresh and `aal2` guard on `/dossiers` · `app/dossiers/[id]/messagerie.tsx` `postgres_changes` subscription · `app/teleconsultation/[id]/page.tsx` Presence and Broadcast (WebRTC signalling) · `app/documents/page.tsx` AES-GCM encryption in the browser before upload, signed URL · `lib/chiffrement.ts` application key from the environment · `lib/storage.ts` on-the-fly image transformation, resumable TUS upload · `app/recherche/page.tsx` PostGIS `st_dwithin` RPC from the browser's location.

No real data, no valid secret. The repository is also a test case for a migration exercise: some difficulties are **deliberate**. Left out on purpose, to keep the scope readable: payments, multi-tenancy, i18n, tests. The front is functional but minimal: the value is in the Supabase surface, not the interface.

## The 18 deliberately hard points

They are there to be found. A migration plan that does not mention them is incomplete.

1. **`pgsodium` / TCE on `patients.nir_chiffre`**: the `security label` does not restore as is through a plain `pg_dump`/`pg_restore`. Decision to make: application-level encryption instead, or an activation request.
2. **`supabase_vault`**: three secrets live there and are read by a trigger. Once out of the Vault, decide where they live.
3. **`pg_cron` + `pg_net`**: four jobs and an outgoing call in a trigger. Without the two extensions, the logic has to leave the database.
4. **GoTrue `custom_access_token` hook**: declared in `config.toml` as `pg-functions://`. To be rewritten as a GoTrue environment variable, and the `supabase_auth_admin` role must exist with the right GRANTs.
5. **`medical.mfa_verifiee()`**: the policies read the `aal` claim. Check that the redeployed GoTrue still emits it.
6. **Realtime**: logical publication, `replica identity full`, and policies on `realtime.messages` for Broadcast/Presence. The most expensive component to take over.
7. **`pg_graphql`**: enabled, but no `/graphql/v1` call anywhere in the code. The plan should say so rather than port it by reflex.
8. **`vector` + `ivfflat` index**: dimension 1536, scheduled reindexing.
9. **PostgREST roles**: `authenticator` must be able to assume the three roles, and `service_role` has `BYPASSRLS`. On a managed PostgreSQL these grants are not a given.
10. **Schema `audit` not exposed**: deliberately missing from `PGRST_DB_SCHEMAS`. The target PostgREST config must keep that scope.
11. **`app/api-recherche.ts`**: calls `supabase.functions.invoke()`, so a function URL to rewrite, not only the base URL.
12. **`supabase_functions.http_request`**: the dashboard's Database Webhooks are a house layer over `pg_net`, missing from a standard PostgreSQL. The `rdv_confirme_webhook` trigger depends on it.
13. **`pgmq`**: three queues and an enqueue trigger. The extension exists in open source; the dashboard's "Queues" integration does not.
14. **PostGIS**: a heavy extension, to confirm on the target platform.
15. **Storage image transformation**: `getPublicUrl(..., { transform })` relies on imgproxy, one more container to deploy.
16. **Resumable TUS upload**: endpoint `/storage/v1/upload/resumable`, segment size fixed at 6 MiB. To check behind another load balancer.
17. **Anonymous auth + identity linking**: pre-registration creates an anonymous user merged later. GoTrue behaviour to validate.
18. **Three distinct keys**: `anon` in the browser, `service_role` on the server and in two Edge Functions, `SUPABASE_JWT_SECRET` to sign them. All to regenerate consistently.

## Run locally

**The target**, against any PostgreSQL (port 8402 here):

```bash
cd exemple-cible && npm install
DATABASE_URL='postgresql://localhost/<db>' \
CELLAR_ADDON_HOST=<cellar-host> CELLAR_ADDON_KEY_ID=<key-id> CELLAR_ADDON_KEY_SECRET=<key-secret> \
API_SERVICE_TOKEN="$(openssl rand -hex 32)" PORT=8402 npm start
curl -s localhost:8402/sante                                              # {"etat":"ok"}
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8402/taches/x  # 401
```

The Cellar variables must be set for the server to start, even if no document route is called.

**The Supabase source**, on a Supabase project (full procedure in [DEPLOIEMENT.md](DEPLOIEMENT.md), scripted in `scripts/deployer.sh`):

```bash
cp .env.example .env.local     # fill in the Supabase project keys
npm install
npx supabase link --project-ref <your-ref>
npx supabase db push --include-all  # applies the 16 migrations
npx supabase functions deploy       # deploys the 5 Edge Functions
npm run dev
```

The extensions `pgsodium`, `pg_cron`, `pg_net`, `pgjwt`, `vector` and `supabase_vault` must be enabled on the project (Database → Extensions).

**The checks** the CI replays on every push (links, French/English parity, key figures, script syntax, no secret):

```bash
./scripts/verifier-produit.sh
```

## License

MIT, see [LICENSE](LICENSE).
