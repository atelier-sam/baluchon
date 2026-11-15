#!/usr/bin/env bash
# ============================================================
#  Baluchon — désinstallation / nettoyage des traces (thorough)
#  Usage :  curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/uninstall.sh | bash
#           (sans question : ... | bash -s -- --oui)
#  Supprime TOUT : binaires, interface, sessions, l'item Trousseau macOS de chaque profil,
#  les jetons Cloudflare Access laissés par la liaison avec le Mac, et la couche
#  (overlay/) éventuelle, après avoir appelé son crochet `uninstall`.
#  C'est aussi ce que fait l'entrée « Partir » du menu : elle exécute une COPIE de ce fichier, vérifiée
#  (cmp, bash -n), car le dossier qu'on efface contient le script. Les gardes ci-dessous n'existent donc
#  qu'ici ; le menu ne les recopie pas.
#  Il ne supprime QUE un dossier qui porte le marqueur d'installation (.baluchon-install), qui
#  n'est ni « / », ni ton domicile, ni un parent de ton domicile (chemin canonique, liens suivis),
#  et dont aucun ancêtre ne peut être modifié par un autre utilisateur.
#
#  Codes de sortie : 0 = tout est effacé ; 1 = rien à désinstaller ou annulé ; 2 = refusé (rien n'est
#  supprimé) ; 10 = des jetons Cloudflare Access restent utilisables ; 11 = la purge des sessions
#  est incomplète ; 12 = le dossier n'a pas pu être supprimé en entier. Un code 10, 11 ou 12 dit
#  ce qui reste, sur la sortie d'erreur : jamais « Plus aucune trace » dans ce cas.
# ============================================================
set -uo pipefail
DIR_DEMANDE="${BALUCHON_DIR:-$HOME/.baluchon}"
BINDIR="$HOME/.local/bin"
OUI=0
[ "${1:-}" = "--oui" ] && OUI=1

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

# Le noyau qui sait le mieux effacer : celui de la couche s'il y en a un qui répond, sinon le public.
# Chaque candidat doit répondre à --contract (un binaire d'une autre plateforme n'est pas choisi).
CORE=""
choisir_noyau() { # choisir_noyau <candidat>... : pose CORE au premier qui répond à --contract
  local c
  for c in "$@"; do
    [ -x "$c" ] || continue
    "$c" --contract >/dev/null 2>&1 && { CORE="$c"; return 0; }
  done
  return 1
}
LDIR="$(couche_dir || true)"
[ -z "$LDIR" ] || choisir_noyau "$LDIR"/bin/*/baluchon-core || true
[ -n "$CORE" ] || choisir_noyau "$DIR"/bin/*/baluchon-core || true

# Ce qui n'a pas pu être effacé : dit à la fin, jamais avalé (revue Codex, 2e passe : un jeton Access
# non supprimable restait utilisable et le script annonçait « Plus aucune trace »).
CODE_SORTIE=0
BILAN=""
incomplet() { # incomplet <code> <texte>
  [ "$CODE_SORTIE" != 0 ] || CODE_SORTIE="$1"
  BILAN="${BILAN}${BILAN:+$'\n'}$2"
}
indente() { printf '%s\n' "$1" | sed 's/^/      /' | head -n 20; }

# 1) Le crochet de la couche défait ce que la couche a posé hors de overlay/.
if [ -f "$DIR/overlay/hooks/uninstall" ]; then
  verifie_ou_refuse
  BALUCHON_ROOT="$DIR" bash "$DIR/overlay/hooks/uninstall" \
    || echo "  ⚠ Le crochet uninstall de la couche a échoué : on continue, le dossier est supprimé en entier." >&2
fi

# 2) macOS : chaque profil du portable a SA session dans le Trousseau, sous
# « Claude Code-credentials-<sha256(dossier config)[:8]> » (Claude suffixe le nom
# du service dès que CLAUDE_CONFIG_DIR est défini). On ne supprime QUE ces
# items-là, calculés depuis les dossiers de ce portable, AVANT d'effacer le
# dossier. Surtout pas « Claude Code-credentials » sans suffixe : c'est la
# session du Claude Code normal de la machine (~/.claude), pas la nôtre.
if [ "$(uname -s)" = "Darwin" ] && [ -d "$DIR/config" ]; then
  verifie_ou_refuse
  if [ -n "$CORE" ]; then
    sortie="$("$CORE" --root "$DIR" accounts purge 2>&1)"; rc=$?
    if [ "$rc" != 0 ]; then
      incomplet 11 "La purge des sessions est incomplète (code $rc) :"$'\n'"$(indente "$sortie")"
    fi
  fi
  for d in "$DIR"/config/*/; do
    [ -d "$d" ] || continue
    cfg="${d%/}"
    svc="Claude Code-credentials-$(printf '%s' "$cfg" | shasum -a 256 | cut -c1-8)"
    security delete-generic-password -s "$svc" >/dev/null 2>&1 && echo "  - Trousseau : $svc supprimé"
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
  incomplet 10 "Aucun noyau n'a répondu : les jetons Cloudflare Access éventuels (fichiers « …-token » de ~/.cloudflared) n'ont pas pu être effacés."
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
