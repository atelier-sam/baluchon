#!/usr/bin/env bash
# ============================================================
#  effacement.test.sh <dossier-vide-absolu> [lib/common.sh à éprouver]
#
#  Épreuves de « Tout effacer » (lib/common.sh : cc_wipe) dans une racine JETABLE, avec un faux
#  noyau dont on choisit les codes de `accounts purge` et de `remote forget-access`. Rien n'est
#  écrit hors de <dossier-vide-absolu> ; ni le vrai Trousseau ni ~/.cloudflared ne sont touchés
#  (CC_OS n'est pas darwin, HOME pointe dans le dossier d'essai).
#
#  Ce qui est prouvé (revue AVAL : le menu affichait « ✓ Effacé » quoi qu'il arrive) :
#    - tout réussit : code 0, config/ vidé, remote.conf compris, aucune note ;
#    - jetons Access non effacés (code 10 du noyau) : code 10, note « UTILISABLES » avec le bilan
#      du noyau, sessions effacées, et config/remote.conf GARDÉ (sinon une nouvelle tentative
#      répondrait « aucun Mac configuré » et réussirait sans rien effacer) ;
#    - noyau absent alors qu'un Mac est configuré : code 10, remote.conf gardé ;
#    - noyau absent sans Mac configuré : repli bash, code 0 ;
#    - session encore ouverte (code 11 du noyau) : code 2.
#  Contrôle positif : passer l'ANCIEN lib/common.sh en 2e argument doit faire échouer les
#  épreuves « jetons restants » (il rendait 0 et effaçait remote.conf).
#  Sortie : « N ok, M ko » ; code 0 seulement si M = 0.
# ============================================================
# SC2016 : le petit `bash -c '...'` d'essai s'écrit volontairement entre apostrophes.
# shellcheck disable=SC2016
set -uo pipefail

ulimit -u "$(( $(ps -A | wc -l) + 300 ))" 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${2:-$HERE/../lib/common.sh}"
[ -f "$LIB" ] || { echo "bibliothèque introuvable : $LIB" >&2; exit 2; }

BASE_IN="${1:-}"
[ -n "$BASE_IN" ] || { echo "usage : effacement.test.sh <dossier-vide-absolu> [lib/common.sh]" >&2; exit 2; }
case "$BASE_IN" in /*) ;; *) echo "le dossier doit être un chemin ABSOLU" >&2; exit 2 ;; esac
[ -d "$BASE_IN" ] || { echo "dossier absent : $BASE_IN" >&2; exit 2; }
[ -z "$(ls -A "$BASE_IN")" ] || { echo "le dossier n'est pas vide : $BASE_IN" >&2; exit 2; }
BASE="$(cd "$BASE_IN" && pwd -P)"

OK=0
KO=0
verdict() { # verdict <vrai|faux> <libellé> [détail]
  if [ "$1" = vrai ]; then
    OK=$((OK + 1)); printf 'ok   %s\n' "$2"
  else
    KO=$((KO + 1)); printf 'KO   %s\n' "$2"; [ -z "${3:-}" ] || printf '%s\n' "$3" | sed 's/^/       /'
  fi
}
egal() { # egal <libellé> <attendu> <obtenu>
  if [ "$2" = "$3" ]; then verdict vrai "$1"; else verdict faux "$1" "attendu « $2 », obtenu « $3 »"; fi
}

# Faux noyau : codes lus dans des fichiers à côté de lui (PURGE_RC, FORGET_RC).
FAUX="$BASE/faux-noyau"
cat > "$FAUX" <<'NOYAU'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
[ "$1" = --root ] && shift 2
case "$1 $2" in
  "accounts purge") exit "$(cat "$d/PURGE_RC" 2>/dev/null || echo 0)" ;;
  "remote forget-access")
    rc="$(cat "$d/FORGET_RC" 2>/dev/null || echo 0)"
    [ "$rc" = 0 ] || printf 'effacement INCOMPLET : app-baluchon-token (permission refusée)\n' >&2
    exit "$rc" ;;
esac
exit 64
NOYAU
chmod +x "$FAUX"

# Une racine de portable avec deux profils connectés et un Mac configuré.
racine() { # racine <nom> -> chemin
  local r="$BASE/$1"
  mkdir -p "$r/config/perso" "$r/config/pro" "$r/home"
  printf '{"jeton":"faux"}\n' > "$r/config/perso/.credentials.json"
  printf '{"jeton":"faux"}\n' > "$r/config/pro/.credentials.json"
  printf 'host = mac.example.test\nuser = sam\n' > "$r/config/remote.conf"
  printf 'perso\n' > "$r/ACTIVE"
  printf '%s\n' "$r"
}

# Joue cc_wipe dans un bash propre. Écrit « code|note » ; $3 = noyau ("" = aucun).
joue() { # joue <racine> <lib> <noyau>
  env -i HOME="$1/home" PATH="/usr/bin:/bin" bash -c '
    ROOT="$1"; . "$2"; CORE="$3"
    rc=0; cc_wipe >/dev/null 2>&1 || rc=$?
    printf "%s|%s" "$rc" "${CC_WIPE_NOTE:-}"
  ' _ "$1" "$2" "$3" 2>/dev/null
}

# 1) Tout réussit.
R="$(racine tout-ok)"; printf '0\n' > "$BASE/PURGE_RC"; printf '0\n' > "$BASE/FORGET_RC"
o="$(joue "$R" "$LIB" "$FAUX")"
egal "1. tout réussit : code 0" 0 "${o%%|*}"
egal "1. tout réussit : aucune note" "" "${o#*|}"
egal "1. config/ vidé (remote.conf compris)" "" "$(ls -A "$R/config")"
verdict "$([ ! -e "$R/ACTIVE" ] && echo vrai || echo faux)" "1. ACTIVE retiré"

# 2) Jetons Access non effacés (code 10 du noyau).
R="$(racine jetons-restent)"; printf '0\n' > "$BASE/PURGE_RC"; printf '10\n' > "$BASE/FORGET_RC"
o="$(joue "$R" "$LIB" "$FAUX")"
egal "2. jetons restants : code 10" 10 "${o%%|*}"
case "${o#*|}" in *UTILISABLES*app-baluchon-token*) verdict vrai "2. la note dit UTILISABLES et porte le bilan du noyau" ;;
  *) verdict faux "2. la note dit UTILISABLES et porte le bilan du noyau" "${o#*|}" ;; esac
verdict "$([ -f "$R/config/remote.conf" ] && echo vrai || echo faux)" "2. config/remote.conf GARDÉ pour une nouvelle tentative"
verdict "$([ ! -e "$R/config/perso" ] && [ ! -e "$R/config/pro" ] && echo vrai || echo faux)" "2. les profils (sessions) sont quand même effacés"

# 3) Noyau absent, Mac configuré.
R="$(racine sans-noyau-avec-mac)"
o="$(joue "$R" "$LIB" "")"
egal "3. sans noyau, Mac configuré : code 10" 10 "${o%%|*}"
verdict "$([ -f "$R/config/remote.conf" ] && echo vrai || echo faux)" "3. config/remote.conf GARDÉ"

# 4) Noyau absent, aucun Mac : repli bash, rien ne reste.
R="$(racine sans-noyau-sans-mac)"; rm -f "$R/config/remote.conf"
o="$(joue "$R" "$LIB" "")"
egal "4. sans noyau ni Mac : code 0" 0 "${o%%|*}"
egal "4. config/ vidé" "" "$(ls -A "$R/config")"

# 5) Session encore ouverte (code 11 du noyau à la purge).
R="$(racine session-ouverte)"; printf '11\n' > "$BASE/PURGE_RC"; printf '0\n' > "$BASE/FORGET_RC"
o="$(joue "$R" "$LIB" "$FAUX")"
egal "5. session ouverte : code 2" 2 "${o%%|*}"

printf '%s ok, %s ko\n' "$OK" "$KO"
[ "$KO" = 0 ]
