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

# ─── Écriture atomique qui ne suit jamais un lien ────────────────────────────────────────────
# cc_ecrire <destination> : écrit l'ENTRÉE STANDARD dans <destination>, par un fichier temporaire du MÊME dossier
# puis un renommage. WHY (revue Codex, 4e passe) : `cp src dst.new && mv dst.new dst` écrivait dans un nom
# PRÉVISIBLE ; qui pouvait écrire dans le dossier y posait `dst.new -> ~/Documents/these.txt`, `cp` suivait le
# lien et écrasait le document, puis `mv` posait le lien sur `dst`. Ici :
#   - le nom du temporaire est imprévisible ($$ + trois $RANDOM) ;
#   - il est ouvert en O_EXCL (`set -C` : le shell refuse d'ouvrir un fichier ou un lien qui existe déjà, même
#     pendant), et les octets partent par CE descripteur : le chemin n'est pas rouvert après sa création ;
#   - rien n'est écrit dans <destination> : `mv` la REMPLACE (si c'est un lien, c'est le lien qui disparaît) ;
#   - un dossier à la place de <destination> est refusé (`mv` y descendrait le fichier).
# Droits du fichier créé : ceux du umask de l'appelant, comme un `>` ordinaire (les exécutables reçoivent leur
# `chmod +x` après coup). Limite assumée : un autre compte qui peut écrire dans le dossier ET qui lit le nom du
# temporaire pendant sa courte vie pourrait encore l'échanger ; il faudrait openat/renameat (Rust). Ce qui est
# fermé : le lien posé d'avance à un nom que l'on peut deviner.
# Rend 1 sans rien laisser derrière lui si quoi que ce soit échoue.
cc_ecrire() {
  local dst="$1" d tmp rc
  case "$dst" in */*) d="${dst%/*}"; [ -n "$d" ] || d=/ ;; *) d=. ;; esac
  [ -d "$d" ] && [ ! -d "$dst" ] || return 1
  tmp="$d/.baluchon-pose.$$.$RANDOM$RANDOM$RANDOM"
  # 97 = l'ouverture O_EXCL a échoué : le fichier n'est pas à nous, on n'y touche pas.
  rc=0; ( set -C; exec 3> "$tmp" || exit 97; cat >&3 ) 2>/dev/null || rc=$?
  [ "$rc" != 97 ] || return 1
  if [ "$rc" = 0 ] && mv -f -- "$tmp" "$dst" 2>/dev/null; then return 0; fi
  rm -f -- "$tmp"
  return 1
}
# cc_poser <source> <destination> : cc_ecrire du contenu d'un fichier ordinaire.
cc_poser() { [ -f "$1" ] || return 1; cc_ecrire "$2" < "$1"; }

# ─── Références authentifiées ───────────────────────────────────────────────────────────────
# RÈGLE (revue Codex, 2e passe) : aucun octet n'est exécuté, ni même sondé (`--version`, `--contract`,
# `about` sont des exécutions), avant d'avoir été comparé à une empreinte AUTHENTIFIÉE, sur une installation
# posée par l'installeur (marqueur .baluchon-install). Deux sources d'empreintes :
#   - le manifeste SIGNÉ de la release, conservé dans ROOT/.baluchon-sums + .baluchon-sums.sig : menu,
#     bibliothèque, désinstalleur, noyau public (cc_sum_signee) ;
#   - ROOT/.baluchon-refs (« <sha256>  <chemin relatif à ROOT> ») pour ce que ce manifeste ne couvre pas :
#     le binaire Claude (vérifié contre le manifeste officiel), gum (archive vérifiée contre l'empreinte
#     épinglée) et le noyau de la couche (sommes signées de la couche, vérifiées par l'amorce). Une ligne
#     n'est écrite qu'APRÈS que l'empreinte a été vérifiée à la source.
# Honnêteté sur ce que ça protège : .baluchon-refs est écrit avec les droits de l'utilisateur. Il écarte un
# fichier remplacé SEUL (corruption, remplacement partiel, gum ou claude échangé) ; il n'arrête pas qui
# réécrit toute l'installation avec ces mêmes droits (celui-là n'a pas besoin de nos fichiers pour agir).
# Une clé portable préparée à la main (sans marqueur) n'a ni manifeste ni références : comportement d'avant.
cc_strict() { cc_est_installation "$ROOT"; }

# Empreinte notée pour $1 (chemin relatif à ROOT) ; vide si aucune.
cc_ref_get() {
  local f="$ROOT/.baluchon-refs"
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  awk -v p="$1" '$2==p {print $1; exit}' "$f"
}
# Note l'empreinte $2 (64 hexadécimaux) de $1, en remplaçant l'ancienne ; écriture atomique.
cc_ref_set() {
  local f="$ROOT/.baluchon-refs" old=""
  case "$2" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#2}" = 64 ] || return 1
  if [ -f "$f" ] && [ ! -L "$f" ]; then old="$(awk -v p="$1" '$2!=p' "$f" 2>/dev/null)" || return 1; fi
  # cc_ecrire : jamais d'écriture à un nom prévisible (un `.baluchon-refs.<pid>` lié ailleurs était suivi).
  { [ -z "$old" ] || printf '%s\n' "$old"; printf '%s  %s\n' "$2" "$1"; } | cc_ecrire "$f"
}
cc_ref_drop() {
  local f="$ROOT/.baluchon-refs" old
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  old="$(awk -v p="$1" '$2!=p' "$f" 2>/dev/null)" || return 1
  { [ -z "$old" ] || printf '%s\n' "$old"; } | cc_ecrire "$f"
}
# Déplace la note de $1 vers $2 (le fichier vient d'être renommé) ; sans note pour $1, $2 n'en a plus.
cc_ref_move() {
  local h; h="$(cc_ref_get "$1")"
  if [ -n "$h" ]; then cc_ref_set "$2" "$h" || true; else cc_ref_drop "$2" || true; fi
  cc_ref_drop "$1" || true
}
# $1 (relatif à ROOT) est-il un fichier ordinaire (pas un lien) qui a EXACTEMENT l'empreinte notée ?
cc_ref_ok() {
  local want; want="$(cc_ref_get "$1")"
  [ -n "$want" ] && [ -f "$ROOT/$1" ] && [ ! -L "$ROOT/$1" ] && [ "$(cc_sha256 "$ROOT/$1")" = "$want" ]
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

# Le manifeste signé que l'installation a CONSERVÉ (ROOT/.baluchon-sums + .sig), relu sur stdout APRÈS
# avoir vérifié sa signature avec la clé épinglée dans cette bibliothèque. Les deux fichiers sont d'abord
# copiés dans un dossier privé et la signature est vérifiée SUR LA COPIE, que l'on relit ensuite : un
# fichier échangé entre la vérification et la lecture ne passe jamais. Rend 1 (et rien sur stdout) si
# l'un manque, est un lien, ou n'est pas signé par cette clé.
# WHY : « Partir » exécute le désinstalleur du dossier qu'il efface, et le menu exécute le noyau ; leur
# empreinte doit venir d'une liste que personne ne peut avoir réécrite sans la clé privée du produit.
# Niveau de confiance (à dire en clair) : la clé qui vérifie est celle de CETTE bibliothèque, déjà vérifiée
# à l'installation ; c'est le même niveau que le menu lui-même.
cc_sums_signees() {
  local d sk rc=1
  sk="$(command -v ssh-keygen 2>/dev/null)"; [ -n "$sk" ] || return 1
  { [ -f "$ROOT/.baluchon-sums" ] && [ ! -L "$ROOT/.baluchon-sums" ] \
    && [ -f "$ROOT/.baluchon-sums.sig" ] && [ ! -L "$ROOT/.baluchon-sums.sig" ]; } || return 1
  d="$(mktemp -d)" || return 1
  chmod 700 "$d" 2>/dev/null || true
  if cp "$ROOT/.baluchon-sums" "$d/SHA256SUMS" && cp "$ROOT/.baluchon-sums.sig" "$d/SHA256SUMS.sig" \
     && printf '%s\n' "$CCP_SIGNER" > "$d/allowed_signers" \
     && "$sk" -Y verify -f "$d/allowed_signers" -I "$CCP_SIGNER_ID" -n file -s "$d/SHA256SUMS.sig" < "$d/SHA256SUMS" >/dev/null 2>&1; then
    cat "$d/SHA256SUMS"; rc=0
  fi
  rm -rf "$d"
  return "$rc"
}
# Empreinte signée de $1 (nom publié) dans ce manifeste conservé ; vide et code 1 si le manifeste n'est pas
# authentique ou ne porte pas ce nom.
cc_sum_signee() {
  local m h
  m="$(cc_sums_signees)" || return 1
  h="$(printf '%s\n' "$m" | awk -v n="$1" '$2==n || $2=="*"n {print $1; exit}')"
  [ -n "$h" ] || return 1
  printf '%s' "$h"
}

# ─── Binaire Claude Code ────────────────────────────────────────────────
# Empreinte d'une plateforme dans le manifest officiel. Les objets plateforme du
# manifest n'ont pas d'accolade imbriquée (vérifié 09/11/2026), d'où le grep.
cc_manifest_sha() {
  printf '%s' "$1" | tr -d ' \n\t\r' | grep -o "\"$2\":{[^}]*}" | grep -o '"checksum":"[0-9a-f]*"' | head -1 | cut -d'"' -f4
}

# Télécharge le binaire d'une plateforme et vérifie le SHA256 du manifest officiel.
cc_download_binary() {
  local plat="$1" binname="$2" ver dir out manifest sha w
  ver="$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null)"; [ -n "$ver" ] || ver=stable
  [ "$ver" = stable ] && ver="$(curl -fsSL "$CC_RELEASES/stable")"
  [ -n "$ver" ] || cc_die "Version de Claude introuvable (pas de réseau ?)"
  dir="$ROOT/bin/$plat"; mkdir -p "$dir"; out="$dir/$binname"
  # Téléchargé ET vérifié dans un dossier PRIVÉ (0700) : le nom `.claude.part` posé d'avance dans bin/<plat>
  # (un lien vers un document) était suivi par curl. Le binaire n'entre dans l'installation que vérifié,
  # par cc_poser (renommage, jamais d'écriture dans un nom connu), puis son empreinte est revérifiée posé.
  w="$(mktemp -d)" || cc_die "Dossier temporaire impossible."
  cc_info "Téléchargement de Claude Code $ver pour $plat ..."
  manifest="$(curl -fsSL "$CC_RELEASES/$ver/manifest.json")" || { rm -rf "$w"; cc_die "Manifest injoignable (pas de réseau ?)"; }
  sha="$(cc_manifest_sha "$manifest" "$plat")"
  curl -fsSL "$CC_RELEASES/$ver/$plat/$binname" -o "$w/$binname" || { rm -rf "$w"; cc_die "Téléchargement échoué pour $plat"; }
  cc_check_sha "$w/$binname" "$sha" || { rm -rf "$w"; cc_die "Binaire $plat non vérifié : refusé."; }
  cc_poser "$w/$binname" "$out" || { rm -rf "$w"; cc_die "Pose de $binname impossible ($out)."; }
  rm -rf "$w"
  [ "$(cc_sha256 "$out")" = "$sha" ] || { rm -f "$out"; cc_die "Binaire $plat modifié pendant sa pose : refusé."; }
  chmod +x "$out" 2>/dev/null || true
  printf '%s' "$ver" | cc_ecrire "$ROOT/VERSION" || cc_warn "VERSION non écrite."
  # La référence authentifiée : l'empreinte que le manifeste officiel vient de confirmer (cc_check_sha).
  cc_ref_set "bin/$plat/$binname" "$sha" || cc_warn "Référence de $binname non notée : elle sera revérifiée au prochain lancement."
  cc_ok "Claude $ver ($plat) vérifié (SHA256 OK)"
}

# Note, pour « Partir », un dossier de copies d'exécution créé par cc_runnable : ROOT/.baluchon-cache en
# garde la liste (un chemin absolu par ligne, sans doublon), précédée, la première fois qu'une base sert, d'une
# ligne « base <cache>/baluchon ». WHY (revue Codex, 4e passe, constat 8) : XDG_CACHE_HOME peut changer entre
# deux lancements ; « Partir » jugeait les entrées selon sa valeur du JOUR et laissait, sans le dire, les copies
# rangées sous l'ancienne. Une ligne « base » n'est pas un chemin absolu : les lecteurs d'avant l'ignorent.
# Sans effet hors installation.
cc_cache_noter() {
  local f="$ROOT/.baluchon-cache" base ne=0 nb=0
  cc_strict || return 0
  [ ! -L "$f" ] || return 0
  base="$(cc_cache_base)"
  if [ -f "$f" ]; then
    if grep -qxF -- "$1" "$f" 2>/dev/null; then ne=1; fi
    if grep -qxF -- "base $base" "$f" 2>/dev/null; then nb=1; fi
  fi
  if [ "$ne$nb" = 11 ]; then return 0; fi
  # Ajout par réécriture atomique (jamais un `>>` sur un nom que quelqu'un a pu lier ailleurs).
  {
    if [ -f "$f" ]; then cat "$f"; fi
    if [ "$nb" = 0 ]; then printf 'base %s\n' "$base"; fi
    if [ "$ne" = 0 ]; then printf '%s\n' "$1"; fi
  } 2>/dev/null | cc_ecrire "$f" || true
}

# Rend exécutable un binaire du portable ; sur une clé exFAT montée noexec,
# copie unique dans le cache local de la machine. $1 = chemin, $2 = clé de cache, $3 = empreinte attendue.
# Écrit le chemin exécutable sur stdout.
# Sur une installation (cc_strict), RIEN n'est exécuté, pas même `--version`, avant que ce qui va l'être
# ait l'empreinte attendue : le fichier lui-même, et la COPIE en cache (c'est elle qu'on lance, pas
# l'original). Une empreinte attendue vide refuse (fail-closed). Hors installation, comme avant.
cc_runnable() {
  local f="$1" key="$2" want="${3:-}" cache c strict=0
  cc_strict && strict=1
  if [ "$strict" = 1 ]; then cc_check_sha "$f" "$want" || return 1; fi
  chmod +x "$f" 2>/dev/null || true
  if "$f" --version >/dev/null 2>&1; then printf '%s' "$f"; return 0; fi
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/baluchon/$key"
  mkdir -p "$cache" 2>/dev/null || return 1
  c="$cache/$(basename "$f")"
  if [ "$strict" = 1 ]; then
    if [ ! -x "$c" ] || [ "$(cc_sha256 "$c")" != "$want" ]; then
      cc_info "Clé montée sans exécution : copie de $(basename "$f") en cache local ($cache)"
      cp "$f" "$cache/" && chmod +x "$c" || return 1
      [ "$(cc_sha256 "$c")" = "$want" ] || { rm -f "$c"; cc_warn "La copie en cache de $(basename "$f") n'a pas l'empreinte attendue : refus."; return 1; }
    fi
    cc_cache_noter "$cache"
  elif [ ! -x "$c" ] || ! cmp -s "$f" "$c"; then
    cc_info "Clé montée sans exécution : copie de $(basename "$f") en cache local ($cache)"
    cp "$f" "$cache/" && chmod +x "$c" || return 1
  fi
  "$c" --version >/dev/null 2>&1 || return 1
  printf '%s' "$c"
}

# Garantit un binaire Claude exécutable. -> BIN
# Sur une installation, son empreinte doit être celle NOTÉE quand il a été vérifié contre le manifeste
# officiel (cc_ref_get). Sans note (installation d'avant cette règle), seule autorité : ce manifeste, relu
# pour la version posée ; une empreinte qui ne correspond à rien fait RETÉLÉCHARGER (vérifié), jamais
# exécuter. Hors ligne et sans note : refus, dit.
cc_ensure_binary() {
  local raw="$ROOT/bin/$PLAT/$BINNAME" rel="bin/$PLAT/$BINNAME" ver want="" manifest sha
  [ -f "$raw" ] || cc_download_binary "$PLAT" "$BINNAME"
  if cc_strict; then
    want="$(cc_ref_get "$rel")"
    if [ -z "$want" ]; then
      ver="$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null)"
      manifest=""; [ -z "$ver" ] || manifest="$(curl -fsSL -m 20 "$CC_RELEASES/$ver/manifest.json" 2>/dev/null)" || manifest=""
      sha="$(cc_manifest_sha "$manifest" "$PLAT")"
      if [ -n "$sha" ] && [ "$(cc_sha256 "$raw")" = "$sha" ]; then
        cc_ref_set "$rel" "$sha" || true; want="$sha"
      elif [ -z "$manifest" ]; then
        cc_die "Le binaire Claude n'a pas pu être authentifié (hors ligne, aucune référence notée) : reconnecte-toi une fois, ou relance l'installation."
      fi
    fi
    # Le fichier est comparé (et seulement alors sondé) par cc_runnable : une seule lecture de ce gros fichier.
    ver="$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null || echo unknown)"
    if [ -n "$want" ] && BIN="$(cc_runnable "$raw" "$ver/$PLAT" "$want" 2>/dev/null)"; then return 0; fi
    cc_warn "Le binaire Claude ne correspond à aucune empreinte vérifiée : il est retéléchargé et revérifié."
    rm -f "$raw"; cc_download_binary "$PLAT" "$BINNAME"
    want="$(cc_ref_get "$rel")"
  fi
  ver="$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null || echo unknown)"
  BIN="$(cc_runnable "$raw" "$ver/$PLAT" "$want")" || cc_die "Impossible d'exécuter le binaire claude"
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
  local g="$ROOT/tools/gum/$PLAT/gum$EXE" os arch tmp b asset h rel="tools/gum/$PLAT/gum$EXE"
  CC_GUM="$g"
  if [ -f "$g" ]; then
    # Sur une installation, gum n'est gardé que s'il a l'empreinte notée quand son archive a été vérifiée
    # (empreinte épinglée) : un gum remplacé SEUL ne s'exécute jamais, il est retéléchargé.
    if ! cc_strict || cc_ref_ok "$rel"; then chmod +x "$g" 2>/dev/null || true; return 0; fi
    rm -f "$g"
    cc_ref_drop "$rel" || true
  fi
  case "$CC_OS" in darwin) os=Darwin;; linux) os=Linux;; win32) os=Windows;; *) return 1;; esac
  case "$CC_ARCH" in arm64) arch=arm64;; x64) arch=x86_64;; *) return 1;; esac
  [ "$CC_OS" = win32 ] && arch=x86_64
  mkdir -p "$ROOT/tools/gum/$PLAT"
  tmp="$(mktemp -d)"
  cc_info "Téléchargement de l'interface gum ($CC_GUM_VER, $PLAT)…"
  # TOUT se passe dans le dossier privé $tmp (0700) : l'archive est vérifiée, le binaire en est extrait, et c'est
  # SUR CE BINAIRE EXTRAIT que l'empreinte de référence est calculée (revue Codex, 4e passe : elle l'était sur
  # $g déjà posé dans l'installation, qu'un autre processus pouvait avoir remplacé entre la copie et le calcul,
  # et l'installeur notait alors lui-même l'empreinte du faux). Le binaire est ensuite posé par renommage
  # (cc_poser) et le fichier POSÉ doit avoir exactement l'empreinte calculée, sinon il est retiré.
  b=""
  if [ "$CC_OS" = win32 ]; then
    asset="gum_${CC_GUM_VER}_${os}_${arch}.zip"
    mkdir -p "$tmp/x" \
      && curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${CC_GUM_VER}/$asset" -o "$tmp/g.zip" \
      && cc_check_sha "$tmp/g.zip" "$(cc_gum_sha "${os}_${arch}")" \
      && ( cd "$tmp/x" && unzip -o -j "$tmp/g.zip" '*gum.exe' >/dev/null 2>&1 ) \
      && b="$tmp/x/gum.exe" && [ -f "$b" ] || b=""
  else
    asset="gum_${CC_GUM_VER}_${os}_${arch}.tar.gz"
    curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${CC_GUM_VER}/$asset" -o "$tmp/g.tgz" \
      && cc_check_sha "$tmp/g.tgz" "$(cc_gum_sha "${os}_${arch}")" \
      && tar xzf "$tmp/g.tgz" -C "$tmp" && b="$(find "$tmp" -type f -name gum | head -1)" && [ -n "$b" ] || b=""
  fi
  if [ -n "$b" ]; then
    h="$(cc_sha256 "$b")"
    if [ -n "$h" ] && cc_poser "$b" "$g" && chmod +x "$g" && [ "$(cc_sha256 "$g")" = "$h" ]; then
      cc_ref_set "$rel" "$h" || { rm -f "$g"; b=""; }
    else
      rm -f "$g"; b=""
    fi
  fi
  rm -rf "$tmp"
  [ -n "$b" ] || return 1
  # Sur une installation, gum n'est jamais « présent donc bon » : un gum recréé pendant que le téléchargement
  # échouait (ou posé d'avance) n'a pas l'empreinte notée, donc n'est pas accepté.
  if cc_strict; then cc_ref_ok "$rel"; else [ -f "$CC_GUM" ]; fi
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
      if cc_poser "$w/$name" "$ROOT/bin/$CORE_PLAT/baluchon-core$EXE" && [ "$(cc_sha256 "$ROOT/bin/$CORE_PLAT/baluchon-core$EXE")" = "$sha" ]; then
        chmod +x "$ROOT/bin/$CORE_PLAT/baluchon-core$EXE" 2>/dev/null || true
        rm -rf "$w"; cc_ok "Noyau baluchon-core vérifié (signature + SHA256)"; return 0
      fi
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
  local name raw c about why="" want=""
  CC_LAYER_CORE=""; CC_LAYER_NOTE=""; CC_CORE_WANT=""
  [ -n "${CC_LAYER_DIR:-}" ] || cc_layer_resolve || return 1
  [ -n "${CC_LAYER_DIR:-}" ] || return 1
  name="$(cc_layer_field name)"; [ -n "$name" ] || name="sans nom"
  raw="$CC_LAYER_DIR/bin/$CORE_PLAT/baluchon-core$EXE"
  # Sur une installation, le noyau de la couche n'est sondé que si son empreinte a été NOTÉE par celui qui
  # connaît la clé de la couche (l'amorce de l'atelier, après avoir vérifié les sommes signées de la
  # couche) : ce fichier-ci ne connaît pas cette clé. Sans note : noyau public, et la ligne dit pourquoi.
  if cc_strict; then want="$(cc_ref_get "${raw#"$ROOT"/}")"; fi
  if [ ! -f "$raw" ]; then why="pas de noyau pour $CORE_PLAT"
  elif cc_strict && [ -z "$want" ]; then why="noyau non authentifié"
  elif ! c="$(cc_runnable "$raw" "overlay-core/$CORE_PLAT" "$want")"; then why="noyau non exécutable"
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
  CC_LAYER_CORE="$c"; CC_CORE_WANT="$want"
}

# Appelle un crochet de la couche (`update` ou `uninstall`) s'il existe. Un échec est dit, jamais
# fatal : la mise à jour du public a déjà réussi et la couche garde sa version précédente.
cc_layer_hook() {
  local h="$ROOT/overlay/hooks/$1" rc=0 priv="" want
  [ -f "$h" ] || return 0
  # L'amorce de l'atelier, seule à connaître la clé de la couche, pose BALUCHON_SANS_CROCHET=1 quand elle n'a
  # pas pu authentifier le crochet installé : il n'est alors pas exécuté (elle repose elle-même la couche).
  if [ "${BALUCHON_SANS_CROCHET:-}" = 1 ]; then cc_info "Couche : crochet « $1 » non exécuté (non authentifié)."; return 0; fi
  # Sur une installation, un crochet ne s'exécute que s'il a l'empreinte NOTÉE par celui qui connaît la clé de la
  # couche (l'amorce, après avoir vérifié les sommes signées de la couche) : ce fichier-ci ne la connaît pas, mais
  # il sait refuser un crochet remplacé SEUL. Sans note : non exécuté, dit, jamais fatal.
  # Ce qui est exécuté est une COPIE privée hachée après copie (rien ne peut plus l'échanger entre le contrôle et
  # l'exécution) ; le crochet se recopie lui-même de toute façon (« cp $0 ») : la copie est donc sans effet sur lui.
  if cc_strict; then
    want="$(cc_ref_get "overlay/hooks/$1")"
    priv="$(mktemp -d)" || return 0
    chmod 700 "$priv" 2>/dev/null || true
    if [ -z "$want" ] || [ -L "$h" ] || ! cp "$h" "$priv/hook" || [ "$(cc_sha256 "$priv/hook")" != "$want" ]; then
      rm -rf "$priv"
      cc_warn "Couche : le crochet « $1 » n'a pas d'empreinte authentifiée : non exécuté. Relance le lien d'installation de l'atelier pour le revérifier."
      return 0
    fi
    h="$priv/hook"
  fi
  cc_info "Couche : crochet « $1 »…"
  ( BALUCHON_ROOT="$ROOT" BALUCHON_CORE_PLAT="${CORE_PLAT:-}" BALUCHON_EXE="${EXE:-}" bash "$h" ) || rc=$?
  [ -z "$priv" ] || rm -rf "$priv"
  [ "$rc" = 0 ] || { cc_warn "Le crochet « $1 » de la couche a échoué (code $rc)."; return 1; }
}

cc_ensure_core() {
  local raw="$ROOT/bin/$CORE_PLAT/baluchon-core$EXE" c want=""
  CORE=""; CC_LAYER_NOTE=""; CC_CORE_WANT=""
  # La génération est résolue ICI, une fois : le pointeur n'est plus relu pendant ce choix.
  cc_layer_resolve || true
  if [ -n "${CC_LAYER_DIR:-}" ] && cc_layer_core; then CORE="$CC_LAYER_CORE"; return 0; fi
  [ -f "$raw" ] || cc_download_core || { cc_log "baluchon-core indisponible (téléchargement)"; return 1; }
  # Le noyau public d'une installation : empreinte du manifeste SIGNÉ conservé (cc_sum_signee), jamais la
  # simple présence du fichier. Manifeste absent ou non authentique : pas de noyau (mode dégradé, dit au journal).
  if cc_strict; then
    want="$(cc_sum_signee "baluchon-core-$CORE_PLAT$EXE")" || want=""
    [ -n "$want" ] || { cc_log "baluchon-core non authentifié (manifeste signé absent ou invalide) : mode dégradé"; return 1; }
  fi
  c="$(cc_runnable "$raw" "core/$CORE_PLAT" "$want")" || { cc_log "baluchon-core non exécutable ou empreinte invalide"; return 1; }
  if [ "$("$c" --contract 2>/dev/null | tr -d ' \r\n')" != "$CCP_CONTRACT" ]; then
    cc_log "baluchon-core : contrat inattendu (attendu $CCP_CONTRACT)"; return 1
  fi
  CORE="$c"; CC_CORE_WANT="$want"
}
# Appelle le noyau avec la racine du portable, Ctrl+C rendu à l'enfant (le
# wizard ignore SIGINT pour survivre à un Ctrl+C dans Claude).
# Sur une installation, l'empreinte du noyau est relue AVANT chaque appel (CC_CORE_WANT, posée quand cc_ensure_core
# l'a authentifié) : un noyau remplacé pendant que le menu reste ouvert n'est jamais exécuté. Une lecture
# SHA-256 de quelques Mo ; reste la fenêtre entre cette lecture et l'exécution (voir TECHNICAL.md).
ccp_core() {
  [ -n "${CORE:-}" ] || return 127
  if [ -n "${CC_CORE_WANT:-}" ] && [ "$(cc_sha256 "$CORE")" != "$CC_CORE_WANT" ]; then
    cc_warn "Le noyau a changé depuis son contrôle : non exécuté."; return 126
  fi
  ( trap - INT; "$CORE" --root "$ROOT" "$@" )
}

# Le binaire Claude (BIN) a-t-il TOUJOURS l'empreinte notée quand il a été vérifié ? À jouer juste avant de le
# lancer : le menu reste ouvert longtemps, et le binaire a pu être remplacé entre-temps. Hors installation :
# rien à comparer, 0. Même fenêtre résiduelle que ccp_core.
cc_bin_verifie() {
  local want
  cc_strict || return 0
  want="$(cc_ref_get "bin/$PLAT/$BINNAME")"
  [ -n "$want" ] && [ -n "${BIN:-}" ] && [ "$(cc_sha256 "$BIN")" = "$want" ] \
    || { cc_warn "Le binaire Claude a changé depuis son contrôle : non lancé. Relance le menu pour le revérifier."; return 1; }
}

# ─── Mises à jour ───────────────────────────────────────────────────────
# Dernière version stable de Claude, relevée au plus une fois par jour (bandeau
# « mise à jour disponible » de l'accueil). Écrit la version sur stdout.
cc_claude_stable_cached() {
  local f="$ROOT/.cache/claude-stable" now age v
  now="$(date +%s)"; mkdir -p "$ROOT/.cache" 2>/dev/null || true
  if [ -f "$f" ]; then age=$(( now - $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) )); else age=999999; fi
  if [ "$age" -gt 86400 ]; then
    v="$(curl -fsSL -m 4 "$CC_RELEASES/stable" 2>/dev/null | tr -d ' \r\n')"
    if [ -n "$v" ]; then printf '%s' "$v" | cc_ecrire "$f" 2>/dev/null || true; fi
  fi
  tr -d ' \r\n' < "$f" 2>/dev/null
}

# Met à jour le binaire Claude de CETTE plateforme (+ les autres présentes sur la
# clé), en gardant la version précédente (claude.prev) pour revenir en arrière.
# $1 = canal (stable/latest)
cc_update() {
  local channel="${1:-stable}" ver manifest plat binname sha tmp dst old here_ok=0 placed
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
    # Téléchargé et vérifié dans un dossier PRIVÉ, posé par renommage (cc_poser) : un `.claude.new` lié d'avance
    # dans bin/<plat> n'est plus un chemin d'écriture (revue Codex, 4e passe).
    dst="$ROOT/bin/$plat/$binname"; tmp="$(mktemp -d)" || { cc_warn "$plat : dossier temporaire impossible."; continue; }
    cc_info "MAJ $plat ..."
    if curl -fsSL "$CC_RELEASES/$ver/$plat/$binname" -o "$tmp/$binname" && cc_check_sha "$tmp/$binname" "$sha"; then
      [ -f "$dst" ] && mv -f "$dst" "$dst.prev" && { printf '%s' "${old:-?}" | cc_ecrire "$ROOT/bin/$plat/.prev-version" || true; } \
        && cc_ref_move "bin/$plat/$binname" "bin/$plat/$binname.prev"
      placed=0; cc_poser "$tmp/$binname" "$dst" && placed=1
      if [ "$placed" = 1 ] && [ "$(cc_sha256 "$dst")" = "$sha" ]; then
        rm -rf "$tmp"
        chmod +x "$dst" 2>/dev/null || true; cc_ok "$plat à jour ($ver)"
        # L'empreinte que le manifeste officiel vient de confirmer devient la référence du nouveau binaire.
        cc_ref_set "bin/$plat/$binname" "$sha" || cc_warn "Référence de $plat non notée : elle sera revérifiée au prochain lancement."
        [ "$plat" = "$PLAT" ] && here_ok=1
      else
        # Un binaire posé qui n'a pas l'empreinte vérifiée (échangé pendant la pose) ne reste jamais.
        [ "$placed" != 1 ] || rm -f "$dst"
        # Remise en place de l'ancien binaire : jamais de plateforme sans claude.
        if [ -f "$dst.prev" ] && [ ! -f "$dst" ] && mv -f "$dst.prev" "$dst"; then cc_ref_move "bin/$plat/$binname.prev" "bin/$plat/$binname"; fi
        rm -rf "$tmp"; cc_warn "$plat : installation impossible, ancienne version conservée."
      fi
    else rm -rf "$tmp"; cc_warn "$plat : échec ou empreinte invalide, ancienne version conservée."; fi
  done
  # VERSION décrit le binaire de CETTE plateforme : on ne l'avance que s'il a
  # réellement été remplacé (sinon le bandeau « mise à jour disponible » disparaît
  # alors que l'ancien binaire tourne toujours).
  [ "$here_ok" = 1 ] || { cc_warn "Claude n'a pas été mis à jour sur $PLAT (version ${old:-?} conservée)."; return 1; }
  printf '%s' "$ver" | cc_ecrire "$ROOT/VERSION" || cc_warn "VERSION non écrite."
  rm -f "$ROOT/.cache/claude-stable"
  cc_ok "Claude = $ver"
}

# Revient à la version précédente de Claude (celle gardée par cc_update).
cc_rollback() {
  local dst="$ROOT/bin/$PLAT/$BINNAME" prev ra rb rel="bin/$PLAT/$BINNAME"
  [ -f "$dst.prev" ] || { cc_warn "Aucune version précédente gardée."; return 1; }
  prev="$(tr -d ' \r\n' < "$ROOT/bin/$PLAT/.prev-version" 2>/dev/null)"
  ra="$(cc_ref_get "$rel")"; rb="$(cc_ref_get "$rel.prev")"
  mv -f "$dst" "$dst.rollback-tmp" && mv -f "$dst.prev" "$dst" && mv -f "$dst.rollback-tmp" "$dst.prev"
  # Les références suivent les fichiers : chacune reste attachée au binaire qu'elle a authentifié.
  if [ -n "$rb" ]; then cc_ref_set "$rel" "$rb" || true; else cc_ref_drop "$rel" || true; fi
  if [ -n "$ra" ]; then cc_ref_set "$rel.prev" "$ra" || true; else cc_ref_drop "$rel.prev" || true; fi
  [ -z "$prev" ] || { printf '%s' "$(tr -d ' \r\n' < "$ROOT/VERSION")" | cc_ecrire "$ROOT/bin/$PLAT/.prev-version" || true; printf '%s' "$prev" | cc_ecrire "$ROOT/VERSION" || true; }
  cc_ok "Claude revenu à ${prev:-la version précédente}"
}

# Met à jour le portable lui-même (wizard, bibliothèque, lanceurs Windows, noyau)
# depuis la dernière release signée. Remplacement fichier par fichier, chacun
# vérifié AVANT d'écraser. N'écrit que les fichiers publics et bin/ : jamais overlay/,
# que son propre crochet `update` met à jour (appelé en dernier, même si rien du public
# n'a changé, pour que la couche se recale sur le public qui vient d'arriver).
cc_update_portable() {
  local w f sha ok=0 fail=0 dest
  w="$(mktemp -d)" || return 1
  cc_fetch_signed_sums "$w" || { rm -rf "$w"; return 1; }
  # uninstall.sh : l'entrée « Partir » du menu l'exécute (copie temporaire, voir cc_depart).
  for f in Claude.command lib/common.sh uninstall.sh claude.cmd claude-classic.cmd "baluchon-core-$CORE_PLAT$EXE"; do
    sha="$(cc_sum_for "$w/SHA256SUMS" "$(basename "$f")")"
    [ -n "$sha" ] || continue
    curl -fsSL "$CCP_DL/$(basename "$f")" -o "$w/$(basename "$f")" || { cc_warn "$(basename "$f") injoignable"; fail=$((fail+1)); continue; }
    cc_check_sha "$w/$(basename "$f")" "$sha" || { fail=$((fail+1)); continue; }
    # cc_poser : renommage d'un fichier temporaire du dossier d'arrivée, jamais d'écriture dans un nom prévisible
    # (revue Codex, 4e passe) ; l'empreinte du fichier POSÉ est revérifiée.
    case "$f" in
      baluchon-core-*) mkdir -p "$ROOT/bin/$CORE_PLAT"; dest="$ROOT/bin/$CORE_PLAT/baluchon-core$EXE" ;;
      *) mkdir -p "$ROOT/$(dirname "$f")"; dest="$ROOT/$f" ;;
    esac
    if ! cc_poser "$w/$(basename "$f")" "$dest" || [ "$(cc_sha256 "$dest")" != "$sha" ]; then
      cc_warn "$(basename "$f") : pose impossible ou fichier modifié pendant la pose."; fail=$((fail+1)); continue
    fi
    case "$f" in baluchon-core-*) chmod +x "$dest" 2>/dev/null || true ;; esac
    ok=$((ok+1)); cc_ok "$(basename "$f") à jour"
  done
  chmod +x "$ROOT/Claude.command" 2>/dev/null || true
  # Le relevé « cette installation est celle de cette release » n'est posé que si TOUT a été remplacé :
  # un fichier manqué ferait croire à install.sh que rien n'est à refaire.
  if [ "$fail" = 0 ] && [ "$ok" -gt 0 ] && cc_est_installation "$ROOT"; then cc_release_noter "$w/SHA256SUMS" "$w/SHA256SUMS.sig" || true; fi
  rm -rf "$w"
  cc_layer_hook update || true
  [ "$ok" -gt 0 ]
}

# ─── Effacement ─────────────────────────────────────────────────────────
# La racine qu'on s'apprête à vider est-elle raisonnable ? À jouer AVANT toute suppression (revue Codex,
# 2e passe : avec `ROOT/config` lié vers ~/Documents, `rm -rf "$ROOT"/config/*` effaçait les documents ; les
# gardes d'uninstall.sh arrivaient trop tard, cc_wipe passant avant). Juge le chemin PHYSIQUE (liens, « . » et
# « .. » résolus) et pose CC_ROOT_REAL, le seul chemin qu'on efface ensuite : absolu, un dossier, ni « / », ni le
# domicile, ni un parent du domicile et, sur une installation (où le propriétaire d'un fichier veut dire
# quelque chose), propriétaire = cet utilisateur. Une racine qui est elle-même un lien (installation rangée
# ailleurs puis liée) est légitime : on efface sa CIBLE, jamais le lien. Pas de contrôle de propriétaire sur une
# clé exFAT/FAT, qui n'en a pas : le refuser laisserait des sessions sur un poste invité.
cc_racine_sure() {
  local real home_real own
  CC_ROOT_REAL=""
  case "${ROOT:-}" in /*) ;; *) return 1 ;; esac
  real="$(cd -P -- "$ROOT" 2>/dev/null && pwd -P)" || return 1
  [ -n "$real" ] && [ "$real" != "/" ] || return 1
  home_real="$(cd -P -- "$HOME" 2>/dev/null && pwd -P)" || home_real=""
  if [ -n "$home_real" ]; then
    [ "$real" != "$home_real" ] || return 1
    case "$home_real/" in "${real%/}/"*) return 1 ;; esac
  fi
  if cc_strict; then
    own="$(find "$real" -maxdepth 0 -user "$(id -u)" 2>/dev/null)"
    [ -n "$own" ] || return 1
  fi
  CC_ROOT_REAL="$real"
}

# Liens symboliques que « Partir » ne doit JAMAIS suivre : `config` lui-même, ou une entrée directe de config/
# (un « profil » qui est un lien). Pose CC_LIENS, une entrée par ligne (`config` ou `config/<nom>`), vide si rien.
# WHY (revue Codex, 4e passe) : à jouer AVANT tout appel au noyau. Un noyau déjà installé liste les profils par
# `is_dir()`, qui SUIT les liens : avec `config/pro -> ~/.claude`, il purgeait les identifiants du Claude normal,
# hors de l'installation. Le noyau d'aujourd'hui ne le fait plus (core/src/root.rs, purge.rs), mais on ne sait pas
# quel noyau est installé : tant qu'un lien existe, aucun noyau n'est appelé, et le repli bash (qui ne suit jamais)
# traite les vrais profils. Les points cachés de config/ ne sont pas des profils : ignorés comme le fait le noyau.
cc_liens_config() {
  local base="${1:-$ROOT}" e
  CC_LIENS=""
  if [ -L "$base/config" ]; then CC_LIENS="config"; return 0; fi
  [ -d "$base/config" ] || return 0
  for e in "$base"/config/*; do
    if [ -L "$e" ]; then CC_LIENS="${CC_LIENS}${CC_LIENS:+$'\n'}config/${e##*/}"; fi
  done
  return 0
}

# Services du Trousseau macOS que l'effacement visera : un par config/<profil>, pour le chemin tel que le menu le
# connaît ET pour son chemin physique s'il diffère (Claude suffixe le nom du service d'après le chemin qu'on lui
# donne). Un service par ligne ; rien hors macOS. Une seule définition : le relevé de « Partir » et le
# pré-contrôle du Trousseau la partagent.
cc_services_trousseau() {
  local real d cfg base
  [ "${CC_OS:-}" = darwin ] || return 0
  real="$(cd -P -- "$ROOT" 2>/dev/null && pwd -P)"
  for d in "$ROOT"/config/*/; do
    [ -d "$d" ] || continue
    cfg="${d%/}"; base="${cfg##*/}"
    printf 'Claude Code-credentials-%s\n' "$(printf '%s' "$cfg" | shasum -a 256 | cut -c1-8)"
    if [ -n "$real" ] && [ "$real" != "$ROOT" ]; then
      printf 'Claude Code-credentials-%s\n' "$(printf '%s' "$real/config/$base" | shasum -a 256 | cut -c1-8)"
    fi
  done
}

# Le Trousseau répond-il, pour chacun de ces services (un par ligne) ? À jouer AVANT de supprimer quoi que ce
# soit : le nom d'un service se calcule depuis le dossier du profil, donc un dossier supprimé pendant que le
# Trousseau refuse (verrouillé, accès refusé, outil absent) laisse des sessions dont plus rien ne dit le nom,
# et l'effacement ne peut plus être rejoué. 0 = chaque réponse est « présent » (0) ou « absent » (44) ; 1
# sinon, avec CC_TROUSSEAU_NOTE (la cause, en une ligne). Hors macOS ou sans service : 0.
# Honnêteté : c'est une LECTURE ; elle prouve que le Trousseau est joignable, pas qu'une suppression
# réussira ensuite (un refus à ce moment-là est vu par la suppression elle-même, code 3 de cc_purge_sessions).
cc_trousseau_pret() { # cc_trousseau_pret <services, un par ligne>
  local s sr
  CC_TROUSSEAU_NOTE=""
  [ "${CC_OS:-}" = darwin ] || return 0
  [ -n "${1:-}" ] || return 0
  if ! command -v security >/dev/null 2>&1; then CC_TROUSSEAU_NOTE="outil « security » absent"; return 1; fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    sr=0; security find-generic-password -s "$s" >/dev/null 2>&1 || sr=$?
    case "$sr" in 0|44) ;; *) CC_TROUSSEAU_NOTE="réponse $sr de « security »"; return 1 ;; esac
  done <<< "$1"
  return 0
}

# Efface les sessions de CE portable : Trousseau macOS (services suffixés
# seulement, jamais la session Claude Code normale de la machine) ET identifiants
# en fichier (seul magasin sous Windows/Linux). Passe par le noyau ; le repli
# bash couvre le cas « noyau absent », sinon un poste invité garderait tout.
# Rend 0 seulement si tout ce qui existait a été effacé.
# Code retour : 0 = tout effacé ; 2 = effacé mais une session ou un renouvellement
# encore vivant pourrait réécrire des identifiants (code 11 du noyau) ; 3 = les fichiers
# sont traités mais le Trousseau a refusé une suppression (verrouillé ?) : des sessions
# y restent, et ce code prime sur 1 ; 1 = autre échec.
cc_purge_sessions() {
  local core_rc=0
  # Jamais sur une racine douteuse, ni à travers un lien : le noyau et le repli ci-dessous suivraient
  # `config` où qu'il mène (voir cc_racine_sure et cc_wipe).
  cc_racine_sure || { cc_warn "Racine d'effacement refusée ($ROOT) : rien n'est effacé."; return 1; }
  cc_liens_config "$CC_ROOT_REAL"
  if [ "$CC_LIENS" = config ]; then cc_warn "config est un lien symbolique : il n'est jamais suivi, rien n'est effacé."; return 1; fi
  local d cfg f rc=0 sr trk=0
  if [ -n "$CC_LIENS" ]; then
    # Le noyau n'est PAS appelé (voir cc_liens_config) : les vrais profils passent par le repli ci-dessous, qui
    # dit chaque lien (config/<nom> est un lien symbolique…) ; le code retour n'est plus 0.
    rc=1
  else
    ccp_core accounts purge >/dev/null 2>&1 || core_rc=$?
    case "$core_rc" in 0) return 0 ;; 11) return 2 ;; esac
  fi
  for d in "$ROOT"/config/*/; do
    [ -d "$d" ] || continue; cfg="${d%/}"
    # Un profil qui est un lien mène hors de la racine : on ne le suit pas, et on le dit par le code retour.
    if [ -L "$cfg" ]; then cc_warn "config/${cfg##*/} est un lien symbolique : non suivi, ses sessions ne sont pas effacées."; rc=1; continue; fi
    if [ "${CC_OS:-}" = darwin ]; then
      # 0 = supprimé, 44 = l'item n'existait pas : les deux disent « il n'y en a plus ». Toute autre
      # réponse (Trousseau verrouillé, accès refusé, outil absent) n'établit RIEN : échec.
      security delete-generic-password -s "Claude Code-credentials-$(printf '%s' "$cfg" | shasum -a 256 | cut -c1-8)" >/dev/null 2>&1; sr=$?
      case "$sr" in 0|44) ;; *) rc=1; trk=1 ;; esac
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
  # Une session qui reste au Trousseau est dite à part (3) : le remède n'est pas le même (déverrouiller),
  # et les fichiers, eux, ont été traités.
  [ "$trk" = 0 ] || return 3
  return "$rc"
}
# Ancien nom, gardé pour les appelants existants.
cc_purge_keychain() { cc_purge_sessions; }
# Efface toutes les sessions et jetons du portable (Trousseau compris), et les jetons
# Cloudflare Access que la liaison avec le Mac a laissés dans ~/.cloudflared.
# Code retour (ce qui RESTE est dit dans CC_WIPE_NOTE, jamais avalé) :
#   0 = tout effacé ; 2 = effacé, mais une session Claude encore ouverte peut réécrire ses
#   identifiants ; 10 = des jetons Cloudflare Access restent UTILISABLES ; 1 = sessions mal effacées ;
#   3 = le Trousseau ne répond pas (verrouillé, accès refusé) : RIEN n'a été effacé, déverrouille-le
#   puis refais (pré-contrôle ci-dessous : un dossier de profil supprimé pendant que le Trousseau refuse
#   ne laisse plus de quoi rejouer l'effacement).
# WHY : avant, les deux échecs étaient ignorés et le menu affichait « ✓ Effacé » ; sur un poste
# prêté, un jeton Access resté en place rouvrait la liaison avec le Mac (même défaut que celui
# que la revue Codex avait trouvé dans uninstall.sh).
# Si l'effacement des jetons Access échoue, config/remote.conf est GARDÉ : c'est lui qui dit quel
# hôte oublier ; sans lui, une nouvelle tentative répondrait « aucun Mac configuré » et réussirait
# sans rien effacer. Il ne contient aucun secret (hôte, utilisateur, options).
cc_wipe() {
  local prc=0 frc=0 sortie="" f h autres cfg liens="" lrc=0 lien_cfg=0
  CC_WIPE_NOTE=""
  # Avant toute suppression : la racine est jugée (cc_racine_sure), et `config` n'est jamais suivi s'il est un lien.
  if ! cc_racine_sure; then
    CC_WIPE_NOTE="La racine « $ROOT » n'est pas un dossier que Baluchon accepte d'effacer (relative, « / », le domicile ou son parent, ou propriétaire étranger) : rien n'a été effacé."
    return 1
  fi
  cfg="$CC_ROOT_REAL/config"
  [ ! -L "$ROOT/config" ] && [ ! -L "$cfg" ] || lien_cfg=1
  # AVANT toute suppression : le Trousseau répond-il ? Sinon on s'arrête là, rien n'est touché.
  if [ "$lien_cfg" = 0 ] && ! cc_trousseau_pret "$(cc_services_trousseau)"; then
    CC_WIPE_NOTE="Trousseau verrouillé ou inaccessible (${CC_TROUSSEAU_NOTE}) : déverrouille-le puis refais l'effacement. Rien n'a été effacé."
    return 3
  fi
  cc_purge_keychain || prc=$?
  if [ "$prc" = 3 ]; then
    # Le pré-contrôle a passé, puis le Trousseau a refusé une suppression (verrouillé entre-temps).
    prc=1
    CC_WIPE_NOTE="Des sessions restent au Trousseau (il a refusé la suppression : verrouillé ?). Les fichiers de connexion, eux, sont effacés : ouvre « Trousseau d'accès » et supprime à la main les items « Claude Code-credentials-… » de ce portable."
  fi
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
  [ "$frc" != 0 ] || rm -f "$CC_ROOT_REAL/.baluchon-acces" 2>/dev/null || true
  # Les suppressions partent d'un dossier OUVERT et contrôlé : on entre dans config (`cd -P`), on vérifie que
  # le dossier où l'on est est bien « <racine physique>/config », puis on supprime par des noms RELATIFS. Un
  # lien échangé après coup ne mène donc plus nulle part ; un profil qui est lui-même un lien est laissé en
  # place, DIT, et jamais suivi.
  if [ "$lien_cfg" = 1 ]; then
    prc=1
    CC_WIPE_NOTE="config est un lien symbolique : il n'est jamais suivi, rien n'y a été effacé."
  elif [ -d "$cfg" ]; then
    liens="$( cd -P -- "$cfg" 2>/dev/null && [ "$(pwd -P)" = "$cfg" ] || exit 3
              for f in ./*; do
                [ -e "$f" ] || [ -L "$f" ] || continue
                if [ "$frc" != 0 ] && [ "${f#./}" = remote.conf ]; then continue; fi
                if [ -L "$f" ]; then printf '%s\n' "${f#./}"; continue; fi
                rm -rf -- "$f" 2>/dev/null || true
              done )" || lrc=$?
    if [ "$lrc" = 3 ]; then
      prc=1; CC_WIPE_NOTE="config n'est plus le dossier jugé (remplacé pendant l'effacement) : rien n'y a été effacé."
    elif [ -n "$liens" ]; then
      prc=1; CC_WIPE_NOTE="Ces entrées de config sont des liens symboliques : jamais suivis, leur contenu n'a PAS été effacé :"$'\n'"$(printf '%s\n' "$liens" | sed 's/^/  - config\//' | head -n 12)"
    fi
  fi
  rm -f "$CC_ROOT_REAL"/ACTIVE 2>/dev/null || true
  if [ "$prc" != 0 ] && [ "$prc" != 2 ] && [ -z "$CC_WIPE_NOTE" ]; then
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
# fichier .baluchon-release porte l'empreinte du SHA256SUMS dont la signature vient d'être vérifiée, et
# l'installation CONSERVE ce manifeste signé (.baluchon-sums + .baluchon-sums.sig) : c'est lui qui permet,
# plus tard, de reconnaître chaque exécutable avant de le lancer, sans retélécharger (cc_sums_signees).
# WHY l'empreinte et non un numéro de version : aucune version à deviner, et deux releases qui diffèrent
# d'un seul octet de n'importe quel actif ne se confondent jamais.
# $1 = SHA256SUMS authentifié, $2 = sa signature (défaut : $1.sig). Sans signature, rien n'est noté : une
# installation dont on ne peut pas prouver la liste n'est jamais « à jour ».
cc_release_noter() {
  local sums="$1" sig="${2:-$1.sig}" h tag
  h="$(cc_sha256 "$sums")"; [ -n "$h" ] || return 1
  [ -f "$sig" ] || return 1
  # cc_poser / cc_ecrire : plus de `.baluchon-sums.$$` à un nom prévisible (un lien posé d'avance était suivi).
  cc_poser "$sums" "$ROOT/.baluchon-sums" || return 1
  cc_poser "$sig" "$ROOT/.baluchon-sums.sig" || return 1
  tag="$(cc_release_tag | tr -c 'A-Za-z0-9._+-' '_')"
  printf 'baluchon-release 1\nsums %s\ntag %s\n' "$h" "$tag" | cc_ecrire "$ROOT/.baluchon-release"
}

# Tout ce que cette installation EXÉCUTE ou source a-t-il l'empreinte d'une liste authentifiée ? $1 = SHA256SUMS
# dont la signature a été vérifiée (frais, ou relu de cc_sums_signees). Vérifie le menu, la bibliothèque, le
# désinstalleur, le noyau public (empreintes du manifeste), puis Claude et gum (références notées quand
# leur empreinte a été vérifiée à la source : cc_ref_ok), chacun fichier ordinaire et non lien. Rien n'est
# exécuté ici. C'est la porte que l'amorce, le menu et « Partir » passent AVANT de lancer quoi que ce soit.
# Suppose cc_detect_platform déjà joué. Fail-closed : au moindre doute, non.
cc_installation_authentique() {
  local sums="$1" paire nom f want
  cc_est_installation "$ROOT" || return 1
  [ -f "$sums" ] || return 1
  for paire in "Claude.command:Claude.command" "common.sh:lib/common.sh" "uninstall.sh:uninstall.sh" \
               "baluchon-core-$CORE_PLAT$EXE:bin/$CORE_PLAT/baluchon-core$EXE"; do
    nom="${paire%%:*}"; f="$ROOT/${paire#*:}"
    want="$(cc_sum_for "$sums" "$nom")"
    if [ -z "$want" ]; then
      # Une release sans désinstalleur (anciennes) n'en exige pas ; tout autre actif manquant = non.
      [ "$nom" = uninstall.sh ] && continue
      return 1
    fi
    [ -f "$f" ] && [ ! -L "$f" ] && [ "$(cc_sha256 "$f")" = "$want" ] || return 1
  done
  # Claude et sa version ; gum seulement s'il est là (sans lui, le menu se contente de lancer le compte par
  # défaut), mais ALORS avec l'empreinte notée : jamais un gum qu'on n'a pas vérifié.
  [ -s "$ROOT/VERSION" ] && cc_ref_ok "bin/$PLAT/$BINNAME" || return 1
  if [ -e "$ROOT/tools/gum/$PLAT/gum$EXE" ] || [ -L "$ROOT/tools/gum/$PLAT/gum$EXE" ]; then
    cc_ref_ok "tools/gum/$PLAT/gum$EXE" || return 1
  fi
}

# Cette installation est-elle EXACTEMENT celle de la release dont $1 (SHA256SUMS authentifié) est la
# liste ? Oui seulement si le marqueur d'installation est valide, si le relevé .baluchon-release et le manifeste
# conservé portent l'empreinte de $1, et si cc_installation_authentique l'accepte. Fail-closed : au moindre
# doute, non, et l'installeur refait tout (il ne perd rien à refaire).
cc_release_a_jour() {
  local sums="$1" st="$ROOT/.baluchon-release" h
  cc_est_installation "$ROOT" || return 1
  [ -f "$st" ] && [ ! -L "$st" ] && [ "$(head -n 1 "$st" 2>/dev/null)" = "baluchon-release 1" ] || return 1
  h="$(cc_sha256 "$sums")"; [ -n "$h" ] || return 1
  [ "$(awk '$1=="sums"{print $2; exit}' "$st" 2>/dev/null)" = "$h" ] || return 1
  [ -f "$ROOT/.baluchon-sums" ] && [ ! -L "$ROOT/.baluchon-sums" ] && [ "$(cc_sha256 "$ROOT/.baluchon-sums")" = "$h" ] || return 1
  # Sans gum, le menu n'existe pas : mieux vaut retenter l'installation.
  [ -f "$ROOT/tools/gum/$PLAT/gum$EXE" ] || return 1
  cc_installation_authentique "$sums"
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
# Sur une installation, le menu n'est lancé qu'APRÈS cc_installation_authentique : $2 = SHA256SUMS dont la
# signature vient d'être vérifiée (install.sh, amorce) ; sans $2, le manifeste signé que l'installation a
# conservé. Refus (code 1, dit) sinon : « Claude.command » ne s'exécute jamais sur la foi de son seul chemin.
# Il reste la fenêtre entre cette vérification et l'exécution du menu par le système, et le menu source
# lui-même lib/common.sh : même niveau de confiance que de taper `baluchon` (voir TECHNICAL.md, « Ce qui
# reste hors de portée »).
cc_open_menu() {
  local cmd="$1" sums="${2:-}" tty="${CC_TTY:-/dev/tty}" rc=0 priv="" ok=1
  [ -x "$cmd" ] || { cc_warn "Menu introuvable ($cmd)."; return 1; }
  if cc_strict; then
    if [ -z "$sums" ]; then
      priv="$(mktemp -d)" || return 1
      chmod 700 "$priv" 2>/dev/null || true
      if cc_sums_signees > "$priv/SHA256SUMS" 2>/dev/null; then sums="$priv/SHA256SUMS"; else ok=0; fi
    fi
    if [ "$ok" = 1 ]; then
      if [ "$cmd" != "$ROOT/Claude.command" ] || ! cc_installation_authentique "$sums"; then ok=0; fi
    fi
    [ -z "$priv" ] || rm -rf "$priv"
    [ "$ok" = 1 ] || { cc_warn "Cette installation ne correspond plus à la release signée : le menu n'est pas ouvert. Relance le lien d'installation (il remet tout d'équerre)."; return 1; }
  fi
  if [ -r "$tty" ] && [ -w "$tty" ] && ( : < "$tty" ) 2>/dev/null; then
    # shellcheck disable=SC2094  # le terminal est lu ET écrit : c'est le but
    BALUCHON_DEPUIS_LIEN=1 "$cmd" < "$tty" >> "$tty" 2>&1 || rc=$?
    return "$rc"
  fi
  cc_info "Pas de terminal ici pour ouvrir le menu. Pour l'ouvrir, tape :  $(cc_commande_menu "$cmd")"
  return 0
}

# ── Partir : tout effacer et désinstaller ──────────────────────────────────────────────────
# Base des copies d'exécution que cc_runnable range quand la clé est montée sans exécution.
cc_cache_base() { printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/baluchon"; }

# Une base de cache est acceptable si elle est absolue, sans « .. » ni « // » ni retour chariot, terminée par
# /baluchon, de parent autre que « / ». (Un lien à cet endroit est refusé, et dit, par uninstall.sh ; il reste
# listé ici pour que le bilan ne dise jamais « Rien ne reste » devant lui. uninstall.sh refait la même vérification
# de forme, il est autonome : cache_base_ok.)
cc_cache_base_ok() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *..*|*//*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "$1" in */baluchon) ;; *) return 1 ;; esac
  [ -n "${1%/baluchon}" ]
}

# Bases où cette installation a pu ranger des copies, une par ligne : ~/.cache/baluchon, celle de la valeur
# ACTUELLE de XDG_CACHE_HOME, et celles que .baluchon-cache enregistre (lignes « base <chemin> »), acceptables
# seulement (cc_cache_base_ok).
cc_cache_bases() {
  local f="$ROOT/.baluchon-cache" b l
  for b in "$HOME/.cache/baluchon" "$(cc_cache_base)"; do
    if cc_cache_base_ok "$b"; then printf '%s\n' "$b"; fi
  done
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
      l="${l%$'\r'}"
      case "$l" in "base /"*) b="${l#base }"; if cc_cache_base_ok "$b"; then printf '%s\n' "$b"; fi ;; esac
    done < "$f"
  fi
}

# Dossiers de cache que CETTE installation a notés (.baluchon-cache), un par ligne, retenus seulement s'ils sont
# sûrs : absolus, strictement SOUS une base acceptée (cc_cache_bases), sans « .. », « // » ni retour chariot.
# Une ligne douteuse est ignorée, jamais suivie : ce fichier est écrit avec les droits de l'utilisateur et ne
# doit pas pouvoir désigner ~/Documents. (uninstall.sh refait la même vérification, il est autonome.)
cc_cache_liste() {
  local f="$ROOT/.baluchon-cache" bases b p
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  bases="$(cc_cache_bases)"
  while IFS= read -r p || [ -n "$p" ]; do
    p="${p%$'\r'}"
    case "$p" in /*) ;; *) continue ;; esac
    case "$p" in *..*|*//*) continue ;; esac
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      case "$p" in "$b"/?*) printf '%s\n' "$p"; break ;; esac
    done <<< "$bases"
  done < "$f"
}

# Relevé de ce qu'il faudra chercher, fait AVANT d'effacer : une fois le dossier parti, plus rien ne dit
# quel item du Trousseau ni quel hôte regarder. Pose CC_DEP_DIRS (le chemin du dossier tel que le menu le
# connaît, et son chemin canonique s'il diffère : un lien mène au même dossier), CC_DEP_SERVICES (items
# Trousseau macOS : un par config/<profil>, pour chacun des deux chemins, puisque Claude suffixe le nom du
# service d'après le chemin qu'on lui donne), CC_DEP_HOTES et CC_DEP_CACHES (copies d'exécution notées
# par cette installation). Une valeur par ligne.
cc_depart_releve() {
  local real
  CC_DEP_DIRS="$ROOT"
  real="$(cd -P -- "$ROOT" 2>/dev/null && pwd -P)"
  if [ -n "$real" ] && [ "$real" != "$ROOT" ]; then CC_DEP_DIRS="$CC_DEP_DIRS"$'\n'"$real"; fi
  CC_DEP_SERVICES="$(cc_services_trousseau)"
  CC_DEP_HOTES="$(cc_acces_hotes)"
  CC_DEP_CACHES="$(cc_cache_liste)"
}

# Relit le DISQUE (jamais le code retour d'un effacement) et dit ce qui reste de ce que cc_depart_releve
# a relevé : le dossier, les commandes de ~/.local/bin qui y mènent, les items du Trousseau, les jetons
# Cloudflare Access (seulement si un hôte était connu : sans hôte, rien ne dit qu'il y en a). Écrit
# CC_DEPART_RESTE (une ligne par reste) ; rend 0 si rien ne reste, 1 sinon. N'écrit nulle part : un
# journal recréé ici serait lui-même un reste.
cc_depart_verifie() {
  local p n f s h nom re lignes="" cf="$HOME/.cloudflared" nl=$'\n' sr nonverif
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
  if [ "${CC_OS:-}" = darwin ] && [ -n "$CC_DEP_SERVICES" ]; then
    # 0 = l'item est là ; 44 = il n'existe pas. Toute autre réponse (Trousseau verrouillé, accès refusé, outil
    # absent) n'établit PAS l'absence : jamais « Rien ne reste » sur un silence.
    nonverif=""
    if ! command -v security >/dev/null 2>&1; then nonverif="outil « security » absent"; fi
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      [ -z "$nonverif" ] || break
      sr=0; security find-generic-password -s "$s" >/dev/null 2>&1 || sr=$?
      case "$sr" in
        0)  lignes="${lignes}Trousseau : l'item « $s » est encore là.$nl" ;;
        44) ;;
        *)  nonverif="code $sr" ;;
      esac
    done <<< "$CC_DEP_SERVICES"
    if [ -n "$nonverif" ]; then lignes="${lignes}Trousseau : sessions non vérifiées ($nonverif ; Trousseau verrouillé ?).$nl"; fi
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$p" ] || [ -L "$p" ]; then lignes="${lignes}Cache d'exécution : $p est encore là.$nl"; fi
  done <<< "${CC_DEP_CACHES:-}"
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
# domicile, ancêtres, identité du dossier). On l'exécute depuis une COPIE dans un dossier privé : le dossier
# qu'on efface contient le script, et un script bash lu pendant qu'on supprime son fichier est un piège.
# Cette copie est AUTHENTIFIÉE : son empreinte est comparée à celle que le manifeste signé de l'installation
# (.baluchon-sums + .sig, signature vérifiée avec la clé épinglée dans cette bibliothèque) donne pour
# uninstall.sh ; la copie est faite dans le dossier privé AVANT le calcul, c'est elle qui est hachée et elle
# qui sera exécutée (un fichier modifié pendant que le menu reste ouvert ne passe plus ; bash -n ne prouvait
# que la syntaxe). Niveau de confiance, dit sans fard : la clé qui vérifie est celle de CETTE bibliothèque,
# déjà vérifiée à l'installation ; c'est le même niveau que le menu lui-même (qui est cette bibliothèque).
# Sans interface, sans question : la confirmation est celle du menu.
# Code de sortie (le détail de ce qui reste est dans CC_DEPART_RESTE et CC_DEPART_NOTE) :
#   0 = rien ne reste, relu sur le disque ; 14 = rien n'a été fait (désinstalleur absent ou altéré, ou
#   manifeste signé absent/invalide) ;
#   15 = le Trousseau ne répond pas (verrouillé, accès refusé) : rien n'a été effacé, déverrouille-le puis
#   relance (pré-contrôle avant tout effacement : le nom d'un service se calcule depuis le dossier du profil) ;
#   2, 10, 11, 12 = codes d'uninstall.sh (refusé, jetons Access, purge incomplète, dossier non supprimé) ;
#   2 aussi si cc_wipe a vu une session Claude encore ouverte ; 1, 10 = codes de cc_wipe quand le
#   désinstalleur n'a pas pu les corriger ; 13 = il reste quelque chose que personne n'avait signalé.
# AUCUN cc_log ici ni après : il recréerait ROOT/logs dans le dossier qu'on vient d'effacer.
cc_depart() {
  local un="$ROOT/uninstall.sh" tmpd copie want wrc=0 urc=0 code=0 reste=0
  CC_DEPART_NOTE=""; CC_DEPART_RESTE=""
  cc_est_installation "$ROOT" && [ -f "$un" ] && [ ! -L "$un" ] \
    || { CC_DEPART_NOTE="Le désinstalleur ($un) est absent : rien n'a été effacé."; return 14; }
  want="$(cc_sum_signee uninstall.sh)" \
    || { CC_DEPART_NOTE="Le manifeste signé de cette installation est absent ou invalide : le désinstalleur ne peut pas être authentifié, rien n'a été effacé. Relance une fois le lien d'installation (il le remet), puis reviens à « Partir »."; return 14; }
  tmpd="$(mktemp -d)" || { CC_DEPART_NOTE="Dossier temporaire impossible : rien n'a été effacé."; return 14; }
  chmod 700 "$tmpd"
  copie="$tmpd/uninstall.sh"
  if ! { cp "$un" "$copie" && [ "$(cc_sha256 "$copie")" = "$want" ] && bash -n "$copie" 2>/dev/null; }; then
    rm -rf "$tmpd"
    CC_DEPART_NOTE="Le désinstalleur n'a pas l'empreinte que la release signe (altéré, ou modifié pendant que le menu était ouvert) : rien n'a été effacé."; return 14
  fi
  cc_depart_releve
  # Le Trousseau doit répondre AVANT que le moindre profil soit supprimé : sinon des sessions y resteraient,
  # sous un nom que plus aucun dossier ne permet de recalculer, et « Partir » ne pourrait plus être rejoué.
  if ! cc_trousseau_pret "$CC_DEP_SERVICES"; then
    rm -rf "$tmpd"
    CC_DEPART_NOTE="Trousseau verrouillé ou inaccessible (${CC_TROUSSEAU_NOTE}) : déverrouille-le puis relance « Partir ». Rien n'a été effacé."
    return 15
  fi
  cc_wipe || wrc=$?
  CC_DEPART_NOTE="${CC_WIPE_NOTE:-}"
  if [ "$wrc" = 3 ]; then
    # Le Trousseau a répondu au relevé puis plus à l'effacement (verrouillé entre-temps) : rien n'est supprimé.
    rm -rf "$tmpd"
    return 15
  fi
  # Le dossier courant ne doit pas être celui qu'on supprime.
  cd / 2>/dev/null || true
  BALUCHON_DIR="$ROOT" bash "$copie" --oui < /dev/null > /dev/null || urc=$?
  rm -rf "$tmpd"
  # Le désinstalleur a son propre pré-contrôle du Trousseau (code 15, « rien n'est supprimé ») : ici cc_wipe a
  # déjà tourné, ce serait faux. Le Trousseau a donc lâché entre les deux : c'est une purge incomplète.
  if [ "$urc" = 15 ]; then
    urc=11
    CC_DEPART_NOTE="${CC_DEPART_NOTE}${CC_DEPART_NOTE:+$'\n'}Le Trousseau a cessé de répondre pendant l'effacement : des sessions peuvent y rester (verrouillé ?)."
  fi
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
