# shellcheck shell=bash
# shellcheck disable=SC2034  # BIN, CORE, CC_GUM, EXE… sont lus par Claude.command
# ============================================================
#  Bibliothèque partagée de Baluchon (macOS / Linux / Windows-Git-bash).
#  Sourcée par Claude.command. Fixe ROOT avant de la sourcer.
#
#  Partage des rôles (cf TECHNICAL.md) :
#   - ce fichier : plateforme, téléchargements VÉRIFIÉS (claude, gum, baluchon-core),
#     mises à jour + retour arrière, effacement ;
#   - baluchon-core (Rust) : tout ce qui touche aux comptes (statut, Trousseau,
#     renouvellement, quota, lancement verrouillé). Le bash n'analyse aucun JSON.
#
#  Règle de sûreté : toute vérification qui ne peut pas conclure REFUSE
#  (fail-closed). Un binaire non vérifié ne s'exécute jamais.
# ============================================================

CC_RELEASES="https://downloads.claude.ai/claude-code-releases"
CCP_REPO="atelier-sam/baluchon"
CCP_DL="${CCP_DL:-https://github.com/$CCP_REPO/releases/latest/download}"  # surcharge = recette locale ; signature toujours exigée
CCP_CONTRACT=1   # version du contrat CLI attendue de baluchon-core (`baluchon-core --contract`)
# Capacité annoncée aux crochets de couche : ce lanceur sait lire une couche rangée par GÉNÉRATIONS
# (pointeur overlay/CURRENT, voir « Couches » dans TECHNICAL.md). Un crochet refuse de poser une
# génération sur un lanceur qui ne l'annonce pas : il ne lirait que l'ancienne couche, en silence.
CCP_LAYER_POINTER=1

# Clé publique qui signe les SHA256SUMS des releases du portable : « <identité> <type> <clé> ».
# La clé privée n'est jamais dans le dépôt (scripts/release.sh la lit hors dépôt).
# release.sh vérifie que install.sh et install.ps1 portent la même.
CCP_SIGNER='baluchon-release ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIRcs8TrzgdQa1DTZ/Tdt2qUYCBeNuJ1p/DP27yyDttp'
CCP_SIGNER_ID="${CCP_SIGNER%% *}"

# gum épinglé : version + empreintes SHA256 relevées sur la release officielle
# (API GitHub, champ digest, 09/11/2026). Épingler évite de dépendre du réseau
# pour savoir quoi vérifier.
CC_GUM_VER="0.17.0"
cc_gum_sha() {
  case "$1" in
    Darwin_arm64)   echo e2a4b8596efa05821d8c58d0c1afbcd7ad1699ba69c689cc3ff23a4a99c8b237 ;;
    Darwin_x86_64)  echo cd66576aeebe6cd19c771863c7e8d696e0e1d5387d1e7075666baa67c2052e53 ;;
    Linux_arm64)    echo b0b9ed95cbf7c8b7073f17b9591811f5c001e33c7cfd066ca83ce8a07c576f9c ;;
    Linux_x86_64)   echo 69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb ;;
    Windows_x86_64) echo b2be80531c6babc8d4e0e6ca95773d58118a2e1582ae006aace08dbc55503072 ;;
    *) echo "" ;;
  esac
}

# Auto-updater désactivé : un binaire sur clé USB ne doit pas se réécrire depuis
# une machine cliente au hasard. Les MAJ passent par le menu, de façon contrôlée,
# avec retour arrière possible.
export DISABLE_AUTOUPDATER=1

# ─── Journal ────────────────────────────────────────────────────────────
# Toujours actif (logs/launch.log). Masque tout ce qui ressemble à un jeton :
# un journal sur clé USB ne doit jamais devenir une fuite.
cc_log() {
  local d="$ROOT/logs" line
  mkdir -p "$d" 2>/dev/null || true
  line="$(printf '%s' "$*" | sed -E 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-<MASQUE>/g')"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$line" >> "$d/launch.log" 2>/dev/null || true
}
cc_die()  { cc_log "ERREUR: $*"; printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
cc_info() { printf '\033[36m• %s\033[0m\n' "$*" >&2; }
cc_ok()   { printf '\033[32m✓ %s\033[0m\n' "$*" >&2; }
cc_warn() { printf '\033[33m⚠ %s\033[0m\n' "$*" >&2; }

# ─── Plateforme ─────────────────────────────────────────────────────────
# PLAT = nom de plateforme des binaires Claude (darwin-arm64, linux-x64-musl…)
# CORE_PLAT = nom des binaires baluchon-core (les linux sont en musl statique : un
# seul binaire par architecture, qui tourne aussi sur glibc).
cc_detect_platform() {
  local s m
  s="$(uname -s)"; m="$(uname -m)"
  case "$s" in
    Darwin) CC_OS=darwin ;;
    Linux)  CC_OS=linux ;;
    MINGW*|MSYS*|CYGWIN*) CC_OS=win32 ;;   # bash de Git for Windows
    *) cc_die "OS non supporté : $s" ;;
  esac
  case "$m" in
    arm64|aarch64) CC_ARCH=arm64 ;;
    x86_64|amd64|x86|i686) CC_ARCH=x64 ;;   # git-win est x64 (émulé sur ARM)
    *) cc_die "Architecture non supportée : $m" ;;
  esac
  PLAT="$CC_OS-$CC_ARCH"
  if [ "$CC_OS" = linux ]; then
    if ls /lib/ld-musl-* >/dev/null 2>&1 || ( command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl ); then
      PLAT="$PLAT-musl"
    fi
  fi
  CORE_PLAT="$CC_OS-$CC_ARCH"
  [ "$CC_OS" = win32 ] && CORE_PLAT=win32-x64   # un seul binaire Windows (ARM64 émule x64)
  BINNAME=claude; EXE=""
  [ "$CC_OS" = win32 ] && { BINNAME=claude.exe; EXE=".exe"; }
  # Claude Code sous Windows exige un bash de Git : on lui donne celui du portable.
  if [ "$CC_OS" = win32 ] && [ -f "$ROOT/git-win/bin/bash.exe" ]; then
    CLAUDE_CODE_GIT_BASH_PATH="$(cygpath -w "$ROOT/git-win/bin/bash.exe" 2>/dev/null)"
    export CLAUDE_CODE_GIT_BASH_PATH
  fi
}

# Convertit un chemin MSYS en chemin Windows pour les .exe natifs (claude.exe).
cc_winpath() {
  if [ "${CC_OS:-}" = win32 ]; then cygpath -w "$1" 2>/dev/null || printf '%s' "$1"
  else printf '%s' "$1"; fi
}

cc_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else echo ""; fi
}

# Vérifie un fichier contre une empreinte attendue. Fail-closed : empreinte
# vide ou outil absent = refus.
cc_check_sha() {
  local f="$1" want="$2" got
  [ -n "$want" ] || { cc_warn "Empreinte attendue inconnue pour $(basename "$f") : refus."; return 1; }
  got="$(cc_sha256 "$f")"
  [ -n "$got" ] || { cc_warn "Aucun outil SHA256 (shasum/sha256sum) : refus."; return 1; }
  [ "$got" = "$want" ] || { cc_warn "Empreinte invalide pour $(basename "$f")."; return 1; }
}

# ─── Releases signées du portable ───────────────────────────────────────
# Télécharge SHA256SUMS + SHA256SUMS.sig de la dernière release et vérifie la
# signature (ssh-keygen -Y, présent sur macOS, Linux openssh et Git for Windows).
# $1 = dossier de travail. Écrit $1/SHA256SUMS vérifié. 0 si authentique.
cc_fetch_signed_sums() {
  local w="$1" sk
  sk="$(command -v ssh-keygen 2>/dev/null)"
  [ -n "$sk" ] || { cc_warn "ssh-keygen introuvable : impossible d'authentifier la release (refus)."; return 1; }
  { curl -fsSL "$CCP_DL/SHA256SUMS" -o "$w/SHA256SUMS" && curl -fsSL "$CCP_DL/SHA256SUMS.sig" -o "$w/SHA256SUMS.sig"; } \
    || { cc_warn "Release du portable injoignable."; return 1; }
  printf '%s\n' "$CCP_SIGNER" > "$w/allowed_signers"
  "$sk" -Y verify -f "$w/allowed_signers" -I "$CCP_SIGNER_ID" -n file -s "$w/SHA256SUMS.sig" < "$w/SHA256SUMS" >/dev/null 2>&1 \
    || { cc_warn "Signature de la release INVALIDE : rien n'est installé."; return 1; }
}
# Empreinte d'un fichier listé dans un SHA256SUMS vérifié. $1 = SHA256SUMS, $2 = nom.
cc_sum_for() { awk -v n="$2" '$2==n || $2=="*"n {print $1; exit}' "$1"; }

# ─── Binaire Claude Code ────────────────────────────────────────────────
# Empreinte d'une plateforme dans le manifest officiel. Les objets plateforme du
# manifest n'ont pas d'accolade imbriquée (vérifié 09/11/2026), d'où le grep.
cc_manifest_sha() {
  printf '%s' "$1" | tr -d ' \n\t\r' | grep -o "\"$2\":{[^}]*}" | grep -o '"checksum":"[0-9a-f]*"' | head -1 | cut -d'"' -f4
}

# Télécharge le binaire d'une plateforme et vérifie le SHA256 du manifest officiel.
cc_download_binary() {
  local plat="$1" binname="$2" ver dir out manifest sha tmp
  ver="$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null)"; [ -n "$ver" ] || ver=stable
  [ "$ver" = stable ] && ver="$(curl -fsSL "$CC_RELEASES/stable")"
  [ -n "$ver" ] || cc_die "Version de Claude introuvable (pas de réseau ?)"
  dir="$ROOT/bin/$plat"; mkdir -p "$dir"; out="$dir/$binname"; tmp="$dir/.$binname.part"
  cc_info "Téléchargement de Claude Code $ver pour $plat ..."
  manifest="$(curl -fsSL "$CC_RELEASES/$ver/manifest.json")" || cc_die "Manifest injoignable (pas de réseau ?)"
  sha="$(cc_manifest_sha "$manifest" "$plat")"
  curl -fsSL "$CC_RELEASES/$ver/$plat/$binname" -o "$tmp" || { rm -f "$tmp"; cc_die "Téléchargement échoué pour $plat"; }
  cc_check_sha "$tmp" "$sha" || { rm -f "$tmp"; cc_die "Binaire $plat non vérifié : refusé."; }
  mv -f "$tmp" "$out"; chmod +x "$out" 2>/dev/null || true
  printf '%s' "$ver" > "$ROOT/VERSION"
  cc_ok "Claude $ver ($plat) vérifié (SHA256 OK)"
}

# Rend exécutable un binaire du portable ; sur une clé exFAT montée noexec,
# copie unique dans le cache local de la machine. $1 = chemin, $2 = clé de cache.
# Écrit le chemin exécutable sur stdout.
cc_runnable() {
  local f="$1" key="$2" cache
  chmod +x "$f" 2>/dev/null || true
  if "$f" --version >/dev/null 2>&1; then printf '%s' "$f"; return 0; fi
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/baluchon/$key"
  mkdir -p "$cache" 2>/dev/null || return 1
  if [ ! -x "$cache/$(basename "$f")" ] || ! cmp -s "$f" "$cache/$(basename "$f")"; then
    cc_info "Clé montée sans exécution : copie de $(basename "$f") en cache local ($cache)"
    cp "$f" "$cache/" && chmod +x "$cache/$(basename "$f")" || return 1
  fi
  "$cache/$(basename "$f")" --version >/dev/null 2>&1 || return 1
  printf '%s' "$cache/$(basename "$f")"
}

# Garantit un binaire Claude exécutable. -> BIN
cc_ensure_binary() {
  local raw="$ROOT/bin/$PLAT/$BINNAME" ver
  [ -f "$raw" ] || cc_download_binary "$PLAT" "$BINNAME"
  ver="$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null || echo unknown)"
  BIN="$(cc_runnable "$raw" "$ver/$PLAT")" || cc_die "Impossible d'exécuter le binaire claude"
}

# Profil actif : variable CC_PROFILE > fichier ACTIVE > "1"
cc_active_profile() {
  if [ -n "${CC_PROFILE:-}" ]; then printf '%s' "$CC_PROFILE"
  elif [ -f "$ROOT/ACTIVE" ]; then tr -d ' \r\n' < "$ROOT/ACTIVE"
  else printf '1'; fi
}

# settings.json du profil (bypass permissions) + onboarding marqué fait.
cc_write_settings() {
  local cfg="$1"
  mkdir -p "$cfg"
  if [ ! -f "$cfg/settings.json" ]; then
    cat > "$cfg/settings.json" <<'JSON'
{
  "defaultMode": "bypassPermissions",
  "skipDangerousModePermissionPrompt": true,
  "env": {
    "DISABLE_AUTOUPDATER": "1"
  }
}
JSON
  fi
  [ -f "$cfg/.claude.json" ] || printf '{"hasCompletedOnboarding":true}\n' > "$cfg/.claude.json"
}

# ─── Interface gum ──────────────────────────────────────────────────────
cc_ensure_gum() {
  local g="$ROOT/tools/gum/$PLAT/gum$EXE" os arch tmp b asset
  CC_GUM="$g"
  [ -f "$g" ] && { chmod +x "$g" 2>/dev/null || true; return 0; }
  case "$CC_OS" in darwin) os=Darwin;; linux) os=Linux;; win32) os=Windows;; *) return 1;; esac
  case "$CC_ARCH" in arm64) arch=arm64;; x64) arch=x86_64;; *) return 1;; esac
  [ "$CC_OS" = win32 ] && arch=x86_64
  mkdir -p "$ROOT/tools/gum/$PLAT"
  tmp="$(mktemp -d)"
  cc_info "Téléchargement de l'interface gum ($CC_GUM_VER, $PLAT)…"
  if [ "$CC_OS" = win32 ]; then
    asset="gum_${CC_GUM_VER}_${os}_${arch}.zip"
    curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${CC_GUM_VER}/$asset" -o "$tmp/g.zip" \
      && cc_check_sha "$tmp/g.zip" "$(cc_gum_sha "${os}_${arch}")" \
      && ( cd "$ROOT/tools/gum/$PLAT" && unzip -o -j "$tmp/g.zip" '*gum.exe' >/dev/null 2>&1 )
  else
    asset="gum_${CC_GUM_VER}_${os}_${arch}.tar.gz"
    curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${CC_GUM_VER}/$asset" -o "$tmp/g.tgz" \
      && cc_check_sha "$tmp/g.tgz" "$(cc_gum_sha "${os}_${arch}")" \
      && tar xzf "$tmp/g.tgz" -C "$tmp" && b="$(find "$tmp" -type f -name gum | head -1)" && [ -n "$b" ] && cp "$b" "$g" && chmod +x "$g"
  fi
  rm -rf "$tmp"
  [ -f "$CC_GUM" ]
}

# ─── Noyau baluchon-core ─────────────────────────────────────────────────────
# Télécharge (release signée) et valide le noyau. -> CORE (vide si indisponible :
# le wizard passe alors en mode dégradé, et LANCER fonctionne toujours).
cc_download_core() {
  local w name sha
  name="baluchon-core-$CORE_PLAT$EXE"
  w="$(mktemp -d)" || return 1
  cc_info "Téléchargement du noyau baluchon-core ($CORE_PLAT)…"
  if cc_fetch_signed_sums "$w" && curl -fsSL "$CCP_DL/$name" -o "$w/$name"; then
    sha="$(cc_sum_for "$w/SHA256SUMS" "$name")"
    if cc_check_sha "$w/$name" "$sha"; then
      mkdir -p "$ROOT/bin/$CORE_PLAT"
      mv -f "$w/$name" "$ROOT/bin/$CORE_PLAT/baluchon-core$EXE"; chmod +x "$ROOT/bin/$CORE_PLAT/baluchon-core$EXE" 2>/dev/null || true
      rm -rf "$w"; cc_ok "Noyau baluchon-core vérifié (signature + SHA256)"; return 0
    fi
  fi
  rm -rf "$w"; return 1
}

# ─── Couche (overlay/) ──────────────────────────────────────────────────
# Une couche est un dossier `<racine>/overlay/` posé À CÔTÉ du portable : un manifeste
# `LAYER` (name, version, built_on, contract, platforms), un noyau complémentaire
# `bin/<plat>/baluchon-core[.exe]` et des crochets `overlay/hooks/{update,uninstall}`.
# Ce fichier ne sait RIEN de son contenu et n'écrit JAMAIS sous overlay/ : installer ou mettre
# à jour le portable n'écrit que bin/ (et les fichiers publics), puis appelle le crochet
# `update`. WHY : sans cela, un clic sur « Mettre à jour » remplaçait en silence le noyau
# complémentaire par le public, et un journal d'écriture laissé par lui devenait orphelin.
#
# GÉNÉRATIONS. Le manifeste et le noyau d'une couche vivent dans un dossier de génération
# `overlay/gen/<nom>/` posé EN ENTIER avant d'être visible ; le fichier `overlay/CURRENT`
# (« gen/<nom> ») le désigne, et un seul renommage le remplace. Un lecteur qui ne prend aucun
# verrou voit donc la génération précédente entière ou la nouvelle entière, jamais un mélange à
# condition de ne lire le pointeur QU'UNE FOIS : `cc_layer_resolve` le fait, et tout le reste
# (manifeste, noyau) lit sous le dossier qu'elle a posé. WHY un fichier et non un lien symbolique :
# une clé exFAT/FAT n'a pas de liens, et Git Bash copie au lieu de lier (la copie n'est pas atomique).
# Sans `CURRENT`, la couche est à plat directement sous overlay/ (couches posées avant les
# générations) : même lecture.

# Résout UNE FOIS le dossier de la couche courante -> CC_LAYER_DIR (vide : pas de couche).
# Un pointeur présent mais illisible (lien, forme inattendue, dossier absent) = pas de couche ET une
# ligne visible (CC_LAYER_NOTE) : on ne devine jamais une autre génération.
cc_layer_resolve() {
  local o="$ROOT/overlay" p
  CC_LAYER_DIR=""
  if [ ! -e "$o/CURRENT" ] && [ ! -L "$o/CURRENT" ]; then
    [ -f "$o/LAYER" ] && CC_LAYER_DIR="$o"
    return 0
  fi
  p=""
  if [ -f "$o/CURRENT" ] && [ ! -L "$o/CURRENT" ]; then
    p="$(head -n 1 "$o/CURRENT" 2>/dev/null | tr -d '\r')"
  fi
  case "$p" in
    gen/[A-Za-z0-9]*) ;;
    *) p="" ;;
  esac
  case "${p#gen/}" in */*|*[!A-Za-z0-9._-]*) p="" ;; esac
  if [ -z "$p" ] || [ ! -d "$o/$p" ] || [ -L "$o/$p" ]; then
    CC_LAYER_NOTE="Couche inutilisable (pointeur overlay/CURRENT illisible) : noyau public utilisé. Relance l'installation pour la mettre à jour."
    cc_log "$CC_LAYER_NOTE"
    return 1
  fi
  CC_LAYER_DIR="$o/$p"
}

# Valeur d'une clé du manifeste (guillemets et fin de ligne Windows retirés), vide si absente.
# Lit sous la génération résolue par `cc_layer_resolve` (résolue ici si personne ne l'a fait).
cc_layer_field() {
  [ -n "${CC_LAYER_DIR:-}" ] || cc_layer_resolve || true
  [ -n "${CC_LAYER_DIR:-}" ] || return 0
  sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$CC_LAYER_DIR/LAYER" 2>/dev/null | head -1 | tr -d '\r"'
}

# La couche est-elle utilisable ici ? Choix du noyau (lanceur) :
#   pas de couche (ni CURRENT ni overlay/LAYER) -> noyau public
#   noyau de la couche absent, non exécutable, autre contrat, ou édition « public »
#                                    -> noyau public ET une ligne visible (CC_LAYER_NOTE)
#   sinon                            -> noyau de la couche
# Rend 0 et pose CC_LAYER_CORE si utilisable ; 1 sinon, avec CC_LAYER_NOTE.
# Lit sous la génération déjà résolue (CC_LAYER_DIR) : le manifeste et le noyau d'un même appel
# viennent TOUJOURS de la même génération.
cc_layer_core() {
  local name raw c about why=""
  CC_LAYER_CORE=""; CC_LAYER_NOTE=""
  [ -n "${CC_LAYER_DIR:-}" ] || cc_layer_resolve || return 1
  [ -n "${CC_LAYER_DIR:-}" ] || return 1
  name="$(cc_layer_field name)"; [ -n "$name" ] || name="sans nom"
  raw="$CC_LAYER_DIR/bin/$CORE_PLAT/baluchon-core$EXE"
  if [ ! -f "$raw" ]; then why="pas de noyau pour $CORE_PLAT"
  elif ! c="$(cc_runnable "$raw" "overlay-core/$CORE_PLAT")"; then why="noyau non exécutable"
  elif [ "$("$c" --contract 2>/dev/null | tr -d ' \r\n')" != "$CCP_CONTRACT" ]; then why="contrat périmé"
  else
    about="$("$c" about --json 2>/dev/null | tr -d ' \r\n')"
    case "$about" in
      *'"edition":"public"'*) why="édition inattendue (public)" ;;
      *'"edition":"'*) ;;
      *) why="édition illisible" ;;
    esac
  fi
  if [ -n "$why" ]; then
    CC_LAYER_NOTE="Couche « $name » inutilisable ($why) : noyau public utilisé. Relance l'installation pour la mettre à jour."
    cc_log "$CC_LAYER_NOTE"
    return 1
  fi
  CC_LAYER_CORE="$c"
}

# Appelle un crochet de la couche (`update` ou `uninstall`) s'il existe. Un échec est dit, jamais
# fatal : la mise à jour du public a déjà réussi et la couche garde sa version précédente.
cc_layer_hook() {
  local h="$ROOT/overlay/hooks/$1" rc=0
  [ -f "$h" ] || return 0
  cc_info "Couche : crochet « $1 »…"
  ( BALUCHON_ROOT="$ROOT" BALUCHON_CORE_PLAT="${CORE_PLAT:-}" BALUCHON_EXE="${EXE:-}" bash "$h" ) || rc=$?
  [ "$rc" = 0 ] || { cc_warn "Le crochet « $1 » de la couche a échoué (code $rc)."; return 1; }
}

cc_ensure_core() {
  local raw="$ROOT/bin/$CORE_PLAT/baluchon-core$EXE" c
  CORE=""; CC_LAYER_NOTE=""
  # La génération est résolue ICI, une fois : le pointeur n'est plus relu pendant ce choix.
  cc_layer_resolve || true
  if [ -n "${CC_LAYER_DIR:-}" ] && cc_layer_core; then CORE="$CC_LAYER_CORE"; return 0; fi
  [ -f "$raw" ] || cc_download_core || { cc_log "baluchon-core indisponible (téléchargement)"; return 1; }
  c="$(cc_runnable "$raw" "core/$CORE_PLAT")" || { cc_log "baluchon-core non exécutable"; return 1; }
  if [ "$("$c" --contract 2>/dev/null | tr -d ' \r\n')" != "$CCP_CONTRACT" ]; then
    cc_log "baluchon-core : contrat inattendu (attendu $CCP_CONTRACT)"; return 1
  fi
  CORE="$c"
}
# Appelle le noyau avec la racine du portable, Ctrl+C rendu à l'enfant (le
# wizard ignore SIGINT pour survivre à un Ctrl+C dans Claude).
ccp_core() { [ -n "${CORE:-}" ] || return 127; ( trap - INT; "$CORE" --root "$ROOT" "$@" ); }

# ─── Mises à jour ───────────────────────────────────────────────────────
# Dernière version stable de Claude, relevée au plus une fois par jour (bandeau
# « mise à jour disponible » de l'accueil). Écrit la version sur stdout.
cc_claude_stable_cached() {
  local f="$ROOT/.cache/claude-stable" now age v
  now="$(date +%s)"; mkdir -p "$ROOT/.cache" 2>/dev/null || true
  if [ -f "$f" ]; then age=$(( now - $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) )); else age=999999; fi
  if [ "$age" -gt 86400 ]; then
    v="$(curl -fsSL -m 4 "$CC_RELEASES/stable" 2>/dev/null | tr -d ' \r\n')"
    [ -n "$v" ] && printf '%s' "$v" > "$f"
  fi
  tr -d ' \r\n' < "$f" 2>/dev/null
}

# Met à jour le binaire Claude de CETTE plateforme (+ les autres présentes sur la
# clé), en gardant la version précédente (claude.prev) pour revenir en arrière.
# $1 = canal (stable/latest)
cc_update() {
  local channel="${1:-stable}" ver manifest plat binname sha tmp dst old here_ok=0
  local plats=()
  old="$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null)"
  ver="$(curl -fsSL "$CC_RELEASES/$channel")" || { cc_warn "Pas de réseau."; return 1; }
  cc_info "Dernière version $channel : $ver (installée : ${old:-?})"
  manifest="$(curl -fsSL "$CC_RELEASES/$ver/manifest.json")" || { cc_warn "Manifest injoignable."; return 1; }
  for d in "$ROOT"/bin/*/; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in win32-*|darwin-*|linux-*) [ -f "$d/claude" ] || [ -f "$d/claude.exe" ] && plats+=("$(basename "$d")");; esac
  done
  [ "${#plats[@]}" -gt 0 ] || plats=("$PLAT")
  for plat in "${plats[@]}"; do
    binname=claude; case "$plat" in win32-*) binname=claude.exe ;; esac
    sha="$(cc_manifest_sha "$manifest" "$plat")"
    dst="$ROOT/bin/$plat/$binname"; tmp="$ROOT/bin/$plat/.$binname.new"
    cc_info "MAJ $plat ..."
    if curl -fsSL "$CC_RELEASES/$ver/$plat/$binname" -o "$tmp" && cc_check_sha "$tmp" "$sha"; then
      [ -f "$dst" ] && mv -f "$dst" "$dst.prev" && printf '%s' "${old:-?}" > "$ROOT/bin/$plat/.prev-version"
      if mv -f "$tmp" "$dst"; then
        chmod +x "$dst" 2>/dev/null || true; cc_ok "$plat à jour ($ver)"
        [ "$plat" = "$PLAT" ] && here_ok=1
      else
        # Remise en place de l'ancien binaire : jamais de plateforme sans claude.
        [ -f "$dst.prev" ] && [ ! -f "$dst" ] && mv -f "$dst.prev" "$dst"
        rm -f "$tmp"; cc_warn "$plat : installation impossible, ancienne version conservée."
      fi
    else rm -f "$tmp"; cc_warn "$plat : échec ou empreinte invalide, ancienne version conservée."; fi
  done
  # VERSION décrit le binaire de CETTE plateforme : on ne l'avance que s'il a
  # réellement été remplacé (sinon le bandeau « mise à jour disponible » disparaît
  # alors que l'ancien binaire tourne toujours).
  [ "$here_ok" = 1 ] || { cc_warn "Claude n'a pas été mis à jour sur $PLAT (version ${old:-?} conservée)."; return 1; }
  printf '%s' "$ver" > "$ROOT/VERSION"
  rm -f "$ROOT/.cache/claude-stable"
  cc_ok "Claude = $ver"
}

# Revient à la version précédente de Claude (celle gardée par cc_update).
cc_rollback() {
  local dst="$ROOT/bin/$PLAT/$BINNAME" prev
  [ -f "$dst.prev" ] || { cc_warn "Aucune version précédente gardée."; return 1; }
  prev="$(tr -d ' \r\n' < "$ROOT/bin/$PLAT/.prev-version" 2>/dev/null)"
  mv -f "$dst" "$dst.rollback-tmp" && mv -f "$dst.prev" "$dst" && mv -f "$dst.rollback-tmp" "$dst.prev"
  [ -n "$prev" ] && { printf '%s' "$(tr -d ' \r\n' < "$ROOT/VERSION")" > "$ROOT/bin/$PLAT/.prev-version"; printf '%s' "$prev" > "$ROOT/VERSION"; }
  cc_ok "Claude revenu à ${prev:-la version précédente}"
}

# Met à jour le portable lui-même (wizard, bibliothèque, lanceurs Windows, noyau)
# depuis la dernière release signée. Remplacement fichier par fichier, chacun
# vérifié AVANT d'écraser. N'écrit que les fichiers publics et bin/ : jamais overlay/,
# que son propre crochet `update` met à jour (appelé en dernier, même si rien du public
# n'a changé, pour que la couche se recale sur le public qui vient d'arriver).
cc_update_portable() {
  local w f sha ok=0 fail=0
  w="$(mktemp -d)" || return 1
  cc_fetch_signed_sums "$w" || { rm -rf "$w"; return 1; }
  # uninstall.sh : l'entrée « Partir » du menu l'exécute (copie temporaire, voir cc_depart).
  for f in Claude.command lib/common.sh uninstall.sh claude.cmd claude-classic.cmd "baluchon-core-$CORE_PLAT$EXE"; do
    sha="$(cc_sum_for "$w/SHA256SUMS" "$(basename "$f")")"
    [ -n "$sha" ] || continue
    curl -fsSL "$CCP_DL/$(basename "$f")" -o "$w/$(basename "$f")" || { cc_warn "$(basename "$f") injoignable"; fail=$((fail+1)); continue; }
    cc_check_sha "$w/$(basename "$f")" "$sha" || { fail=$((fail+1)); continue; }
    case "$f" in
      baluchon-core-*) mkdir -p "$ROOT/bin/$CORE_PLAT"; mv -f "$w/$(basename "$f")" "$ROOT/bin/$CORE_PLAT/baluchon-core$EXE"; chmod +x "$ROOT/bin/$CORE_PLAT/baluchon-core$EXE" 2>/dev/null || true ;;
      *) mkdir -p "$ROOT/$(dirname "$f")"; mv -f "$w/$(basename "$f")" "$ROOT/$f" ;;
    esac
    ok=$((ok+1)); cc_ok "$(basename "$f") à jour"
  done
  chmod +x "$ROOT/Claude.command" 2>/dev/null || true
  # Le relevé « cette installation est celle de cette release » n'est posé que si TOUT a été remplacé :
  # un fichier manqué ferait croire à install.sh que rien n'est à refaire.
  if [ "$fail" = 0 ] && [ "$ok" -gt 0 ] && cc_est_installation "$ROOT"; then cc_release_noter "$w/SHA256SUMS" || true; fi
  rm -rf "$w"
  cc_layer_hook update || true
  [ "$ok" -gt 0 ]
}

# ─── Effacement ─────────────────────────────────────────────────────────
# Efface les sessions de CE portable : Trousseau macOS (services suffixés
# seulement, jamais la session Claude Code normale de la machine) ET identifiants
# en fichier (seul magasin sous Windows/Linux). Passe par le noyau ; le repli
# bash couvre le cas « noyau absent », sinon un poste invité garderait tout.
# Rend 0 seulement si tout ce qui existait a été effacé.
# Code retour : 0 = tout effacé ; 2 = effacé mais une session ou un renouvellement
# encore vivant pourrait réécrire des identifiants (code 11 du noyau) ; 1 = échec.
cc_purge_sessions() {
  local core_rc=0
  ccp_core accounts purge >/dev/null 2>&1 || core_rc=$?
  case "$core_rc" in 0) return 0 ;; 11) return 2 ;; esac
  local d cfg f rc=0
  for d in "$ROOT"/config/*/; do
    [ -d "$d" ] || continue; cfg="${d%/}"
    if [ "${CC_OS:-}" = darwin ]; then
      security delete-generic-password -s "Claude Code-credentials-$(printf '%s' "$cfg" | shasum -a 256 | cut -c1-8)" >/dev/null 2>&1 || true
    fi
    # Même liste que core/src/purge.rs : journal, sa réservation (peut contenir
    # des jetons neufs) et les temporaires d'écriture atomique.
    for f in .credentials.json oauth.token oauth.token.bak .ccp-pending .ccp-pending.reserve "$cfg"/.ccp-tmp-*; do
      f="${f#"$cfg"/}"
      [ -e "$cfg/$f" ] || continue
      rm -f "$cfg/$f" 2>/dev/null || rc=1
      [ -e "$cfg/$f" ] && rc=1
    done
  done
  return "$rc"
}
# Ancien nom, gardé pour les appelants existants.
cc_purge_keychain() { cc_purge_sessions; }
# Efface toutes les sessions et jetons du portable (Trousseau compris), et les jetons
# Cloudflare Access que la liaison avec le Mac a laissés dans ~/.cloudflared.
# Code retour (ce qui RESTE est dit dans CC_WIPE_NOTE, jamais avalé) :
#   0 = tout effacé ; 2 = effacé, mais une session Claude encore ouverte peut réécrire ses
#   identifiants ; 10 = des jetons Cloudflare Access restent UTILISABLES ; 1 = sessions mal effacées.
# WHY : avant, les deux échecs étaient ignorés et le menu affichait « ✓ Effacé » ; sur un poste
# prêté, un jeton Access resté en place rouvrait la liaison avec le Mac (même défaut que celui
# que la revue Codex avait trouvé dans uninstall.sh).
# Si l'effacement des jetons Access échoue, config/remote.conf est GARDÉ : c'est lui qui dit quel
# hôte oublier ; sans lui, une nouvelle tentative répondrait « aucun Mac configuré » et réussirait
# sans rien effacer. Il ne contient aucun secret (hôte, utilisateur, options).
cc_wipe() {
  local prc=0 frc=0 sortie="" f h autres
  CC_WIPE_NOTE=""
  cc_purge_keychain || prc=$?
  # Hôtes d'accès que l'amorce a signalés parce que leurs jetons pouvaient rester (.baluchon-acces) :
  # ils ne sont pas dans remote.conf, donc le `forget-access` nu ne les verrait jamais.
  autres="$(cc_acces_hotes_notes)"
  if [ -n "${CORE:-}" ]; then
    sortie="$(ccp_core remote forget-access 2>&1)" || frc=$?
    for h in $autres; do
      f="$(ccp_core remote forget-access --host "$h" 2>&1)" || { frc=$?; sortie="${sortie}"$'\n'"$f"; }
    done
  elif [ -f "$ROOT/config/remote.conf" ] || [ -n "$autres" ]; then
    frc=127; sortie="noyau indisponible : les jetons de ~/.cloudflared n'ont pas pu être cherchés."
  fi
  # Tout est effacé : plus rien à surveiller. Sur un échec, le fichier reste, pour le prochain essai.
  [ "$frc" != 0 ] || rm -f "$ROOT/.baluchon-acces" 2>/dev/null || true
  for f in "$ROOT"/config/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ "$frc" != 0 ] && [ "${f##*/}" = remote.conf ]; then continue; fi
    rm -rf "$f" 2>/dev/null || true
  done
  rm -f "$ROOT"/ACTIVE 2>/dev/null || true
  if [ "$prc" != 0 ] && [ "$prc" != 2 ]; then
    CC_WIPE_NOTE="Des identifiants Claude n'ont pas pu être effacés (Trousseau ou fichiers de $ROOT/config)."
  fi
  if [ "$frc" != 0 ]; then
    CC_WIPE_NOTE="${CC_WIPE_NOTE}${CC_WIPE_NOTE:+$'\n'}Des jetons Cloudflare Access restent UTILISABLES sur cet ordinateur (code $frc) :"$'\n'"$(printf '%s\n' "$sortie" | head -n 12)"$'\n'"Supprime-les à la main : fichiers dont le nom finit par « -token » dans ~/.cloudflared."
    return 10
  fi
  [ "$prc" = 0 ] || [ "$prc" = 2 ] || return 1
  return "$prc"
}

# ─── Un seul lien chez le client ────────────────────────────────────────────────────────────
# Le lien d'installation (install.sh, ou l'amorce de l'atelier) doit se suffire à lui-même : installer,
# se reconnaître déjà installé et à jour, ouvrir le menu, et permettre d'en PARTIR sans rien laisser.
# Tout ce qui suit est partagé par install.sh, l'amorce et Claude.command, pour n'avoir qu'une
# définition de « installé », de « à jour » et de « ce qui reste » (tests : scripts/lien-unique.test.sh
# et scripts/depart.test.sh).

# 0 si $1 (défaut : ROOT) se déclare une installation de Baluchon : marqueur ordinaire (pas un lien)
# dont la première ligne est « baluchon-install 1 ». Même jugement que uninstall.sh, qui reste la
# SEULE autorité pour effacer ; ici il ne sert qu'à décider quoi PROPOSER (« Partir » n'existe pas sur
# une clé sans marqueur) et à reconnaître une installation.
cc_est_installation() {
  local d="${1:-$ROOT}"
  [ -d "$d" ] && [ ! -L "$d/.baluchon-install" ] && [ -f "$d/.baluchon-install" ] \
    && [ "$(head -n 1 "$d/.baluchon-install" 2>/dev/null)" = "baluchon-install 1" ]
}

# Étiquette INFORMATIVE de la release (« v3.0.0 » si CCP_DL en désigne une, sinon « latest »). Elle ne
# décide de rien : l'identité d'une release est l'empreinte de son SHA256SUMS signé.
cc_release_tag() {
  case "$CCP_DL" in
    */releases/download/*) printf '%s' "${CCP_DL##*/}" ;;
    *) printf 'latest' ;;
  esac
}

# Note, EN DERNIER (après une installation ou une mise à jour complète), quelle release est posée : le
# fichier .baluchon-release porte l'empreinte du SHA256SUMS dont la signature vient d'être vérifiée.
# WHY l'empreinte et non un numéro de version : aucune version à deviner, et deux releases qui diffèrent
# d'un seul octet de n'importe quel actif ne se confondent jamais. $1 = SHA256SUMS authentifié.
cc_release_noter() {
  local sums="$1" h tag tmp
  h="$(cc_sha256 "$sums")"; [ -n "$h" ] || return 1
  tag="$(cc_release_tag | tr -c 'A-Za-z0-9._+-' '_')"
  tmp="$ROOT/.baluchon-release.$$"
  printf 'baluchon-release 1\nsums %s\ntag %s\n' "$h" "$tag" > "$tmp" && mv -f "$tmp" "$ROOT/.baluchon-release"
}

# Cette installation est-elle EXACTEMENT celle de la release dont $1 (SHA256SUMS authentifié) est la
# liste ? Oui seulement si le marqueur d'installation est valide, si le relevé .baluchon-release porte
# l'empreinte de $1, si chaque fichier posé (menu, bibliothèque, désinstalleur, noyau) a l'empreinte
# que la release signe, et si le binaire Claude, sa version et gum sont là. Fail-closed : au moindre doute,
# non, et l'installeur refait tout (il ne perd rien à refaire). Suppose cc_detect_platform déjà joué.
cc_release_a_jour() {
  local sums="$1" st="$ROOT/.baluchon-release" paire nom f want
  cc_est_installation "$ROOT" || return 1
  [ -f "$st" ] && [ ! -L "$st" ] && [ "$(head -n 1 "$st" 2>/dev/null)" = "baluchon-release 1" ] || return 1
  [ "$(awk '$1=="sums"{print $2; exit}' "$st" 2>/dev/null)" = "$(cc_sha256 "$sums")" ] || return 1
  for paire in "Claude.command:Claude.command" "common.sh:lib/common.sh" "uninstall.sh:uninstall.sh" \
               "baluchon-core-$CORE_PLAT$EXE:bin/$CORE_PLAT/baluchon-core$EXE"; do
    nom="${paire%%:*}"; f="$ROOT/${paire#*:}"
    want="$(cc_sum_for "$sums" "$nom")"
    if [ -z "$want" ]; then
      # Une release sans désinstalleur (anciennes) n'en exige pas ; tout autre actif manquant = non.
      [ "$nom" = uninstall.sh ] && continue
      return 1
    fi
    [ -f "$f" ] && [ "$(cc_sha256 "$f")" = "$want" ] || return 1
  done
  # Le binaire Claude, sa version et l'interface (sans gum, le menu n'existe pas : mieux vaut retenter).
  [ -f "$ROOT/bin/$PLAT/$BINNAME" ] && [ -s "$ROOT/VERSION" ] && [ -f "$ROOT/tools/gum/$PLAT/gum$EXE" ]
}

# Nom d'hôte DNS sûr (même règle que le noyau : jamais de tiret ni de point en tête, rien hors
# lettres, chiffres, point, tiret).
cc_hote_valide() {
  case "$1" in ''|-*|.*|*.|*..*|*[!A-Za-z0-9.-]*) return 1 ;; esac
  [ "${#1}" -le 253 ]
}

# Hôtes dont l'AMORCE a signalé que des jetons Cloudflare Access ont pu rester (fichier .baluchon-acces :
# un nom d'hôte par ligne, jamais un jeton). Ils ne sont pas dans config/remote.conf, donc le
# `forget-access` sans argument ne les verrait jamais. Un nom invalide est ignoré.
cc_acces_hotes_notes() {
  local f="$ROOT/.baluchon-acces" h
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  while IFS= read -r h || [ -n "$h" ]; do
    h="${h%$'\r'}"
    if cc_hote_valide "$h"; then printf '%s\n' "$h"; fi
  done < "$f" | sort -u
}

# Tous les hôtes d'accès connus de ce portable : celui de config/remote.conf (même syntaxe que le noyau :
# « host = valeur », guillemets facultatifs) et ceux de .baluchon-acces. Un par ligne, sans doublon.
cc_acces_hotes() {
  local f="$ROOT/config/remote.conf" l k v
  {
    if [ -f "$f" ]; then
      while IFS= read -r l || [ -n "$l" ]; do
        l="${l%$'\r'}"
        case "$l" in \#*) continue ;; *=*) ;; *) continue ;; esac
        k="${l%%=*}"; v="${l#*=}"
        k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
        [ "$k" = host ] || continue
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
        if cc_hote_valide "$v"; then printf '%s\n' "$v"; fi
      done < "$f"
    fi
    cc_acces_hotes_notes
  } | sort -u
}

# La commande à taper pour rouvrir le menu : « baluchon » si ~/.local/bin est dans le PATH, sinon son
# chemin complet, sinon celui du menu lui-même. $1 = chemin de Claude.command.
cc_commande_menu() {
  local b="$HOME/.local/bin/baluchon"
  [ -x "$b" ] || { printf '%s' "$1"; return 0; }
  case ":$PATH:" in *":$HOME/.local/bin:"*) printf 'baluchon' ;; *) printf '%s' "$b" ;; esac
}

# Ouvre le menu depuis le lien d'installation. $1 = chemin de Claude.command. Rend le code de sortie du
# menu (0 : fermé normalement ; autre : « Partir » incomplet, voir cc_depart), ou 0 sans terminal.
# WHY un ENFANT et non `exec` : l'appelant a des nettoyages à faire quand le menu se ferme (l'amorce
# efface ses jetons Access et son dossier de travail). WHY /dev/tty : avec `curl … | bash`, l'entrée
# standard est le script lui-même ; le menu doit lire le clavier. Sans terminal (cron, SSH sans -t,
# agent), il n'y a rien à ouvrir : on dit la commande à taper, et ce n'est pas une erreur.
# CC_TTY remplace /dev/tty (essais : un fichier).
cc_open_menu() {
  local cmd="$1" tty="${CC_TTY:-/dev/tty}" rc=0
  [ -x "$cmd" ] || { cc_warn "Menu introuvable ($cmd)."; return 1; }
  if [ -r "$tty" ] && [ -w "$tty" ] && ( : < "$tty" ) 2>/dev/null; then
    # shellcheck disable=SC2094  # le terminal est lu ET écrit : c'est le but
    BALUCHON_DEPUIS_LIEN=1 "$cmd" < "$tty" >> "$tty" 2>&1 || rc=$?
    return "$rc"
  fi
  cc_info "Pas de terminal ici pour ouvrir le menu. Pour l'ouvrir, tape :  $(cc_commande_menu "$cmd")"
  return 0
}

# ── Partir : tout effacer et désinstaller ──────────────────────────────────────────────────
# Relevé de ce qu'il faudra chercher, fait AVANT d'effacer : une fois le dossier parti, plus rien ne dit
# quel item du Trousseau ni quel hôte regarder. Pose CC_DEP_DIRS (le chemin du dossier tel que le menu le
# connaît, et son chemin canonique s'il diffère : un lien mène au même dossier), CC_DEP_SERVICES (items
# Trousseau macOS : un par config/<profil>, pour chacun des deux chemins, puisque Claude suffixe le nom du
# service d'après le chemin qu'on lui donne) et CC_DEP_HOTES. Une valeur par ligne.
cc_depart_releve() {
  local real d cfg base
  CC_DEP_DIRS="$ROOT"
  real="$(cd -P -- "$ROOT" 2>/dev/null && pwd -P)"
  if [ -n "$real" ] && [ "$real" != "$ROOT" ]; then CC_DEP_DIRS="$CC_DEP_DIRS"$'\n'"$real"; fi
  CC_DEP_SERVICES=""
  if [ "${CC_OS:-}" = darwin ]; then
    for d in "$ROOT"/config/*/; do
      [ -d "$d" ] || continue
      cfg="${d%/}"; base="${cfg##*/}"
      CC_DEP_SERVICES="$CC_DEP_SERVICES"$'\n'"Claude Code-credentials-$(printf '%s' "$cfg" | shasum -a 256 | cut -c1-8)"
      if [ -n "$real" ] && [ "$real" != "$ROOT" ]; then
        CC_DEP_SERVICES="$CC_DEP_SERVICES"$'\n'"Claude Code-credentials-$(printf '%s' "$real/config/$base" | shasum -a 256 | cut -c1-8)"
      fi
    done
  fi
  CC_DEP_HOTES="$(cc_acces_hotes)"
}

# Relit le DISQUE (jamais le code retour d'un effacement) et dit ce qui reste de ce que cc_depart_releve
# a relevé : le dossier, les commandes de ~/.local/bin qui y mènent, les items du Trousseau, les jetons
# Cloudflare Access (seulement si un hôte était connu : sans hôte, rien ne dit qu'il y en a). Écrit
# CC_DEPART_RESTE (une ligne par reste) ; rend 0 si rien ne reste, 1 sinon. N'écrit nulle part : un
# journal recréé ici serait lui-même un reste.
cc_depart_verifie() {
  local p n f s h nom re lignes="" cf="$HOME/.cloudflared" nl=$'\n'
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$p" ] || [ -L "$p" ]; then lignes="${lignes}Le dossier $p est encore là.$nl"; fi
  done <<< "$CC_DEP_DIRS"
  for n in baluchon baluchon1 ccp ccp1; do
    f="$HOME/.local/bin/$n"
    { [ -f "$f" ] || [ -L "$f" ]; } || continue
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if grep -qF "$p/Claude.command" "$f" 2>/dev/null; then lignes="${lignes}La commande $f lance encore Baluchon.$nl"; break; fi
    done <<< "$CC_DEP_DIRS"
  done
  if [ "${CC_OS:-}" = darwin ] && command -v security >/dev/null 2>&1; then
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if security find-generic-password -s "$s" >/dev/null 2>&1; then lignes="${lignes}Trousseau : l'item « $s » est encore là.$nl"; fi
    done <<< "$CC_DEP_SERVICES"
  fi
  if [ -n "$CC_DEP_HOTES" ] && [ -d "$cf" ]; then
    for f in "$cf"/*; do
      { [ -e "$f" ] || [ -L "$f" ]; } || continue
      nom="${f##*/}"
      if [[ "$nom" =~ ^[A-Za-z0-9-]+[.]cloudflareaccess[.]com-org-token([.]lock)?$ ]]; then
        lignes="${lignes}Jeton Cloudflare Access : $cf/$nom est encore là.$nl"; continue
      fi
      while IFS= read -r h; do
        [ -n "$h" ] || continue
        re="^${h//./[.]}-[0-9a-fA-F]{32,}-token([.]lock)?\$"
        if [[ "$nom" =~ $re ]]; then lignes="${lignes}Jeton Cloudflare Access : $cf/$nom est encore là.$nl"; break; fi
      done <<< "$CC_DEP_HOTES"
    done
  fi
  CC_DEPART_RESTE="$lignes"
  [ -z "$lignes" ]
}

# Efface tout ce que Baluchon a posé sur cet ordinateur : sessions et jetons (cc_wipe), puis le dossier et
# les commandes (uninstall.sh, l'UNIQUE endroit où vivent les gardes du chemin à effacer : marqueur,
# domicile, ancêtres, identité du dossier). On l'exécute depuis une COPIE vérifiée (cmp + bash -n) dans un
# dossier privé : le dossier qu'on efface contient le script, et un script bash lu pendant qu'on supprime
# son fichier est un piège. Sans interface, sans question : la confirmation est celle du menu.
# Code de sortie (le détail de ce qui reste est dans CC_DEPART_RESTE et CC_DEPART_NOTE) :
#   0 = rien ne reste, relu sur le disque ; 14 = rien n'a été fait (désinstalleur absent ou altéré) ;
#   2, 10, 11, 12 = codes d'uninstall.sh (refusé, jetons Access, purge incomplète, dossier non supprimé) ;
#   2 aussi si cc_wipe a vu une session Claude encore ouverte ; 1, 10 = codes de cc_wipe quand le
#   désinstalleur n'a pas pu les corriger ; 13 = il reste quelque chose que personne n'avait signalé.
# AUCUN cc_log ici ni après : il recréerait ROOT/logs dans le dossier qu'on vient d'effacer.
cc_depart() {
  local un="$ROOT/uninstall.sh" tmpd copie wrc=0 urc=0 code=0 reste=0
  CC_DEPART_NOTE=""; CC_DEPART_RESTE=""
  cc_est_installation "$ROOT" && [ -f "$un" ] && [ ! -L "$un" ] \
    || { CC_DEPART_NOTE="Le désinstalleur ($un) est absent : rien n'a été effacé."; return 14; }
  tmpd="$(mktemp -d)" || { CC_DEPART_NOTE="Dossier temporaire impossible : rien n'a été effacé."; return 14; }
  chmod 700 "$tmpd"
  copie="$tmpd/uninstall.sh"
  if ! { cp "$un" "$copie" && cmp -s "$un" "$copie" && bash -n "$copie" 2>/dev/null; }; then
    rm -rf "$tmpd"
    CC_DEPART_NOTE="Le désinstalleur n'a pas pu être copié intact : rien n'a été effacé."; return 14
  fi
  cc_depart_releve
  cc_wipe || wrc=$?
  CC_DEPART_NOTE="${CC_WIPE_NOTE:-}"
  # Le dossier courant ne doit pas être celui qu'on supprime.
  cd / 2>/dev/null || true
  BALUCHON_DIR="$ROOT" bash "$copie" --oui < /dev/null > /dev/null || urc=$?
  rm -rf "$tmpd"
  # Le disque relu fait foi : le désinstalleur refait lui-même la purge et l'oubli des jetons, donc un
  # échec de cc_wipe suivi d'une désinstallation complète n'est plus un échec. Ce que le disque ne voit
  # pas (une session Claude encore ouverte, qui peut réécrire ses identifiants) vient des codes 2 et 11.
  cc_depart_verifie || reste=1
  if [ "$urc" != 0 ]; then code="$urc"
  elif [ "$reste" = 1 ]; then
    case "$wrc" in 1|10) code="$wrc" ;; *) code=13 ;; esac
  elif [ "$wrc" = 2 ]; then code=2
  fi
  return "$code"
}
