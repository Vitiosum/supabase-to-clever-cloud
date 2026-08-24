#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Verifie que le produit ne s'est pas degrade : liens, parite FR/EN, chiffres
# porteurs, syntaxe des scripts, absence de secrets.
#
#   ./scripts/verifier-produit.sh
#
# C'est la version scriptee de la revue qui a trouve 14 defauts a la main.
# Joue en CI a chaque push : une edition qui casse un lien, desynchronise les
# versions FR/EN ou fait diverger un chiffre est refusee avant d'etre publiee.
#
# Code de sortie : 0 si tout passe, 1 sinon (chaque echec est liste).
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ECHECS=0

ko() { echo "ECHEC  $*"; ECHECS=$((ECHECS + 1)); }
ok() { echo "ok     $*"; }

# --- 1. Liens relatifs des documents publics --------------------------------
DOCS_PUBLICS=(README.md DEMO.md MIGRER-DEPUIS-SUPABASE.md MIGRATING-FROM-SUPABASE.md
              ATTERRIR-SUR-CLEVER-CLOUD.md LANDING-ON-CLEVER-CLOUD.md
              MIGRER-DEPUIS-SUPABASE-HDS.md llms.txt exemple-cible/README.md)

for src in "${DOCS_PUBLICS[@]}"; do
  [[ -f "$src" ]] || { ko "document manquant : $src"; continue; }
  base=$(dirname "$src")
  while IFS= read -r lien; do
    [[ -e "$base/$lien" || -e "$lien" ]] || ko "lien mort dans $src : $lien"
  done < <(grep -oE '\]\(([A-Za-z0-9_./-]+\.(md|sh|py|js|json|txt))\)' "$src" \
           | sed -E 's/\]\((.*)\)/\1/' | sort -u)
done
ok "liens relatifs"

# --- 2. Parite FR/EN : meme nombre de sections ------------------------------
parite() {                                  # parite <fr> <en>
  local nfr nen
  nfr=$(grep -c '^## ' "$1"); nen=$(grep -c '^## ' "$2")
  [[ "$nfr" == "$nen" ]] \
    && ok "parite sections $1 ($nfr) = $2 ($nen)" \
    || ko "parite sections : $1 a $nfr sections, $2 en a $nen"
}
parite MIGRER-DEPUIS-SUPABASE.md MIGRATING-FROM-SUPABASE.md
parite ATTERRIR-SUR-CLEVER-CLOUD.md LANDING-ON-CLEVER-CLOUD.md

# --- 3. Chiffres porteurs presents des deux cotes ---------------------------
# Si l'un est mis a jour sans l'autre, la CI le dit. La liste est courte a
# dessein : uniquement les chiffres qui fondent l'argumentaire.
chiffres() {                                # chiffres <fr> <en> <motifs...>
  local fr="$1" en="$2"; shift 2
  for m in "$@"; do
    if grep -q -- "$m" "$fr" && grep -q -- "$m" "$en"; then
      ok "chiffre '$m' present dans $fr et $en"
    else
      ko "chiffre '$m' absent d'un cote : $fr / $en"
    fi
  done
}
chiffres MIGRER-DEPUIS-SUPABASE.md MIGRATING-FROM-SUPABASE.md \
  "17.6" "324" "1 min 42" "102" "495" "65 M" "1536" "93" "68" "47 extensions"
chiffres ATTERRIR-SUR-CLEVER-CLOUD.md LANDING-ON-CLEVER-CLOUD.md \
  "47 extensions" "INSTANCE_NUMBER" "CELLAR_ADDON_HOST" "force row level security"

# --- 4. Syntaxe de tout ce qui s'execute ------------------------------------
while IFS= read -r f; do
  bash -n "$f" && ok "bash -n $f" || ko "syntaxe bash : $f"
done < <(git ls-files 'scripts/*.sh' 'exemple-cible/clevercloud/*.sh')

while IFS= read -r f; do
  python3 -c "import ast; ast.parse(open('$f').read())" 2>/dev/null \
    && ok "python $f" || ko "syntaxe python : $f"
done < <(git ls-files 'scripts/*.py')

if command -v node >/dev/null; then
  while IFS= read -r f; do
    node --check "$f" 2>/dev/null && ok "node --check $f" || ko "syntaxe js : $f"
  done < <(git ls-files 'exemple-cible/*.js')
fi

while IFS= read -r f; do
  python3 -m json.tool "$f" >/dev/null 2>&1 && ok "json $f" || ko "json invalide : $f"
done < <(git ls-files '*.json')

# --- 5. Bit executable des scripts ------------------------------------------
while IFS= read -r ligne; do
  mode=${ligne%% *}; f=${ligne##*$'\t'}
  [[ "$mode" == 100755 ]] || ko "non executable (commiter avec git update-index --chmod=+x) : $f"
done < <(git ls-files -s 'scripts/*.sh' 'exemple-cible/clevercloud/*.sh')
ok "bits executables"

# --- 6. Aucun secret dans les fichiers suivis -------------------------------
if git grep -lE 'sb_secret_[A-Za-z0-9]' -- ':!scripts/verifier-produit.sh' >/dev/null 2>&1; then
  ko "motif de cle secrete (sb_secret_) dans un fichier suivi"
else
  ok "aucune cle secrete suivie"
fi
# Mot de passe reel dans une URI postgres. Les placeholders connus sont
# ecartes ligne a ligne ('password', 'xxxx...', '<...>') plutot que d'exclure
# des fichiers entiers : un vrai secret colle dans .env.example doit sonner.
FUITES=$(git grep -hE 'postgresql://[A-Za-z0-9_.]+:[A-Za-z0-9%+/=_-]{8,}@' \
           -- ':!scripts/verifier-produit.sh' 2>/dev/null \
         | grep -vE ':password@|:x{4,}|:<[^>]*>@' || true)
if [[ -n "$FUITES" ]]; then
  ko "URI postgres avec mot de passe apparent dans un fichier suivi :"
  echo "$FUITES" | head -3 | sed 's/^/       /'
else
  ok "aucune URI avec mot de passe (placeholders ecartes)"
fi

# --- Bilan ------------------------------------------------------------------
echo
if [[ $ECHECS -gt 0 ]]; then
  echo "$ECHECS echec(s)."
  exit 1
fi
echo "Tout passe."
