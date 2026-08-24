#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Recette de la cible : la meme matrice ressource x identite que sur la
# source, jouee en SQL contre l'add-on PostgreSQL.
#
#   CIBLE_URL='postgresql://...' ./scripts/recette-cible.sh
#
# Sur la source, la matrice passait par PostgREST et de vrais JWT. Ici,
# PostgREST n'existe plus : l'identite est posee par transaction via
# request.jwt.claims, et le shim auth.* (cree par reprise-cible.sh) fait que
# LES MEMES policies et LES MEMES helpers repondent.
#
# Matrice identique a celle de la source = reprise fidele.
# ---------------------------------------------------------------------------
set -euo pipefail

DST="${CIBLE_URL:?CIBLE_URL non definie}"
pg="/opt/homebrew/bin"; [[ -x "$pg/psql" ]] || pg="$(dirname "$(command -v psql)")"

# Les trois profils reels de la source (auth.users), et l'anonyme.
declare -a IDS=(
  "anon|"
  "patient|{\"sub\":\"c7bb7b8f-048b-4835-bf66-54b1bb57861d\",\"role\":\"authenticated\",\"aal\":\"aal1\",\"app_metadata\":{\"role_metier\":\"patient\",\"patient_id\":\"e46257a8-1c7f-4eb8-bca6-50efccecb2c1\"}}"
  "praticien|{\"sub\":\"0ad9c920-6df0-4eae-8d9f-a07b568e5506\",\"role\":\"authenticated\",\"aal\":\"aal2\",\"app_metadata\":{\"role_metier\":\"praticien\",\"praticien_id\":\"d24bffcd-9ed5-4cab-bb69-2d5e8eef5a2a\"}}"
  "secretariat|{\"sub\":\"1613d127-edd4-4e9d-897c-8d0522fe8641\",\"role\":\"authenticated\",\"aal\":\"aal1\",\"app_metadata\":{\"role_metier\":\"secretariat\"}}"
)
TABLES=(cabinets profils praticiens patients prises_en_charge rendez_vous consultations documents messages)

printf '%-18s' ""
for e in "${IDS[@]}"; do printf '%-14s' "${e%%|*}"; done
echo; printf -- '-%.0s' {1..74}; echo

for t in "${TABLES[@]}"; do
  printf '%-18s' "$t"
  for e in "${IDS[@]}"; do
    claims="${e#*|}"
    if [[ -z "$claims" ]]; then
      v=$("$pg/psql" "$DST" -tAqc "select count(*) from medical.$t" 2>&1 | grep -oE '^[0-9]+$|recursion|ERROR[^ ]*' | tail -1 || true)
    else
      v=$("$pg/psql" "$DST" -tAq <<SQL 2>&1 | grep -E '^[0-9]+$|ERROR' | tail -1
begin;
select set_config('request.jwt.claims', '$claims', true);
select count(*) from medical.$t;
rollback;
SQL
      ) || true
    fi
    v="${v:-?}"
    printf '%-14s' "${v:0:12}"
  done
  echo
done

cat <<'FIN'

Reference source (PostgREST, 24/08) :
  patients          0  1  1      0
  prises_en_charge  0  1  1      0
  rendez_vous       0  3  20003  0
  consultations     0  1  1      0
Ligne a ligne identique = reprise fidele. Les zeros du secretariat sont un
defaut CONNU du modele source (constats n°3/23) : fideles aussi.
FIN
