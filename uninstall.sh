#!/usr/bin/env bash
# ============================================================
#  Baluchon — désinstallation / nettoyage des traces (thorough)
#  Usage :  curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/uninstall.sh | bash
#           (sans question : ... | bash -s -- --oui)
#  Supprime TOUT : binaires, interface, sessions, l'item Trousseau macOS de chaque profil,
#  les jetons Cloudflare Access laissés par la liaison avec le Mac, et la couche
#  (overlay/) éventuelle, après avoir appelé son crochet `uninstall`.
#  C'est aussi ce que fait l'entrée « Partir » du menu : elle exécute une COPIE de ce fichier, dont l'empreinte
#  est celle que le manifeste SIGNÉ de l'installation donne (cc_depart, lib/common.sh), car le dossier qu'on
#  efface contient le script. Les gardes ci-dessous n'existent donc qu'ici ; le menu ne les recopie pas.
#  Il ne supprime QUE un dossier qui porte le marqueur d'installation (.baluchon-install), qui
#  n'est ni « / », ni ton domicile, ni un parent de ton domicile (chemin canonique, liens suivis),
#  et dont aucun ancêtre ne peut être modifié par un autre utilisateur.
#  Il n'EXÉCUTE rien qu'il n'ait authentifié : un noyau (ou un crochet de couche) n'est lancé que si son
#  empreinte est celle du manifeste signé conservé par l'installation (noyau public) ou celle que l'amorce a
#  notée après avoir vérifié les sommes signées de la couche (.baluchon-refs). Sinon il n'est pas lancé, et
#  ce qu'il aurait effacé est dit au bilan. Niveau de confiance : la clé qui vérifie est celle épinglée ICI
#  (la même que dans install.sh et lib/common.sh) ; c'est le même niveau que le menu lui-même.
#  Il ne suit JAMAIS un lien symbolique pour effacer : config, un profil ou un dossier de cache qui est un
#  lien est signalé et laissé en place.
#
#  Codes de sortie : 0 = tout est effacé ; 1 = rien à désinstaller ou annulé ; 2 = refusé (rien n'est
#  supprimé) ; 10 = des jetons Cloudflare Access restent utilisables ; 11 = la purge des sessions
#  est incomplète (dont : Trousseau illisible, config en lien) ; 12 = le dossier ou un cache d'exécution
#  n'a pas pu être supprimé en entier ; 15 = le Trousseau (macOS) refuse : L'INSTALLATION EST CONSERVÉE
#  (dossier, profils, commandes), déverrouille-le puis relance. Deux moments, même code :
#    - avant toute suppression : `security show-keychain-info` (0 = déverrouillé, 36 = verrouillé) puis la lecture
#      de chaque item (0 présent, 44 absent) ; une autre réponse est un refus, rien n'est supprimé ;
#    - à la suppression d'un item (verrouillé entre le contrôle et le geste) : le dossier d'installation, le lien
#      qui y mène et les commandes ne sont PAS supprimés, parce que le nom d'un item du Trousseau se calcule depuis
#      le dossier de son profil : sans lui, les sessions restantes ne se retrouveraient plus et l'effacement ne se
#      rejouerait plus. Ce qui était déjà fait (crochet de la couche, noyau, fichiers de connexion purgés, jetons
#      Cloudflare Access, cache d'exécution) reste fait ; le bilan le dit. La relance, Trousseau déverrouillé, va
#      au bout.
#  Un code 10, 11, 12 ou 15 dit ce qui reste, sur la sortie d'erreur : jamais « Plus aucune trace » dans ce cas.
# ============================================================
set -uo pipefail
DIR_DEMANDE="${BALUCHON_DIR:-$HOME/.baluchon}"
BINDIR="$HOME/.local/bin"
OUI=0
[ "${1:-}" = "--oui" ] && OUI=1
# Clé qui signe les releases du produit (même constante que install.sh et lib/common.sh).
CCP_SIGNER='baluchon-release ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIRcs8TrzgdQa1DTZ/Tdt2qUYCBeNuJ1p/DP27yyDttp'
CCP_SIGNER_ID="${CCP_SIGNER%% *}"
PRIV=""   # dossier privé (700) où vit la copie vérifiée du manifeste signé ; retiré à la sortie
# shellcheck disable=SC2329  # appelée par le piège EXIT ci-dessous
nettoie_priv() { case "$PRIV" in /*?) rm -rf "$PRIV" ;; esac; }
trap nettoie_priv EXIT

# ── Ce qu'on a le droit d'effacer ───────────────────────────────────────────────
# Un `rm -rf` sur une variable est le geste le plus dangereux de ce dépôt. Comparer des CHAÎNES ne
# protège de rien (revue Codex : `BALUCHON_DIR="$HOME/."` passait et effaçait le contenu du domicile).
# On juge donc le chemin PHYSIQUE, et on exige que le dossier se déclare lui-même une installation :
#   1. chemin canonique (liens, « . » et « .. » résolus : `cd -P` + `pwd -P`) ;
#   2. jamais « / », jamais le domicile, jamais un parent du domicile ;
#   3. le MARQUEUR que l'installeur pose (.baluchon-install, première ligne « baluchon-install 1 »),
#      fichier ordinaire (pas un lien). Sans marqueur, ce n'est pas notre dossier : rien n'est effacé ;
#   4. aucun ANCÊTRE du dossier ne peut être modifié par un autre utilisateur (écriture de groupe ou
#      du monde sans bit « sticky », ou propriétaire autre que toi ou root) : sinon cet autre
#      utilisateur pourrait remplacer un maillon du chemin par un lien APRÈS ce jugement (revue
#      Codex, 2e passe : l'effacement résolvait le chemin une seconde fois) ;
#   5. l'identité du dossier (périphérique:inode) est relevée ICI, et revérifiée juste avant chaque
#      geste qui passe par son chemin (crochet, noyau, effacement). L'effacement part du dossier
#      PARENT figé (`cd -P`, puis un nom relatif) : un maillon d'ancêtre échangé après coup n'y
#      change plus rien, et une différence d'identité est un refus.
MARQUEUR=".baluchon-install"
MARQUEUR_TEXTE="baluchon-install 1"
refus() { printf '✗ %s Rien n'"'"'est supprimé.\n' "$1" >&2; exit 2; }
canonique() { ( cd -P -- "$1" 2>/dev/null && pwd -P ); }
# « périphérique:inode » d'un chemin ; vide et code 1 si illisible. GNU d'abord (`stat -c`), BSD ensuite
# (`stat -f`) : sur GNU, `-f` veut dire autre chose (système de fichiers), d'où cet ordre.
identite() {
  local i
  i="$(stat -c '%d:%i' -- "$1" 2>/dev/null)" && [ -n "$i" ] && { printf '%s\n' "$i"; return 0; }
  i="$(stat -f '%d:%i' "$1" 2>/dev/null)" && [ -n "$i" ] && { printf '%s\n' "$i"; return 0; }
  return 1
}
# 0 si SEUL toi (ou root) peut ajouter, renommer ou retirer une entrée de ce dossier : propriétaire
# toi ou root, et pas d'écriture de groupe ou du monde (sauf bit sticky, qui réserve chaque entrée à
# son propriétaire). Les ACL étendues ne se lisent pas ici : limite connue.
ancetre_sur() {
  local ligne mode uid
  ligne="$(ls -ldn -- "$1" 2>/dev/null)" || return 1
  read -r mode _ uid _ <<< "$ligne"
  case "$uid" in "$(id -u)"|0) ;; *) return 1 ;; esac
  case "${mode:5:1}${mode:8:1}" in
    *w*) case "${mode:9:1}" in t|T) ;; *) return 1 ;; esac ;;
  esac
  return 0
}

[ -d "$DIR_DEMANDE" ] || { echo "Aucun dossier d'installation à « $DIR_DEMANDE » : rien à désinstaller." >&2; exit 1; }
DIR="$(canonique "$DIR_DEMANDE")"
DOMICILE="$(canonique "$HOME")"
[ -n "$DIR" ] || refus "Le dossier « $DIR_DEMANDE » n'a pas pu être résolu."
[ -n "$DOMICILE" ] || refus "Le domicile « $HOME » n'a pas pu être résolu."
[ "$DIR" != "/" ] || refus "Le dossier d'installation est la racine du disque."
[ "$DIR" != "$DOMICILE" ] || refus "Le dossier d'installation « $DIR_DEMANDE » est ton domicile."
case "$DOMICILE/" in
  "${DIR%/}/"*) refus "Le dossier d'installation « $DIR_DEMANDE » (soit $DIR) contient ton domicile." ;;
esac
if [ -L "$DIR/$MARQUEUR" ] || [ ! -f "$DIR/$MARQUEUR" ] || [ "$(head -n 1 "$DIR/$MARQUEUR" 2>/dev/null)" != "$MARQUEUR_TEXTE" ]; then
  refus "« $DIR » ne porte pas le marqueur d'une installation de Baluchon ($MARQUEUR). Si c'est bien une installation ancienne : réinstalle (install.sh le pose), ou crée-le toi-même avec  printf '%s\\n' '$MARQUEUR_TEXTE' > '$DIR/$MARQUEUR'."
fi
PARENT="$(dirname -- "$DIR")"
LEAF="$(basename -- "$DIR")"
ancetre="$PARENT"
while :; do
  ancetre_sur "$ancetre" \
    || refus "L'ancêtre « $ancetre » de « $DIR » peut être modifié par un autre utilisateur (écriture de groupe ou du monde sans bit sticky, ou propriétaire étranger) : il pourrait y glisser un lien entre le jugement et l'effacement. Supprime le dossier toi-même si tu es sûr de ce que tu fais."
  [ "$ancetre" != "/" ] || break
  ancetre="$(dirname -- "$ancetre")"
done
ID_DIR="$(identite "$DIR")" || refus "L'identité du dossier « $DIR » n'a pas pu être relevée."
ID_PARENT="$(identite "$PARENT")" || refus "L'identité du dossier parent « $PARENT » n'a pas pu être relevée."

# Le dossier jugé est-il toujours LE MÊME ? (même chemin physique, même périphérique et même inode)
# À rappeler avant chaque geste qui repasse par son chemin.
meme_dossier() {
  [ "$(canonique "$DIR")" = "$DIR" ] && [ "$(identite "$DIR")" = "$ID_DIR" ]
}
refus_tard() {
  printf '✗ %s Le dossier « %s » n'"'"'est PAS supprimé.\n' "$1" "$DIR" >&2
  exit 2
}
verifie_ou_refuse() { meme_dossier || refus_tard "Le dossier d'installation a changé (lien ou dossier remplacé) depuis qu'il a été jugé."; }

# Dossier de la génération courante de la couche (voir TECHNICAL.md, « Couches ») : `overlay/CURRENT`
# la désigne (« gen/<nom> ») ; sans pointeur, la couche est à plat dans overlay/.
couche_dir() {
  local p
  if [ -f "$DIR/overlay/CURRENT" ] && [ ! -L "$DIR/overlay/CURRENT" ]; then
    p="$(head -n 1 "$DIR/overlay/CURRENT" 2>/dev/null | tr -d '\r')"
    case "$p" in
      gen/[A-Za-z0-9]*) ;;
      *) return 1 ;;
    esac
    case "${p#gen/}" in */*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ -d "$DIR/overlay/$p" ] && [ ! -L "$DIR/overlay/$p" ] || return 1
    printf '%s\n' "$DIR/overlay/$p"
    return 0
  fi
  printf '%s\n' "$DIR/overlay"
}

echo "Cela va supprimer :"
echo "  - $DIR   (binaires, interface, SESSIONS, couche éventuelle)"
echo "  - les commandes  baluchon  baluchon1  ccp  ccp1  de $BINDIR (seulement si elles pointent ici)"
if [ "$OUI" != 1 ]; then
  # Avec `curl | bash`, l'entrée standard est le script lui-même : la réponse se lit au clavier.
  printf "Confirmer ? [tape OUI] : "
  if [ -t 0 ]; then read -r ans; else read -r ans < /dev/tty 2>/dev/null || ans=""; fi
  [ "$ans" = "OUI" ] || { echo "Annulé."; exit 1; }
fi
verifie_ou_refuse

# ── Ce qu'on a le droit d'EXÉCUTER ──────────────────────────────────────────────────
# Revue Codex, 2e passe : choisir un noyau par `--contract` EXÉCUTAIT déjà un fichier que rien n'avait
# authentifié. Désormais, aucun noyau n'est lancé, pas même pour une sonde, avant d'avoir été comparé à une
# empreinte authentifiée :
#   - noyau public (bin/<plat>/baluchon-core) : empreinte du manifeste SIGNÉ que l'installation a conservé
#     (.baluchon-sums + .sig), dont la signature est vérifiée ICI sur une copie privée, avec la clé épinglée ;
#   - noyau de la couche (overlay/gen/<nom>/bin/<plat>/baluchon-core) : empreinte notée dans .baluchon-refs
#     par l'amorce de l'atelier, seule à connaître la clé de la couche (elle y vérifie les sommes signées de la
#     couche avant de noter) ;
#   - crochet uninstall de la couche : même règle que le noyau de la couche.
# Honnêteté : .baluchon-refs est écrit avec les droits de l'utilisateur ; il protège d'un fichier remplacé SEUL,
# pas de qui réécrit toute l'installation (celui-là n'a pas besoin de ce script pour agir).
SUMS_PRIVE=""
manifeste_signe() { # pose SUMS_PRIVE (copie privée du manifeste dont la signature est valide), ou rend 1
  local sk
  sk="$(command -v ssh-keygen 2>/dev/null)"; [ -n "$sk" ] || return 1
  { [ -f "$DIR/.baluchon-sums" ] && [ ! -L "$DIR/.baluchon-sums" ] \
    && [ -f "$DIR/.baluchon-sums.sig" ] && [ ! -L "$DIR/.baluchon-sums.sig" ]; } || return 1
  PRIV="$(mktemp -d)" || { PRIV=""; return 1; }
  chmod 700 "$PRIV" 2>/dev/null || true
  if cp "$DIR/.baluchon-sums" "$PRIV/SHA256SUMS" && cp "$DIR/.baluchon-sums.sig" "$PRIV/SHA256SUMS.sig" \
     && printf '%s\n' "$CCP_SIGNER" > "$PRIV/allowed_signers" \
     && "$sk" -Y verify -f "$PRIV/allowed_signers" -I "$CCP_SIGNER_ID" -n file -s "$PRIV/SHA256SUMS.sig" < "$PRIV/SHA256SUMS" >/dev/null 2>&1; then
    SUMS_PRIVE="$PRIV/SHA256SUMS"; return 0
  fi
  return 1
}
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
# Empreinte notée dans .baluchon-refs pour un chemin relatif à $DIR ; vide si aucune.
ref_de() {
  [ -f "$DIR/.baluchon-refs" ] && [ ! -L "$DIR/.baluchon-refs" ] || return 0
  awk -v p="$1" '$2==p {print $1; exit}' "$DIR/.baluchon-refs"
}
# 0 si $1 (fichier ordinaire, pas un lien) a l'empreinte attendue pour lui : manifeste signé pour le noyau
# public, référence notée pour tout ce qui est sous overlay/.
authentique() { # authentique <chemin>
  local f="$1" rel nom plat want="" got
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  rel="${f#"$DIR"/}"
  case "$rel" in
    overlay/*) want="$(ref_de "$rel")" ;;
    bin/*/baluchon-core|bin/*/baluchon-core.exe)
      [ -n "$SUMS_PRIVE" ] || return 1
      plat="${rel#bin/}"; plat="${plat%%/*}"; nom="baluchon-core-$plat"
      case "$rel" in *.exe) nom="$nom.exe" ;; esac
      want="$(awk -v n="$nom" '$2==n || $2=="*"n {print $1; exit}' "$SUMS_PRIVE")" ;;
    *) return 1 ;;
  esac
  [ -n "$want" ] || return 1
  got="$(sha "$f")"
  [ -n "$got" ] && [ "$got" = "$want" ]
}

# Le noyau qui sait le mieux effacer : celui de la couche s'il y en a un qui répond, sinon le public.
# Chaque candidat doit d'abord être AUTHENTIFIÉ, puis répondre à --contract (un binaire d'une autre
# plateforme n'est pas choisi).
CORE=""
CORE_REFUSES=""   # candidats présents mais non authentifiés : dits au bilan, jamais lancés
choisir_noyau() { # choisir_noyau <candidat>... : pose CORE au premier authentique qui répond à --contract
  local c
  for c in "$@"; do
    [ -x "$c" ] || continue
    if ! authentique "$c"; then CORE_REFUSES="${CORE_REFUSES}${CORE_REFUSES:+ }${c#"$DIR"/}"; continue; fi
    "$c" --contract >/dev/null 2>&1 && { CORE="$c"; return 0; }
  done
  return 1
}
manifeste_signe || true
LDIR="$(couche_dir || true)"
[ -z "$LDIR" ] || choisir_noyau "$LDIR"/bin/*/baluchon-core || true
[ -n "$CORE" ] || choisir_noyau "$DIR"/bin/*/baluchon-core || true

# Ce qui n'a pas pu être effacé : dit à la fin, jamais avalé (revue Codex, 2e passe : un jeton Access
# non supprimable restait utilisable et le script annonçait « Plus aucune trace »).
CODE_SORTIE=0
BILAN=""
# 1 dès qu'un item du Trousseau refuse d'être supprimé (ni « supprimé » ni « absent ») : le dossier d'installation, le
# lien qui y mène et les commandes sont alors CONSERVÉS (code 15) pour que l'effacement puisse être rejoué.
TROUSSEAU_REFUSE=0
incomplet() { # incomplet <code> <texte>
  [ "$CODE_SORTIE" != 0 ] || CODE_SORTIE="$1"
  BILAN="${BILAN}${BILAN:+$'\n'}$2"
}
indente() { printf '%s\n' "$1" | sed 's/^/      /' | head -n 20; }

# 0) macOS : le Trousseau répond-il ? AVANT de supprimer quoi que ce soit (le crochet de la couche, le noyau et
# `rm -rf` viennent après). Le nom d'un item du Trousseau se calcule depuis le dossier de son profil : un dossier
# supprimé pendant que le Trousseau refuse (verrouillé, accès refusé) laisse des sessions dont plus rien ne dit le
# nom, et l'effacement ne peut plus être rejoué. Rien n'est donc touché : code 15, déverrouille puis relance.
# Deux contrôles. (1) `security show-keychain-info` (Trousseau par défaut) : 0 = déverrouillé, 36 = verrouillé, toute
# réponse ≠ 0 est un refus. WHY : une recherche d'attributs (find-generic-password sans -w) peut répondre 0 ou 44 sur
# un Trousseau VERROUILLÉ, seule la suppression exige le déverrouillage ; c'est le test que Claude Code applique
# lui-même. (2) Pour chaque profil, 0 (présent) et 44 (absent) disent « le Trousseau répond » ; toute autre réponse,
# y compris « security » absent. Un Trousseau qui se verrouille APRÈS ces contrôles est vu par la suppression (étape 2),
# qui laisse alors l'installation en place (code 15, voir plus bas).
if [ "$(uname -s)" = "Darwin" ] && [ -d "$DIR/config" ] && [ ! -L "$DIR/config" ]; then
  verifie_ou_refuse
  AU_MOINS_UN_PROFIL=0
  for d in "$DIR"/config/*/; do
    [ -d "$d" ] && AU_MOINS_UN_PROFIL=1 && break
  done
  if [ "$AU_MOINS_UN_PROFIL" = 1 ]; then
    ir=0; security show-keychain-info >/dev/null 2>&1 || ir=$?
    if [ "$ir" != 0 ]; then
      printf '✗ Trousseau verrouillé ou inaccessible (« security show-keychain-info » répond %s) : déverrouille-le puis relance. Rien n'"'"'est supprimé.\n' "$ir" >&2
      exit 15
    fi
  fi
  for d in "$DIR"/config/*/; do
    [ -d "$d" ] || continue
    svc="Claude Code-credentials-$(printf '%s' "${d%/}" | shasum -a 256 | cut -c1-8)"
    sr=0; security find-generic-password -s "$svc" >/dev/null 2>&1 || sr=$?
    case "$sr" in
      0|44) ;;
      *) printf '✗ Trousseau verrouillé ou inaccessible (réponse %s de « security ») : déverrouille-le puis relance. Rien n'"'"'est supprimé.\n' "$sr" >&2; exit 15 ;;
    esac
  done
fi

# 1) Le crochet de la couche défait ce que la couche a posé hors de overlay/.
# Il n'est lancé que s'il a l'empreinte notée par l'amorce (voir authentique) ; sinon il est DIT, car ce qu'il
# aurait défait hors de overlay/ peut rester.
if [ -f "$DIR/overlay/hooks/uninstall" ]; then
  verifie_ou_refuse
  if authentique "$DIR/overlay/hooks/uninstall"; then
    BALUCHON_ROOT="$DIR" bash "$DIR/overlay/hooks/uninstall" \
      || echo "  ⚠ Le crochet uninstall de la couche a échoué : on continue, le dossier est supprimé en entier." >&2
  else
    incomplet 12 "Le crochet uninstall de la couche n'a pas d'empreinte authentifiée : il n'a PAS été lancé. Ce que la couche a posé hors de $DIR (s'il y en a) reste à retirer à la main."
  fi
fi

# 2) macOS : chaque profil du portable a SA session dans le Trousseau, sous
# « Claude Code-credentials-<sha256(dossier config)[:8]> » (Claude suffixe le nom
# du service dès que CLAUDE_CONFIG_DIR est défini). On ne supprime QUE ces
# items-là, calculés depuis les dossiers de ce portable, AVANT d'effacer le
# dossier. Surtout pas « Claude Code-credentials » sans suffixe : c'est la
# session du Claude Code normal de la machine (~/.claude), pas la nôtre.
# Un `config` qui est un LIEN ne se suit jamais (revue Codex : il menait à ~/Documents) : ni purge par le noyau,
# ni parcours des profils ; c'est dit, et le code est 11.
#
# Les ENTRÉES de config qui sont des liens (config/pro -> ~/.claude) sont jugées AVANT le noyau (revue Codex, 4e
# passe) : un noyau déjà installé liste ses profils par `is_dir()`, qui suit les liens, et purgeait alors les
# identifiants d'un Claude hors de ce dossier. Tant qu'un lien existe, le noyau n'est PAS appelé pour la purge ;
# les services du Trousseau de chaque profil sont tout de même supprimés ci-dessous (leur nom vient du chemin du
# profil, pas de sa cible), et `rm -rf` du dossier retire le lien lui-même sans jamais entrer dans sa cible.
LIENS_CFG=""
if [ -d "$DIR/config" ] && [ ! -L "$DIR/config" ]; then
  for d in "$DIR"/config/*; do
    if [ -L "$d" ]; then LIENS_CFG="${LIENS_CFG}${LIENS_CFG:+, }config/${d##*/}"; fi
  done
fi
if [ -L "$DIR/config" ]; then
  incomplet 11 "« config » est un lien symbolique : il n'a pas été suivi, les sessions qu'il désigne n'ont PAS été effacées."
elif [ "$(uname -s)" = "Darwin" ] && [ -d "$DIR/config" ]; then
  verifie_ou_refuse
  if [ -n "$LIENS_CFG" ]; then
    incomplet 11 "Ces entrées de config sont des liens symboliques : non suivis, le noyau n'a pas été appelé pour la purge des fichiers, les sessions qu'elles désignent n'ont PAS été effacées : $LIENS_CFG"
  elif [ -n "$CORE" ]; then
    sortie="$("$CORE" --root "$DIR" accounts purge 2>&1)"; rc=$?
    if [ "$rc" != 0 ]; then
      incomplet 11 "La purge des sessions est incomplète (code $rc) :"$'\n'"$(indente "$sortie")"
    fi
  fi
  for d in "$DIR"/config/*/; do
    [ -d "$d" ] || continue
    cfg="${d%/}"
    svc="Claude Code-credentials-$(printf '%s' "$cfg" | shasum -a 256 | cut -c1-8)"
    # 0 = supprimé, 44 = l'item n'existait pas (déjà effacé par le noyau) : les deux disent « plus rien ».
    # Toute autre réponse (Trousseau verrouillé, accès refusé) n'établit RIEN : jamais « Plus aucune trace ».
    security delete-generic-password -s "$svc" >/dev/null 2>&1; sr=$?
    case "$sr" in
      0)  echo "  - Trousseau : $svc supprimé" ;;
      44) ;;
      *)  TROUSSEAU_REFUSE=1
          incomplet 11 "Trousseau : « $svc » n'a pas pu être effacé, ni son absence établie (code $sr ; Trousseau verrouillé ?)." ;;
    esac
  done
fi

# 3) Jetons Cloudflare Access de ~/.cloudflared (application ET équipe) : sans eux, plus personne
# ne peut rouvrir la liaison avec le Mac depuis cet ordinateur. Le bilan du noyau (code 10, noms
# seulement) remonte tel quel ; sans noyau qui réponde, on ne peut pas savoir ce qui reste.
if [ -n "$CORE" ]; then
  verifie_ou_refuse
  sortie="$("$CORE" --root "$DIR" remote forget-access 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    incomplet 10 "Des jetons Cloudflare Access restent UTILISABLES sur cet ordinateur (code $rc) :"$'\n'"$(indente "$sortie")"
  fi
elif [ -f "$DIR/config/remote.conf" ] || [ -f "$DIR/.baluchon-acces" ]; then
  incomplet 10 "Aucun noyau authentifié n'a répondu${CORE_REFUSES:+ (non lancés, empreinte non authentifiée : $CORE_REFUSES)} : les jetons Cloudflare Access éventuels (fichiers « …-token » de ~/.cloudflared) n'ont pas pu être effacés."
fi
# Les hôtes que l'AMORCE de l'atelier a notés dans .baluchon-acces (noms seulement, un par ligne) parce que
# ses jetons Access avaient pu rester : ils ne sont pas dans config/remote.conf, donc le `forget-access`
# sans argument ci-dessus ne les voit pas. Un nom qui n'est pas un nom d'hôte sûr est ignoré.
if [ -n "$CORE" ] && [ -f "$DIR/.baluchon-acces" ] && [ ! -L "$DIR/.baluchon-acces" ]; then
  while IFS= read -r h || [ -n "$h" ]; do
    h="${h%$'\r'}"
    case "$h" in ''|-*|.*|*.|*..*|*[!A-Za-z0-9.-]*) continue ;; esac
    verifie_ou_refuse
    sortie="$("$CORE" --root "$DIR" remote forget-access --host "$h" 2>&1)"; rc=$?
    if [ "$rc" != 0 ]; then
      incomplet 10 "Des jetons Cloudflare Access de « $h » restent UTILISABLES sur cet ordinateur (code $rc) :"$'\n'"$(indente "$sortie")"
    fi
  done < "$DIR/.baluchon-acces"
fi

# Les copies d'exécution (revue Codex : le bilan oubliait le cache) : sur une clé montée sans exécution, le
# portable copie ses binaires sous ${XDG_CACHE_HOME:-~/.cache}/baluchon et en note les dossiers dans
# .baluchon-cache (un chemin par ligne, plus UNE ligne « base <cache>/baluchon » la première fois qu'une base
# sert). WHY ces lignes « base » (revue Codex, 4e passe, constat 8) : XDG_CACHE_HOME peut changer entre deux
# lancements ; juger les entrées selon sa valeur du JOUR laissait sur le disque, sans le dire, les copies rangées
# sous l'ancienne. Les lignes « base » sont ignorées comme chemins par les lecteurs d'avant (elles ne sont pas
# absolues). On retire SEULEMENT ces dossiers :
#   - bases acceptées : ~/.cache/baluchon, celle de XDG_CACHE_HOME ACTUEL, et celles que .baluchon-cache
#     enregistre ; chacune absolue, sans « .. » ni « // », terminée par /baluchon, de parent autre que « / »,
#     jamais un lien ;
#   - une entrée est strictement SOUS une base acceptée (la plus courte qui la contient) ;
#   - de la base à l'entrée comprise, chaque dossier est un vrai dossier (jamais un lien), à toi, que ni les
#     autres ni (hors compte privé du même nom que toi) le groupe ne peuvent modifier : le sticky bit n'y
#     dispense de rien. Au-dessus de la base, chaque ancêtre du chemin PHYSIQUE passe ancetre_sur ;
#   - la suppression ne repasse jamais par le chemin absolu : `cd -P` chaîné dossier par dossier depuis la base
#     (chaque pas revérifié sur le dossier où l'on est ENTRÉ : ni lien, ni propriétaire, ni droits d'écriture,
#     chemin physique attendu), puis `rm -rf -- ./feuille` et remontée par `rmdir -- ./nom` relatifs.
# Limite dite : en bash la garantie complète (openat / unlinkat) n'existe pas ; ce qui est fermé, c'est le
# remplacement d'un composant par un lien ET l'écriture par un autre compte dans l'un d'eux.
# Une ligne qui ne tient pas ces bornes n'est jamais suivie. Les dossiers parents devenus vides sont retirés avec,
# jamais un parent non vide.
cache_base_ok() { # cache_base_ok <chemin> : forme acceptable pour une base (un lien est refusé par efface_cache, et dit)
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *..*|*//*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "$1" in */baluchon) ;; *) return 1 ;; esac
  [ -n "${1%/baluchon}" ]
}
cache_dossier_sur() { # cache_dossier_sur <dossier> : un vrai dossier à toi que les autres ne modifient pas
  local ligne mode uid gid
  { [ ! -L "$1" ] && [ -d "$1" ]; } || return 1
  ligne="$(ls -ldn -- "$1" 2>/dev/null)" || return 1
  read -r mode _ uid gid _ <<< "$ligne"
  [ "$uid" = "$(id -u)" ] || return 1
  case "${mode:8:1}" in w) return 1 ;; esac
  # Écriture du groupe : refusée, sauf dans le cas d'un groupe privé de même nom que toi (umask 002 de Debian et
  # d'Ubuntu : tout ce que tu crées l'est), dont tu es le seul membre par construction.
  case "${mode:5:1}" in
    w) { [ "$gid" = "$(id -g)" ] && [ "$(id -gn)" = "$(id -un)" ]; } || return 1 ;;
  esac
  return 0
}
efface_cache() { # efface_cache <base> <entrée sous la base> : 0 effacée, 3 refusée (rien de supprimé), 4 non supprimée en entier
  local b="$1" rel="${2#"$1"/}"
  (
    [ ! -L "$b" ] || exit 3
    cd -P -- "$b" 2>/dev/null || exit 3
    bp="$(pwd -P)"
    cache_dossier_sur . || exit 3
    p="$bp"
    while [ "$p" != / ]; do
      p="$(dirname -- "$p")"
      ancetre_sur "$p" || exit 3
    done
    noms=(); cur="$bp"; reste="$rel"
    while [ -n "$reste" ]; do
      part="${reste%%/*}"
      case "$reste" in */*) reste="${reste#*/}" ;; *) reste="" ;; esac
      case "$part" in ''|.|..) exit 3 ;; esac
      { [ -d "./$part" ] && [ ! -L "./$part" ]; } || exit 3
      cd -P -- "./$part" 2>/dev/null || exit 3
      cur="$cur/$part"
      [ "$(pwd -P)" = "$cur" ] || exit 3
      cache_dossier_sur . || exit 3
      noms[${#noms[@]}]="$part"
    done
    n=${#noms[@]}
    [ "$n" -ge 1 ] || exit 3
    feuille="${noms[$((n - 1))]}"
    id_feuille="$(identite .)" || exit 3
    cd -P -- .. 2>/dev/null || exit 3
    [ "$(pwd -P)" = "${cur%/*}" ] || exit 3
    { [ -d "./$feuille" ] && [ ! -L "./$feuille" ] && [ "$(identite "./$feuille")" = "$id_feuille" ]; } || exit 3
    rm -rf -- "./$feuille" 2>/dev/null
    if [ -e "./$feuille" ] || [ -L "./$feuille" ]; then exit 4; fi
    i=$((n - 1))
    while [ "$i" -ge 1 ]; do
      nom="${noms[$((i - 1))]}"
      cd -P -- .. 2>/dev/null || exit 0
      rmdir -- "./$nom" 2>/dev/null || exit 0
      i=$((i - 1))
    done
    if cd -P -- .. 2>/dev/null; then rmdir -- "./${bp##*/}" 2>/dev/null || true; fi
    exit 0
  )
}
if [ -f "$DIR/.baluchon-cache" ] && [ ! -L "$DIR/.baluchon-cache" ]; then
  verifie_ou_refuse
  BASES_CACHE=("$HOME/.cache/baluchon" "${XDG_CACHE_HOME:-$HOME/.cache}/baluchon")
  while IFS= read -r c || [ -n "$c" ]; do
    c="${c%$'\r'}"
    case "$c" in "base /"*) BASES_CACHE[${#BASES_CACHE[@]}]="${c#base }" ;; esac
  done < "$DIR/.baluchon-cache"
  while IFS= read -r c || [ -n "$c" ]; do
    c="${c%$'\r'}"
    case "$c" in /*) ;; *) continue ;; esac
    case "$c" in *..*|*//*) continue ;; esac
    b=""
    for cand in "${BASES_CACHE[@]}"; do
      cache_base_ok "$cand" || continue
      case "$c" in "$cand"/?*) if [ -z "$b" ] || [ "${#cand}" -lt "${#b}" ]; then b="$cand"; fi ;; esac
    done
    [ -n "$b" ] || continue
    { [ -e "$c" ] || [ -L "$c" ]; } || continue
    efface_cache "$b" "$c"; rc_cache=$?
    case "$rc_cache" in
      0) ;;
      3) incomplet 12 "Cache d'exécution NON effacé (lien, pas un dossier, pas à toi, ou un dossier du chemin que d'autres peuvent modifier) : $c" ;;
      *) incomplet 12 "Cache d'exécution non supprimé en entier : $c" ;;
    esac
  done < "$DIR/.baluchon-cache"
fi

# Un item du Trousseau a refusé d'être supprimé : on s'ARRÊTE ICI, avant tout geste sur le dossier d'installation.
# Les dossiers de profil sont la seule chose dont on recalcule le nom des items restants : les supprimer rendrait
# l'effacement impossible à rejouer (re-revue Codex, constat 7). Rien du dossier, du lien qui y mène ni des commandes
# n'est supprimé ; ce qui était déjà fait (crochet, noyau, fichiers de connexion, jetons Access, cache) reste fait et
# est dit. Code 15 : l'appelant (menu « Partir ») dit que l'installation est conservée et qu'on relance après
# déverrouillage.
if [ "$TROUSSEAU_REFUSE" = 1 ]; then
  echo "⚠ Désinstallation INTERROMPUE : le Trousseau a refusé la suppression de sessions (verrouillé ?)." >&2
  echo "  Rien de l'installation n'est supprimé (dossier, profils, commandes) : des sessions restent au Trousseau." >&2
  echo "  Déverrouille le Trousseau puis relance : l'effacement ira au bout." >&2
  printf '%s\n' "$BILAN" | sed 's/^/  /' >&2
  exit 15
fi

# On efface le dossier PHYSIQUE jugé plus haut, sans repasser par son chemin : on entre dans le dossier
# PARENT figé (cwd = un descripteur : plus aucun lien d'ancêtre n'y change rien), on y revérifie son
# identité et celle du dossier, puis on supprime par un nom RELATIF. Un sous-shell : le répertoire
# courant du script ne change pas (BALUCHON_DIR peut être relatif).
(
  cd -P -- "$PARENT" 2>/dev/null || exit 3
  [ "$(pwd -P)" = "$PARENT" ] && [ "$(identite .)" = "$ID_PARENT" ] || exit 3
  [ -d "./$LEAF" ] && [ ! -L "./$LEAF" ] && [ "$(identite "./$LEAF")" = "$ID_DIR" ] || exit 3
  rm -rf -- "./$LEAF"
)
rc_rm=$?
[ "$rc_rm" -ne 3 ] || refus_tard "Le dossier d'installation a changé (lien ou dossier remplacé) depuis qu'il a été jugé."
if [ -e "$DIR" ] || [ -L "$DIR" ]; then
  incomplet 12 "Le dossier « $DIR » n'a pas pu être supprimé en entier (code $rc_rm)."
fi
# Puis le lien qui y menait, s'il y en avait un.
if [ -L "$DIR_DEMANDE" ]; then rm -f "$DIR_DEMANDE"; fi

# 4) Les commandes : seulement celles qui lancent CE dossier (`ccp` peut être un autre programme).
# L'installeur y a écrit le chemin tel qu'il l'avait reçu : on reconnaît aussi bien celui-là que le canonique.
for n in baluchon baluchon1 ccp ccp1; do
  f="$BINDIR/$n"
  if [ -f "$f" ] && { grep -qF "$DIR/Claude.command" "$f" 2>/dev/null || grep -qF "${DIR_DEMANDE%/}/Claude.command" "$f" 2>/dev/null; }; then
    rm -f "$f"
  fi
done

if [ "$CODE_SORTIE" = 0 ]; then
  echo "✓ Désinstallé. Plus aucune trace de Baluchon sur cette machine."
  echo "  (Pense à révoquer la session sur https://claude.ai si la machine n'est pas la tienne.)"
else
  echo "⚠ Désinstallation INCOMPLÈTE :" >&2
  printf '%s\n' "$BILAN" | sed 's/^/  /' >&2
  echo "  Ce qui reste est utilisable : traite-le à la main (jetons : fichiers « …-token » de ~/.cloudflared)." >&2
  echo "  (Pense à révoquer la session sur https://claude.ai si la machine n'est pas la tienne.)" >&2
fi
exit "$CODE_SORTIE"
