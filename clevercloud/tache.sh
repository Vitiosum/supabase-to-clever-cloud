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

# CONSTATE A L'EXECUTION : le contexte cron ne porte PAS les variables
# d'environnement de l'application. Premiere tentative : CMDEND 5 ms apres
# CMD — le script mourait sur API_SERVICE_TOKEN non defini avant son premier
# echo. On source donc l'environnement injecte par la plateforme.
for ENVF in /home/bas/.env "$HOME/.env"; do
  if [[ -f "$ENVF" ]]; then
    set -a; . "$ENVF"; set +a
    break
  fi
done
echo "$(date -u +%FT%TZ) tache.sh demarre (env: ${ENVF:-aucun fichier trouve})"

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
