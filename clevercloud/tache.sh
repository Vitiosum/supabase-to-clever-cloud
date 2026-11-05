#!/bin/bash -l
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
# Deduplication obligatoire : les crons tournent sur CHAQUE instance. Le filtre
# INSTANCE_NUMBER ci-dessous ne suffit pas : pendant un deploiement, un scale
# ou un `clever restart`, deux instances peuvent etre toutes deux numero 0
# (verifie sur Clever Cloud le 2026-11-04). La garantie est en base : la route
# reserve le creneau de 15 min (prendreCreneau, exemple-cible/db.js) et
# l'appel perdant repond 200 « deja executee » sans rien faire.
# ---------------------------------------------------------------------------
set -euo pipefail

# LE SHEBANG #!/bin/bash -l N'EST PAS DECORATIF. Le crontab n'a pas acces aux
# variables d'environnement de l'application ; c'est le login shell (-l) qui
# les charge. Piege documente : ne JAMAIS prefixer l'appel par /bin/bash dans
# cron.json, ca superseder le shebang et annule le -l.
#
# Constate en trois executions reelles : (1) le clevercloud/ d'un sous-dossier
# APP_FOLDER n'est pas lu — d'ou ce dossier a la racine ; (2) sans -l, le
# script meurt en 5 ms sur API_SERVICE_TOKEN non defini ; (3) /home/bas/.env
# existe mais ne contient pas les variables de l'application.
echo "$(date -u +%FT%TZ) tache.sh demarre"

# Premier filtre, pas une garantie (voir l'en-tete).
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
