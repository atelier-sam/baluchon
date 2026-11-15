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
#    - session encore ouverte (code 11 du noyau) : code 2 ;
#    - (revue Codex, 2e passe, HIGH 5) `config` ou un profil qui est un LIEN vers un dossier témoin n'est
#      jamais suivi : témoin intact, lien laissé en place et signalé, code non nul ; une racine qui est le
#      domicile, ou un chemin relatif, est refusée avant toute suppression.
#    - (revue Codex, 4e passe, constat 7) Trousseau macOS (faux `security`, CC_OS=darwin dans le seul bash
#      d'essai) : verrouillé AVANT l'effacement = code 3 et RIEN n'est touché, la relance après
#      déverrouillage va au bout ; refusé À la suppression = code 1 et la note nomme le Trousseau.
#  Contrôle positif : passer l'ANCIEN lib/common.sh en 2e argument doit faire échouer les
#  épreuves « jetons restants » (il rendait 0 et effaçait remote.conf) et les épreuves 6 à 8 (il suivait
#  le lien et effaçait le témoin).
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
  mkdir -p "$r/config/perso" "$r/config/pro"
  printf '{"jeton":"faux"}\n' > "$r/config/perso/.credentials.json"
  printf '{"jeton":"faux"}\n' > "$r/config/pro/.credentials.json"
  printf 'host = mac.example.test\nuser = sam\n' > "$r/config/remote.conf"
  printf 'perso\n' > "$r/ACTIVE"
  printf '%s\n' "$r"
}

# Joue cc_wipe dans un bash propre. Écrit « code|note » ; $3 = noyau ("" = aucun).
joue() { # joue <racine> <lib> <noyau> [domicile]
  # Le domicile d'essai est HORS de toute racine : une racine qui contient le domicile est refusée (cc_racine_sure).
  mkdir -p "$BASE/domicile-essai"
  env -i HOME="${4:-$BASE/domicile-essai}" PATH="/usr/bin:/bin" bash -c '
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

# 6) (revue Codex, 2e passe, HIGH 5) `config` est un LIEN vers un dossier qui n'est pas à nous : l'effacement le
# suivait (`rm -rf "$ROOT"/config/*`) et supprimait les documents. Désormais : témoin intact, lien signalé.
printf '0\n' > "$BASE/PURGE_RC"; printf '0\n' > "$BASE/FORGET_RC"
T="$BASE/temoin-config"; mkdir -p "$T/sous"
printf 'precieux\n' > "$T/these.txt"; printf 'precieux\n' > "$T/sous/notes.txt"
R="$BASE/config-lien"; mkdir -p "$R"; ln -s "$T" "$R/config"
o="$(joue "$R" "$LIB" "$FAUX")"
temoin_ok() { [ "$(cat "$1/these.txt" 2>/dev/null)" = precieux ] && [ "$(cat "$1/sous/notes.txt" 2>/dev/null)" = precieux ]; }
verdict "$(temoin_ok "$T" && echo vrai || echo faux)" "6. config lien : le dossier témoin est INTACT"
verdict "$([ -L "$R/config" ] && echo vrai || echo faux)" "6. config lien : le lien est laissé en place, jamais suivi"
case "${o#*|}" in *"lien symbolique"*) verdict vrai "6. config lien : la note le SIGNALE" ;; *) verdict faux "6. config lien : la note le SIGNALE" "${o#*|}" ;; esac
[ "${o%%|*}" != 0 ] && verdict vrai "6. config lien : le code n'est pas 0" || verdict faux "6. config lien : le code n'est pas 0" "code ${o%%|*}"

# 7) Un PROFIL qui est un lien : le profil ordinaire est effacé, le lien est signalé et jamais suivi.
T2="$BASE/temoin-profil"; mkdir -p "$T2"; printf 'precieux\n' > "$T2/these.txt"; printf 'precieux\n' > "$T2/sous-notes.txt"
R="$BASE/profil-lien"; mkdir -p "$R/config/perso"
printf '{"jeton":"faux"}\n' > "$R/config/perso/.credentials.json"; ln -s "$T2" "$R/config/pro"
o="$(joue "$R" "$LIB" "$FAUX")"
verdict "$([ "$(cat "$T2/these.txt" 2>/dev/null)" = precieux ] && [ "$(cat "$T2/sous-notes.txt" 2>/dev/null)" = precieux ] && echo vrai || echo faux)" "7. profil lien : le dossier témoin est INTACT"
verdict "$([ ! -e "$R/config/perso" ] && echo vrai || echo faux)" "7. profil lien : le profil ordinaire est effacé"
case "${o#*|}" in *"config/pro"*) verdict vrai "7. profil lien : la note NOMME l'entrée" ;; *) verdict faux "7. profil lien : la note NOMME l'entrée" "${o#*|}" ;; esac
[ "${o%%|*}" != 0 ] && verdict vrai "7. profil lien : le code n'est pas 0" || verdict faux "7. profil lien : le code n'est pas 0" "code ${o%%|*}"

# 8) Racine douteuse : refusée AVANT toute suppression (le domicile lui-même, un chemin relatif).
H8="$BASE/domicile-racine"; mkdir -p "$H8/config/p1"; printf 'precieux\n' > "$H8/config/p1/.credentials.json"
o="$(joue "$H8" "$LIB" "$FAUX" "$H8")"
egal "8. racine = domicile : refusée (code 1)" 1 "${o%%|*}"
verdict "$([ -f "$H8/config/p1/.credentials.json" ] && echo vrai || echo faux)" "8. racine = domicile : rien n'est effacé"
mkdir -p "$BASE/rel8/config/p1"; printf 'x\n' > "$BASE/rel8/config/p1/.credentials.json"
o="$(cd "$BASE" && env -i HOME="$BASE/domicile-essai" PATH="/usr/bin:/bin" bash -c 'ROOT="rel8"; . "$1"; CORE="$2"; rc=0; cc_wipe >/dev/null 2>&1 || rc=$?; printf "%s" "$rc"' _ "$LIB" "$FAUX" 2>/dev/null)"
egal "8. racine relative : refusée (code 1)" 1 "$o"
verdict "$([ -f "$BASE/rel8/config/p1/.credentials.json" ] && echo vrai || echo faux)" "8. racine relative : rien n'est effacé"

# 9) (revue Codex, 4e passe, HIGH 5) Le lien était jugé APRÈS l'appel au noyau : `config/pro -> ~/.claude` faisait
# purger au noyau (qui listait ses profils par `is_dir()`, donc en suivant le lien) les identifiants du Claude normal.
# Le faux noyau ci-dessous est un modèle de ce vieux noyau : il parcourt config/*/ en suivant les liens et efface
# les secrets de chaque entrée, et il note ses appels dans APPELS. Preuve attendue : tant qu'un lien existe, il n'est
# PAS appelé pour `accounts purge`, le témoin est intact, les vrais profils sont effacés par le repli bash, code != 0.
HOSTILE="$BASE/noyau-hostile"
cat > "$HOSTILE" <<'NOYAU'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
root=""
if [ "$1" = --root ]; then root="$2"; shift 2; fi
printf '%s\n' "$*" >> "$d/APPELS"
case "$1 $2" in
  "accounts purge")
    for p in "$root"/config/*/; do
      [ -d "$p" ] || continue
      rm -f "$p/.credentials.json" "$p/oauth.token" "$p/.ccp-pending" 2>/dev/null
    done
    exit 0 ;;
  "remote forget-access") exit 0 ;;
esac
exit 64
NOYAU
chmod +x "$HOSTILE"
appels_purge() { grep -c '^accounts purge' "$BASE/APPELS" 2>/dev/null || true; }

# 9a) config/pro est un lien vers un dossier témoin qui porte des identifiants.
: > "$BASE/APPELS"
T9="$BASE/temoin-claude-normal"; mkdir -p "$T9"
printf 'precieux\n' > "$T9/.credentials.json"; printf 'precieux\n' > "$T9/oauth.token"; printf 'precieux\n' > "$T9/these.txt"
R="$BASE/lien-profil-noyau-hostile"; mkdir -p "$R/config/perso"
printf '{"jeton":"faux"}\n' > "$R/config/perso/.credentials.json"; ln -s "$T9" "$R/config/pro"
o="$(joue "$R" "$LIB" "$HOSTILE")"
verdict "$([ "$(cat "$T9/.credentials.json" 2>/dev/null)" = precieux ] && [ "$(cat "$T9/oauth.token" 2>/dev/null)" = precieux ] && [ "$(cat "$T9/these.txt" 2>/dev/null)" = precieux ] && echo vrai || echo faux)" "9a. profil lien + noyau qui suit les liens : le témoin est INTACT"
egal "9a. profil lien : le noyau n'est PAS appelé pour accounts purge" 0 "$(appels_purge)"
verdict "$([ ! -e "$R/config/perso" ] && echo vrai || echo faux)" "9a. profil lien : le vrai profil est quand même effacé (repli bash)"
verdict "$([ -L "$R/config/pro" ] && echo vrai || echo faux)" "9a. profil lien : le lien est laissé en place"
[ "${o%%|*}" != 0 ] && verdict vrai "9a. profil lien : le code n'est pas 0" || verdict faux "9a. profil lien : le code n'est pas 0" "code ${o%%|*}"

# 9b) config lui-même est un lien.
: > "$BASE/APPELS"
T9b="$BASE/temoin-config-hostile"; mkdir -p "$T9b/1"; printf 'precieux\n' > "$T9b/1/.credentials.json"
R="$BASE/lien-config-noyau-hostile"; mkdir -p "$R"; ln -s "$T9b" "$R/config"
o="$(joue "$R" "$LIB" "$HOSTILE")"
verdict "$([ "$(cat "$T9b/1/.credentials.json" 2>/dev/null)" = precieux ] && echo vrai || echo faux)" "9b. config lien + noyau qui suit les liens : le témoin est INTACT"
egal "9b. config lien : le noyau n'est PAS appelé pour accounts purge" 0 "$(appels_purge)"
[ "${o%%|*}" != 0 ] && verdict vrai "9b. config lien : le code n'est pas 0" || verdict faux "9b. config lien : le code n'est pas 0" "code ${o%%|*}"

# 9c) Contrôle d'instrument : sans lien, le même faux noyau EST appelé (sinon 9a/9b ne prouveraient rien).
: > "$BASE/APPELS"
R="$(racine sans-lien-noyau-hostile)"
o="$(joue "$R" "$LIB" "$HOSTILE")"
egal "9c. sans lien : le noyau est appelé pour accounts purge" 1 "$(appels_purge)"
egal "9c. sans lien : code 0" 0 "${o%%|*}"

# 10) (revue Codex, 4e passe, constat 7) Le Trousseau macOS est contrôlé AVANT toute suppression : le nom d'un item se
# calcule depuis le dossier de son profil, donc un profil supprimé pendant que le Trousseau refuse ne laisse plus de quoi
# rejouer l'effacement. Un faux `security` (rien d'autre n'est joué : jamais le vrai Trousseau) répond selon FIND_RC et
# DELETE_RC ; CC_OS est posé à darwin dans le seul bash d'essai.
SECD="$BASE/faux-security"; mkdir -p "$SECD"
cat > "$SECD/security" <<'SEC'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$1" >> "$d/APPELS_SECURITY"
case "$1" in
  find-generic-password) exit "$(cat "$d/FIND_RC" 2>/dev/null || echo 44)" ;;
  delete-generic-password) exit "$(cat "$d/DELETE_RC" 2>/dev/null || echo 44)" ;;
esac
exit 1
SEC
chmod +x "$SECD/security"
joue_mac() { # joue_mac <racine> <noyau> : « code|note » de cc_wipe avec CC_OS=darwin et le faux security en tête du PATH
  mkdir -p "$BASE/domicile-essai"
  env -i HOME="$BASE/domicile-essai" PATH="$SECD:/usr/bin:/bin" bash -c '
    ROOT="$1"; . "$2"; CORE="$3"; CC_OS=darwin
    rc=0; cc_wipe >/dev/null 2>&1 || rc=$?
    printf "%s|%s" "$rc" "${CC_WIPE_NOTE:-}"
  ' _ "$1" "$LIB" "$2" 2>/dev/null
}
contenu() { ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(shasum -a 256 "$f" | cut -c1-16)" "$f"; done ); }

# 10a) Trousseau verrouillé (toute réponse ≠ 0 et ≠ 44) : code 3, RIEN n'est touché, aucun ordre au noyau.
: > "$BASE/APPELS"; : > "$SECD/APPELS_SECURITY"; printf '36\n' > "$SECD/FIND_RC"; printf '36\n' > "$SECD/DELETE_RC"
R="$(racine trousseau-verrouille)"; AVANT="$(contenu "$R")"
o="$(joue_mac "$R" "$HOSTILE")"
egal "10a. Trousseau verrouillé : code 3" 3 "${o%%|*}"
case "${o#*|}" in *"Trousseau verrouillé"*"Rien n'a été effacé"*) verdict vrai "10a. …la note dit « Trousseau verrouillé … Rien n'a été effacé »" ;; *) verdict faux "10a. …la note le dit" "${o#*|}" ;; esac
egal "10a. …RIEN n'est modifié (profils, remote.conf, ACTIVE)" "$AVANT" "$(contenu "$R")"
egal "10a. …le noyau n'a reçu aucun ordre (ni purge, ni oubli des jetons)" 0 "$(wc -l < "$BASE/APPELS" | tr -d ' ')"
verdict "$(grep -q delete-generic-password "$SECD/APPELS_SECURITY" && echo faux || echo vrai)" "10a. …aucune suppression du Trousseau n'a été demandée"
# Déverrouillé : la relance retrouve tout (les profils sont toujours là pour calculer les noms).
printf '0\n' > "$SECD/FIND_RC"; printf '0\n' > "$SECD/DELETE_RC"
o="$(joue_mac "$R" "$HOSTILE")"
egal "10a. …déverrouillé, la relance aboutit (code 0)" 0 "${o%%|*}"
egal "10a. …et config/ est vidé" "" "$(ls -A "$R/config")"

# 10b) Le pré-contrôle passe (lecture 44), puis la SUPPRESSION est refusée : les fichiers sont traités, le Trousseau est dit
# (code 1, note « Trousseau »), jamais 0. Le noyau échoue (PURGE_RC=1) pour que le repli bash joue le Trousseau.
printf '44\n' > "$SECD/FIND_RC"; printf '36\n' > "$SECD/DELETE_RC"; printf '1\n' > "$BASE/PURGE_RC"; printf '0\n' > "$BASE/FORGET_RC"
R="$(racine trousseau-delete-refuse)"
o="$(joue_mac "$R" "$FAUX")"
egal "10b. lecture 44 puis suppression refusée (36) : code 1, jamais 0" 1 "${o%%|*}"
case "${o#*|}" in *"Trousseau"*) verdict vrai "10b. …la note nomme le Trousseau" ;; *) verdict faux "10b. …la note nomme le Trousseau" "${o#*|}" ;; esac
verdict "$([ ! -e "$R/config/perso" ] && [ ! -e "$R/config/pro" ] && echo vrai || echo faux)" "10b. …les fichiers de connexion sont effacés quand même"

# 10c) Items absents (44 partout) : succès, code 0.
printf '44\n' > "$SECD/FIND_RC"; printf '44\n' > "$SECD/DELETE_RC"; printf '1\n' > "$BASE/PURGE_RC"
R="$(racine trousseau-absent)"
o="$(joue_mac "$R" "$FAUX")"
egal "10c. items absents (44) : code 0" 0 "${o%%|*}"

printf '%s ok, %s ko\n' "$OK" "$KO"
[ "$KO" = 0 ]
