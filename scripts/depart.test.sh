#!/usr/bin/env bash
# ============================================================
#  depart.test.sh <dossier-vide-absolu>
#
#  Épreuves de l'entrée « 🚪 Partir : tout effacer et désinstaller » du menu (Claude.command, avec
#  lib/common.sh : cc_depart, cc_depart_releve, cc_depart_verifie) et de ses garde-fous, jouées sur le
#  VRAI Claude.command, la VRAIE bibliothèque et le VRAI uninstall.sh du dépôt, dans une installation
#  JETABLE : faux gum (qui répond au script de l'essai et note le menu qu'on lui présente), faux noyau,
#  faux `security` (un Trousseau dans un fichier), faux `curl` (aucun réseau), HOME dans le dossier
#  d'essai. Ni le vrai Trousseau, ni ~/.baluchon, ni ~/.cloudflared ne sont jamais touchés.
#
#  Ce qui est prouvé :
#    - tout réussit : code 0, dossier + commandes + Trousseau + jetons Access disparus, RELUS sur le
#      disque ; une commande « ccp » qui n'est pas la nôtre et l'item du Trousseau « sans suffixe » (la
#      session du Claude Code normal de la machine) survivent ;
#    - ce qui reste est DIT et le code n'est jamais 0 : jeton Access non effaçable (10), item du Trousseau
#      refusé (13), commande non supprimable (13), désinstallation refusée par ses gardes (2, sessions
#      déjà effacées) ;
#    - un désinstalleur qui MENT (rend 0 sans rien effacer) ne fait jamais dire « Rien ne reste » ;
#    - annulation : rien n'est touché ; désinstalleur altéré : code 14, rien n'est touché, le menu revient ;
#    - « Partir » n'est proposé que sur une installation (marqueur + désinstalleur) ; en tête sur un poste
#      invité, juste avant « Quitter » sinon ; la question est posée avec « Non » par défaut ;
#    - lien symbolique, hôte d'accès noté par l'amorce (.baluchon-acces) ;
#    - (revue Codex, 2e passe) le désinstalleur n'est exécuté que s'il a l'empreinte du manifeste SIGNÉ conservé
#      par l'installation (remplacé pendant le menu, manifeste forgé, illisible : jamais exécuté, c'est dit) ;
#      `config` est un lien : jamais suivi ; Trousseau verrouillé : « sessions non vérifiées », jamais « Rien ne
#      reste » ; cache d'exécution (~/.cache/baluchon) retiré avec des bornes sûres ou nommé s'il reste.
#  Contrôles positifs : l'ANCIEN Claude.command (c0172f7) ne propose pas « Partir » ; l'ANCIEN code (1238b14) exécute
#  un désinstalleur remplacé, suit un lien sur `config`, lit un Trousseau verrouillé comme « absent » et oublie le
#  cache : chaque épreuve nouvelle échouerait contre lui.
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
for f in Claude.command lib/common.sh uninstall.sh; do [ -f "$DEPOT/$f" ] || { echo "$f introuvable" >&2; exit 2; }; done

BASE_IN="${1:-}"
[ -n "$BASE_IN" ] || { echo "usage : depart.test.sh <dossier-vide-absolu>" >&2; exit 2; }
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
vrai_si() { # vrai_si <libellé> <commande…>
  local l="$1"; shift
  if "$@" >/dev/null 2>&1; then verdict vrai "$l"; else verdict faux "$l"; fi
}
dit() { # dit <libellé> <motif fixe> : la sortie du menu contient le motif
  if grep -qF -- "$2" "$T/out" 2>/dev/null; then verdict vrai "$1"; else verdict faux "$1" "$(tail -n 15 "$T/out" 2>/dev/null)"; fi
}
ne_dit_pas() {
  if grep -qF -- "$2" "$T/out" 2>/dev/null; then verdict faux "$1" "$(tail -n 15 "$T/out" 2>/dev/null)"; else verdict vrai "$1"; fi
}

# ── La clé d'essai (JAMAIS celle du produit) et les copies re-clées de la bibliothèque et du désinstalleur ─
# Le menu et « Partir » authentifient ce qu'ils exécutent contre le manifeste SIGNÉ que l'installation conserve ;
# la signature est vérifiée avec la clé épinglée dans la bibliothèque. L'essai pose donc une clé jetable à la
# place, comme lien-unique.test.sh (même technique, la seule ligne CCP_SIGNER= change).
command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen est requis" >&2; exit 2; }
CLE="$BASE/cle-essai"
ssh-keygen -q -t ed25519 -N '' -C essai -f "$CLE" >/dev/null
PUB="$(cut -d' ' -f1,2 "$CLE.pub")"
recle() { # recle <source> <destination>
  awk -v pub="$PUB" '/^CCP_SIGNER=/ && !fait {print "CCP_SIGNER='\''baluchon-release " pub "'\''"; fait=1; next} {print}' "$1" > "$2"
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Plateforme telle que la bibliothèque la voit (nom des dossiers bin/<plat>, tools/gum/<plat>).
read -r PLAT CORE_PLAT BINNAME CC_OS_T < <(bash -c 'ROOT=/x; . "$1"; cc_detect_platform; echo "$PLAT $CORE_PLAT $BINNAME $CC_OS"' _ "$DEPOT/lib/common.sh")
TROUSSEAU=0; [ "$CC_OS_T" = darwin ] && TROUSSEAU=1
[ "$TROUSSEAU" = 1 ] || echo "(!) hors macOS : les épreuves du Trousseau sont sautées"
TIMEOUT="$(command -v timeout || command -v gtimeout || true)"

# ── Les faux ────────────────────────────────────────────────────────────────────────────────
FAUX="$BASE/faux"; mkdir -p "$FAUX"
cat > "$FAUX/gum" <<'GUM'
#!/usr/bin/env bash
# Faux gum : `choose` répond selon CTL/choix (une réponse par appel : un motif cherché dans les
# entrées), note les entrées offertes ; `confirm` rend le code de CTL/confirm-rc et note sa ligne.
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
  confirm)
    printf '%s\n' "$*" >> "$c/confirms"
    # CTL/pendant-confirm : ce que fait un tiers PENDANT que le menu reste ouvert, avant la réponse.
    [ ! -x "$c/pendant-confirm" ] || "$c/pendant-confirm"
    rc="$(pop "$c/confirm-rc")"; exit "${rc:-0}" ;;
  style) for last; do :; done; printf '%s\n' "$last"; exit 0 ;;
  *) exit 0 ;;
esac
GUM
cat > "$FAUX/noyau" <<'NOYAU'
#!/usr/bin/env bash
# Faux noyau : contrat 1 ; `remote forget-access [--host h]` efface les vrais fichiers de jeton de
# $HOME/.cloudflared de l'hôte (sauf si CTL/forget-echec nomme cet hôte : code 10, rien d'effacé).
c="${GUM_CTL:?}"
case "${1:-}" in --contract) echo 1; exit 0 ;; --version) echo faux; exit 0 ;; esac
root=""; [ "${1:-}" = --root ] && { root="$2"; shift 2; }
case "${1:-} ${2:-}" in
  "accounts purge")
    echo "purge" >> "$c/core.log"
    # Comme le vrai noyau : un item du Trousseau par dossier config/<profil> ; un item qui ne part pas = code 1.
    # CTL/purge-ment : un noyau qui répond 0 SANS avoir rien effacé (le disque relu doit le dire).
    if [ ! -e "$c/purge-ment" ] && [ -s "$c/trousseau" ]; then
      for d in "$root"/config/*/; do
        [ -d "$d" ] || continue
        svc="Claude Code-credentials-$(printf '%s' "${d%/}" | shasum -a 256 | cut -c1-8)"
        security delete-generic-password -s "$svc" >/dev/null 2>&1
        if security find-generic-password -s "$svc" >/dev/null 2>&1; then exit 1; fi
      done
    fi
    exit "$(cat "$c/purge-rc" 2>/dev/null || echo 0)" ;;
  "accounts best") echo perso; exit 0 ;;
  "accounts status") echo "perso   connecté"; exit 0 ;;
  "accounts discover") exit 0 ;;
  "remote forget-access")
    host=""
    [ "${3:-}" = --host ] && host="${4:-}"
    [ -n "$host" ] || host="$(sed -n 's/^host *= *//p' "$root/config/remote.conf" 2>/dev/null | head -n 1)"
    echo "forget-access host=${host:-aucun}" >> "$c/core.log"
    [ -n "$host" ] || { echo "baluchon-core : aucun Mac configuré, aucun jeton à effacer." >&2; exit 0; }
    if grep -qxF "$host" "$c/forget-echec" 2>/dev/null; then echo "effacement INCOMPLET : ${host}-token (permission refusée)" >&2; exit 10; fi
    for f in "$HOME/.cloudflared/$host"-*-token* "$HOME/.cloudflared"/*.cloudflareaccess.com-org-token*; do [ -e "$f" ] && rm -f "$f"; done
    exit 0 ;;
esac
exit 64
NOYAU
cat > "$FAUX/security" <<'SEC'
#!/usr/bin/env bash
# Faux Trousseau : CTL/trousseau (un service par ligne) ; CTL/trousseau-refus = les suppressions échouent ;
# CTL/trousseau-ment = « supprimé » (0) sans rien retirer ; CTL/trousseau-verrouille = TOUT répond 36 (Trousseau
# verrouillé : ni présent ni absent) ; CTL/trousseau-find-verrouille = seule la lecture répond 36.
c="${GUM_CTL:?}"; f="$c/trousseau"; sub="${1:-}"; shift || true
svc=""; while [ $# -gt 0 ]; do [ "$1" = -s ] && { svc="$2"; shift; }; shift; done
case "$sub" in
  find-generic-password)
    [ ! -e "$c/trousseau-verrouille" ] && [ ! -e "$c/trousseau-find-verrouille" ] || exit 36
    grep -qxF -- "$svc" "$f" 2>/dev/null && exit 0; exit 44 ;;
  delete-generic-password)
    echo "delete $svc" >> "$c/security.log"
    [ ! -e "$c/trousseau-verrouille" ] || exit 36
    [ ! -e "$c/trousseau-refus" ] || exit 1
    [ ! -e "$c/trousseau-ment" ] || exit 0
    grep -qxF -- "$svc" "$f" 2>/dev/null || exit 44
    grep -vxF -- "$svc" "$f" > "$f.tmp"; mv -f "$f.tmp" "$f"; exit 0 ;;
esac
exit 1
SEC
printf '#!/bin/sh\nexit 22\n' > "$FAUX/curl"
printf '#!/bin/sh\nexit 0\n' > "$FAUX/sleep"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "claude faux" \nexit 0\n' > "$FAUX/claude"
chmod +x "$FAUX"/*

# ── Un monde jetable ─────────────────────────────────────────────────────────────────────────
# Pose T (dossier de l'épreuve), H (domicile), R (installation), CTL (état des faux), puis une
# installation complète à deux profils connectés, un Mac configuré, des commandes, un Trousseau et des
# jetons Access. $2 = Claude.command à poser (défaut : celui du dépôt).
monde() { # monde <nom> [Claude.command]   (MONDE_LIB / MONDE_UN : bibliothèque / désinstalleur à poser, par défaut ceux du dépôt)
  T="$BASE/$1"; H="$T/home"; R="$H/.baluchon"; CTL="$T/ctl"
  mkdir -p "$T/bin" "$CTL" "$H/.local/bin" "$H/.cloudflared" "$R/lib" "$R/config/perso" "$R/config/pro" "$R/config/.hosts" \
           "$R/tools/gum/$PLAT" "$R/bin/$CORE_PLAT" "$R/bin/$PLAT" "$R/logs"
  cp "$FAUX/security" "$FAUX/curl" "$FAUX/sleep" "$T/bin/"
  cp "${2:-$DEPOT/Claude.command}" "$R/Claude.command"; chmod +x "$R/Claude.command"
  recle "${MONDE_LIB:-$DEPOT/lib/common.sh}" "$R/lib/common.sh"; recle "${MONDE_UN:-$DEPOT/uninstall.sh}" "$R/uninstall.sh"
  printf 'baluchon-install 1\n' > "$R/.baluchon-install"
  cp "$FAUX/gum" "$R/tools/gum/$PLAT/gum"; cp "$FAUX/noyau" "$R/bin/$CORE_PLAT/baluchon-core"
  cp "$FAUX/claude" "$R/bin/$PLAT/$BINNAME"; printf '9.9.9\n' > "$R/VERSION"
  notes_de_confiance
  printf '{"jeton":"faux"}\n' > "$R/config/perso/.credentials.json"; printf '{"jeton":"faux"}\n' > "$R/config/pro/.credentials.json"
  printf 'host = mac.example.test\nuser = sam\n' > "$R/config/remote.conf"
  printf 'perso\n' > "$R/ACTIVE"
  : > "$CTL/choix"; : > "$CTL/confirm-rc"; : > "$CTL/menus"
  confiance trusted
  commandes_ici
  if [ "$TROUSSEAU" = 1 ]; then
    { echo "Claude Code-credentials"   # la session du Claude Code NORMAL de la machine : intouchable
      service_de "$R/config/perso"; service_de "$R/config/pro"; } > "$CTL/trousseau"
  fi
  jetons mac.example.test
}
# Ce que l'installeur note après avoir tout vérifié : références de Claude et de gum (cc_ref_set, les VRAIES fonctions),
# puis le manifeste signé (sommes de ce qui est posé, signées par la clé d'essai) conservé dans l'installation.
notes_de_confiance() {
  bash -c 'ROOT="$1"; . "$ROOT/lib/common.sh"; cc_detect_platform
           cc_ref_set "bin/$PLAT/$BINNAME" "$(cc_sha256 "$ROOT/bin/$PLAT/$BINNAME")"
           cc_ref_set "tools/gum/$PLAT/gum$EXE" "$(cc_sha256 "$ROOT/tools/gum/$PLAT/gum$EXE")"' _ "$R" 2>/dev/null
  resigne
}
resigne() { # resigne : le manifeste signé reflète EXACTEMENT les fichiers posés maintenant (désinstalleur compris)
  { printf '%s  Claude.command\n' "$(sha "$R/Claude.command")"
    printf '%s  common.sh\n' "$(sha "$R/lib/common.sh")"
    [ ! -f "$R/uninstall.sh" ] || printf '%s  uninstall.sh\n' "$(sha "$R/uninstall.sh")"
    printf '%s  baluchon-core-%s\n' "$(sha "$R/bin/$CORE_PLAT/baluchon-core")" "$CORE_PLAT"; } > "$R/.baluchon-sums"
  rm -f "$R/.baluchon-sums.sig"
  ssh-keygen -q -Y sign -f "$CLE" -n file "$R/.baluchon-sums" >/dev/null 2>&1
}
confiance() { local k; k="$(hostname 2>/dev/null | tr -c 'a-zA-Z0-9_.-' '_')"; printf '%s\n' "$1" > "$R/config/.hosts/$k"; }
service_de() { printf 'Claude Code-credentials-%s\n' "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"; }
commandes_ici() { # les quatre commandes pointent sur CETTE installation
  local n
  for n in baluchon ccp; do printf '#!/usr/bin/env bash\nexec "%s/Claude.command" "$@"\n' "$R" > "$H/.local/bin/$n"; done
  for n in baluchon1 ccp1; do printf '#!/usr/bin/env bash\nexec env CC_PROFILE=2 "%s/Claude.command" "$@"\n' "$R" > "$H/.local/bin/$n"; done
  chmod +x "$H/.local/bin"/*
}
jetons() { # jetons <hôte> : un jeton d'application, son .lock, et celui de l'équipe
  local aud=00d26537aaaaaaaaaaaaaaaaaaaaaaaaaaaa1234
  : > "$H/.cloudflared/$1-$aud-token"; : > "$H/.cloudflared/$1-$aud-token.lock"
  : > "$H/.cloudflared/equipe.cloudflareaccess.com-org-token"
}
# Joue le menu (le VRAI Claude.command), avec le script de réponses déjà écrit dans CTL. Code dans $RC, sortie dans $T/out.
joue() { # joue [chemin de Claude.command]
  RC=0; mkdir -p "$T/tmp"
  ( cd "$H" && ${TIMEOUT:+"$TIMEOUT" 120} env -i HOME="$H" PATH="$T/bin:/usr/bin:/bin" TERM=dumb BALUCHON_DEPUIS_LIEN=1 GUM_CTL="$CTL" TMPDIR="$T/tmp" \
      bash "${1:-$R/Claude.command}" < /dev/null > "$T/out" 2>&1 ) || RC=$?
}
choix() { printf '%s\n' "$@" > "$CTL/choix"; }
premier_menu() { awk '/^---$/{n++; next} n==1' "$CTL/menus"; }
presente() { grep -qF -- "$1" "$CTL/menus"; }

# ── 1. Tout réussit ─────────────────────────────────────────────────────────────────────────
monde succes
printf '#!/usr/bin/env bash\necho programme etranger\n' > "$H/.local/bin/ccp"; chmod +x "$H/.local/bin/ccp"   # un « ccp » qui n'est pas le nôtre
choix Partir; printf '0\n' > "$CTL/confirm-rc"
joue
egal "1. tout réussit : code 0" 0 "$RC"
dit "1. …et le dit" "Rien ne reste sur cet ordinateur"
vrai_si "1. le dossier d'installation a disparu (relu sur le disque)" test ! -e "$R" -a ! -L "$R"
vrai_si "1. les commandes baluchon, baluchon1 et ccp1 ont disparu" test ! -e "$H/.local/bin/baluchon" -a ! -e "$H/.local/bin/baluchon1" -a ! -e "$H/.local/bin/ccp1"
vrai_si "1. un « ccp » qui n'est pas le nôtre est INTACT" grep -q 'programme etranger' "$H/.local/bin/ccp"
vrai_si "1. plus aucun jeton Cloudflare Access (application, .lock, équipe)" test -z "$(ls -A "$H/.cloudflared")"
if [ "$TROUSSEAU" = 1 ]; then
  egal "1. Trousseau : il ne reste que la session du Claude Code NORMAL" "Claude Code-credentials" "$(cat "$CTL/trousseau")"
fi
vrai_si "1. aucun journal recréé dans l'ancien dossier (logs/)" test ! -e "$R/logs"
vrai_si "1. la question a été posée avec « Non » par défaut" grep -q -- '--default=false' "$CTL/confirms"
vrai_si "1. …et nomme l'action (« Oui, tout effacer »)" grep -q 'Oui, tout effacer' "$CTL/confirms"
vrai_si "1. aucune copie temporaire du désinstalleur ne traîne" test -z "$(ls -A "$T/tmp")"

# ── 2. Jeton Access non effaçable : il reste, c'est dit, jamais « Rien ne reste » ─────────────
monde jeton-reste
echo mac.example.test > "$CTL/forget-echec"
choix Partir; printf '0\n' > "$CTL/confirm-rc"
joue
egal "2. jeton Access non effaçable : code 10" 10 "$RC"
dit "2. …le jeton est NOMMÉ" "Jeton Cloudflare Access"
ne_dit_pas "2. …jamais « Rien ne reste »" "Rien ne reste"
vrai_si "2. …le dossier a bien été effacé malgré tout" test ! -e "$R"

# ── 3. Trousseau : l'item refuse de partir ──────────────────────────────────────────────────
if [ "$TROUSSEAU" = 1 ]; then
  monde trousseau-refuse
  : > "$CTL/trousseau-refus"
  choix Partir; printf '0\n' > "$CTL/confirm-rc"
  joue
  # Le noyau dit 1, puis le repli bash de cc_purge_sessions voit lui-même le refus de `security` (code 1, ni 0
  # ni 44) : avant, ce refus était avalé (code 13 par la seule relecture) ; maintenant l'effacement des sessions
  # est dit mal fait (code 1). Le Trousseau relu à la fin nomme l'item.
  egal "3. item du Trousseau refusé (le noyau dit 1, security refuse) : code 1, relevé sur le Trousseau" 1 "$RC"
  dit "3. …l'item est NOMMÉ" "Trousseau : l'item « Claude Code-credentials-"
  ne_dit_pas "3. …jamais « Rien ne reste »" "Rien ne reste"
  # Un noyau qui répond 0 sans avoir rien effacé : personne ne le signale, seul le disque relu le dit (13).
  monde noyau-menteur
  : > "$CTL/purge-ment"; : > "$CTL/trousseau-refus"
  choix Partir; printf '0\n' > "$CTL/confirm-rc"
  joue
  egal "3. noyau menteur (0 sans rien effacer) : code 13, relevé sur le Trousseau" 13 "$RC"
  dit "3. …l'item est NOMMÉ" "Trousseau : l'item « Claude Code-credentials-"
  # Un Trousseau qui MENT (« supprimé » sans rien retirer) : personne ne le signale, seul le disque relu le dit.
  monde trousseau-ment
  : > "$CTL/trousseau-ment"; : > "$CTL/purge-ment"
  choix Partir; printf '0\n' > "$CTL/confirm-rc"
  joue
  egal "3. Trousseau qui ment (0 sans rien retirer) : code 13, relevé sur le Trousseau" 13 "$RC"
  dit "3. …l'item est NOMMÉ" "Trousseau : l'item « Claude Code-credentials-"
  ne_dit_pas "3. …jamais « Rien ne reste »" "Rien ne reste"

  # (revue Codex, 2e passe, MED 7) Trousseau VERROUILLÉ : ni `delete` ni `find` ne répondent « absent » (44),
  # ils répondent une erreur. Avant : l'erreur valait « il n'y est plus » et « Rien ne reste » s'affichait.
  monde trousseau-verrouille
  : > "$CTL/trousseau-verrouille"
  choix Partir; printf '0\n' > "$CTL/confirm-rc"
  joue
  vrai_si "3. Trousseau verrouillé : le code n'est JAMAIS 0" test "$RC" != 0
  ne_dit_pas "3. …jamais « Rien ne reste »" "Rien ne reste"
  dit "3. …les sessions du Trousseau sont dites NON VÉRIFIÉES" "sessions non vérifiées"
  # Le désinstalleur a pu tout effacer, mais la RELECTURE finale est impossible (verrou) : même honnêteté.
  monde trousseau-lecture-verrouillee
  : > "$CTL/trousseau-find-verrouille"
  choix Partir; printf '0\n' > "$CTL/confirm-rc"
  joue
  egal "3. relecture du Trousseau impossible (verrou) : code 13 (jamais 0)" 13 "$RC"
  dit "3. …dit « sessions non vérifiées »" "sessions non vérifiées"
  ne_dit_pas "3. …jamais « Rien ne reste »" "Rien ne reste"
  # Contrôle positif : l'ANCIEN code (1238b14) lisait cette même erreur comme « absent » et annonçait « Rien ne reste ».
  ANCIEN_REV=1238b14; AN="$BASE/anciens-fichiers"; mkdir -p "$AN"
  if git -C "$DEPOT" show "$ANCIEN_REV:lib/common.sh" > "$AN/common.sh" 2>/dev/null && git -C "$DEPOT" show "$ANCIEN_REV:uninstall.sh" > "$AN/uninstall.sh" 2>/dev/null \
     && git -C "$DEPOT" show "$ANCIEN_REV:Claude.command" > "$AN/Claude.command" 2>/dev/null && [ -s "$AN/common.sh" ]; then
    MONDE_LIB="$AN/common.sh" MONDE_UN="$AN/uninstall.sh" monde ancien-trousseau "$AN/Claude.command"
    : > "$CTL/trousseau-find-verrouille"
    choix Partir; printf '0\n' > "$CTL/confirm-rc"
    joue
    dit "3. CONTRÔLE POSITIF : l'ancien code annonçait « Rien ne reste » avec un Trousseau illisible" "Rien ne reste"
  else
    echo "(!) historique git absent : le contrôle positif du Trousseau ($ANCIEN_REV) est sauté"
  fi
fi

# ── 4. Une commande ne peut pas être supprimée ──────────────────────────────────────────────
# Un faux `rm` qui refuse tout ce qui est sous ~/.local/bin (vrai quel que soit l'utilisateur qui joue l'essai).
monde commande-reste
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */.local/bin/*) echo "rm: $a: Operation not permitted" >&2; exit 1 ;; esac; done\nexec /bin/rm "$@"\n' > "$T/bin/rm"
chmod +x "$T/bin/rm"
choix Partir; printf '0\n' > "$CTL/confirm-rc"
joue
egal "4. commande non supprimable : code 13" 13 "$RC"
dit "4. …la commande est NOMMÉE" "lance encore Baluchon"
ne_dit_pas "4. …jamais « Rien ne reste »" "Rien ne reste"

# ── 5. Le désinstalleur refuse (ancêtre modifiable par d'autres) : sessions effacées, dossier gardé ─
monde refus-gardes
choix Partir; printf '0\n' > "$CTL/confirm-rc"
chmod 777 "$H"
joue
chmod 755 "$H"
egal "5. désinstalleur refusé par ses gardes : code 2" 2 "$RC"
vrai_si "5. …le dossier est toujours là (rien n'a été supprimé par le désinstalleur)" test -d "$R"
vrai_si "5. …mais les SESSIONS ont été effacées d'abord (config/perso, config/pro)" test ! -e "$R/config/perso" -a ! -e "$R/config/pro"
dit "5. …et le dossier restant est dit" "est encore là"
ne_dit_pas "5. …jamais « Rien ne reste »" "Rien ne reste"

# ── 6. Un désinstalleur qui MENT ne fait jamais dire « Rien ne reste » ─────────────────────────
monde menteur
printf '#!/usr/bin/env bash\necho "✓ Désinstallé. Plus aucune trace de Baluchon sur cette machine."\nexit 0\n' > "$R/uninstall.sh"
resigne   # un désinstalleur menteur MAIS authentique (signé) : seule la relecture du disque peut le démentir
choix Partir; printf '0\n' > "$CTL/confirm-rc"
joue
egal "6. désinstalleur menteur (0 sans rien faire) : code 13" 13 "$RC"
ne_dit_pas "6. …jamais « Rien ne reste »" "Rien ne reste"
dit "6. …ce qui reste est relu sur le disque" "est encore là"

# ── 6b. (revue Codex, 2e passe, HIGH 4) Le désinstalleur est REMPLACÉ pendant que le menu reste ouvert ──
# Un script parfaitement valide, qui laisse un témoin s'il tourne : avant, « Partir » le copiait (cmp + bash -n,
# qui n'établissent que la ressemblance et la syntaxe) puis l'exécutait. Maintenant l'empreinte de la copie
# doit être celle du manifeste signé.
monde remplace-pendant-le-menu
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T/pwned-uninstall" > "$CTL/uninstall-malveillant"
printf '#!/bin/sh\ncp "%s" "%s/uninstall.sh"\n' "$CTL/uninstall-malveillant" "$R" > "$CTL/pendant-confirm"; chmod +x "$CTL/pendant-confirm"
choix Partir Quitter; printf '0\n' > "$CTL/confirm-rc"
joue
vrai_si "6b. désinstalleur remplacé pendant le menu : il n'est JAMAIS exécuté" test ! -e "$T/pwned-uninstall"
vrai_si "6b. …rien n'a été effacé (sessions, dossier)" test -f "$R/config/perso/.credentials.json" -a -f "$R/Claude.command"
dit "6b. …et c'est dit (l'empreinte n'est pas celle que la release signe)" "n'a pas l'empreinte que la release signe"
egal "6b. …le menu revient et se ferme normalement (code 0)" 0 "$RC"
# Contrôle positif : l'ANCIEN « Partir » (1238b14 : cmp + bash -n) exécute ce remplaçant.
if [ -s "${AN:-/inexistant}/common.sh" ]; then
  MONDE_LIB="$AN/common.sh" MONDE_UN="$AN/uninstall.sh" monde remplace-ancien "$AN/Claude.command"
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T/pwned-uninstall" > "$CTL/uninstall-malveillant"
  printf '#!/bin/sh\ncp "%s" "%s/uninstall.sh"\n' "$CTL/uninstall-malveillant" "$R" > "$CTL/pendant-confirm"; chmod +x "$CTL/pendant-confirm"
  choix Partir Quitter; printf '0\n' > "$CTL/confirm-rc"
  joue
  vrai_si "6b. CONTRÔLE POSITIF : l'ancien « Partir » exécute le désinstalleur remplacé" test -e "$T/pwned-uninstall"
fi

# ── 6c. Désinstalleur ET manifeste réécrits par un tiers (la signature ne correspond plus) : refusé ────
monde manifeste-forge
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T/pwned-uninstall" > "$R/uninstall.sh"
{ printf '%s  uninstall.sh\n' "$(sha "$R/uninstall.sh")"; printf '%s  Claude.command\n' "$(sha "$R/Claude.command")"; } > "$R/.baluchon-sums"
choix Partir Quitter; printf '0\n' > "$CTL/confirm-rc"
joue
vrai_si "6c. manifeste réécrit sans signature valide : le désinstalleur n'est JAMAIS exécuté" test ! -e "$T/pwned-uninstall"
dit "6c. …et c'est dit (manifeste signé absent ou invalide)" "manifeste signé de cette installation est absent ou invalide"
vrai_si "6c. …rien n'a été effacé" test -f "$R/config/perso/.credentials.json"

# ── 7. Annulation : rien n'est touché, le menu revient ──────────────────────────────────────
monde annule
choix Partir Quitter; printf '1\n' > "$CTL/confirm-rc"
joue
egal "7. annulation : le menu se ferme normalement ensuite (code 0)" 0 "$RC"
vrai_si "7. …l'installation est intacte" test -f "$R/Claude.command" -a -f "$R/config/perso/.credentials.json"
vrai_si "7. …les commandes et les jetons aussi" test -f "$H/.local/bin/baluchon" -a -f "$H/.cloudflared/equipe.cloudflareaccess.com-org-token"
vrai_si "7. …et le noyau n'a reçu aucun ordre d'effacement" test ! -e "$CTL/core.log" -o -z "$(grep -E 'purge|forget' "$CTL/core.log" 2>/dev/null)"

# ── 8. Le désinstalleur est altéré (ne se lit même plus) : code 14, rien n'est touché, le menu revient ─
monde altere
printf '#!/usr/bin/env bash\nif then fi (((\n' > "$R/uninstall.sh"
choix Partir Quitter; printf '0\n' > "$CTL/confirm-rc"
joue
egal "8. désinstalleur illisible : le menu revient et se ferme (code 0)" 0 "$RC"
vrai_si "8. …rien n'a été effacé (sessions comprises)" test -f "$R/config/perso/.credentials.json" -a -f "$R/Claude.command"
dit "8. …et c'est dit" "rien n'a été effacé"
# Même chose mais SIGNÉ (le manifeste dit que ce fichier-là est le bon) : seule la syntaxe l'arrête encore.
monde altere-signe
printf '#!/usr/bin/env bash\nif then fi (((\n' > "$R/uninstall.sh"; resigne
choix Partir Quitter; printf '0\n' > "$CTL/confirm-rc"
joue
egal "8. désinstalleur illisible mais signé : le menu revient (code 0)" 0 "$RC"
vrai_si "8. …rien n'a été effacé" test -f "$R/config/perso/.credentials.json" -a -f "$R/Claude.command"

# ── 9. « Partir » n'est proposé que sur une installation, et à la bonne place ─────────────────
monde sans-marqueur
rm -f "$R/.baluchon-install"
choix Quitter; joue
vrai_si "9. sans marqueur d'installation : pas de « Partir »" test -n "$(premier_menu)" -a -z "$(premier_menu | grep Partir)"
monde sans-desinstalleur
rm -f "$R/uninstall.sh"
choix Quitter; joue
vrai_si "9. sans désinstalleur : pas de « Partir »" test -n "$(premier_menu)" -a -z "$(premier_menu | grep Partir)"
monde position-proprio
choix Quitter; joue
egal "9. poste à soi : « Partir » juste AVANT « Quitter »" "Partir" "$(premier_menu | tail -n 2 | head -n 1 | sed -E 's/^[^A-Za-z]*(Partir).*/\1/')"
egal "9. …et « Quitter » reste la dernière entrée" "Quitter" "$(premier_menu | tail -n 1 | sed -E 's/^[^A-Za-z]*(Quitter).*/\1/')"
monde position-invite
confiance guest
choix Quitter; joue
egal "9. poste invité : « Partir » est la PREMIÈRE entrée" "Partir" "$(premier_menu | head -n 1 | sed -E 's/^[^A-Za-z]*(Partir).*/\1/')"
vrai_si "9. …et il n'y est pas deux fois" test "$(premier_menu | grep -c Partir)" = 1

# ── 10. Portable vide (aucun compte) : « Partir » y est aussi ──────────────────────────────────
monde vide
rm -rf "$R/config/perso" "$R/config/pro"
choix Quitter; joue
vrai_si "10. aucun compte : « Partir » est proposé quand même" test "$(premier_menu | grep -c Partir)" = 1

# ── 11. Installation derrière un lien symbolique : le lien et sa cible partent ──────────────
monde lien
ln -s "$R" "$H/lien-vers-baluchon"
# Claude suffixe le service du Trousseau d'après le chemin qu'on lui donne : lancé par le lien, c'est celui du lien.
[ "$TROUSSEAU" != 1 ] || { echo "Claude Code-credentials"; service_de "$H/lien-vers-baluchon/config/perso"; service_de "$H/lien-vers-baluchon/config/pro"; } > "$CTL/trousseau"
choix Partir; printf '0\n' > "$CTL/confirm-rc"
joue "$H/lien-vers-baluchon/Claude.command"
egal "11. lancé par un lien symbolique : code 0" 0 "$RC"
vrai_si "11. …la cible ET le lien ont disparu" test ! -e "$R" -a ! -L "$H/lien-vers-baluchon" -a ! -e "$H/lien-vers-baluchon"
if [ "$TROUSSEAU" = 1 ]; then
  # Même installation, mais ses items portent le nom du chemin CANONIQUE (lancée un jour sans le lien) et le
  # noyau (qui efface par le chemin donné) ne les voit pas : le relevé les cherche sous les DEUX noms.
  monde lien-canonique
  ln -s "$R" "$H/lien-vers-baluchon"
  choix Partir; printf '0\n' > "$CTL/confirm-rc"
  joue "$H/lien-vers-baluchon/Claude.command"
  egal "11. items sous le nom du chemin canonique, noyau qui ne les voit pas : code 13" 13 "$RC"
  dit "11. …ils sont NOMMÉS" "Trousseau : l'item « Claude Code-credentials-"
fi

# ── 12. Hôte d'accès noté par l'amorce (.baluchon-acces) : ses jetons sont oubliés aussi ───────
monde hote-note
rm -f "$R/config/remote.conf"                       # aucun Mac configuré : seul le fichier de l'amorce le sait
find "$H/.cloudflared" -name 'mac.example.test-*' -delete
jetons acces.example.test
printf 'acces.example.test\n' > "$R/.baluchon-acces"
choix Partir; printf '0\n' > "$CTL/confirm-rc"
joue
egal "12. hôte noté par l'amorce : code 0" 0 "$RC"
vrai_si "12. …le noyau a reçu --host pour cet hôte" grep -q 'forget-access host=acces.example.test' "$CTL/core.log"
vrai_si "12. …ses jetons ont disparu" test -z "$(ls -A "$H/.cloudflared")"
monde hote-note-echec
rm -f "$R/config/remote.conf"
find "$H/.cloudflared" -name 'mac.example.test-*' -delete
jetons acces.example.test
printf 'acces.example.test\n' > "$R/.baluchon-acces"; echo acces.example.test > "$CTL/forget-echec"
choix Partir; printf '0\n' > "$CTL/confirm-rc"
joue
egal "12. hôte noté dont les jetons ne partent pas : code 10" 10 "$RC"
dit "12. …le jeton est NOMMÉ" "acces.example.test-"

# ── 14. (revue Codex, 2e passe, HIGH 5) `config` est un LIEN : « Partir » ne le suit JAMAIS ────────
# Avant : cc_wipe supprimait ce que `"$ROOT"/config/*` désignait, donc les documents vers lesquels le lien menait,
# avant même que les gardes de uninstall.sh ne soient consultées.
monde config-lien
mkdir -p "$T/temoin-config/Documents"; printf 'precieux\n' > "$T/temoin-config/Documents/these.txt"; printf 'precieux\n' > "$T/temoin-config/notes.txt"
mv "$R/config/.hosts" "$T/temoin-config/.hosts"; rm -rf "$R/config/perso" "$R/config/pro" "$R/config/remote.conf"
rmdir "$R/config"; ln -s "$T/temoin-config" "$R/config"
choix Partir; printf '0\n' > "$CTL/confirm-rc"
joue
vrai_si "14. config lien : le dossier témoin est INTACT (fichiers et sous-dossiers)" test "$(cat "$T/temoin-config/Documents/these.txt" 2>/dev/null)" = precieux -a "$(cat "$T/temoin-config/notes.txt" 2>/dev/null)" = precieux
vrai_si "14. …le code n'est JAMAIS 0" test "$RC" != 0
dit "14. …le lien est SIGNALÉ" "lien symbolique"
ne_dit_pas "14. …jamais « Rien ne reste »" "Rien ne reste"
# Même scénario joué contre l'ANCIEN code (1238b14) : le contrôle positif — le témoin est supprimé.
if [ -s "${AN:-/inexistant}/common.sh" ]; then
  MONDE_LIB="$AN/common.sh" MONDE_UN="$AN/uninstall.sh" monde config-lien-ancien "$AN/Claude.command"
  mkdir -p "$T/temoin-config/Documents"; printf 'precieux\n' > "$T/temoin-config/Documents/these.txt"; printf 'precieux\n' > "$T/temoin-config/notes.txt"
  mv "$R/config/.hosts" "$T/temoin-config/.hosts"; rm -rf "$R/config/perso" "$R/config/pro" "$R/config/remote.conf"
  rmdir "$R/config"; ln -s "$T/temoin-config" "$R/config"
  choix Partir; printf '0\n' > "$CTL/confirm-rc"
  joue
  vrai_si "14. CONTRÔLE POSITIF : l'ancien « Partir » suivait le lien et supprimait le témoin" test ! -e "$T/temoin-config/notes.txt"
fi

# ── 15. (LOW 8) Le cache d'exécution : retiré, borné, et jamais « Rien ne reste » s'il en reste ─────
# Sur une clé montée sans exécution, les binaires sont copiés sous ~/.cache/baluchon ; .baluchon-cache en note les
# dossiers. « Partir » les retire (jamais au-delà de la base, jamais à travers un lien) et relit le disque.
monde cache
mkdir -p "$H/.cache/baluchon/9.9.9/$PLAT" "$H/.cache/baluchon/overlay-core/$CORE_PLAT" "$H/.cache/autre-programme"
printf 'copie\n' > "$H/.cache/baluchon/9.9.9/$PLAT/claude"; printf 'copie\n' > "$H/.cache/baluchon/overlay-core/$CORE_PLAT/baluchon-core"
printf 'a-moi-pas\n' > "$H/.cache/autre-programme/fichier"
mkdir -p "$H/Documents"; printf 'precieux\n' > "$H/Documents/these.txt"
# Le fichier est écrit avec les droits de l'utilisateur : des lignes hostiles y sont ignorées, jamais suivies.
{ printf '%s\n' "$H/.cache/baluchon/9.9.9/$PLAT" "$H/.cache/baluchon/overlay-core/$CORE_PLAT" \
    "$H/Documents" "$H/.cache/autre-programme" "$H/.cache/baluchon/../../Documents" "relatif/chemin" "$H/.cache/baluchon"; } > "$R/.baluchon-cache"
choix Partir; printf '0\n' > "$CTL/confirm-rc"
joue
egal "15. cache d'exécution : code 0" 0 "$RC"
vrai_si "15. …les copies notées ont disparu (et leurs parents devenus vides, base comprise)" test ! -e "$H/.cache/baluchon"
vrai_si "15. …un dossier d'un AUTRE programme dans ~/.cache est intact" test "$(cat "$H/.cache/autre-programme/fichier" 2>/dev/null)" = a-moi-pas
vrai_si "15. …les lignes hostiles (Documents, ..) n'ont rien supprimé" test "$(cat "$H/Documents/these.txt" 2>/dev/null)" = precieux
dit "15. …et le bilan dit « Rien ne reste »" "Rien ne reste"
# Un dossier de cache qui est un LIEN vers des documents : jamais suivi, dit, code non nul.
monde cache-lien
mkdir -p "$H/Documents" "$H/.cache/baluchon/9.9.9"; printf 'precieux\n' > "$H/Documents/these.txt"
ln -s "$H/Documents" "$H/.cache/baluchon/9.9.9/$PLAT"
printf '%s\n' "$H/.cache/baluchon/9.9.9/$PLAT" > "$R/.baluchon-cache"
choix Partir; printf '0\n' > "$CTL/confirm-rc"
joue
vrai_si "15. cache = lien vers Documents : le témoin est INTACT" test "$(cat "$H/Documents/these.txt" 2>/dev/null)" = precieux
vrai_si "15. …le code n'est JAMAIS 0" test "$RC" != 0
dit "15. …le cache restant est NOMMÉ" "Cache d'exécution"
ne_dit_pas "15. …jamais « Rien ne reste »" "Rien ne reste"
# Contrôle positif : l'ANCIEN « Partir » laissait le cache en place ET annonçait « Rien ne reste ».
if [ -s "${AN:-/inexistant}/common.sh" ]; then
  MONDE_LIB="$AN/common.sh" MONDE_UN="$AN/uninstall.sh" monde cache-ancien "$AN/Claude.command"
  mkdir -p "$H/.cache/baluchon/9.9.9/$PLAT"; printf 'copie\n' > "$H/.cache/baluchon/9.9.9/$PLAT/claude"
  printf '%s\n' "$H/.cache/baluchon/9.9.9/$PLAT" > "$R/.baluchon-cache"
  choix Partir; printf '0\n' > "$CTL/confirm-rc"
  joue
  vrai_si "15. CONTRÔLE POSITIF : l'ancien « Partir » laissait le cache en place…" test -e "$H/.cache/baluchon/9.9.9/$PLAT/claude"
  dit "15. …ET disait « Rien ne reste »" "Rien ne reste"
fi

# ── 13. Contrôle positif : l'ANCIEN menu ne propose pas « Partir » (l'épreuve 1 y échouerait) ──
ANCIEN="$BASE/Claude.command.ancien"
if git -C "$DEPOT" show c0172f7:Claude.command > "$ANCIEN" 2>/dev/null && [ -s "$ANCIEN" ]; then
  monde ancien-menu "$ANCIEN"
  choix Partir Quitter; printf '0\n' > "$CTL/confirm-rc"
  joue
  vrai_si "13. CONTRÔLE POSITIF : l'ancien menu n'a pas d'entrée « Partir »" test -z "$(premier_menu | grep Partir)"
  vrai_si "13. …et le dossier est donc toujours là (l'épreuve 1 aurait échoué)" test -d "$R"
else
  echo "(!) historique git absent : le contrôle positif sur l'ancien menu (c0172f7) est sauté"
fi

printf '%s ok, %s ko\n' "$OK" "$KO"
[ "$KO" = 0 ]
