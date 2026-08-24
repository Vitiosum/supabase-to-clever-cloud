#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Tache planifiee de la cible deployee (app supabase-demo-cible).
#
# POURQUOI CE DOSSIER EST A LA RACINE et non dans exemple-cible/ : constate en
# deployant, avec APP_FOLDER le clevercloud/ du sous-dossier n'est PAS lu
# (« No cron to setup »). Le contournement documente dans
# ATTERRIR-SUR-CLEVER-CLOUD.md est applique ici meme : clevercloud/ a la
# racine du depot, meme si l'application vit dans exemple-cible/.
#
# La tache appelle la route protegee de l'application sur l'instance locale.
# Deduplication obligatoire : les crons tournent sur CHAQUE instance.
# ---------------------------------------------------------------------------
set -euo pipefail

if [[ "${INSTANCE_NUMBER:-0}" != "0" ]]; then
  echo "instance ${INSTANCE_NUMBER} : tache ignoree (deduplication)"
  exit 0
fi

TACHE="${1:-battement}"
BASE="http://localhost:${PORT:-8080}"
JETON="${API_SERVICE_TOKEN:?API_SERVICE_TOKEN non defini}"

echo "$(date -u +%FT%TZ) cron -> $TACHE"
CODE=$(curl -sS -o /tmp/cron-"$TACHE".out -w '%{http_code}' \
  -X POST "$BASE/taches/$TACHE" \
  -H "Authorization: Bearer $JETON" \
  -H 'Content-Type: application/json' --max-time 60 -d '{}')
echo "$(date -u +%FT%TZ) cron $TACHE -> HTTP $CODE : $(head -c 200 /tmp/cron-"$TACHE".out)"
[[ "$CODE" =~ ^2 ]] || exit 1
