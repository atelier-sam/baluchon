#!/usr/bin/env bash
# ============================================================
#  logiciels.test.sh <dossier-vide-absolu>
#
#  Épreuves de « 💿 Installer des logiciels » du wizard gum (Claude.command : `logiciels_depart` et
#  `tool_windows_apps`) AVEC les packs : « Par où commencer ? » avant la liste. Les deux fonctions sont
#  extraites du VRAI Claude.command du dépôt et jouées contre un faux gum (qui répond au script de l'essai
#  et note chaque menu qu'on lui présente : en-tête, cases pré-cochées, entrées) et un faux noyau (le
#  catalogue, les packs, et le journal des `win install`). Rien n'est installé, aucun réseau, aucun HOME touché.
#
#  Ce qui est prouvé :
#    - le menu des packs liste les packs DANS L'ORDRE du noyau (« Essentiels d'un PC neuf » en tête), avec leur
#      nombre de logiciels (« 1 logiciel » au singulier), puis « Tout le catalogue, à cocher moi-même » ;
#    - choisir un pack PRÉ-COCHE exactement ses logiciels dans la liste COMPLÈTE (qui garde ses six lignes) ;
#      on peut en décocher, et ce qui est installé est ce qui reste coché, par CLÉ, dans l'ordre du catalogue ;
#    - « Essentiels » + Entrée = ce que la liste pré-cochait avant les packs (les cases « coché » du noyau) ;
#    - « à la carte » ne pré-coche rien ;
#    - Échap au menu des packs OU à la liste : rien n'est installé, et la liste n'est pas posée après un Échap ;
#    - un noyau d'AVANT (qui refuse `--format packs`, code 2) ou sans aucun pack : AUCUN menu de packs, la liste
#      seule, pré-cochée comme avant.
#  Contrôle positif : l'ANCIEN Claude.command (01c3183, avant les packs) ne présente aucun menu de packs ; les
#  mêmes vérifications échouent contre lui.
#  Sortie : « N ok, M ko » ; code 0 seulement si M = 0.
# ============================================================
# SC2016 : les petits scripts d'essai s'écrivent volontairement entre apostrophes.
# shellcheck disable=SC2016
set -uo pipefail

ulimit -u 3000 2>/dev/null || true
DEPOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -f "$DEPOT/Claude.command" ] || { echo "Claude.command introuvable" >&2; exit 2; }

BASE_IN="${1:-}"
[ -n "$BASE_IN" ] || { echo "usage : logiciels.test.sh <dossier-vide-absolu>" >&2; exit 2; }
case "$BASE_IN" in /*) ;; *) echo "le dossier doit être un chemin ABSOLU" >&2; exit 2 ;; esac
[ -d "$BASE_IN" ] || { echo "dossier absent : $BASE_IN" >&2; exit 2; }
[ -z "$(ls -A "$BASE_IN")" ] || { echo "le dossier n'est pas vide : $BASE_IN" >&2; exit 2; }
BASE="$(cd "$BASE_IN" && pwd -P)"

OK=0; KO=0
verdict() { # verdict <vrai|faux> <libellé> [détail]
  if [ "$1" = vrai ]; then OK=$((OK + 1)); printf 'ok   %s\n' "$2"
  else KO=$((KO + 1)); printf 'KO   %s\n' "$2"; [ -z "${3:-}" ] || printf '%s\n' "$3" | sed 's/^/       /'; fi
}
egal() { if [ "$2" = "$3" ]; then verdict vrai "$1"; else verdict faux "$1" "attendu « $2 », obtenu « $3 »"; fi; }

# ── Les faux ────────────────────────────────────────────────────────────────────────────────
FAUX="$BASE/faux"; mkdir -p "$FAUX"
cat > "$FAUX/gum" <<'GUM'
#!/usr/bin/env bash
# Faux gum : `choose` lit ses entrées sur l'entrée standard (comme le wizard), note le menu dans CTL/menu.N
# (ligne 1 : en-tête, ligne 2 : cases pré-cochées, ligne 3 : 1 si --no-limit, puis une entrée par ligne), puis répond
# selon CTL/reponses (une réponse par appel) :
#   @annule : Échap (code 1) ; @pre : valide les cases pré-cochées telles quelles ; @rien : valide sans rien ;
#   sinon des motifs séparés par « | » : pour chacun, la première entrée qui le contient.
c="${GUM_CTL:?}"
[ "${1:-}" = choose ] || exit 0
shift
hdr=""; sel=""; nolimit=0
while [ $# -gt 0 ]; do
  case "$1" in
    --header) hdr="$2"; shift 2 ;;
    --selected) sel="$2"; shift 2 ;;
    --no-limit) nolimit=1; shift ;;
    --cursor.foreground|--height|--cursor) shift 2 ;;
    *) shift ;;
  esac
done
items=()
while IFS= read -r l; do items+=("$l"); done
n=$(( $(cat "$c/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c/n"
{ printf '%s\n%s\n%s\n' "$hdr" "$sel" "$nolimit"; printf '%s\n' "${items[@]}"; } > "$c/menu.$n"
want="$(head -n 1 "$c/reponses" 2>/dev/null)"; tail -n +2 "$c/reponses" > "$c/reponses.tmp" 2>/dev/null; mv -f "$c/reponses.tmp" "$c/reponses" 2>/dev/null
case "$want" in
  "") echo "plus de réponse scriptée (menu $n)" >> "$c/anomalies"; exit 1 ;;
  @annule) exit 1 ;;
  @rien) exit 0 ;;
  @pre) [ -n "$sel" ] && printf '%s\n' "$sel" | tr ',' '\n'; exit 0 ;;
esac
old="$IFS"; IFS='|'; set -- $want; IFS="$old"
for p in "$@"; do
  for i in "${items[@]}"; do case "$i" in *"$p"*) printf '%s\n' "$i"; break ;; esac; done
done
exit 0
GUM
cat > "$FAUX/noyau" <<'NOYAU'
#!/usr/bin/env bash
# Faux noyau : `win catalog --format lines` rend le catalogue d'essai ; `--format packs` rend CTL/packs (code 2 si
# CTL/sans-packs : un noyau d'avant) ; `win install <clés>` note ses arguments dans CTL/install.log.
c="${GUM_CTL:?}"
[ "${1:-}" = win ] || exit 64
case "${2:-} ${3:-} ${4:-}" in
  "catalog --format lines")
    printf '%s\t%s\t%s\n' \
      chrome "Google Chrome" 1 firefox "Mozilla Firefox" 0 vlc "VLC (lecteur multimédia)" 1 \
      7zip "7-Zip (archives gratuit)" 1 artcraft-cad "CADCraft (CAO)" 0 artcraft-material "MaterialCraft (matériaux)" 0
    exit 0 ;;
  "catalog --format packs")
    [ ! -e "$c/sans-packs" ] || { echo "error: invalid value 'packs' for '--format <FORMAT>'" >&2; exit 2; }
    cat "$c/packs" 2>/dev/null; exit 0 ;;
  "install "*) shift 2; echo "install $*" >> "$c/install.log"; exit 0 ;;
esac
exit 64
NOYAU
chmod +x "$FAUX/gum" "$FAUX/noyau"

# Le texte d'une fonction d'un fichier (de « nom() { » à la « } » en colonne 0).
extraire() { awk -v f="$2" 'index($0, f "() {") == 1 { p = 1 } p { print } p && /^}/ { exit }' "$1"; }

# jouer <Claude.command> <dossier> <réponses…> : rejoue « Installer des logiciels » ; CTL = <dossier>/ctl
jouer() {
  local fichier="$1" d="$2"; shift 2
  mkdir -p "$d/ctl"
  printf '%s\n' "$@" > "$d/ctl/reponses"
  [ -e "$d/ctl/packs" ] || printf '%s\t%s\t%s\n' \
    essentiels "Essentiels d'un PC neuf" chrome,vlc,7zip \
    artcraft-3d "ArtCraft 3D" artcraft-cad,artcraft-material \
    solo "Un seul logiciel" firefox > "$d/ctl/packs"
  {
    echo 'ORANGE=x'
    echo 'title() { :; }; note() { :; }; pause_key() { :; }; bad() { echo "bad: $*" >> "$GUM_CTL/anomalies"; }'
    echo 'ccp_core() { "'"$FAUX"'/noyau" "$@"; }'
    extraire "$fichier" logiciels_depart
    extraire "$fichier" tool_windows_apps
    echo 'tool_windows_apps'
  } > "$d/run.sh"
  GUM_CTL="$d/ctl" PATH="$FAUX:$PATH" bash "$d/run.sh" > "$d/out" 2>&1
}
menu() { sed -n "${2}p" "$1/ctl/menu.$3" 2>/dev/null; }  # menu <dossier> <ligne> <n°>
entrees() { tail -n +4 "$1/ctl/menu.$2" 2>/dev/null; }    # entrees <dossier> <n°>
installe() { cat "$1/ctl/install.log" 2>/dev/null; }
menus_vus() { find "$1/ctl" -maxdepth 1 -name 'menu.*' 2>/dev/null | wc -l | tr -d ' '; }

NOUVEAU="$DEPOT/Claude.command"
CATALOGUE_LIBELLES=$'Google Chrome\nMozilla Firefox\nVLC (lecteur multimédia)\n7-Zip (archives gratuit)\nCADCraft (CAO)\nMaterialCraft (matériaux)'
ESSENTIELS_COCHES='Google Chrome,VLC (lecteur multimédia),7-Zip (archives gratuit)'

# 0. L'extraction ne ment pas : les deux fonctions existent dans le fichier du dépôt.
for f in logiciels_depart tool_windows_apps; do
  if [ -n "$(extraire "$NOUVEAU" "$f")" ]; then verdict vrai "$f est dans Claude.command"; else verdict faux "$f est dans Claude.command"; fi
done

# 1. « Essentiels » puis Entrée sur la liste : le menu des packs, puis les cases d'avant les packs.
D="$BASE/e1"; jouer "$NOUVEAU" "$D" "Essentiels" "@pre"
egal "1. en-tête du menu des packs" "Par où commencer ?" "$(menu "$D" 1 1)"
egal "1. le menu des packs : packs dans l'ordre du noyau (essentiels d'abord), nombre au singulier, puis « à la carte »" \
  $'Essentiels d\'un PC neuf (3 logiciels)\nArtCraft 3D (2 logiciels)\nUn seul logiciel (1 logiciel)\nTout le catalogue, à cocher moi-même' "$(entrees "$D" 1)"
egal "1. le menu des packs n'est pas à choix multiple" "0" "$(menu "$D" 3 1)"
egal "1. la liste complète reste là (six lignes, dans l'ordre du catalogue)" "$CATALOGUE_LIBELLES" "$(entrees "$D" 2)"
egal "1. la liste est à choix multiple, avec l'en-tête d'avant" "1|Logiciels à installer" "$(menu "$D" 3 2)|$(menu "$D" 1 2)"
egal "1. « Essentiels » pré-coche EXACTEMENT les cases « coché » du noyau" "$ESSENTIELS_COCHES" "$(menu "$D" 2 2)"
egal "1. ce qui est installé : les clés des cases restées cochées, dans l'ordre du catalogue" "install chrome vlc 7zip" "$(installe "$D")"
egal "1. aucune anomalie (réponses scriptées toutes consommées)" "" "$(cat "$D/ctl/anomalies" 2>/dev/null)"

# 2. Un pack thématique, dont on décoche un logiciel.
D="$BASE/e2"; jouer "$NOUVEAU" "$D" "ArtCraft 3D" "CADCraft"
egal "2. « ArtCraft 3D » pré-coche ses deux logiciels, pas les autres" "CADCraft (CAO),MaterialCraft (matériaux)" "$(menu "$D" 2 2)"
egal "2. la liste complète est toujours posée (on peut ajouter d'autres logiciels)" "$CATALOGUE_LIBELLES" "$(entrees "$D" 2)"
egal "2. seul ce qui reste coché s'installe" "install artcraft-cad" "$(installe "$D")"

# 3. Un pack d'un seul logiciel, et un pack dont on AJOUTE un logiciel à la main.
D="$BASE/e3"; jouer "$NOUVEAU" "$D" "Un seul logiciel" "Mozilla|VLC"
egal "3. un pack d'un logiciel pré-coche ce logiciel" "Mozilla Firefox" "$(menu "$D" 2 2)"
egal "3. on peut ajouter un logiciel en plus du pack : les deux s'installent" "install firefox vlc" "$(installe "$D")"

# 4. « À la carte » : rien n'est pré-coché.
D="$BASE/e4"; jouer "$NOUVEAU" "$D" "Tout le catalogue" "Mozilla|7-Zip"
egal "4. « à la carte » : la liste complète, AUCUNE case pré-cochée" "|1" "$(menu "$D" 2 2)|$(menu "$D" 3 2)"
egal "4. ce qui est coché à la main s'installe" "install firefox 7zip" "$(installe "$D")"

# 5. Échap au menu des packs : rien n'est installé, la liste n'est pas posée.
D="$BASE/e5"; jouer "$NOUVEAU" "$D" "@annule"
egal "5. Échap au menu des packs : un seul menu posé, rien installé" "1|" "$(menus_vus "$D")|$(installe "$D")"

# 6. Échap à la liste, après un pack : rien n'est installé.
D="$BASE/e6"; jouer "$NOUVEAU" "$D" "Essentiels" "@annule"
egal "6. Échap à la liste : rien installé" "2|" "$(menus_vus "$D")|$(installe "$D")"

# 7. La liste validée sans rien de coché : rien n'est installé (comme avant).
D="$BASE/e7"; jouer "$NOUVEAU" "$D" "Tout le catalogue" "@rien"
egal "7. rien de coché : rien installé" "" "$(installe "$D")"

# 8. Un noyau d'AVANT (refuse --format packs) : pas de menu de packs, la liste seule, pré-cochée comme avant.
D="$BASE/e8"; mkdir -p "$D/ctl"; : > "$D/ctl/sans-packs"; jouer "$NOUVEAU" "$D" "@pre"
egal "8. noyau d'avant : un seul menu, la liste, en-tête d'avant" "1|Logiciels à installer" "$(menus_vus "$D")|$(menu "$D" 1 1)"
egal "8. noyau d'avant : les cases « coché » du noyau, comme avant" "$ESSENTIELS_COCHES" "$(menu "$D" 2 1)"
egal "8. noyau d'avant : l'installation part avec les mêmes clés" "install chrome vlc 7zip" "$(installe "$D")"

# 9. Un noyau qui répond 0 sans aucun pack : même repli (aucun menu vide).
D="$BASE/e9"; mkdir -p "$D/ctl"; : > "$D/ctl/packs"; jouer "$NOUVEAU" "$D" "@pre"
egal "9. aucun pack : pas de menu de packs, la liste seule" "1|Logiciels à installer" "$(menus_vus "$D")|$(menu "$D" 1 1)"

# CONTRÔLE POSITIF : l'ANCIEN assistant (avant les packs) ne présente aucun menu de packs, et ne pré-coche donc rien d'un pack :
# les épreuves 1 à 3 échoueraient contre lui. On rejoue la 1re contre lui et on lit que SON premier menu est la liste.
if git -C "$DEPOT" show 01c3183:Claude.command > "$BASE/ancien-Claude.command" 2>/dev/null && [ -s "$BASE/ancien-Claude.command" ]; then
  D="$BASE/ancien"; jouer "$BASE/ancien-Claude.command" "$D" "@pre"
  egal "contrôle positif : l'ancien assistant pose la liste d'emblée, sans « Par où commencer ? »" "1|Logiciels à installer" "$(menus_vus "$D")|$(menu "$D" 1 1)"
  if [ "$(menu "$D" 1 1)" = "Par où commencer ?" ]; then verdict faux "contrôle positif : l'ancien assistant n'a pas de menu de packs"; else verdict vrai "contrôle positif : l'épreuve 1 échouerait contre l'ancien assistant (pas de menu de packs)"; fi
else
  echo "(!) l'ancien Claude.command (01c3183) est introuvable : contrôle positif sauté"
fi

for f in "${BASH_SOURCE[0]}" "$NOUVEAU"; do
  if bash -n "$f"; then verdict vrai "bash -n $(basename "$f")"; else verdict faux "bash -n $(basename "$f")"; fi
done

printf '%d ok, %d ko\n' "$OK" "$KO"
[ "$KO" -eq 0 ]
