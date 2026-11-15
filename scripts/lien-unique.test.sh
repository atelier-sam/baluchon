#!/usr/bin/env bash
# ============================================================
#  lien-unique.test.sh <dossier-vide-absolu>
#
#  Épreuves de « un seul lien » côté public : install.sh (le VRAI, recopié avec la seule ligne du
#  signataire changée pour la clé d'essai) installe, se reconnaît déjà installé et à jour, met à jour,
#  ouvre le menu (lib/common.sh : cc_open_menu), et laisse « Partir » tout effacer. Hors ligne : la
#  release est un dossier local signé par une clé d'essai (JAMAIS la clé du produit), servi par
#  file:// ; un faux curl sert downloads.claude.ai et refuse gum (qu'on pose d'avance, faux) ; le
#  menu est le VRAI Claude.command avec un faux gum. HOME est dans le dossier d'essai.
#
#  Ce qui est prouvé :
#    - première installation : fichiers, désinstalleur vérifié, commandes, relevé de release ;
#    - 2e exécution sur la même release : AUCUN téléchargement hors des deux fichiers de signature,
#      aucun fichier modifié, « déjà installé et à jour », état « a-jour » ;
#    - la même exécution avec BALUCHON_OUVRIR_MENU=1 ouvre le menu (sur CC_TTY) ; sans terminal, dit la
#      commande à taper et réussit ; sans la variable, n'ouvre rien ;
#    - installation interrompue (pas de relevé), fichier altéré, autre release : tout est refait ;
#    - un désinstalleur falsifié (empreinte ≠ sommes signées) est refusé, et AUCUN relevé « à jour »
#      n'existe après l'échec ; une release sans désinstalleur s'installe (pas de « Partir ») ;
#    - « Partir » depuis le menu ouvert par l'installeur : dossier et commandes effacés, l'installeur
#      n'annonce rien d'une installation qui n'existe plus ;
#    - contrôle positif : l'ANCIEN install.sh (c0172f7) retélécharge tout à la 2e exécution.
#  Sortie : « N ok, M ko » ; code 0 seulement si M = 0.
# ============================================================
# SC2016 : les petits scripts d'essai s'écrivent volontairement entre apostrophes.
# shellcheck disable=SC2016
set -uo pipefail

ulimit -u 3000 2>/dev/null || true
ulimit -v 4000000 2>/dev/null || true   # plafond mémoire (sans effet sous macOS, utile ailleurs)
for v in $(git rev-parse --local-env-vars 2>/dev/null); do unset "$v"; done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPOT="$(cd "$HERE/.." && pwd)"
for f in install.sh Claude.command lib/common.sh uninstall.sh; do [ -f "$DEPOT/$f" ] || { echo "$f introuvable" >&2; exit 2; }; done
command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen est requis" >&2; exit 2; }

BASE_IN="${1:-}"
[ -n "$BASE_IN" ] || { echo "usage : lien-unique.test.sh <dossier-vide-absolu>" >&2; exit 2; }
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
vrai_si() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then verdict vrai "$l"; else verdict faux "$l"; fi; }
dit() { if grep -qF -- "$2" "$T/out" 2>/dev/null; then verdict vrai "$1"; else verdict faux "$1" "$(tail -n 12 "$T/out" 2>/dev/null)"; fi; }
ne_dit_pas() { if grep -qF -- "$2" "$T/out" 2>/dev/null; then verdict faux "$1" "$(tail -n 12 "$T/out" 2>/dev/null)"; else verdict vrai "$1"; fi; }

read -r PLAT CORE_PLAT BINNAME < <(bash -c 'ROOT=/x; . "$1"; cc_detect_platform; echo "$PLAT $CORE_PLAT $BINNAME"' _ "$DEPOT/lib/common.sh")
TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
REAL_CURL="$(command -v curl)"
REAL_SHASUM="$(command -v shasum || true)"

# ── La clé d'essai, et une copie de install.sh qui ne diffère que par la ligne du signataire ──────
KEYS="$BASE/cles"; mkdir -p "$KEYS"
ssh-keygen -q -t ed25519 -N '' -C essai -f "$KEYS/signataire" >/dev/null
PUB="$(cut -d' ' -f1,2 "$KEYS/signataire.pub")"
recle() { # recle <source> <destination> : même fichier, ligne CCP_SIGNER= de l'essai
  awk -v pub="$PUB" '/^CCP_SIGNER=/ && !fait {print "CCP_SIGNER='\''baluchon-release " pub "'\''"; fait=1; next} {print}' "$1" > "$2"
}
INSTALL="$BASE/install.sh"; recle "$DEPOT/install.sh" "$INSTALL"
egal "0. la copie de install.sh ne diffère de l'original que par la ligne du signataire" 1 "$(diff "$DEPOT/install.sh" "$INSTALL" | grep -c '^<')"

# ── Les faux ────────────────────────────────────────────────────────────────────────────────
FAUX="$BASE/faux"; mkdir -p "$FAUX/claude-stable"
cat > "$FAUX/gum" <<'GUM'
#!/usr/bin/env bash
c="${GUM_CTL:?}"
pop() { local f="$1" v; v="$(head -n 1 "$f" 2>/dev/null)"; tail -n +2 "$f" > "$f.tmp" 2>/dev/null; mv -f "$f.tmp" "$f" 2>/dev/null; printf '%s' "$v"; }
sub="${1:-}"; shift || true
case "$sub" in
  choose)
    items=()
    while [ $# -gt 0 ]; do
      case "$1" in --header|--cursor|--cursor.foreground|--height|--selected.foreground) shift 2 ;; --*) shift ;; *) items+=("$1"); shift ;; esac
    done
    { echo '---'; printf '%s\n' "${items[@]}"; } >> "$c/menus"
    want="$(pop "$c/choix")"
    [ -n "$want" ] || exit 1
    for i in "${items[@]}"; do case "$i" in *"$want"*) printf '%s\n' "$i"; exit 0 ;; esac; done
    exit 1 ;;
  confirm) printf '%s\n' "$*" >> "$c/confirms"; rc="$(pop "$c/confirm-rc")"; exit "${rc:-0}" ;;
  style) for last; do :; done; printf '%s\n' "$last"; exit 0 ;;
  *) exit 0 ;;
esac
GUM
cat > "$FAUX/curl" <<'CURL'
#!/usr/bin/env bash
# Faux curl : sert downloads.claude.ai depuis FAKE_CLAUDE, refuse gum, journalise l'adresse demandée ;
# tout le reste (file://) va au vrai curl.
url=""; out=""; prev=""
for a in "$@"; do
  [ "$prev" = -o ] && out="$a"
  case "$a" in http*|file*) url="$a" ;; esac
  prev="$a"
done
printf '%s\n' "$url" >> "${CURL_LOG:?}"
serve() { if [ -n "$out" ]; then cp "$1" "$out"; else cat "$1"; fi; exit 0; }
case "$url" in
  https://downloads.claude.ai/claude-code-releases/stable) serve "$FAKE_CLAUDE/stable" ;;
  https://downloads.claude.ai/claude-code-releases/9.9.9/manifest.json) serve "$FAKE_CLAUDE/manifest.json" ;;
  https://downloads.claude.ai/claude-code-releases/9.9.9/*/claude) serve "$FAKE_CLAUDE/claude" ;;
  https://github.com/charmbracelet/*) exit 22 ;;
esac
exec "${REAL_CURL:?}" "$@"
CURL
printf '#!/bin/sh\necho "$@" >> "${GUM_CTL:?}/security.log"\nexit 44\n' > "$FAUX/security"   # filet : jamais le vrai Trousseau
cat > "$FAUX/noyau" <<'NOYAU'
#!/usr/bin/env bash
case "${1:-}" in --contract) echo 1; exit 0 ;; --version) echo faux; exit 0 ;; esac
[ "${1:-}" = --root ] && shift 2
case "${1:-} ${2:-}" in
  "accounts best") echo perso; exit 0 ;;
  "accounts status") echo "perso   connecté"; exit 0 ;;
  "accounts purge"|"accounts discover"|"remote forget-access") exit 0 ;;
esac
exit 64
NOYAU
printf '#!/bin/sh\n[ "$1" = --version ] && echo "claude faux"\nexit 0\n' > "$FAUX/claude-stable/claude"
printf '9.9.9' > "$FAUX/claude-stable/stable"
CSHA="$(shasum -a 256 "$FAUX/claude-stable/claude" | cut -d' ' -f1)"
printf '{"version":"9.9.9","platforms":{"%s":{"checksum":"%s","size":10}}}\n' "$PLAT" "$CSHA" > "$FAUX/claude-stable/manifest.json"
chmod +x "$FAUX"/gum "$FAUX"/curl "$FAUX"/noyau "$FAUX"/security "$FAUX/claude-stable/claude"

# ── Une release locale signée ───────────────────────────────────────────────────────────────
release() { # release <dossier> [sans-uninstall] [variante] : actifs + SHA256SUMS signé
  local r="$1" mode="${2:-}" variante="${3:-}"
  mkdir -p "$r"; rm -f "$r"/*
  # La bibliothèque et le désinstalleur publiés portent EUX AUSSI la clé de l'essai : ce sont eux qui vérifient,
  # plus tard, le manifeste signé que l'installation conserve (la vraie clé du produit n'a pas servi à signer ici).
  cp "$DEPOT/Claude.command" "$r/Claude.command"; recle "$DEPOT/lib/common.sh" "$r/common.sh"
  [ "$mode" = sans-uninstall ] || recle "$DEPOT/uninstall.sh" "$r/uninstall.sh"
  cp "$FAUX/noyau" "$r/baluchon-core-$CORE_PLAT"
  [ -z "$variante" ] || printf '\n# variante %s\n' "$variante" >> "$r/Claude.command"
  ( cd "$r" && shasum -a 256 -- * > "$BASE/SHA256SUMS.tmp" && mv "$BASE/SHA256SUMS.tmp" SHA256SUMS )
  ssh-keygen -q -Y sign -f "$KEYS/signataire" -n file "$r/SHA256SUMS" >/dev/null
}

# ── Un monde : domicile, gum posé d'avance (faux), journaux ─────────────────────────────────
monde() { # monde <nom> [release-source]
  T="$BASE/$1"; H="$T/home"; DIR="$H/.baluchon"; CTL="$T/ctl"; REL="${2:-$BASE/release-a}"
  mkdir -p "$T/bin" "$T/tmp" "$CTL" "$H/.local/bin" "$DIR/tools/gum/$PLAT"
  cp "$FAUX/curl" "$FAUX/security" "$T/bin/"
  cp "$FAUX/gum" "$DIR/tools/gum/$PLAT/gum"; chmod +x "$DIR/tools/gum/$PLAT/gum"
  # Le vrai gum est vérifié par l'empreinte épinglée de son archive, que l'essai ne peut pas reproduire (faux gum) :
  # on note donc sa référence comme l'installeur le fait après cette vérification. Sans elle, un gum qu'aucune
  # référence n'authentifie est retiré (c'est la règle, éprouvée plus bas).
  printf '%s  tools/gum/%s/gum\n' "$(shasum -a 256 "$DIR/tools/gum/$PLAT/gum" | cut -d' ' -f1)" "$PLAT" > "$DIR/.baluchon-refs"
  : > "$CTL/choix"; : > "$CTL/confirm-rc"; : > "$CTL/menus"; : > "$T/tty"
}
# Joue un installeur dans le monde courant. $1 = install.sh à jouer ; les suivants = variables d'environnement.
joue() {
  local script="$1"; shift
  RC=0; : > "$T/curl.log"; rm -f "$T/etat"
  ( cd "$H" && ${TIMEOUT:+"$TIMEOUT" 300} env -i HOME="$H" PATH="$T/bin:/usr/bin:/bin" TERM=dumb TMPDIR="$T/tmp" \
      BALUCHON_DIR="$DIR" CCP_DL="file://$REL" CURL_LOG="$T/curl.log" FAKE_CLAUDE="$FAUX/claude-stable" REAL_CURL="$REAL_CURL" REAL_SHASUM="$REAL_SHASUM" \
      GUM_CTL="$CTL" CC_TTY="$T/tty" BALUCHON_ETAT_SORTIE="$T/etat" "$@" bash "$script" < /dev/null > "$T/out" 2>&1 ) || RC=$?
}
choix() { printf '%s\n' "$@" > "$CTL/choix"; }
etat() { tr -d '\n' < "$T/etat" 2>/dev/null; }
telechargements() { grep -c "$1" "$T/curl.log" 2>/dev/null || true; }
lourds() { grep -vc -e '/SHA256SUMS$' -e '/SHA256SUMS\.sig$' "$T/curl.log" 2>/dev/null || true; }
# Le menu, lui, consulte la version stable de Claude (un seul GET de quelques octets) : ce n'est pas l'installeur.
# Quand le menu s'ouvre, on vérifie donc que l'installeur n'a rien téléchargé de lourd en dehors de cette consultation.
lourds_hors_menu() { grep -vc -e '/SHA256SUMS$' -e '/SHA256SUMS\.sig$' -e 'claude-code-releases/stable$' "$T/curl.log" 2>/dev/null || true; }
instantane() { # empreinte de chaque fichier de l'installation (hors journaux, comptes, cache) et des commandes
  ( cd "$DIR" && find . -type f -not -path './logs/*' -not -path './config/*' -not -path './.cache/*' | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done ) 2>/dev/null
  ( cd "$H/.local/bin" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done ) 2>/dev/null
}
nb_menus() { grep -c '^---$' "$CTL/menus" 2>/dev/null || true; }
SHA_REL() { shasum -a 256 "$REL/SHA256SUMS" | cut -d' ' -f1; }

release "$BASE/release-a"
release "$BASE/release-b" "" b
release "$BASE/release-ancienne" sans-uninstall

# ── A. Première installation, puis « déjà à jour », puis tout ce qui doit la défaire ──────────
monde A
joue "$INSTALL"
egal "A1. première installation : code 0" 0 "$RC"
egal "A1. …état « installe »" installe "$(etat)"
vrai_si "A1. …marqueur, wizard, bibliothèque, désinstalleur, noyau, binaire Claude, VERSION posés" \
  test -f "$DIR/.baluchon-install" -a -x "$DIR/Claude.command" -a -f "$DIR/lib/common.sh" -a -f "$DIR/uninstall.sh" \
       -a -x "$DIR/bin/$CORE_PLAT/baluchon-core" -a -f "$DIR/bin/$PLAT/$BINNAME" -a -s "$DIR/VERSION"
vrai_si "A1. …le désinstalleur posé est celui de la release (empreinte vérifiée)" test "$(shasum -a 256 "$DIR/uninstall.sh" | cut -d' ' -f1)" = "$(shasum -a 256 "$BASE/release-a/uninstall.sh" | cut -d' ' -f1)"
vrai_si "A1. …les quatre commandes sont posées" test -x "$H/.local/bin/baluchon" -a -x "$H/.local/bin/baluchon1" -a -x "$H/.local/bin/ccp" -a -x "$H/.local/bin/ccp1"
egal "A1. …le relevé de release porte l'empreinte des sommes signées" "sums $(SHA_REL)" "$(sed -n 2p "$DIR/.baluchon-release")"
egal "A1. …et son en-tête" "baluchon-release 1" "$(sed -n 1p "$DIR/.baluchon-release")"
ne_dit_pas "A1. …sans BALUCHON_OUVRIR_MENU, le menu ne s'ouvre pas" "À bientôt"
egal "A1. …aucun menu ouvert" 0 "$(nb_menus)"

instantane > "$T/avant"
joue "$INSTALL"
egal "A2. 2e exécution sur la même release : code 0" 0 "$RC"
egal "A2. …état « a-jour »" a-jour "$(etat)"
dit "A2. …dit « déjà installé et à jour »" "déjà installé et à jour"
egal "A2. …AUCUN téléchargement hors des deux fichiers de signature" 0 "$(lourds)"
instantane > "$T/apres"
vrai_si "A2. …aucun fichier de l'installation n'a changé" cmp -s "$T/avant" "$T/apres"

rm -f "$H/.local/bin/baluchon"
joue "$INSTALL"
vrai_si "A2. …la commande supprimée entre-temps est reposée sans rien retélécharger" test -x "$H/.local/bin/baluchon" -a "$(lourds)" = 0

choix Quitter
joue "$INSTALL" BALUCHON_OUVRIR_MENU=1
egal "A3. déjà à jour + BALUCHON_OUVRIR_MENU=1 : code 0" 0 "$RC"
egal "A3. …le menu s'est ouvert (une fois)" 1 "$(nb_menus)"
vrai_si "A3. …sur le terminal demandé (CC_TTY), pas sur la sortie de l'installeur" grep -q 'À bientôt' "$T/tty"
ne_dit_pas "A3. …la sortie de l'installeur ne porte pas le dessin du menu" "À bientôt"
dit "A3. …l'installeur finit son travail APRÈS le menu (messages de fin)" "Tout est rangé ici"
egal "A3. …toujours aucun téléchargement lourd de l'installeur (hors la consultation de version du menu)" 0 "$(lourds_hors_menu)"

joue "$INSTALL" BALUCHON_OUVRIR_MENU=1 CC_TTY="$T/absent"
egal "A4. pas de terminal : code 0 (ce n'est pas une erreur)" 0 "$RC"
dit "A4. …dit la commande à taper" "Pour l'ouvrir, tape"
egal "A4. …aucun menu ouvert de plus" 1 "$(nb_menus)"

rm -f "$DIR/.baluchon-release"
joue "$INSTALL"
egal "A5. relevé absent (installation interrompue) : tout est refait, état « installe »" installe "$(etat)"
vrai_si "A5. …des téléchargements ont eu lieu" test "$(lourds)" -gt 0
vrai_si "A5. …et le relevé est reposé" test -f "$DIR/.baluchon-release"

printf '\n# altéré\n' >> "$DIR/uninstall.sh"
joue "$INSTALL"
egal "A6. un fichier posé a été modifié : tout est refait" installe "$(etat)"
vrai_si "A6. …le désinstalleur est redevenu celui de la release" test "$(shasum -a 256 "$DIR/uninstall.sh" | cut -d' ' -f1)" = "$(shasum -a 256 "$BASE/release-a/uninstall.sh" | cut -d' ' -f1)"

rm -f "$DIR/tools/gum/$PLAT/gum"
joue "$INSTALL"
egal "A7. gum a disparu : pas « à jour » (sans lui, pas de menu)" installe "$(etat)"
dit "A7. …et l'interface manquante est dite, sans faire échouer l'installation" "gum indisponible"
cp "$FAUX/gum" "$DIR/tools/gum/$PLAT/gum"; chmod +x "$DIR/tools/gum/$PLAT/gum"
joue "$INSTALL"   # redonne un état « à jour » avant la suite
REL="$BASE/release-b"
joue "$INSTALL"
egal "A8. autre release (sommes signées différentes) : mise à jour complète, état « installe »" installe "$(etat)"
egal "A8. …le relevé porte les sommes de la NOUVELLE release" "sums $(SHA_REL)" "$(sed -n 2p "$DIR/.baluchon-release")"
vrai_si "A8. …Claude.command est celui de la nouvelle release" grep -q '# variante b' "$DIR/Claude.command"
joue "$INSTALL"
egal "A8. …et la suivante, sur cette release, est « a-jour »" a-jour "$(etat)"

# ── B. Menu ouvert tout de suite après une première installation ──────────────────────────────
monde B
choix Quitter
joue "$INSTALL" BALUCHON_OUVRIR_MENU=1
egal "B1. première installation + menu : code 0" 0 "$RC"
egal "B1. …le menu s'est ouvert" 1 "$(nb_menus)"
vrai_si "B1. …et l'installation est complète" test -f "$DIR/.baluchon-release" -a -f "$DIR/uninstall.sh"
vrai_si "B1. …la question « cet ordinateur est-il à toi ? » a été posée par le menu" grep -q 'est-il à toi' "$CTL/confirms"

# ── C. Un désinstalleur falsifié est refusé, et aucun relevé « à jour » n'en reste ─────────────
monde C "$BASE/release-c"
release "$BASE/release-c"
printf '\n# falsifié après signature\n' >> "$BASE/release-c/uninstall.sh"
joue "$INSTALL"
egal "C1. désinstalleur ≠ sommes signées : code 1" 1 "$RC"
dit "C1. …refusé pour empreinte invalide" "Empreinte invalide pour uninstall.sh"
vrai_si "C1. …aucun relevé « à jour » après l'échec" test ! -e "$DIR/.baluchon-release"
vrai_si "C1. …et le désinstalleur falsifié n'est PAS posé" test ! -e "$DIR/uninstall.sh"
release "$BASE/release-c"
joue "$INSTALL"
egal "C2. la release réparée s'installe ensuite normalement" 0 "$RC"

# ── D. Une release SANS désinstalleur (ancienne) s'installe, sans « Partir » ───────────────────
monde D "$BASE/release-ancienne"
choix Quitter
joue "$INSTALL" BALUCHON_OUVRIR_MENU=1
egal "D1. release sans désinstalleur : code 0" 0 "$RC"
dit "D1. …l'absence est dite" "ne porte pas de désinstalleur"
vrai_si "D1. …aucun uninstall.sh posé" test ! -e "$DIR/uninstall.sh"
vrai_si "D1. …le menu ouvert ne propose pas « Partir »" test "$(grep -c Partir "$CTL/menus")" = 0
joue "$INSTALL"
egal "D2. …et la 2e exécution reconnaît quand même l'installation « a-jour »" a-jour "$(etat)"

# ── E. « Partir » depuis le menu ouvert par l'installeur ───────────────────────────────────────
monde E
choix Partir
# Le menu pose d'abord « cet ordinateur est-il à toi ? » : on répond oui (code 0), puis on confirme Partir.
printf '0\n0\n' > "$CTL/confirm-rc"
joue "$INSTALL" BALUCHON_OUVRIR_MENU=1
egal "E1. première installation, menu, « Partir » : code 0" 0 "$RC"
vrai_si "E1. …le dossier d'installation a disparu" test ! -e "$DIR"
vrai_si "E1. …les commandes aussi" test ! -e "$H/.local/bin/baluchon" -a ! -e "$H/.local/bin/baluchon1" -a ! -e "$H/.local/bin/ccp" -a ! -e "$H/.local/bin/ccp1"
vrai_si "E1. …et le menu l'a dit (relu sur le disque), sur le terminal" grep -q 'Rien ne reste sur cet ordinateur' "$T/tty"
ne_dit_pas "E1. …l'installeur n'annonce pas « Tout est prêt » pour une installation effacée" "Tout est prêt"
ne_dit_pas "E1. …ni le conseil de PATH" "Ajoute"
vrai_si "E1. …et aucun dossier d'installation n'est recréé par la suite (journaux compris)" test ! -e "$DIR"

# ── F. Contrôle positif : l'ANCIEN install.sh (c0172f7) retélécharge tout, à chaque fois ───────
ANCIEN_BRUT="$BASE/install-ancien-brut.sh"
if git -C "$DEPOT" show c0172f7:install.sh > "$ANCIEN_BRUT" 2>/dev/null && [ -s "$ANCIEN_BRUT" ]; then
  ANCIEN="$BASE/install-ancien.sh"; recle "$ANCIEN_BRUT" "$ANCIEN"
  monde F
  joue "$ANCIEN"
  joue "$ANCIEN"
  vrai_si "F1. CONTRÔLE POSITIF : l'ancien install.sh retélécharge Claude.command à la 2e exécution" test "$(telechargements 'Claude.command')" -ge 1
  joue "$INSTALL"
  joue "$INSTALL"
  vrai_si "F1. …le nouveau, lui, ne retélécharge rien (sur un monde que l'ancien avait installé : tout est refait UNE fois, puis plus rien)" test "$(lourds)" = 0
else
  echo "(!) historique git absent : le contrôle positif sur l'ancien install.sh (c0172f7) est sauté"
fi

# ── G. Rien n'est exécuté ni sourcé avant d'avoir été comparé à une empreinte authentifiée ─────
# (revue Codex, 2e passe, HIGH 1 à 3 : la bibliothèque était hachée puis sourcée par son chemin ; « à jour »
# se contentait de la PRÉSENCE de Claude et de gum ; le menu lançait ce qu'il trouvait.)
# Un faux `shasum` joue l'attaque la plus étroite : une fois la bibliothèque contrôlée, il la REMPLACE dans
# l'installation par une autre qui laisse un témoin si on l'exécute.
cat > "$FAUX/shasum" <<'SHASUM'
#!/usr/bin/env bash
sortie="$("${REAL_SHASUM:?}" "$@")"; rc=$?
printf '%s\n' "$sortie"
if [ -e "${GUM_CTL:?}/piege-lib" ]; then
  for a in "$@"; do
    case "$a" in */lib/common.sh|*/lib-posee.sh)
      rm -f "$GUM_CTL/piege-lib"
      printf '#!/usr/bin/env bash\ntouch "%s"\n' "$GUM_CTL/pwned-lib" > "$BALUCHON_DIR/lib/common.sh.new"
      mv -f "$BALUCHON_DIR/lib/common.sh.new" "$BALUCHON_DIR/lib/common.sh" ;;
    esac
  done
fi
exit "$rc"
SHASUM
chmod +x "$FAUX/shasum"
mauvais() { printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$1"; }   # un exécutable qui laisse un témoin s'il tourne

monde G
joue "$INSTALL"
cp "$FAUX/shasum" "$T/bin/"
touch "$CTL/piege-lib"
joue "$INSTALL"
vrai_si "G1. bibliothèque remplacée APRÈS son contrôle : la version malveillante n'est JAMAIS exécutée" test ! -e "$CTL/pwned-lib"
egal "G1. …l'installation n'est pas « à jour » (la bibliothèque posée ne correspond plus) : tout est refait" installe "$(etat)"
vrai_si "G1. …et la bibliothèque posée est redevenue celle de la release" test "$(shasum -a 256 "$DIR/lib/common.sh" | cut -d' ' -f1)" = "$(shasum -a 256 "$BASE/release-a/common.sh" | cut -d' ' -f1)"

# Contrôle positif : le MÊME piège, joué contre l'installeur d'avant ce correctif (1238b14), exécute la version malveillante.
ANCIEN_G_BRUT="$BASE/install-avant-correctif-brut.sh"
if git -C "$DEPOT" show 1238b14:install.sh > "$ANCIEN_G_BRUT" 2>/dev/null && [ -s "$ANCIEN_G_BRUT" ]; then
  ANCIEN_G="$BASE/install-avant-correctif.sh"; recle "$ANCIEN_G_BRUT" "$ANCIEN_G"
  monde G0
  joue "$INSTALL"
  cp "$FAUX/shasum" "$T/bin/"
  touch "$CTL/piege-lib"
  joue "$ANCIEN_G"
  vrai_si "G1. CONTRÔLE POSITIF : l'ancien installeur EXÉCUTE la bibliothèque échangée (le piège fonctionne)" test -e "$CTL/pwned-lib"
else
  echo "(!) historique git absent : le contrôle positif de G1 (1238b14) est sauté"
fi

# G2. gum, puis Claude, remplacés SEULS dans une installation « à jour » : plus « à jour », rien n'est exécuté.
monde G2
joue "$INSTALL"
egal "G2. (point de départ) installation faite puis « à jour »" a-jour "$( joue "$INSTALL"; etat )"
mauvais "$CTL/pwned-gum" > "$DIR/tools/gum/$PLAT/gum"; chmod +x "$DIR/tools/gum/$PLAT/gum"
joue "$INSTALL"
egal "G2. gum remplacé seul : l'installation n'est plus « à jour »" installe "$(etat)"
vrai_si "G2. …le gum remplacé n'a JAMAIS été exécuté" test ! -e "$CTL/pwned-gum"
vrai_si "G2. …et il n'est plus là (retiré faute de référence, jamais gardé)" test ! -e "$DIR/tools/gum/$PLAT/gum" -o -z "$(grep -l pwned-gum "$DIR/tools/gum/$PLAT/gum" 2>/dev/null)"
monde G3
joue "$INSTALL"
mauvais "$CTL/pwned-claude" > "$DIR/bin/$PLAT/$BINNAME"; chmod +x "$DIR/bin/$PLAT/$BINNAME"
joue "$INSTALL"
egal "G3. Claude remplacé seul : l'installation n'est plus « à jour »" installe "$(etat)"
vrai_si "G3. …le binaire remplacé n'a JAMAIS été exécuté (pas même un --version)" test ! -e "$CTL/pwned-claude"
egal "G3. …il est RETÉLÉCHARGÉ et revérifié (empreinte du manifeste)" "$CSHA" "$(shasum -a 256 "$DIR/bin/$PLAT/$BINNAME" | cut -d' ' -f1)"

# G4. Le menu ne s'ouvre que sur une installation authentifiée : exécutable remplacé = refus dit, menu jamais lancé.
ouvre() { # joue cc_open_menu sur l'installation courante (sans $2 : le manifeste signé que l'installation a conservé)
  RC=0
  env -i HOME="$H" PATH="$T/bin:/usr/bin:/bin" TERM=dumb TMPDIR="$T/tmp" GUM_CTL="$CTL" CC_TTY="$T/tty" \
    bash -c 'ROOT="$1"; . "$ROOT/lib/common.sh"; cc_detect_platform; cc_open_menu "$ROOT/Claude.command"' _ "$DIR" < /dev/null > "$T/out" 2>&1 || RC=$?
}
monde G4
joue "$INSTALL"; choix Quitter; ouvre
egal "G4. (point de départ) installation intacte : le menu s'ouvre" 1 "$(nb_menus)"
for cas in noyau desinstalleur menu gum manifeste; do
  monde "G4-$cas"; joue "$INSTALL"; choix Quitter
  case "$cas" in
    noyau)         mauvais "$CTL/pwned-menu" > "$DIR/bin/$CORE_PLAT/baluchon-core" ;;
    desinstalleur) mauvais "$CTL/pwned-menu" > "$DIR/uninstall.sh" ;;
    menu)          mauvais "$CTL/pwned-menu" > "$DIR/Claude.command" ;;
    gum)           mauvais "$CTL/pwned-menu" > "$DIR/tools/gum/$PLAT/gum" ;;
    manifeste)     # un manifeste de l'attaquant (sommes de SES fichiers) sans signature valide
                   mauvais "$CTL/pwned-menu" > "$DIR/Claude.command"
                   ( cd "$DIR" && shasum -a 256 Claude.command > .baluchon-sums ) ;;
  esac
  chmod +x "$DIR/Claude.command" "$DIR/uninstall.sh" "$DIR/bin/$CORE_PLAT/baluchon-core" 2>/dev/null
  ouvre
  egal "G4. $cas remplacé : le menu est refusé (code 1)" 1 "$RC"
  vrai_si "G4. $cas remplacé : rien n'a été exécuté" test ! -e "$CTL/pwned-menu"
  dit "G4. $cas remplacé : le refus est DIT" "ne correspond plus à la release signée"
done

printf '%s ok, %s ko\n' "$OK" "$KO"
[ "$KO" = 0 ]
