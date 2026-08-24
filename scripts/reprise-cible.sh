#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Reprise des donnees : Supabase (source) -> add-on PostgreSQL Clever Cloud.
#
#   SOURCE_URL='postgresql://...' CIBLE_URL='postgresql://...' \
#     ./scripts/reprise-cible.sh [dossier_travail]
#
# C'est la reprise REELLEMENT JOUEE sur le cas de reference, phase par phase,
# avec le catalogue des adaptations qu'un dump Supabase impose sur une base
# managee standard. Chaque adaptation est commentee : c'est la partie
# « modification du code » de la migration, executee et non decrite.
#
# Phases :
#   A  preparer la cible : schema extensions (miroir de la source), shim auth
#   B  schema : dump --no-owner --no-privileges + adaptations, erreurs cataloguees
#   C  donnees : sans l'index vectoriel, chronometre
#   D  index vectoriel : recree sur la cible, chronometre
#   E  FORCE RLS partout (l'application se connecte en proprietaire)
#   F  recette : matrice par identite, a comparer a celle de la source
# ---------------------------------------------------------------------------
set -uo pipefail

SRC="${SOURCE_URL:?SOURCE_URL non definie}"
DST="${CIBLE_URL:?CIBLE_URL non definie}"
W="${1:-/tmp/reprise}"
mkdir -p "$W"

pg="/opt/homebrew/bin"
[[ -x "$pg/psql" ]] || pg="$(dirname "$(command -v psql)")"

etape() { echo; echo "==> $*"; }

# --- Phase A : preparer la cible --------------------------------------------
etape "A. Preparation de la cible"

"$pg/psql" "$DST" -v ON_ERROR_STOP=0 -q <<'SQL' 2>"$W/A.err"
-- Le schema de demonstration cede la place aux vraies donnees.
drop schema if exists medical cascade;
drop schema if exists audit cascade;
drop schema if exists auth_hooks cascade;

-- CONSTATE : sur ce cluster partage (PG 15.4), plusieurs extensions
-- preexistent dans PUBLIC et ne sont pas relogeables (postgis). Et `vector`
-- n'est PAS disponible — la recherche vectorielle exige un plan dont le
-- cluster embarque pgvector. On installe donc dans public, et le dump sera
-- re-prefixe extensions. -> public. (adaptation n°4).
create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;
create extension if not exists btree_gist;
create extension if not exists unaccent;
create extension if not exists pg_trgm;
create extension if not exists postgis;
do $$
begin
  begin
    create extension if not exists vector;
    raise notice 'pgvector : DISPONIBLE';
  exception when others then
    raise notice 'pgvector : INDISPONIBLE sur ce cluster (%) — colonnes vector degradees en text', sqlerrm;
  end;
end $$;

-- SHIM auth.* : la piece centrale de l'adaptation.
-- Chez Supabase, auth.uid() lit le JWT pose par PostgREST dans
-- request.jwt.claims. Ici, l'application pose soit app.utilisateur_id
-- (exemple-cible/db.js), soit un request.jwt.claims complet. Le shim accepte
-- les deux : LES POLICIES DU DUMP NE CHANGENT PAS D'UNE LIGNE.
create schema if not exists auth;
create or replace function auth.uid() returns uuid
language sql stable as $$
  select coalesce(
    nullif(current_setting('app.utilisateur_id', true), '')::uuid,
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
  )
$$;
create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;
create or replace function auth.role() returns text
language sql stable as $$
  select coalesce(auth.jwt() ->> 'role', 'anon')
$$;

-- Test documente : la creation de roles est-elle permise ?
do $$
begin
  begin
    create role anon nologin;
    raise notice 'CREATE ROLE anon : PERMIS';
  exception when others then
    raise notice 'CREATE ROLE anon : REFUSE (%)', sqlerrm;
  end;
end $$;
SQL
grep -E "NOTICE|ERROR" "$W/A.err" | sed 's/^/   /' | head -8

# --- Phase B : le schema, avec adaptations ----------------------------------
etape "B. Schema (dump frais --no-owner --no-privileges, puis adaptations)"

# EN TROIS SECTIONS — la lecon de la premiere tentative : restaurer le
# schema complet (FK, triggers) AVANT les donnees impose --disable-triggers,
# qui exige superuser (refuse : « system trigger »security. Sans lui, les COPY
# tombent sur l'ordre des cles etrangeres. pre-data -> donnees -> post-data
# est l'ordre canonique, et il n'exige aucun privilege.
"$pg/pg_dump" "$SRC" --schema-only --no-owner --no-privileges --section=pre-data \
  --schema=medical --schema=audit --schema=auth_hooks --schema=public \
  -f "$W/schema.sql" 2>"$W/B-dump.err"
"$pg/pg_dump" "$SRC" --schema-only --no-owner --no-privileges --section=post-data \
  --schema=medical --schema=audit --schema=auth_hooks --schema=public \
  -f "$W/postdata.sql" 2>>"$W/B-dump.err"

python3 - "$W/schema.sql" "$W/schema-adapte.sql" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
adaptations = []

# 1. SECURITY LABEL pgsodium : ne se restaure pas hors image Supabase.
n = len(re.findall(r"^SECURITY LABEL FOR pgsodium.*?;$", t, re.M | re.S))
t = re.sub(r"^SECURITY LABEL FOR pgsodium.*?;$", "-- [adaptation] SECURITY LABEL pgsodium retire (chiffrement applicatif a la place)", t, flags=re.M | re.S)
if n: adaptations.append(f"{n} SECURITY LABEL pgsodium retires")

# 2a. Policies destinees aux ROLES DE SERVICE (supabase_auth_admin,
#     service_role, batch_runner) : leur consommateur (GoTrue, PostgREST
#     service) n'existe plus sur la cible. Les convertir en TO public
#     PUBLIERAIT leurs USING(true) — constate : 501 patients visibles de
#     tous. Elles se SUPPRIMENT.
motif_service = r"^CREATE POLICY [^;]*TO (?:service_role|supabase_auth_admin|batch_runner)(?:\s*,\s*(?:service_role|supabase_auth_admin|batch_runner))*[^;]*;"
n = len(re.findall(motif_service, t, re.M | re.S))
t = re.sub(motif_service, "-- [adaptation] policy de role de service supprimee (consommateur absent)", t, flags=re.M | re.S)
if n: adaptations.append(f"{n} policy(ies) de roles de service SUPPRIMEE(S) — les convertir eut ete une faille")

# 2b. Policies utilisateurs (anon/authenticated) : l'application se connecte
#     en proprietaire, la restriction par role n'a plus d'objet -> TO public.
n = len(re.findall(r"TO (?:anon|authenticated)(?:\s*,\s*(?:anon|authenticated))*", t))
t = re.sub(r"TO (?:anon|authenticated)(?:\s*,\s*(?:anon|authenticated))*", "TO public", t)
if n: adaptations.append(f"{n} clauses TO anon/authenticated -> TO public")

# 3. Le trigger sur auth.users (gerer_nouvel_utilisateur) : la table n'existe
#    pas ici, GoTrue est remplace.
n = len(re.findall(r"^CREATE TRIGGER \w+\s[^;]*ON auth\.users[^;]*;", t, re.M | re.S))
t = re.sub(r"^CREATE TRIGGER \w+\s[^;]*ON auth\.users[^;]*;", "-- [adaptation] trigger sur auth.users retire (GoTrue remplace)", t, flags=re.M | re.S)
if n: adaptations.append(f"{n} trigger(s) sur auth.users retires")

# 4. Colonnes vector : indisponible sur ce cluster -> text (les donnees
#    textuelles du dump se chargent telles quelles ; la recherche vectorielle
#    exige un plan avec pgvector).
n = len(re.findall(r"extensions\.vector\(\d+\)", t))
t = re.sub(r"extensions\.vector\(\d+\)", "text", t)
if n: adaptations.append(f"{n} colonne(s) vector degradee(s) en text (pgvector absent du cluster)")
n = len(re.findall(r"^CREATE INDEX \w+ ON [^;]*ivfflat[^;]*;", t, re.M | re.S))
t = re.sub(r"^CREATE INDEX \w+ ON [^;]*ivfflat[^;]*;", "-- [adaptation] index ivfflat retire (pgvector absent)", t, flags=re.M | re.S)
if n: adaptations.append(f"{n} index ivfflat retire(s)")

# 4bis. References vector NUES (arguments/retours de fonctions).
n = len(re.findall(r"extensions\.vector\b", t))
t = re.sub(r"extensions\.vector\b", "text", t)
if n: adaptations.append(f"{n} reference(s) vector nue(s) degradee(s) en text")

# 4ter. Idempotence : le schema public de la cible n'est pas droppable
#       (pas proprietaire) — les fonctions publiques passent en OR REPLACE.
n = t.count("CREATE FUNCTION public.")
t = t.replace("CREATE FUNCTION public.", "CREATE OR REPLACE FUNCTION public.")
if n: adaptations.append(f"{n} fonction(s) public.* en CREATE OR REPLACE (idempotence)")

# 6. Triggers de chiffrement generes par le SECURITY LABEL pgsodium : le
#    label materialise des triggers qui appellent pgsodium.* a CHAQUE insert.
#    Les donnees migrent deja chiffrees : suppression, chiffrement applicatif.
n = len(re.findall(r"^CREATE (?:TRIGGER|FUNCTION) [^;]*encrypt_secret[^;]*;", t, re.M | re.S))
t = re.sub(r"^CREATE (?:TRIGGER|FUNCTION) [^;]*encrypt_secret[^;]*;", "-- [adaptation] trigger/fonction pgsodium encrypt_secret supprime", t, flags=re.M | re.S)
if n: adaptations.append(f"{n} trigger(s)/fonction(s) de chiffrement pgsodium supprime(s)")

# 5. Le cluster heberge les extensions dans public, la source dans
#    extensions : re-prefixage global des references.
n = t.count("extensions.")
t = t.replace("extensions.", "public.")
if n: adaptations.append(f"{n} references extensions.* re-prefixees public.*")

open(sys.argv[2], "w").write(t)
print("\n".join("   [adaptation] " + a for a in adaptations))
PY

python3 - "$W/postdata.sql" "$W/postdata-adapte.sql" <<'PY2'
import re, sys
t = open(sys.argv[1]).read()
t = re.sub(r"^SECURITY LABEL FOR pgsodium.*?;$", "-- [adaptation] label pgsodium retire", t, flags=re.M | re.S)
t = re.sub(r"^CREATE POLICY [^;]*TO (?:service_role|supabase_auth_admin|batch_runner)(?:\s*,\s*(?:service_role|supabase_auth_admin|batch_runner))*[^;]*;", "-- [adaptation] policy de role de service supprimee", t, flags=re.M | re.S)
t = re.sub(r"TO (?:anon|authenticated)(?:\s*,\s*(?:anon|authenticated))*", "TO public", t)
t = re.sub(r"^CREATE TRIGGER \w+\s[^;]*ON auth\.users[^;]*;", "-- [adaptation] trigger auth.users retire", t, flags=re.M | re.S)
t = re.sub(r"^CREATE INDEX \w+ ON [^;]*ivfflat[^;]*;", "-- [adaptation] index ivfflat retire", t, flags=re.M | re.S)
t = re.sub(r"extensions\.vector\(\d+\)", "text", t)
t = re.sub(r"extensions\.vector\b", "text", t)
t = re.sub(r"^CREATE (?:TRIGGER|FUNCTION) [^;]*encrypt_secret[^;]*;", "-- [adaptation] pgsodium encrypt_secret supprime", t, flags=re.M | re.S)
t = t.replace("extensions.", "public.")
open(sys.argv[2], "w").write(t)
PY2

"$pg/psql" "$DST" -v ON_ERROR_STOP=0 -q -f "$W/schema-adapte.sql" 2>"$W/B.err"
NBERR=$(grep -cE "ERROR:" "$W/B.err" || true)
echo "   erreurs restantes au restore du schema : $NBERR (catalogue : $W/B.err)"
grep -E "ERROR:" "$W/B.err" | sed -E 's/ERROR:\s*//' | sort | uniq -c | sort -rn | head -8 | sed 's/^/   /'

# --- Phase C : les donnees, sans l'index vectoriel ---------------------------
etape "C. Donnees (index vectoriel retire le temps du chargement)"

"$pg/psql" "$DST" -qc "drop index if exists medical.consultations_embedding_idx;" 2>/dev/null

D0=$(date +%s)
"$pg/pg_dump" "$SRC" --data-only --no-owner \
  --schema=medical --schema=audit --schema=auth_hooks --schema=public \
  2>"$W/C-dump.err" \
  | "$pg/psql" "$DST" -v ON_ERROR_STOP=0 -q 2>"$W/C.err"
D1=$(date +%s)
echo "   post-data (index, contraintes, triggers, policies)..."
"$pg/psql" "$DST" -v ON_ERROR_STOP=0 -q -f "$W/postdata-adapte.sql" 2>"$W/C2.err"
echo "   post-data : $(grep -cE 'ERROR:' "$W/C2.err" || true) erreur(s) (catalogue : $W/C2.err)"
NBERRC=$(grep -cE "ERROR:" "$W/C.err" || true)
echo "   duree du chargement : $((D1 - D0)) s, erreurs : $NBERRC"
grep -E "ERROR:" "$W/C.err" | sed -E 's/ERROR:\s*//' | sort | uniq -c | sort -rn | head -5 | sed 's/^/   /'

# --- Phase D : l'index vectoriel sur la cible --------------------------------
etape "D. Reconstruction de l'index ivfflat sur la cible"
if ! "$pg/psql" "$DST" -tAqc "select 1 from pg_available_extensions where name='vector'" | grep -q 1; then
  echo "   sautee : pgvector indisponible sur ce cluster (colonnes degradees en text)."
  echo "   Pour la recherche vectorielle : plan avec pgvector, puis recreer l'index."
else
D0=$(date +%s)
"$pg/psql" "$DST" -qc "set statement_timeout='30min';
create index consultations_embedding_idx on medical.consultations
  using ivfflat (embedding extensions.vector_cosine_ops) with (lists='100');" 2>"$W/D.err" \
  && echo "   reconstruit en $(( $(date +%s) - D0 )) s avec le maintenance_work_mem du plan" \
  || { echo "   ECHEC :"; tail -2 "$W/D.err" | sed 's/^/   /'; }
fi

# --- Phase E : FORCE RLS partout ---------------------------------------------
etape "E. FORCE ROW LEVEL SECURITY sur toutes les tables medical"
"$pg/psql" "$DST" -tAq <<'SQL'
do $$
declare r record; n int := 0;
begin
  for r in select schemaname, tablename from pg_tables where schemaname = 'medical' loop
    execute format('alter table %I.%I enable row level security', r.schemaname, r.tablename);
    execute format('alter table %I.%I force row level security',  r.schemaname, r.tablename);
    n := n + 1;
  end loop;
  raise notice 'FORCE RLS sur % tables', n;
end $$;
SQL

# --- Phase E2 : helpers en lecture de claims ---------------------------------
etape "E2. Helpers redefinis en lecture de claims (adaptation n°9)"
# Chez Supabase, le hook custom_access_token injectait role_metier,
# praticien_id et patient_id dans le JWT : les helpers n'atteignaient jamais
# leur repli SQL. Sur la cible, ce repli est PLANIFIE au moment d'evaluer les
# policies et le cycle patients <-> prises_en_charge explose en recursion
# (« infinite recursion / stack depth »). Lecture de claims exclusive :
# memes valeurs qu'a la source, cycle impossible. L'application doit donc
# poser request.jwt.claims avec sub, aal, app_metadata{role_metier,
# praticien_id?, patient_id?} — le contrat exact du hook.
"$pg/psql" "$DST" -v ON_ERROR_STOP=0 -q <<'SQL2' 2>>"$W/E2.err"
create or replace function medical.role_courant() returns medical.role_metier
language sql stable as $f$
  select coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'role_metier')::medical.role_metier,
    'patient'::medical.role_metier)
$f$;
create or replace function medical.patient_courant() returns uuid
language sql stable as $f$
  select (auth.jwt() -> 'app_metadata' ->> 'patient_id')::uuid
$f$;
create or replace function medical.praticien_courant() returns uuid
language sql stable as $f$
  select (auth.jwt() -> 'app_metadata' ->> 'praticien_id')::uuid
$f$;
SQL2
echo "   role_courant / patient_courant / praticien_courant : claims uniquement"

# --- Phase F : etat final ----------------------------------------------------
etape "F. Etat de la cible"
# Les comptages metier se font SOUS IDENTITE : le proprietaire est soumis au
# FORCE RLS pose en phase E — un count nu renvoie zero, et c'est la preuve
# que le verrou fonctionne, pas que la base est vide (pg_size_pretty fait foi).
"$pg/psql" "$DST" -tAc "
select 'taille          = ' || pg_size_pretty(pg_database_size(current_database()))
union all select 'tables medical  = ' || count(*)::text from pg_tables where schemaname='medical'
union all select 'policies        = ' || count(*)::text from pg_policies where schemaname='medical'
union all select 'lignes estimees (consultations, pg_class) = ' || reltuples::bigint::text
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='medical' and c.relname='consultations';"

echo
echo "Recette : jouer la matrice par identite (voir scripts/recette-cible.sql)"
echo "et la comparer a celle de la source. Matrice identique = reprise fidele."
