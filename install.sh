#!/usr/bin/env bash
# ============================================================
#  Baluchon — installeur macOS / Linux
#  Usage :  curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/install.sh | bash
#           (puis ouvrir le menu tout de suite :  … | BALUCHON_OUVRIR_MENU=1 bash)
#  Installe le wizard + le noyau baluchon-core + le binaire Claude + gum dans
#  ~/.baluchon, et les commandes courtes « baluchon » et « baluchon1 » (alias : « ccp », « ccp1 »).
#
#  Tout vient de la DERNIÈRE RELEASE SIGNÉE du dépôt (pas de la branche main) :
#  SHA256SUMS est signé (ssh-keygen -Y), chaque fichier est vérifié avant d'être
#  posé. Le binaire Claude est vérifié contre le manifest officiel d'Anthropic.
#  Aucun secret : tes sessions restent locales dans ~/.baluchon/config.
#
#  Relancé sur une installation DÉJÀ À JOUR (mêmes sommes signées, mêmes fichiers), il ne télécharge
#  rien de lourd et ne touche à rien : il dit « déjà installé » et, si demandé, ouvre le menu. Relancé
#  sur une autre release, il refait l'installation complète (mise à jour).
#
#  Ce script n'écrit que les fichiers publics et bin/. Si une couche est posée dans
#  overlay/, il ne la touche pas : il appelle seulement son crochet `update` à la fin.
#
#  Variables (toutes facultatives) :
#    BALUCHON_DIR           dossier d'installation (défaut ~/.baluchon)
#    CCP_DL                 source de la release (recette locale ; la signature reste exigée)
#    BALUCHON_OUVRIR_MENU   1 = ouvre le menu à la fin, sur le terminal (/dev/tty). Sans terminal,
#                           dit la commande à taper et réussit quand même. Défaut : 0.
#    BALUCHON_ETAT_SORTIE   fichier où écrire « installe » ou « a-jour » (pour l'amorce de l'atelier,
#                           qui s'en sert pour savoir si elle doit encore poser sa couche).
#    BALUCHON_ETAPES        1 = écrit aussi des repères « @@etape <code> <statut> » (voir etape()) pour
#                           un appelant qui affiche ses propres étapes. Défaut : 0.
# ============================================================
set -euo pipefail

# Surchargeable pour une recette locale : sans danger, la signature (clé ci-dessous) reste exigée.
CCP_DL="${CCP_DL:-https://github.com/atelier-sam/baluchon/releases/latest/download}"
CCP_SIGNER='baluchon-release ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIRcs8TrzgdQa1DTZ/Tdt2qUYCBeNuJ1p/DP27yyDttp'
CCP_SIGNER_ID="${CCP_SIGNER%% *}"
DIR="${BALUCHON_DIR:-$HOME/.baluchon}"
BINDIR="$HOME/.local/bin"
W=""   # dossier de travail temporaire, global : le piège EXIT le lit

say() { printf '\033[36m• %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
die() { etape fin echec; printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# Repères d'étape pour un appelant qui dessine sa propre interface (amorce, assistant) : BALUCHON_ETAPES=1.
# Une ligne stable « @@etape <code> <statut> » sur la sortie standard ; rien sans la variable. L'appelant
# garde le reste de la sortie dans un journal. Codes : outils signature programmes claude commandes fin ;
# statuts : debut ok deja echec. Contrat lu par l'amorce de la couche : ne pas renommer sans elle.
etape() { [ "${BALUCHON_ETAPES:-0}" = 1 ] && printf '@@etape %s %s\n' "$1" "$2"; return 0; }
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

# Télécharge un fichier de la release et le vérifie contre SHA256SUMS. $1 = nom publié, $2 = destination.
# La copie VÉRIFIÉE reste dans $W (dossier privé, 700) : quand la bibliothèque doit être lue, c'est cette copie
# qu'on lit, jamais le fichier posé sous $DIR, qu'un autre processus a pu remplacer entre le contrôle et la
# lecture (revue Codex, 2e passe : la bibliothèque était hachée puis sourcée par son CHEMIN).
fetch() {
  local want
  want="$(awk -v n="$1" '$2==n || $2=="*"n {print $1; exit}' "$W/SHA256SUMS")"
  [ -n "$want" ] || die "$1 absent de la release."
  curl -fsSL "$CCP_DL/$1" -o "$W/$1" || die "Téléchargement de $1 échoué."
  [ "$(sha "$W/$1")" = "$want" ] || die "Empreinte invalide pour $1 : installation annulée."
  mkdir -p "$(dirname "$2")"
  poser "$W/$1" "$2" || die "Pose de $1 impossible ($2) : installation annulée."
  # Ce qui est POSÉ doit avoir l'empreinte signée, pas seulement ce qui a été téléchargé.
  [ "$(sha "$2")" = "$want" ] || { rm -f "$2"; die "$1 modifié pendant sa pose : installation annulée."; }
}

# poser <source> <destination> : copie par un fichier temporaire du MÊME dossier puis renommage, sans jamais
# écrire dans un nom prévisible ni suivre un lien (revue Codex, 4e passe : `cp src dst.new && mv dst.new dst`
# suivait un `dst.new` lié par un tiers vers un document de l'utilisateur, puis posait ce lien sur `dst`).
# Même mécanique que cc_ecrire (lib/common.sh), reprise ici parce que la bibliothèque n'est ni téléchargée ni
# vérifiée à ce stade : nom imprévisible, ouverture en O_EXCL (`set -C`), octets écrits par ce descripteur
# (le chemin n'est pas rouvert), `mv` REMPLACE la destination (un lien disparaît, sa cible est intacte),
# un dossier à la place de la destination est refusé. Droits : ceux du umask, comme un `>`.
poser() { # poser <source> <destination>
  local dst="$2" d tmp rc
  [ -f "$1" ] || return 1
  case "$dst" in */*) d="${dst%/*}"; [ -n "$d" ] || d=/ ;; *) d=. ;; esac
  [ -d "$d" ] && [ ! -d "$dst" ] || return 1
  tmp="$d/.baluchon-pose.$$.$RANDOM$RANDOM$RANDOM"
  # 97 = l'ouverture O_EXCL a échoué : ce fichier n'est pas à nous, on n'y touche pas.
  rc=0; ( set -C; exec 3> "$tmp" || exit 97; cat < "$1" >&3 ) 2>/dev/null || rc=$?
  [ "$rc" != 97 ] || return 1
  if [ "$rc" = 0 ] && mv -f -- "$tmp" "$dst" 2>/dev/null; then return 0; fi
  rm -f -- "$tmp"
  return 1
}

# Copie PRIVÉE et AUTHENTIFIÉE de la bibliothèque posée sous $DIR : copiée dans $W, hachée SUR LA COPIE, et
# acceptée seulement si son empreinte est celle que la release signe. Pose LIB_PRIVEE ; c'est elle, et elle
# seule, que ce script source ensuite (jamais « $DIR/lib/common.sh » par son chemin).
LIB_PRIVEE=""
lib_privee() {
  local want
  [ -f "$DIR/lib/common.sh" ] && [ ! -L "$DIR/lib/common.sh" ] || return 1
  want="$(awk '$2=="common.sh" || $2=="*common.sh" {print $1; exit}' "$W/SHA256SUMS")"
  [ -n "$want" ] || return 1
  cp "$DIR/lib/common.sh" "$W/lib-posee.sh" || return 1
  [ "$(sha "$W/lib-posee.sh")" = "$want" ] || return 1
  LIB_PRIVEE="$W/lib-posee.sh"
}

# L'installation de $DIR est-elle DÉJÀ exactement celle de cette release ? La bibliothèque posée n'est
# exécutée que si son empreinte est celle que la release signe (sinon elle n'est pas la bonne, donc
# l'installation n'est pas à jour, et on ne lit pas un fichier qu'on ne peut pas juger). Le jugement
# lui-même est cc_release_a_jour (lib/common.sh), le même que celui qui écrit le relevé.
deja_a_jour() {
  lib_privee || return 1
  # shellcheck source=lib/common.sh
  ( ROOT="$DIR"; . "$LIB_PRIVEE"; cc_detect_platform; cc_release_a_jour "$W/SHA256SUMS" ) >/dev/null 2>&1
}

# Installation complète : tout est vérifié contre les sommes signées AVANT d'être posé.
installer_complet() {
  # Le marqueur par lequel uninstall.sh reconnaît CE dossier comme une installation de Baluchon : sans
  # lui, la désinstallation refuse d'effacer quoi que ce soit (revue Codex : une comparaison de
  # chaînes ne protège pas le domicile). Posé AVANT tout le reste, après la signature. Le relevé
  # « à jour » tombe tant que l'installation n'est pas finie : une coupure au milieu ne passe jamais
  # pour une installation complète.
  mkdir -p "$DIR"
  printf 'baluchon-install 1\n' > "$W/marqueur"
  poser "$W/marqueur" "$DIR/.baluchon-install" || die "Marqueur d'installation impossible à poser dans $DIR."
  # Le relevé ET le manifeste conservé de l'ancienne release tombent ensemble : tant que l'installation n'est
  # pas finie, rien n'est reconnu (ni « à jour », ni authentifié), et un fichier posé à moitié n'est jamais lancé.
  rm -f "$DIR/.baluchon-release" "$DIR/.baluchon-sums" "$DIR/.baluchon-sums.sig"

  etape programmes debut
  # 2) Wizard + bibliothèque, puis plateforme via la bibliothèque vérifiée. On source la COPIE VÉRIFIÉE
  # gardée dans $W (voir fetch), pas le fichier qui vient d'être posé sous $DIR.
  fetch Claude.command "$DIR/Claude.command"; chmod +x "$DIR/Claude.command"
  fetch common.sh "$DIR/lib/common.sh"
  ROOT="$DIR"
  # shellcheck source=lib/common.sh
  . "$W/common.sh"
  cc_detect_platform

  # Le désinstalleur : l'entrée « Partir » du menu l'exécute. Une release qui ne le porte pas (anciennes)
  # s'installe quand même ; il n'y a alors pas d'entrée « Partir » et la commande curl ci-dessous reste.
  if awk '$2=="uninstall.sh" || $2=="*uninstall.sh" {f=1} END {exit !f}' "$W/SHA256SUMS"; then
    fetch uninstall.sh "$DIR/uninstall.sh"; chmod +x "$DIR/uninstall.sh"
  elif [ ! -f "$DIR/uninstall.sh" ]; then
    printf '\033[33m⚠ Cette release ne porte pas de désinstalleur : « Partir » ne sera pas proposé dans le menu.\033[0m\n'
  fi

  # 3) Noyau baluchon-core de cette plateforme
  # ($EXE = « .exe » sous Windows : install.ps1 pose Git portable puis lance CE script avec son bash, pour qu'une
  # seule chaîne de confiance serve les deux systèmes.)
  fetch "baluchon-core-$CORE_PLAT$EXE" "$DIR/bin/$CORE_PLAT/baluchon-core$EXE"; chmod +x "$DIR/bin/$CORE_PLAT/baluchon-core$EXE"
  if [ "$CC_OS" = win32 ]; then
    # Lanceurs Windows (double-clic, commandes .cmd) : vérifiés comme le reste.
    fetch claude.cmd "$DIR/claude.cmd"
    fetch claude-classic.cmd "$DIR/claude-classic.cmd"
  fi
  ok "Wizard + noyau baluchon-core vérifiés"
  etape programmes ok

  # 4) Claude (canal stable, vérifié contre le manifest Anthropic) + gum (empreinte épinglée)
  curl -fsSL "https://downloads.claude.ai/claude-code-releases/stable" -o "$W/VERSION" || die "Version de Claude introuvable."
  [ -s "$W/VERSION" ] || die "Version de Claude introuvable."
  poser "$W/VERSION" "$DIR/VERSION" || die "Version de Claude impossible à noter dans $DIR."
  say "Téléchargement du binaire Claude + de l'interface… (peut prendre ~1 min)"
  etape claude debut
  ( set +e; cc_ensure_binary ) || die "Échec du téléchargement de Claude."
  cc_ensure_gum >/dev/null 2>&1 || printf '\033[33m⚠ Interface gum indisponible : baluchon lancera directement le compte par défaut.\033[0m\n'
  etape claude ok
}

# 5) Commandes courtes : `baluchon` / `baluchon1` (2e compte) et leurs alias historiques `ccp` / `ccp1`.
poser_commandes() {
  local n
  mkdir -p "$BINDIR"
  for n in baluchon ccp; do
    cat > "$BINDIR/$n" <<EOF
#!/usr/bin/env bash
exec "$DIR/Claude.command" "\$@"
EOF
  done
  for n in baluchon1 ccp1; do
    cat > "$BINDIR/$n" <<EOF
#!/usr/bin/env bash
exec env CC_PROFILE=2 "$DIR/Claude.command" "\$@"
EOF
  done
  chmod +x "$BINDIR/baluchon" "$BINDIR/baluchon1" "$BINDIR/ccp" "$BINDIR/ccp1"
  ok "Commandes installées : baluchon  (et baluchon1 pour le 2e compte ; alias : ccp, ccp1)"
}

installer() {
  local etat menu_rc=0 rc
  command -v curl >/dev/null 2>&1 || die "curl est requis."
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen est requis pour authentifier la release (paquet openssh-client)."

  W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
  say "Installation de Baluchon dans $DIR"

  # 1) Sommes signées de la release
  { curl -fsSL "$CCP_DL/SHA256SUMS" -o "$W/SHA256SUMS" && curl -fsSL "$CCP_DL/SHA256SUMS.sig" -o "$W/SHA256SUMS.sig"; } \
    || die "Release injoignable (réseau ?)."
  printf '%s\n' "$CCP_SIGNER" > "$W/allowed_signers"
  ssh-keygen -Y verify -f "$W/allowed_signers" -I "$CCP_SIGNER_ID" -n file -s "$W/SHA256SUMS.sig" < "$W/SHA256SUMS" >/dev/null 2>&1 \
    || die "Signature de la release INVALIDE : installation annulée."
  ok "Release authentifiée (signature $CCP_SIGNER_ID)"
  etape signature ok

  if deja_a_jour; then
    etat=a-jour
    ROOT="$DIR"
    # La copie privée authentifiée par deja_a_jour, jamais le fichier posé relu par son chemin.
    # shellcheck source=lib/common.sh
    . "$LIB_PRIVEE"
    cc_detect_platform
    ok "Baluchon est déjà installé et à jour : rien à télécharger."
    etape programmes deja; etape claude deja
    poser_commandes   # locale et sans risque : rend la commande à qui l'avait supprimée
    etape commandes ok
  else
    etat=installe
    installer_complet
    poser_commandes
    etape commandes ok
    # 6) Couche éventuelle (overlay/) : jamais écrite ici, seulement mise à jour par son crochet.
    cc_layer_hook update || true
    # Le relevé « cette installation est celle de cette release » vient EN DERNIER : il n'existe que si tout
    # ce qui précède a été posé.
    # Il conserve aussi le manifeste SIGNÉ (sommes + signature) : c'est lui qui authentifiera, plus tard, chaque
    # exécutable avant qu'il soit lancé (menu, « Partir »), sans retélécharger.
    cc_release_noter "$W/SHA256SUMS" "$W/SHA256SUMS.sig" || printf '\033[33m⚠ Relevé de release non écrit : la prochaine exécution refera tout, et « Partir » restera refusé jusque-là.\033[0m\n'
  fi
  if [ -n "${BALUCHON_ETAT_SORTIE:-}" ]; then printf '%s\n' "$etat" > "$BALUCHON_ETAT_SORTIE" 2>/dev/null || true; fi
  etape fin ok

  # Le menu, si demandé : AVANT les derniers messages, qui parlent de ce qui reste à faire une fois le menu fermé.
  if [ "${BALUCHON_OUVRIR_MENU:-0}" = 1 ]; then
    # Les sommes dont la signature vient d'être vérifiée : le menu n'est lancé que si l'installation y correspond.
    cc_open_menu "$DIR/Claude.command" "$W/SHA256SUMS" || menu_rc=$?
    # « Partir » a pu tout effacer : plus rien à annoncer, et le code de sortie dit ce qui reste.
    if ! cc_est_installation "$DIR"; then exit "$menu_rc"; fi
  fi

  # Sous Windows, install.ps1 pose les commandes .cmd, règle le PATH et dit lui-même la suite.
  [ "$CC_OS" != win32 ] || exit "$menu_rc"

  case ":$PATH:" in
    *":$BINDIR:"*) ok "Tout est prêt. Tape :  baluchon" ;;
    *)
      rc="$HOME/.zshrc"; [ -n "${BASH_VERSION:-}" ] && [ "$(basename "${SHELL:-}")" = bash ] && rc="$HOME/.bashrc"
      printf '\n\033[33m⚠ Ajoute %s à ton PATH :\033[0m\n' "$BINDIR"
      printf "   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> %s && source %s\n" "$rc" "$rc"
      printf '\033[36mEnsuite, tape :  baluchon\033[0m\n'
      ;;
  esac

  echo
  say "Tout est rangé ici (sessions incluses) :  $DIR"
  say "Effacer juste tes comptes : dans baluchon → « Tout déconnecter »."
  say "Tout désinstaller (Trousseau compris) : dans baluchon → « Partir », ou  curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/uninstall.sh | bash"
  exit "$menu_rc"
}

# Appelée EN DERNIER : avec `curl … | bash`, bash lit le script au fil de l'eau ; tout le texte doit être
# arrivé avant que la moindre ligne s'exécute (une coupure réseau à mi-script n'en lance jamais la moitié).
installer
