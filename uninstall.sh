#!/usr/bin/env bash
# ============================================================
#  Baluchon — désinstallation / nettoyage des traces (thorough)
#  Usage :  curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/uninstall.sh | bash
#           (sans question : ... | bash -s -- --oui)
#  Supprime TOUT : binaires, interface, sessions, l'item Trousseau macOS de chaque profil,
#  les jetons Cloudflare Access laissés par la liaison avec le Mac, et la couche
#  (overlay/) éventuelle, après avoir appelé son crochet `uninstall`.
#  Il ne supprime QUE un dossier qui porte le marqueur d'installation (.baluchon-install) et qui
#  n'est ni « / », ni ton domicile, ni un parent de ton domicile (chemin canonique, liens suivis).
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
#      fichier ordinaire (pas un lien). Sans marqueur, ce n'est pas notre dossier : rien n'est effacé.
MARQUEUR=".baluchon-install"
MARQUEUR_TEXTE="baluchon-install 1"
refus() { printf '✗ %s Rien n'"'"'est supprimé.\n' "$1" >&2; exit 2; }
canonique() { ( cd -P -- "$1" 2>/dev/null && pwd -P ); }

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

echo "Cela va supprimer :"
echo "  - $DIR   (binaires, interface, SESSIONS, couche éventuelle)"
echo "  - les commandes  baluchon  baluchon1  ccp  ccp1  de $BINDIR (seulement si elles pointent ici)"
if [ "$OUI" != 1 ]; then
  # Avec `curl | bash`, l'entrée standard est le script lui-même : la réponse se lit au clavier.
  printf "Confirmer ? [tape OUI] : "
  if [ -t 0 ]; then read -r ans; else read -r ans < /dev/tty 2>/dev/null || ans=""; fi
  [ "$ans" = "OUI" ] || { echo "Annulé."; exit 1; }
fi

# Le noyau qui sait le mieux effacer : celui de la couche s'il y en a un qui répond, sinon le public.
# Chaque candidat doit répondre à --contract (un binaire d'une autre plateforme n'est pas choisi).
CORE=""
for c in "$DIR"/overlay/bin/*/baluchon-core "$DIR"/bin/*/baluchon-core; do
  [ -x "$c" ] || continue
  "$c" --contract >/dev/null 2>&1 && { CORE="$c"; break; }
done

# 1) Le crochet de la couche défait ce que la couche a posé hors de overlay/.
if [ -f "$DIR/overlay/hooks/uninstall" ]; then
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
  if [ -n "$CORE" ]; then
    "$CORE" --root "$DIR" accounts purge >/dev/null 2>&1 || true
  fi
  for d in "$DIR"/config/*/; do
    [ -d "$d" ] || continue
    cfg="${d%/}"
    svc="Claude Code-credentials-$(printf '%s' "$cfg" | shasum -a 256 | cut -c1-8)"
    security delete-generic-password -s "$svc" >/dev/null 2>&1 && echo "  - Trousseau : $svc supprimé"
  done
fi

# 3) Jetons Cloudflare Access de ~/.cloudflared (application ET équipe) : sans eux, plus personne
# ne peut rouvrir la liaison avec le Mac depuis cet ordinateur.
if [ -n "$CORE" ]; then
  "$CORE" --root "$DIR" remote forget-access >/dev/null 2>&1 || true
fi

# On efface le dossier PHYSIQUE jugé plus haut (jamais le chemin tel que tapé), puis le lien qui y
# menait s'il y en avait un.
rm -rf "$DIR"
if [ -L "$DIR_DEMANDE" ]; then rm -f "$DIR_DEMANDE"; fi

# 4) Les commandes : seulement celles qui lancent CE dossier (`ccp` peut être un autre programme).
# L'installeur y a écrit le chemin tel qu'il l'avait reçu : on reconnaît aussi bien celui-là que le canonique.
for n in baluchon baluchon1 ccp ccp1; do
  f="$BINDIR/$n"
  if [ -f "$f" ] && { grep -qF "$DIR/Claude.command" "$f" 2>/dev/null || grep -qF "${DIR_DEMANDE%/}/Claude.command" "$f" 2>/dev/null; }; then
    rm -f "$f"
  fi
done

echo "✓ Désinstallé. Plus aucune trace de Baluchon sur cette machine."
echo "  (Pense à révoquer la session sur https://claude.ai si la machine n'est pas la tienne.)"
