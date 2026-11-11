#!/usr/bin/env bash
# ============================================================
#  garde-lecture-seule.sh [--racine DIR] [BINAIRE ...]
#
#  Porte de release PUBLIQUE : prouve que le noyau public ne sait pas ÉCRIRE un
#  identifiant. Elle échoue (code 1) si le code source du noyau (`core/src`) ou l'un
#  des binaires donnés contient un motif d'écriture ou de renouvellement.
#
#  POURQUOI cette porte, et pas seulement un test : un test montre qu'un scénario ne
#  renouvelle pas ; la porte montre qu'aucun code capable de renouveler n'est LÀ. Un
#  test de comportement qui passe ne dit rien d'un chemin que personne n'a joué.
#
#  Motifs (audit §3.5) :
#    code source, partout dans core/src
#      PostJson, write_login, upsert, apply_renewal, Reserved    portes d'écriture
#      grant_type, add-generic-password, /v1/oauth/token         corps/URL du renouvellement,
#                                                                 écriture du Trousseau
#      refresh_token HORS lecture de blob : `refresh_token()` (accesseur du blob) et
#        les identifiants qui le contiennent (`refresh_token_end_of_life…`) restent permis,
#        la clé nue (`"refresh_token"`, `grant_type=refresh_token`) est refusée.
#      delete-generic-password : permis SEULEMENT dans `fn delete_all` (purge d'un item
#        du portable, jamais l'item de la machine : garde-fou dans la fonction).
#    binaire (`strings -a`)
#      /v1/oauth/token, grant_type, add-generic-password, PostJson
#      (`delete-generic-password` reste permis : la purge le porte.)
#
#  Code de sortie : 0 propre, 1 motif trouvé, 2 usage ou entrée illisible (la porte
#  FERME : un dossier source absent, un binaire introuvable ou l'absence de `strings`
#  ne rendent jamais vert).
#
#  Périmètre : `core/src` seulement. Les essais (core/tests, core/testkit) fabriquent des
#  trousseaux jetables avec `add-generic-password` et ne partent dans aucun binaire ; les
#  scripts shell du portable ne font que SUPPRIMER (`uninstall.sh`, `lib/common.sh`).
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RACINE="$(cd "$HERE/.." && pwd)"
BINAIRES=()

usage() {
  echo "usage : garde-lecture-seule.sh [--racine DIR] [BINAIRE ...]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --racine)
      [ $# -ge 2 ] || usage
      RACINE="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      BINAIRES+=("$1")
      shift
      ;;
  esac
done

SRC="$RACINE/core/src"
[ -d "$SRC" ] || { echo "garde-lecture-seule : dossier source absent : $SRC" >&2; exit 2; }
command -v strings >/dev/null 2>&1 || { echo "garde-lecture-seule : « strings » introuvable" >&2; exit 2; }

# Les `sort`, `grep` et `awk` du système lisent l'UTF-8 des commentaires sans broncher.
export LC_ALL=C

TROUVES=0
signaler() { # signaler <motif> <lieu> [détail]
  TROUVES=$((TROUVES + 1))
  printf 'REFUSÉ  %s  --  %s\n' "$1" "$2"
  [ -z "${3:-}" ] || printf '          %s\n' "$3"
}

# --- code source -------------------------------------------------------------------
# Identifiants interdits : bornés (un autre mot qui les contient n'est pas visé).
MOTS=(PostJson write_login upsert apply_renewal Reserved)
# Textes interdits tels quels.
TEXTES=(grant_type add-generic-password /v1/oauth/token)

FICHIERS=()
while IFS= read -r f; do FICHIERS+=("$f"); done < <(find "$SRC" -type f -name '*.rs' | sort)
[ "${#FICHIERS[@]}" -gt 0 ] || { echo "garde-lecture-seule : aucun .rs sous $SRC" >&2; exit 2; }

for mot in "${MOTS[@]}"; do
  while IFS= read -r l; do
    signaler "$mot" "${l%%:*}:$(echo "$l" | cut -d: -f2)" "$(echo "$l" | cut -d: -f3- | cut -c1-140)"
  done < <(grep -nHE "(^|[^A-Za-z0-9_])${mot}([^A-Za-z0-9_]|\$)" "${FICHIERS[@]}" 2>/dev/null)
done

for txt in "${TEXTES[@]}"; do
  while IFS= read -r l; do
    signaler "$txt" "${l%%:*}:$(echo "$l" | cut -d: -f2)" "$(echo "$l" | cut -d: -f3- | cut -c1-140)"
  done < <(grep -nHF -e "$txt" "${FICHIERS[@]}" 2>/dev/null)
done

# refresh_token : refusé quand il n'est ni suivi d'un caractère d'identifiant ni d'une
# parenthèse (donc pas l'accesseur `refresh_token()`, pas `refresh_token_end_of_life…`),
# et pas précédé d'un caractère d'identifiant.
while IFS= read -r l; do
  signaler "refresh_token" "${l%%:*}:$(echo "$l" | cut -d: -f2)" "$(echo "$l" | cut -d: -f3- | cut -c1-140)"
done < <(grep -nHE '(^|[^A-Za-z0-9_])refresh_token($|[^A-Za-z0-9_(])' "${FICHIERS[@]}" 2>/dev/null)

# delete-generic-password : seulement dans `fn delete_all` (fin = première ligne qui
# referme à la même indentation, ce que rustfmt garantit).
for f in "${FICHIERS[@]}"; do
  while IFS= read -r l; do
    signaler "delete-generic-password hors delete_all" "$l"
  done < <(awk '
    FNR == 1 { infn = 0 }
    !infn && /(^|[[:space:]])fn delete_all[[:space:](<]/ {
      match($0, /^ */); fin = substr($0, 1, RLENGTH) "}"; infn = 1; next
    }
    /delete-generic-password/ && !infn { printf "%s:%d\n", FILENAME, FNR }
    infn && $0 == fin { infn = 0 }
  ' "$f")
done

# --- binaires ----------------------------------------------------------------------
MOTIFS_BIN=(/v1/oauth/token grant_type add-generic-password PostJson)
for b in ${BINAIRES[@]+"${BINAIRES[@]}"}; do
  [ -f "$b" ] || { echo "garde-lecture-seule : binaire introuvable : $b" >&2; exit 2; }
  chaines="$(strings -a "$b" 2>/dev/null)" || { echo "garde-lecture-seule : « strings » a échoué sur $b" >&2; exit 2; }
  for m in "${MOTIFS_BIN[@]}"; do
    # Seul le MOTIF est écrit : jamais le voisinage de la chaîne trouvée.
    # Pas de tube vers `grep -q` : il quitte au premier trouvé, `printf` meurt de SIGPIPE
    # et `pipefail` rendrait le test FAUX alors que le motif est là (mesuré : le binaire
    # d'une édition qui sait écrire passait vert). La chaîne est donnée par redirection.
    if grep -qF -e "$m" <<<"$chaines"; then
      signaler "$m" "binaire $b"
    fi
  done
done

if [ "$TROUVES" -gt 0 ]; then
  echo "garde-lecture-seule : $TROUVES motif(s) d'écriture trouvé(s) -- le noyau public ne doit pas savoir écrire un identifiant." >&2
  exit 1
fi
if [ "${#BINAIRES[@]}" -eq 0 ]; then
  echo "garde-lecture-seule : propre (${#FICHIERS[@]} fichiers source ; AUCUN binaire fourni, donc binaire non vérifié)."
else
  echo "garde-lecture-seule : propre (${#FICHIERS[@]} fichiers source, ${#BINAIRES[@]} binaire(s))."
fi
exit 0
