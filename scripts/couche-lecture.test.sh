#!/usr/bin/env bash
# ============================================================
#  couche-lecture.test.sh <dossier-vide-absolu>
#
#  Épreuves de la LECTURE d'une couche par le lanceur (lib/common.sh : cc_layer_resolve,
#  cc_layer_field, cc_layer_core, cc_ensure_core), dans une racine JETABLE, avec de faux noyaux
#  (scripts qui répondent --version, --contract et about --json). Le vrai `claude` n'est jamais
#  lancé ; rien n'est écrit hors de <dossier-vide-absolu>.
#
#  Ce qui est prouvé (re-revue Codex : « aucune atomicité de génération » côté lecteurs) :
#    - sans couche : noyau public ; couche à plat (posée avant les générations) : noyau de la couche ;
#    - `overlay/CURRENT` désigne `overlay/gen/<nom>/` : manifeste ET noyau viennent de cette génération,
#      jamais de l'ancienne couche à plat restée à côté ;
#    - le pointeur est lu UNE fois : le renommer entre `cc_layer_resolve` et la lecture du noyau ne
#      change pas de génération en cours de route (le manifeste et le noyau d'un même appel
#      concordent toujours) ;
#    - un pointeur illisible (forme, remontée « .. », lien, génération absente ou liée) = pas de
#      couche, ligne visible, noyau public, et JAMAIS un repli sur la couche à plat ;
#    - le lanceur annonce sa capacité (CCP_LAYER_POINTER=1) que les crochets exigent.
#  Sortie : « N ok, M ko » ; code 0 seulement si M = 0.
# ============================================================
# SC2015 : `verdict` rend toujours 0, le « A && ok || ko » est donc un vrai si-sinon.
# SC2016 : les petits `bash -c '...'` d'essai s'écrivent volontairement entre apostrophes.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

ulimit -u "$(( $(ps -A | wc -l) + 300 ))" 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/common.sh"
[ -f "$LIB" ] || { echo "lib/common.sh introuvable" >&2; exit 2; }

BASE_IN="${1:-}"
[ -n "$BASE_IN" ] || { echo "usage : couche-lecture.test.sh <dossier-vide-absolu>" >&2; exit 2; }
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

# Plateforme de cette machine, telle que la bibliothèque la nomme.
PLAT="$(env -i HOME="$BASE" PATH="/usr/bin:/bin" bash -c 'ROOT="$1"; . "$2"; cc_detect_platform; printf "%s" "$CORE_PLAT"' _ "$BASE" "$LIB" 2>/dev/null)"
[ -n "$PLAT" ] || { echo "plateforme non détectée" >&2; exit 2; }
EXE=""; [ "$PLAT" = win32-x64 ] && EXE=.exe

# Un faux noyau : répond à --version, --contract (1) et about --json (édition donnée), et dit qui il est.
faux_noyau() { # faux_noyau <fichier> <édition> <étiquette>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "faux 1.0"; exit 0 ;;
  --contract) echo 1; exit 0 ;;
  about) echo '{"edition":"$2"}'; exit 0 ;;
  --whoami) echo "$3"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$1"
}
manifeste() { # manifeste <fichier> <nom> <version>
  mkdir -p "$(dirname "$1")"
  printf 'name = %s\nversion = %s\nbuilt_on = 3.0.0\ncontract = 1\nplatforms = *\n' "$2" "$3" > "$1"
}
# Une racine neuve avec le noyau PUBLIC : racine <nom> -> écrit R.
racine() {
  R="$BASE/$1"
  mkdir -p "$R/lib"
  cp "$LIB" "$R/lib/common.sh"
  faux_noyau "$R/bin/$PLAT/baluchon-core$EXE" public public
}
# Joue du code dans la bibliothèque de la racine $R, dans un environnement vide.
dans() { # dans <code bash> : ROOT, la bibliothèque et la plateforme sont posés
  env -i HOME="$BASE" XDG_CACHE_HOME="$BASE/cache" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c 'ROOT="$1"; . "$ROOT/lib/common.sh"; cc_detect_platform; shift; eval "$1"' _ "$R" "$1" 2>&1
}
choix() { dans 'cc_ensure_core && printf "%s" "$CORE"'; }
qui() { "$1" --whoami 2>/dev/null; }

echo "== 0. syntaxe, capacité annoncée =="
bash -n "$LIB" && verdict vrai "bash -n lib/common.sh" || verdict faux "bash -n lib/common.sh"
bash -n "${BASH_SOURCE[0]}" && verdict vrai "bash -n couche-lecture.test.sh" || verdict faux "bash -n couche-lecture.test.sh"
grep -q '^CCP_LAYER_POINTER=1' "$LIB" && verdict vrai "lib/common.sh annonce CCP_LAYER_POINTER=1 (ce que les crochets exigent)" || verdict faux "lib/common.sh annonce CCP_LAYER_POINTER=1"

echo "== 1. sans couche, couche à plat =="
racine sans-couche
egal "sans overlay/ : noyau public" "$R/bin/$PLAT/baluchon-core$EXE" "$(choix)"
racine a-plat
manifeste "$R/overlay/LAYER" plat 3.0.0+essai.1
faux_noyau "$R/overlay/bin/$PLAT/baluchon-core$EXE" extension plat
egal "couche à plat (avant les générations) : noyau de la couche" "$R/overlay/bin/$PLAT/baluchon-core$EXE" "$(choix)"
egal "…son manifeste est lu" "plat" "$(dans 'cc_layer_resolve; cc_layer_field name')"

echo "== 2. le pointeur désigne une génération =="
racine generations
manifeste "$R/overlay/LAYER" ancienne-a-plat 3.0.0+essai.0
faux_noyau "$R/overlay/bin/$PLAT/baluchon-core$EXE" extension ancienne-a-plat
for g in g1 g2; do
  manifeste "$R/overlay/gen/$g/LAYER" "generation-$g" "3.0.0+essai.${g#g}"
  faux_noyau "$R/overlay/gen/$g/bin/$PLAT/baluchon-core$EXE" extension "generation-$g"
done
printf 'gen/g1\n' > "$R/overlay/CURRENT"
egal "CURRENT = gen/g1 : le noyau est celui de g1, pas celui de l'ancienne couche à plat" \
  "$R/overlay/gen/g1/bin/$PLAT/baluchon-core$EXE" "$(choix)"
egal "…et le manifeste lu est celui de g1" "generation-g1" "$(dans 'cc_layer_resolve; cc_layer_field name')"
printf 'gen/g2\n' > "$R/overlay/CURRENT"
egal "CURRENT = gen/g2 : le noyau est celui de g2" "$R/overlay/gen/g2/bin/$PLAT/baluchon-core$EXE" "$(choix)"
printf 'gen/g2\r\n' > "$R/overlay/CURRENT"
egal "CURRENT en fin de ligne Windows (\\r\\n) : lu" "$R/overlay/gen/g2/bin/$PLAT/baluchon-core$EXE" "$(choix)"
printf 'gen/g1\n' > "$R/overlay/CURRENT"
# CONTRÔLE POSITIF : l'ANCIEN lanceur (commit 9975006, lu dans l'historique git) ne connaît pas le
# pointeur et lit la couche à plat restée à côté. C'est pourquoi les crochets exigent la capacité
# CCP_LAYER_POINTER avant de poser une génération. Sans historique (archive), le contrôle est sauté.
ANCIEN_LIB="$BASE/ancien-common.sh"
if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$HERE" show 9975006:lib/common.sh > "$ANCIEN_LIB" 2>/dev/null && [ -s "$ANCIEN_LIB" ]; then
  grep -q 'CCP_LAYER_POINTER' "$ANCIEN_LIB" && verdict faux "l'ancien lanceur ne devrait pas annoncer la capacité" || verdict vrai "l'ancien lanceur (9975006) n'annonce pas CCP_LAYER_POINTER"
  cp -R "$R" "$BASE/generations-ancien"
  cp "$ANCIEN_LIB" "$BASE/generations-ancien/lib/common.sh"
  R="$BASE/generations-ancien"
  egal "CONTRÔLE POSITIF : l'ANCIEN lanceur ignore CURRENT et lit la couche à plat périmée" \
    "$R/overlay/bin/$PLAT/baluchon-core$EXE" "$(choix)"
  R="$BASE/generations"
else
  echo "(!) historique git absent : contrôle positif sur l'ancien lanceur (9975006) sauté"
fi

echo "== 3. le pointeur est lu UNE seule fois =="
# Entre la résolution et la lecture du noyau, le pointeur passe à g2 (une mise à jour qui bascule).
# Manifeste ET noyau doivent rester ceux de g1 : c'est la garantie « génération entière ».
RES="$(dans 'cc_layer_resolve; printf "%s\n" "$CC_LAYER_DIR" > "$ROOT/vu"; printf "gen/g2\n" > "$ROOT/overlay/CURRENT"; n="$(cc_layer_field name)"; cc_layer_core; printf "%s|%s\n" "$n" "$CC_LAYER_CORE"')"
egal "pointeur basculé entre la résolution et la lecture : manifeste ET noyau restent ceux de g1" \
  "generation-g1|$R/overlay/gen/g1/bin/$PLAT/baluchon-core$EXE" "$RES"
printf 'gen/g1\n' > "$R/overlay/CURRENT"

echo "== 4. un pointeur illisible : pas de couche, une ligne visible, jamais un repli sur le plat =="
refus_pointeur() { # refus_pointeur <libellé> : CURRENT déjà posé par l'appelant
  local sortie noyau
  sortie="$(dans 'cc_ensure_core; printf "%s\n" "$CORE"; printf "NOTE=%s\n" "$CC_LAYER_NOTE"')"
  noyau="$(printf '%s\n' "$sortie" | grep -v '^NOTE=' | tail -n 1)"
  if [ "$noyau" = "$R/bin/$PLAT/baluchon-core$EXE" ] && printf '%s' "$sortie" | grep -q '^NOTE=Couche inutilisable (pointeur'; then
    verdict vrai "$1 : noyau public + ligne visible, la couche à plat valide n'est PAS utilisée"
  else
    verdict faux "$1 : noyau public + ligne visible" "$sortie"
  fi
}
for mauvais in 'gen/../..' 'gen/absente' '../gen/g1' 'gen/g1/bin' '/etc/passwd' 'gen/' 'n importe quoi'; do
  printf '%s\n' "$mauvais" > "$R/overlay/CURRENT"
  refus_pointeur "pointeur « $mauvais »"
done
: > "$R/overlay/CURRENT"
refus_pointeur "pointeur vide"
rm -f "$R/overlay/CURRENT"
printf 'gen/g1\n' > "$R/vrai-pointeur"
ln -s "$R/vrai-pointeur" "$R/overlay/CURRENT"
refus_pointeur "pointeur qui est un LIEN vers un vrai pointeur"
rm -f "$R/overlay/CURRENT"
ln -s "$R/overlay/gen/g1" "$R/overlay/gen/lien"
printf 'gen/lien\n' > "$R/overlay/CURRENT"
refus_pointeur "génération qui est un LIEN vers un dossier"
rm -f "$R/overlay/gen/lien"
rm -f "$R/overlay/CURRENT"; mkdir "$R/overlay/CURRENT"
refus_pointeur "pointeur qui est un DOSSIER"
rmdir "$R/overlay/CURRENT"

echo "== 5. le lecteur ne crée ni n'écrit rien sous overlay/ =="
printf 'gen/g1\n' > "$R/overlay/CURRENT"
avant="$(cd "$R/overlay" && find . | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")"; done)"
choix >/dev/null
apres="$(cd "$R/overlay" && find . | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")"; done)"
egal "cc_ensure_core ne modifie rien sous overlay/ (noms et dates)" "$avant" "$apres"

echo
printf '%d ok, %d ko\n' "$OK" "$KO"
[ "$KO" -eq 0 ]
