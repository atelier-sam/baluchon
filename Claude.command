#!/usr/bin/env bash
# ============================================================
#  BALUCHON — lanceur portable pour Claude Code : wizard (macOS / Linux / Windows via Git-bash)
#  Couleur d'accent : orange (#D84D2B).
#
#  Ce fichier n'est QUE l'interface (gum). Les comptes (statut réel, forfait,
#  quota, renouvellement, Trousseau macOS, lancement verrouillé) sont tenus par
#  le noyau Rust baluchon-core. Sans noyau, le wizard reste utilisable en mode
#  dégradé : liste des comptes + lancement direct.
# ============================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
cc_detect_platform
# Le wizard ne doit pas mourir quand on fait Ctrl+C dans Claude (le signal va à
# tout le groupe de processus). On l'ignore ici ; chaque enfant (baluchon-core, ssh,
# winget…) est lancé avec Ctrl+C rétabli (ccp_core / sub()).
trap '' INT
sub() { ( trap - INT; "$@" ); }

cc_ensure_gum >/dev/null 2>&1 || true
GUMBIN="${CC_GUM:-$ROOT/tools/gum/$PLAT/gum$EXE}"
gum() { "$GUMBIN" "$@"; }

ORANGE="#D84D2B"; DG="244"; OK="42"; ERRC="203"; WARNC="214"
aD=$'\033[2m'; aR=$'\033[0m'; aO=$'\033[38;2;216;77;43m'; aB=$'\033[1m'

cols()        { local c; c=$(tput cols 2>/dev/null || echo "${COLUMNS:-80}"); case "$c" in ''|*[!0-9]*) c=80;; esac; echo "$c"; }
free_space()  { df -h "$ROOT" 2>/dev/null | awk 'NR==2{print $4}'; }
os_label()    { case "$CC_OS" in darwin) echo macOS;; linux) echo Linux;; win32) echo Windows;; *) echo "$CC_OS";; esac; }
ver_str()     { tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null || echo '?'; }
accounts()    { local d n; for d in "$ROOT"/config/*/; do [ -d "$d" ] || continue; n="$(basename "$d")"; case "$n" in ._*|.*) continue;; esac; echo "$n"; done; }
pause_key()   { printf '\n'; gum input --placeholder "Entrée pour revenir" >/dev/null 2>&1 || true; }
title()       { clear 2>/dev/null || true; gum style --border rounded --border-foreground "$ORANGE" --padding "0 2" --margin "1 0 1 2" --foreground "$ORANGE" --bold "$1"; }
note()        { gum style --foreground "$DG" --margin "0 0 0 2" "$@"; }
good()        { gum style --foreground "$OK" --margin "0 0 0 2" "$@"; }
bad()         { gum style --foreground "$ERRC" --margin "0 0 0 2" "$@"; }
valid_name()  { case "$1" in ''|*[!a-zA-Z0-9_-]*) return 1;; *) return 0;; esac; }

# ---------- statut des comptes ----------
# Sonde complète, bornée par le noyau (≈ 5 s), sous un spinner.
probe_all() {
  [ -n "${CORE:-}" ] || return 0
  gum spin --spinner dot --spinner.foreground "$ORANGE" --title "Vérification des comptes (statut, forfait, quota)…" -- \
    "$CORE" --root "$ROOT" accounts status --refresh --format json >/dev/null 2>&1 || true
}
# Sonde en arrière-plan des seuls comptes périmés : le prochain affichage sera à jour.
probe_background() {
  [ -n "${CORE:-}" ] || return 0
  ( trap - INT; "$CORE" --root "$ROOT" accounts status --format json >/dev/null 2>&1 & ) 2>/dev/null
}

render_accounts_fallback() {
  local n active any=0
  active="$(cc_active_profile)"
  printf '   %s%sCOMPTES%s  %s(noyau baluchon-core indisponible : statuts et quotas non affichés)%s\n' "$aB" "$aO" "$aR" "$aD" "$aR"
  while read -r n; do
    [ -n "$n" ] || continue; any=1
    if [ "$n" = "$active" ]; then printf '   %s★%s %s\n' "$aO" "$aR" "$n"; else printf '     %s\n' "$n"; fi
  done <<< "$(accounts)"
  [ "$any" = 1 ] || printf '     %s(aucun compte — Comptes › Ajouter)%s\n' "$aD" "$aR"
}

render() {
  clear 2>/dev/null || true
  local c pw status stable banner=""
  c="$(cols)"; pw=$((c-6)); [ "$pw" -gt 76 ] && pw=76; [ "$pw" -lt 24 ] && pw=24
  if [ "$c" -ge 54 ]; then status="Claude v$(ver_str) · $(os_label) · $(free_space) libres · bypass ON"
  else status="v$(ver_str) · bypass ON"; fi
  stable="$(cc_claude_stable_cached 2>/dev/null)"
  if [ -n "$stable" ] && [ "$stable" != "$(ver_str)" ]; then banner="⬆ Claude $stable disponible — menu « Mettre à jour »"; fi
  # Une couche posée mais inutilisable est dite à chaque écran, jamais seulement dans le journal.
  if [ -n "${CC_LAYER_NOTE:-}" ]; then banner="${CC_LAYER_NOTE}${banner:+$'\n'$banner}"; fi
  gum style --width "$pw" --border rounded --border-foreground "$ORANGE" --padding "0 2" --margin "1 0 1 2" --align center --foreground "$ORANGE" --bold \
    "BALUCHON" "$(gum style --foreground "$DG" --faint "$status")" ${banner:+"$(gum style --foreground "$WARNC" "$banner")"}
  if [ -n "${CORE:-}" ] && [ -n "$(accounts)" ]; then
    "$CORE" --root "$ROOT" accounts status --offline --format table --width "$c" 2>/dev/null | sed 's/^/ /' || render_accounts_fallback
  elif [ -n "${CORE:-}" ]; then
    render_empty
  else
    render_accounts_fallback
  fi
  echo
}

# Portable vide (1re ouverture, ou après « Tout déconnecter ») : au lieu d'une
# liste vide, on montre ce que la machine connaît déjà et l'action à faire.
# MACHINE_MISSING est mis à jour ici et lu par le menu principal.
MACHINE_MISSING=0
render_empty() {
  local miss
  miss="$("$CORE" --root "$ROOT" accounts discover --missing 2>/dev/null)"
  MACHINE_MISSING="$(printf '%s\n' "$miss" | grep -c '@' || true)"
  printf '   %s%sCOMPTES%s\n' "$aB" "$aO" "$aR"
  printf '     Aucun compte dans ce portable pour l'"'"'instant.\n'
  if [ "$MACHINE_MISSING" -gt 0 ]; then
    printf '     %s%s compte(s) Claude trouvé(s) sur cet ordinateur :%s\n' "$aD" "$MACHINE_MISSING" "$aR"
    printf '%s\n' "$miss" | grep '@' | sed "s/^/       • /"
    printf '     %s→ « Réindexer mes comptes » : une connexion navigateur par compte, puis statut et quota ici.%s\n' "$aD" "$aR"
  else
    printf '     %s→ « Ajouter un compte » : connexion navigateur, puis statut et quota ici.%s\n' "$aD" "$aR"
  fi
}

# ---------- lancement ----------
launch() {
  local p="$1" cfg rc
  [ -n "$p" ] || p="$(cc_active_profile)"
  clear 2>/dev/null || true
  cfg="$ROOT/config/$p"; cc_write_settings "$cfg"
  cc_log "=== lancement profil=$p ==="
  # Le menu reste ouvert longtemps : l'empreinte du binaire est relue JUSTE avant de le lancer.
  cc_bin_verifie || { bad "Le binaire Claude ne correspond plus à ce qui a été vérifié : rien n'est lancé."; sleep 3; return 1; }
  gum style --foreground "$ORANGE" --bold --margin "1 0 1 3" "▶  Compte « $p » — bypass ON — démarrage…   (/status dans Claude = vue native)"
  if [ -n "${CORE:-}" ]; then
    ccp_core run "$p" --claude "$BIN" -- --dangerously-skip-permissions; rc=$?
    if [ "$rc" -eq 5 ]; then bad "Ce compte est déjà ouvert dans une autre fenêtre."; sleep 2; fi
  else
    # Repli sans noyau : lancement direct (le statut ne sera pas lu).
    export CLAUDE_CONFIG_DIR; CLAUDE_CONFIG_DIR="$(cc_winpath "$cfg")"
    unset CLAUDE_CODE_OAUTH_TOKEN
    if [ ! -f "$cfg/.credentials.json" ] && [ -f "$cfg/oauth.token" ]; then
      CLAUDE_CODE_OAUTH_TOKEN="$(tr -d ' \r\n' < "$cfg/oauth.token")"; export CLAUDE_CODE_OAUTH_TOKEN
    fi
    sub "$BIN" --dangerously-skip-permissions; rc=$?
    unset CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN
  fi
  cc_log "claude terminé (code $rc)"
}

choose_account() {
  local list; list="$(accounts)"
  [ -n "$list" ] || { bad "Aucun compte. Ajoute-en un d'abord (Comptes › Ajouter)."; sleep 2; return 1; }
  printf '%s\n' "$list" | gum choose --header "${1:-Quel compte ?}" --cursor "❯ " --cursor.foreground "$ORANGE"
}

# ---------- comptes ----------
# Connexion fraîche d'un profil (nouvelle lignée OAuth : jamais de copie
# d'identifiants entre magasins, c'est ce qui provoquait les révocations).
# $1 = profil, $2 = email attendu (facultatif). Rend 0 si un login existe à la
# fin ; LOGIN_EMAIL = email réellement connecté (lu par le noyau, qui connaît le
# nom exact de l'item du Trousseau — ne jamais recalculer ce hash en bash).
# Le wizard n'écrit, ne déplace ni ne sauvegarde AUCUN jeton : la connexion est faite par
# `claude` lui-même, qui range sa session où il l'entend. Un fichier `oauth.token` que
# l'utilisateur aurait déposé lui-même reste lu au lancement (repli sans noyau), jamais touché.
LOGIN_EMAIL=""
login_profile() {
  local name="$1" want="${2:-}" cfg="$ROOT/config/$1"
  LOGIN_EMAIL=""
  mkdir -p "$cfg"; cc_write_settings "$cfg"
  note "Une page de connexion va s'ouvrir dans le navigateur.${want:+ Connecte-toi avec : $want}"
  cc_bin_verifie || { bad "Le binaire Claude ne correspond plus à ce qui a été vérifié : connexion non lancée."; return 1; }
  if [ -n "${CORE:-}" ]; then ccp_core run "$name" --claude "$BIN" -- auth login
  else CLAUDE_CONFIG_DIR="$(cc_winpath "$cfg")" sub "$BIN" auth login; fi
  [ -n "${CORE:-}" ] && LOGIN_EMAIL="$(ccp_core accounts email "$name" 2>/dev/null | tr -d '\r\n')"
  if [ -z "$LOGIN_EMAIL" ] && [ ! -f "$cfg/.credentials.json" ]; then
    return 1
  fi
  if [ -n "$want" ] && [ -n "$LOGIN_EMAIL" ] && [ "$LOGIN_EMAIL" != "$want" ]; then
    bad "Attention : connecté avec $LOGIN_EMAIL, et non $want (mauvais compte choisi dans le navigateur ?)."
    return 2
  fi
  return 0
}

add_account() {
  title "AJOUTER / RECONNECTER UN COMPTE"
  local name
  name="$(gum input --header "Nom du compte (ex : 1, 2, perso, travail)" --placeholder "1" --cursor.foreground "$ORANGE")" || return
  valid_name "$name" || { bad "Nom invalide (lettres, chiffres, - et _ seulement)."; sleep 2; return; }
  # Une seule route : la connexion navigateur de `claude`. Le wizard ne demande, ne reçoit ni
  # ne range jamais un jeton collé par l'utilisateur (un jeton se copie, se perd et se révoque).
  if ! login_profile "$name"; then
    [ -n "$LOGIN_EMAIL" ] || { bad "Connexion non aboutie : profil « $name » retiré."; rm -rf "${ROOT:?}/config/$name"; sleep 2; return; }
  fi
  printf '%s' "$name" | cc_ecrire "$ROOT/ACTIVE" || true   # cc_ecrire : jamais d'écriture à travers un lien
  probe_all
  render; good "Compte « $name » enregistré et défini par défaut."; sleep 2
}

# Réindexation : inventaire (lecture seule) des logins Claude de cet ordinateur,
# puis reconnexion fraîche dans le portable de ceux qui manquent.
reindex() {
  title "RÉINDEXER LES COMPTES DE CET ORDINATEUR"
  [ -n "${CORE:-}" ] || { bad "Nécessite le noyau baluchon-core."; pause_key; return; }
  ccp_core accounts discover --format table --width "$(cols)" | sed 's/^/ /'
  echo
  local missing sel email name i lrc
  missing="$(ccp_core accounts discover --missing 2>/dev/null)"
  if [ -z "$missing" ]; then good "Tous les comptes trouvés sont déjà dans le portable."; probe_all; pause_key; return; fi
  note "Ces comptes existent sur la machine mais pas dans le portable. On ne copie jamais leurs" \
       "identifiants (une copie se fait révoquer dès que l'original se renouvelle) : on se reconnecte proprement."
  sel="$(printf '%s\n' "$missing" | gum choose --no-limit --header "Lesquels ajouter ? (espace pour cocher, Entrée pour valider)" --cursor.foreground "$ORANGE")" || return
  [ -n "$sel" ] || return
  # Boucle sur un tableau, pas sur un here-string : claude auth login et gum
  # liraient sinon le reste de la liste sur leur stdin.
  local emails=() l
  while IFS= read -r l; do [ -n "$l" ] && emails+=("$l"); done <<< "$sel"
  for email in "${emails[@]}"; do
    name="$(printf '%s' "${email%%@*}" | tr -c 'a-zA-Z0-9_-' '-' | sed 's/-*$//' | cut -c1-24)"; [ -n "$name" ] || name=compte
    i=2; while [ -d "$ROOT/config/$name" ]; do name="${name%-[0-9]*}-$i"; i=$((i+1)); done
    title "CONNEXION DE $email"
    note "Profil « $name »."
    login_profile "$name" "$email"; lrc=$?
    case "$lrc" in
      0) good "✓ $email connecté (profil « $name »)." ;;
      2) if gum confirm "Garder quand même ce compte ($LOGIN_EMAIL) ?" --affirmative "Garder" --negative "Retirer" --selected.background "$ORANGE"; then :
         else ccp_core accounts purge "$name" >/dev/null 2>&1; rm -rf "${ROOT:?}/config/$name"; note "Profil retiré."; fi ;;
      *) bad "Connexion de $email non aboutie : profil « $name » retiré."; rm -rf "${ROOT:?}/config/$name" ;;
    esac
    [ -f "$ROOT/ACTIVE" ] || { [ "$lrc" = 0 ] && { printf '%s' "$name" | cc_ecrire "$ROOT/ACTIVE" || true; }; }
    sleep 1
  done
  probe_all
  render; pause_key
}

set_default() {
  clear 2>/dev/null || true
  local sel; sel="$(choose_account "Compte par défaut ?")" || return
  [ -n "$sel" ] && { printf '%s' "$sel" | cc_ecrire "$ROOT/ACTIVE" || true; good "✓ Défaut : « $sel »"; sleep 1; }
}

remove_account() {
  clear 2>/dev/null || true
  local sel; sel="$(choose_account "Supprimer quel compte du portable ?")" || return
  [ -n "$sel" ] || return
  gum confirm "Supprimer « $sel » (session, historique de ce compte sur le portable) ?" --selected.background "$ORANGE" || return
  [ -n "${CORE:-}" ] && ccp_core accounts purge "$sel" >/dev/null 2>&1
  rm -rf "${ROOT:?}/config/$sel"
  [ "$(cc_active_profile)" = "$sel" ] && rm -f "$ROOT/ACTIVE"
  good "✓ « $sel » supprimé."; sleep 1
}

doctor() {
  title "DIAGNOSTIC DES COMPTES"
  # shellcheck disable=SC2012  # simple liste affichée dans un message, noms maîtrisés (bin/<plat>/)
  if [ -n "${CORE:-}" ]; then ccp_core doctor --claude "$BIN" 2>&1 | sed 's/^/  /'
  else bad "Noyau baluchon-core indisponible : $(ls "$ROOT/bin/$CORE_PLAT/" 2>/dev/null | tr '\n' ' ')"; fi
  echo; note "Journal : $ROOT/logs/launch.log"
  pause_key
}

menu_accounts() {
  while true; do
    render
    local c; c="$(gum choose --header "Comptes" --cursor "❯ " --cursor.foreground "$ORANGE" \
      "➕  Ajouter / reconnecter un compte" \
      "🔎  Réindexer les comptes de cet ordinateur" \
      "⭐  Changer le compte par défaut" \
      "🩺  Diagnostic" \
      "➖  Supprimer un compte" \
      "←  Retour")" || return
    case "$c" in
      "➕"*) add_account ;; "🔎"*) reindex ;; "⭐"*) set_default ;; "🩺"*) doctor ;; "➖"*) remove_account ;; *) return ;;
    esac
  done
}

# ---------- outils ----------
tool_windows_apps() {
  title "INSTALLER DES LOGICIELS (WINDOWS)"
  local cat sel keys pre
  cat="$(ccp_core win catalog --format lines 2>/dev/null)" || { bad "Catalogue indisponible (noyau baluchon-core)."; pause_key; return; }
  note "Coche avec Espace, valide avec Entrée. Installation silencieuse par winget (sources officielles)."
  # Lignes « clé<TAB>libellé<TAB>coché(0|1) » : on affiche le libellé, on garde la clé.
  # gum --selected sépare par des virgules : le noyau garantit des libellés sans virgule.
  pre="$(printf '%s\n' "$cat" | awk -F'\t' '$3=="1"{printf "%s%s", (n++ ? "," : ""), $2}')"
  sel="$(printf '%s\n' "$cat" | cut -f2 | gum choose --no-limit --height 20 ${pre:+--selected "$pre"} --header "Logiciels à installer" --cursor.foreground "$ORANGE")" || return
  [ -n "$sel" ] || return
  keys="$(printf '%s\n' "$cat" | awk -F'\t' 'NR==FNR{want[$0]=1; next} ($2 in want){print $1}' <(printf '%s\n' "$sel") -)"
  # shellcheck disable=SC2086
  ccp_core win install $keys
  pause_key
}

tool_office() {
  title "INSTALLER MICROSOFT OFFICE (WINDOWS)"
  local eds ed apps
  eds="$(ccp_core win office --list 2>/dev/null)" || { bad "Noyau baluchon-core indisponible."; pause_key; return; }
  note "Installation officielle Microsoft (Office Deployment Tool), en français, sans clé :" \
       "Office s'installe « non activé » ; tu mettras la licence plus tard."
  ed="$(printf '%s\n' "$eds" | cut -f2 | gum choose --header "Quelle version ?" --cursor.foreground "$ORANGE")" || return
  ed="$(printf '%s\n' "$eds" | awk -F'\t' -v l="$ed" '$2==l{print $1; exit}')"
  apps="$(printf '%s\n' Word Excel PowerPoint Outlook OneNote Access Publisher Teams OneDrive | \
    gum choose --no-limit --selected "Word,Excel,PowerPoint,Outlook" --header "Applications (Espace pour cocher)" --cursor.foreground "$ORANGE")" || return
  # Le noyau attend des clés en minuscules (word,excel,…) ; les apps non cochées deviennent des ExcludeApp.
  ccp_core win office --edition "$ed" --lang fr-fr --apps "$(printf '%s' "$apps" | tr '[:upper:]' '[:lower:]' | tr '\n' ',' | sed 's/,$//')"
  pause_key
}

tool_remote_connect() {
  title "PARLER À MES AGENTS (MAC)"
  note "Connexion à ton Mac par le tunnel Cloudflare (rien à installer sur ce PC)." \
       "1re fois : code de vérification par e-mail (Cloudflare Access), puis mot de passe du Mac."
  ccp_core remote connect
  pause_key
}

tool_remote_share() {
  title "PARTAGER CE PC AVEC MES AGENTS"
  note "Tes agents du Mac pourront exécuter des commandes sur CE PC tant que cette fenêtre reste ouverte." \
       "Rien n'est installé durablement ; tout est retiré à la fermeture."
  gum confirm "Le client est d'accord et tu restes devant le PC ?" --selected.background "$ORANGE" || return
  ccp_core remote share
  pause_key
}

tool_remote_setup_mac() {
  title "CONFIGURER CE MAC COMME POSTE DISTANT"
  # Sortie du noyau : « ok|ko<TAB>contrôle<TAB>détail » ; rendu ✓ / ✗ lisible.
  ccp_core remote setup-mac | awk -F'\t' -v g=$'\033[32m' -v r=$'\033[31m' -v d=$'\033[2m' -v z=$'\033[0m' '
    $1=="ok" {printf "  %s✓%s %-20s %s%s%s\n", g, z, $2, d, $3, z; next}
    $1=="ko" {printf "  %s✗%s %-20s %s\n", r, z, $2, $3; next}
    {print "  " $0}'
  pause_key
}

menu_tools() {
  while true; do
    render
    local items=()
    if [ "$CC_OS" = win32 ]; then
      items+=("💿  Installer des logiciels (Chrome, Firefox, LibreOffice, WinRAR…)" "📎  Installer Microsoft Office (version au choix)" "🤝  Partager ce PC avec les agents de mon Mac")
    fi
    items+=("💬  Parler à mes agents (Mac)")
    [ "$CC_OS" = darwin ] && items+=("🛠  Configurer ce Mac comme poste distant")
    items+=("←  Retour")
    local c; c="$(gum choose --header "Outils" --cursor "❯ " --cursor.foreground "$ORANGE" "${items[@]}")" || return
    case "$c" in
      "💿"*) tool_windows_apps ;; "📎"*) tool_office ;; "🤝"*) tool_remote_share ;;
      "💬"*) tool_remote_connect ;; "🛠"*) tool_remote_setup_mac ;; *) return ;;
    esac
  done
}

# ---------- mise à jour / effacement / sortie ----------
menu_update() {
  title "MISE À JOUR"
  local c; c="$(gum choose --header "Que mettre à jour ?" --cursor "❯ " --cursor.foreground "$ORANGE" \
    "⬆  Claude Code (version stable)" "⬆  Claude Code (toute dernière version)" \
    "⬆  Le portable lui-même (wizard + noyau)" "↩  Revenir à la version précédente de Claude" "←  Retour")" || return
  case "$c" in
    *stable*)   cc_update stable ;;
    *dernière*) cc_update latest ;;
    *portable*) if cc_update_portable; then good "✓ Portable à jour — redémarrage du wizard…"; sleep 1; exec "$ROOT/Claude.command"; fi ;;
    "↩"*)       cc_rollback ;;
    *) return ;;
  esac
  cc_ensure_binary
  sleep 2
}

do_wipe() {
  clear 2>/dev/null || true
  if gum confirm "Tout déconnecter et effacer les sessions de ce portable ?" --selected.background "$ORANGE"; then
    local wrc=0; cc_wipe || wrc=$?
    case "$wrc" in
      0) good "✓ Effacé (Trousseau compris). Révoque les jetons sur claude.ai si la clé a été perdue." ;;
      2) bad "Effacé, mais une session Claude restait ouverte : ferme-la, puis refais « Tout effacer »." ;;
      *) bad "⚠ Effacement INCOMPLET : ce qui reste est utilisable."
         printf '%s\n' "$CC_WIPE_NOTE" | sed 's/^/  /'
         read -r -p "  Entrée pour revenir au menu… " _ < /dev/tty 2>/dev/null || sleep 8 ;;
    esac
  else note "Annulé."; fi
  sleep 2
}

# Sur un ordinateur qui n'est pas celui de l'utilisateur (PC prêté, de passage), on retire
# en partant tout ce qui permettrait de réutiliser ses comptes : sessions Claude (Trousseau de
# l'hôte sur macOS, fichiers du portable ailleurs) et jetons Cloudflare Access
# (baluchon-core remote lit le même marqueur config/.hosts/<hôte>). Une question par machine.
host_key() { hostname 2>/dev/null | tr -c 'a-zA-Z0-9_.-' '_' ; }
host_trust() { cat "$ROOT/config/.hosts/$(host_key)" 2>/dev/null; }
ask_host_trust() {
  [ -n "$(host_trust)" ] && return 0
  mkdir -p "$ROOT/config/.hosts"
  if gum confirm "Cet ordinateur ($(hostname)) est-il à toi ? (Non = tes connexions sont effacées en quittant)" --affirmative "Oui, à moi" --negative "Non" --selected.background "$ORANGE"; then
    echo trusted > "$ROOT/config/.hosts/$(host_key)"
  else echo guest > "$ROOT/config/.hosts/$(host_key)"; fi
}

quit_wizard() {
  clear 2>/dev/null || true
  trap - EXIT HUP TERM
  if [ "$(host_trust)" = guest ]; then
    local prc=0; cc_purge_sessions || prc=$?
    if [ "$prc" = 2 ]; then
      # Une session Claude encore ouverte peut réécrire ses identifiants : on
      # laisse la fermer, puis on efface une 2e fois avant de rien promettre.
      bad "Une session Claude est encore ouverte sur cet ordinateur : ferme-la (sinon elle peut réenregistrer ta connexion)."
      gum confirm "C'est fermé ? On efface à nouveau." --affirmative "Effacer" --negative "Plus tard" --selected.background "$ORANGE" \
        && { prc=0; cc_purge_sessions || prc=$?; }
    fi
    case "$prc" in
      0) note "Connexions Claude effacées de cet ordinateur (il faudra te reconnecter la prochaine fois)." ;;
      2) bad "Effacement fait, mais une session Claude restait ouverte : ferme-la et relance baluchon → Quitter pour garantir l'effacement." ;;
      *) bad "Effacement INCOMPLET des connexions : supprime à la main le dossier $ROOT/config avant de partir." ;;
    esac
  fi
  gum style --foreground "$ORANGE" --bold --margin "1 0 1 2" "À bientôt 👋"
  # Ouvert depuis le lien d'installation (BALUCHON_DEPUIS_LIEN=1, posé par cc_open_menu), le menu est un
  # ENFANT de l'installeur : on rend la main à qui l'a lancé, qui finit son travail (messages, nettoyage).
  # Remplacé par un shell, il le coincerait dans un shell de connexion imbriqué.
  if [ "$CC_OS" = win32 ] || [ "${BALUCHON_DEPUIS_LIEN:-}" = 1 ]; then exit 0; else exec "${SHELL:-/bin/zsh}" -l; fi
}

# « Partir » : tout effacer et désinstaller, depuis le menu. Proposé seulement si ce dossier se déclare une
# installation (marqueur) ET porte son désinstalleur : jamais sur une clé qui n'a pas été posée par
# l'installeur. Pas encore sous Windows (le désinstalleur est un script bash : phase suivante).
can_leave() {
  [ "$CC_OS" != win32 ] && cc_est_installation "$ROOT" && [ -f "$ROOT/uninstall.sh" ] && [ ! -L "$ROOT/uninstall.sh" ]
}
LEAVE_LABEL="🚪  Partir : tout effacer et désinstaller"
do_partir() {
  clear 2>/dev/null || true
  can_leave || { bad "Le désinstalleur de ce dossier est absent : rien n'a été effacé."; sleep 3; return 0; }
  # Une seule question, et « Non » par défaut : l'effacement n'a pas de retour.
  gum confirm "Effacer tous tes comptes et désinstaller Baluchon de cet ordinateur ?" --default=false \
    --affirmative "Oui, tout effacer" --negative "Non, annuler" --selected.background "$ORANGE" \
    || { note "Annulé."; sleep 1; return 0; }
  note "Effacement en cours…"
  local code=0
  cc_depart || code=$?
  if [ "$code" = 14 ]; then
    # Rien n'a été fait (désinstalleur absent ou altéré) : le menu est intact, on y revient.
    bad "$CC_DEPART_NOTE"; sleep 4; return 0
  fi
  # Le dossier n'existe plus (ni gum, ni le noyau, ni la bibliothèque) : à partir d'ici, printf seul, et
  # aucun cc_log (il recréerait logs/ dans le dossier qu'on vient d'effacer).
  trap - EXIT HUP TERM
  if [ "$code" = 0 ]; then
    printf '\n  \033[32m✓ Rien ne reste sur cet ordinateur.\033[0m\n'
    printf "  Si cet ordinateur n'est pas le tien, révoque aussi la session sur https://claude.ai.\n\n"
  else
    printf '\n  \033[31m⚠ Il reste quelque chose sur cet ordinateur (code %s) :\033[0m\n' "$code"
    printf '%s' "$CC_DEPART_RESTE" | sed 's/^/    - /'
    [ -z "$CC_DEPART_NOTE" ] || printf '%s\n' "$CC_DEPART_NOTE" | sed 's/^/    /'
    case "$code" in
      2|11) printf '  Une session Claude est peut-être encore ouverte : ferme-la, puis révoque la session sur https://claude.ai.\n' ;;
      10)   printf '  Supprime à la main les fichiers dont le nom finit par « -token » dans ~/.cloudflared.\n' ;;
      *)    printf "  Supprime à la main ce qui est listé ci-dessus : c'est encore utilisable.\n" ;;
    esac
    printf '\n'
  fi
  exit "$code"
}

# ---------- préparation ----------
if [ ! -f "$GUMBIN" ]; then
  # Sans interface : lancement direct du compte par défaut.
  echo "Interface gum absente pour $PLAT — lancement direct du compte par défaut."
  cc_ensure_binary; cc_ensure_core >/dev/null 2>&1 || true
  p="$(cc_active_profile)"; cc_write_settings "$ROOT/config/$p"
  if [ -n "${CORE:-}" ]; then exec "$CORE" --root "$ROOT" run "$p" --claude "$BIN" -- --dangerously-skip-permissions "$@"; fi
  export CLAUDE_CONFIG_DIR; CLAUDE_CONFIG_DIR="$(cc_winpath "$ROOT/config/$p")"
  [ -f "$ROOT/config/$p/oauth.token" ] && [ ! -f "$ROOT/config/$p/.credentials.json" ] && { CLAUDE_CODE_OAUTH_TOKEN="$(tr -d ' \r\n' < "$ROOT/config/$p/oauth.token")"; export CLAUDE_CODE_OAUTH_TOKEN; }
  exec "$BIN" --dangerously-skip-permissions "$@"
fi
clear 2>/dev/null || true
cc_ensure_binary
cc_ensure_core 2>/dev/null || cc_log "mode dégradé : baluchon-core indisponible"
ask_host_trust
# Poste invité : fermer la fenêtre (croix, SIGHUP) ou tuer le wizard (SIGTERM)
# doit effacer les connexions comme « Quitter ». quit_wizard désarme ce piège et
# fait sa propre purge, qui affiche le résultat. Les sous-shells ( ) et $( ) ne
# reçoivent pas ces pièges (bash les réinitialise).
guest_purge_on_close() {
  trap - EXIT HUP TERM
  cc_purge_sessions >/dev/null 2>&1 || true
}
# Filet pour ce que les pièges ne voient pas (SIGKILL, fenêtre tuée par
# l'OS) : un guetteur détaché, sourd à SIGHUP, efface dès que le wizard n'existe
# plus. Après « Quitter », le wizard devient le shell (exec, même pid) : le
# guetteur efface alors à la fermeture de ce shell — sans effet si déjà vide.
guest_watchdog() {
  local wpid=$$
  ( trap '' HUP INT TERM
    while kill -0 "$wpid" 2>/dev/null; do sleep 2; done
    cc_purge_sessions ) </dev/null >/dev/null 2>&1 &
}
if [ "$(host_trust)" = guest ]; then
  trap guest_purge_on_close EXIT
  trap 'guest_purge_on_close; exit 129' HUP
  trap 'guest_purge_on_close; exit 143' TERM
  guest_watchdog
fi
probe_all

# ---------- boucle ----------
while true; do
  render
  items=()
  # « Partir » : en TÊTE sur un poste invité (c'est la sortie propre d'un ordinateur de passage),
  # sinon juste avant « Quitter ». Absente si ce dossier n'est pas une installation posée par l'installeur.
  leave_top=0; leave_bottom=0
  if can_leave; then
    if [ "$(host_trust)" = guest ]; then leave_top=1; else leave_bottom=1; fi
  fi
  [ "$leave_top" = 1 ] && items+=("$LEAVE_LABEL")
  if [ -z "$(accounts)" ]; then
    # Portable vide : la seule chose utile est d'y mettre des comptes.
    [ "$MACHINE_MISSING" -gt 0 ] && items+=("🔎  Réindexer mes comptes ($MACHINE_MISSING trouvés sur cet ordinateur)")
    items+=("➕  Ajouter un compte" "🧰  Outils…" "⬆  Mettre à jour…")
    [ "$leave_bottom" = 1 ] && items+=("$LEAVE_LABEL")
    items+=("✕  Quitter")
  else
    best=""; [ -n "${CORE:-}" ] && best="$("$CORE" --root "$ROOT" accounts best 2>/dev/null | tr -d '\r\n')"
    active="$(cc_active_profile)"
    [ -n "$best" ] && items+=("▶  Lancer le compte recommandé ($best)")
    { [ -z "$best" ] || [ "$best" != "$active" ]; } && items+=("▶  Lancer le compte par défaut ($active)")
    items+=("↪  Lancer un autre compte" "👤  Comptes…" "🧰  Outils…" "🔄  Actualiser les statuts" "⬆  Mettre à jour…" "🗑  Tout déconnecter")
    [ "$leave_bottom" = 1 ] && items+=("$LEAVE_LABEL")
    items+=("✕  Quitter")
  fi
  choice="$(gum choose --header "" --cursor "❯ " --cursor.foreground "$ORANGE" "${items[@]}")"; rc=$?
  if [ "$rc" -ne 0 ]; then if [ "$rc" -eq 130 ]; then continue; else break; fi; fi
  case "$choice" in
    *recommandé*)  launch "$best" ;;
    *"par défaut"*) launch "$active" ;;
    "↪"*)  sel="$(choose_account "Quel compte lancer ?")" && [ -n "$sel" ] && launch "$sel" ;;
    "🔎"*) reindex ;;
    "➕"*) add_account ;;
    "👤"*) menu_accounts ;;
    "🧰"*) menu_tools ;;
    "🔄"*) probe_all; continue ;;
    "⬆"*)  menu_update ;;
    "🗑"*) do_wipe ;;
    "🚪"*) do_partir ;;
    "✕"*)  quit_wizard ;;
    *)     continue ;;
  esac
  probe_background
done
quit_wizard
