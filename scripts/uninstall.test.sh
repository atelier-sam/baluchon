#!/usr/bin/env bash
# ============================================================
#  uninstall.test.sh <dossier-vide-absolu>
#
#  Épreuves de uninstall.sh dans un domicile JETABLE (HOME=<dossier>/home). Un `rm -rf` sur une
#  variable est le geste le plus dangereux du dépôt : la revue Codex terminale a montré que
#  `BALUCHON_DIR="$HOME/."` passait la garde par comparaison de chaînes et effaçait le domicile.
#
#  Ce qui est prouvé :
#    - sont REFUSÉS (code 2, rien n'est effacé, un témoin du domicile est intact) :
#      « $HOME/. », « $HOME/.. », « $HOME/ », « $HOME », « / », le parent du domicile, un lien symbolique
#      vers le domicile, un dossier ordinaire sans marqueur, un marqueur qui est un LIEN, un
#      marqueur au mauvais texte, un dossier dont un enfant est le domicile, « . » depuis le domicile ;
#    - un dossier absent n'est pas une installation (code 1, rien n'est fait) ;
#    - une installation marquée est désinstallée : dossier effacé, Trousseau (faux `security`)
#      et noyau (faux noyau qui répond à --contract) appelés, commandes de ~/.local/bin retirées
#      si elles lancent ce dossier, et SEULEMENT celles-là ;
#    - une installation atteinte par un LIEN SYMBOLIQUE est effacée à sa vraie place, le lien
#      aussi, et le domicile reste intact ;
#    - un marqueur posé dans le domicile ne rend pas le domicile effaçable.
#
#  Le Trousseau et le noyau sont des FAUX (dans le PATH / le dossier d'essai) : aucun vrai item,
#  aucun vrai jeton, aucun vrai `claude`. Rien n'est jamais supprimé hors de <dossier-vide-absolu>.
#  Sortie : « N ok, M ko » ; code 0 seulement si M = 0.
# ============================================================
# SC2015 : `verdict` rend toujours 0, le « A && ok || ko » est donc un vrai si-sinon.
# SC2016 : les petits scripts factices s'écrivent volontairement entre apostrophes.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

ulimit -u "$(( $(ps -A | wc -l) + 300 ))" 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALL="$HERE/../uninstall.sh"
[ -f "$UNINSTALL" ] || { echo "uninstall.sh introuvable" >&2; exit 2; }

BASE_IN="${1:-}"
[ -n "$BASE_IN" ] || { echo "usage : uninstall.test.sh <dossier-vide-absolu>" >&2; exit 2; }
case "$BASE_IN" in /*) ;; *) echo "le dossier doit être un chemin ABSOLU" >&2; exit 2 ;; esac
[ -d "$BASE_IN" ] || { echo "dossier absent : $BASE_IN" >&2; exit 2; }
[ -z "$(ls -A "$BASE_IN")" ] || { echo "le dossier n'est pas vide : $BASE_IN" >&2; exit 2; }
BASE="$(cd "$BASE_IN" && pwd -P)"

OK=0
KO=0
verdict() { # verdict <vrai|faux> <libellé> [détail]
  if [ "$1" = vrai ]; then
    OK=$((OK + 1)); printf 'ok   %s\n' "$2"
  else
    KO=$((KO + 1)); printf 'KO   %s\n' "$2"; [ -z "${3:-}" ] || printf '%s\n' "$3" | sed 's/^/       /'
  fi
}
LAST_OUT=""
LAST_RC=0

# ── Faux PATH : `security` et `shasum` réels ne sont pas touchés, `security` est un journal ──────────
FAUX="$BASE/faux-bin"
JOURNAL_SECURITY="$BASE/security.log"
JOURNAL_NOYAU="$BASE/noyau.log"
mkdir -p "$FAUX"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$JOURNAL_SECURITY" > "$FAUX/security"
chmod +x "$FAUX/security"

# ── Un domicile jetable, avec des TÉMOINS qui ne doivent jamais disparaître ──────────────────────────
H="$BASE/home"
mkdir -p "$H/Documents" "$H/.local/bin" "$H/.ssh"
printf 'precieux\n' > "$H/Documents/thèse.txt"
printf 'cle\n' > "$H/.ssh/id_essai"
printf 'temoin\n' > "$H/temoin.txt"

temoins_intacts() {
  [ "$(cat "$H/Documents/thèse.txt" 2>/dev/null)" = precieux ] \
    && [ "$(cat "$H/.ssh/id_essai" 2>/dev/null)" = cle ] \
    && [ "$(cat "$H/temoin.txt" 2>/dev/null)" = temoin ]
}

# Une installation factice : le marqueur, un faux noyau (répond à --contract, journalise le reste), un
# profil (dossier config/p1) et les commandes courtes que l'installeur écrit dans ~/.local/bin.
faire_install() { # faire_install <dossier>
  local d="$1"
  mkdir -p "$d/bin/plat" "$d/config/p1" "$d/lib"
  printf 'baluchon-install 1\n' > "$d/.baluchon-install"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = "--contract" ] && exit 0\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$JOURNAL_NOYAU" > "$d/bin/plat/baluchon-core"
  chmod +x "$d/bin/plat/baluchon-core"
  printf 'x\n' > "$d/Claude.command"
  printf 'secret\n' > "$d/config/p1/.credentials.json"
}

lancer() { # lancer <BALUCHON_DIR ou rien> [dossier-de-travail] : uninstall.sh --oui dans le faux domicile
  local dir="$1" cwd="${2:-$BASE}"
  LAST_RC=0
  if [ "$dir" = "@absent@" ]; then
    LAST_OUT="$(cd "$cwd" && env -i HOME="$H" PATH="$FAUX:/usr/bin:/bin:/usr/sbin:/sbin" bash "$UNINSTALL" --oui 2>&1 < /dev/null)" || LAST_RC=$?
  else
    LAST_OUT="$(cd "$cwd" && env -i HOME="$H" PATH="$FAUX:/usr/bin:/bin:/usr/sbin:/sbin" BALUCHON_DIR="$dir" bash "$UNINSTALL" --oui 2>&1 < /dev/null)" || LAST_RC=$?
  fi
}
# ARRÊT DE SÉCURITÉ : si un uninstall.sh défaillant laisse passer une cible dangereuse, les cas
# suivants (« / », le parent du domicile) ne doivent pas être joués contre lui. Les cibles sont
# ordonnées du plus inoffensif (le faux domicile) au plus large ; au premier refus manqué, on s'arrête.
SECURITE=1
expect_refus() { # expect_refus <libellé> <BALUCHON_DIR> [cwd] : code 2, rien d'effacé
  lancer "$2" "${3:-$BASE}"
  if [ "$LAST_RC" -eq 2 ] && temoins_intacts; then
    verdict vrai "$1 : refusé (code 2), témoins du domicile intacts"
  else
    verdict faux "$1 : refusé (code 2), témoins du domicile intacts" "code $LAST_RC ; témoins : $(temoins_intacts && echo intacts || echo ENDOMMAGÉS) ; $LAST_OUT"
    if [ "$SECURITE" = 1 ]; then
      printf '\nARRÊT DE SÉCURITÉ : une cible dangereuse n'"'"'a pas été refusée ; les épreuves suivantes ne sont pas jouées.\n%d ok, %d ko\n' "$OK" "$KO"
      exit 3
    fi
  fi
}

echo "== 0. syntaxe =="
bash -n "$UNINSTALL" && verdict vrai "bash -n uninstall.sh" || verdict faux "bash -n uninstall.sh"
bash -n "${BASH_SOURCE[0]}" && verdict vrai "bash -n uninstall.test.sh" || verdict faux "bash -n uninstall.test.sh"

echo "== 1. refus : le domicile et ses parents, sous toutes leurs écritures =="
# Même avec un marqueur dans le domicile (un dossier peut avoir été « installé » à tort ici) : le
# domicile ne s'efface JAMAIS.
printf 'baluchon-install 1\n' > "$H/.baluchon-install"
expect_refus '$HOME' "$H"
expect_refus '$HOME/' "$H/"
expect_refus '$HOME/.  (revue Codex : passait la comparaison de chaînes)' "$H/."
expect_refus '$HOME/..' "$H/.."
expect_refus '$HOME/Documents/..' "$H/Documents/.."
expect_refus '$HOME/./' "$H/./"
expect_refus '"."  lancé depuis le domicile' "." "$H"
expect_refus '".."  lancé depuis un enfant du domicile' ".." "$H/Documents"
expect_refus "le parent direct du domicile (qui le contient)" "$BASE"
expect_refus "la racine du disque" "/"
lancer ""
# Vide = non défini (`${BALUCHON_DIR:-défaut}`) : on retombe sur ~/.baluchon, qui n'existe pas encore.
[ "$LAST_RC" -eq 1 ] && temoins_intacts && verdict vrai "BALUCHON_DIR vide : retombe sur ~/.baluchon, absent, rien n'est fait (code 1)" || verdict faux "BALUCHON_DIR vide : retombe sur ~/.baluchon, absent, rien n'est fait (code 1)" "$LAST_RC $LAST_OUT"
rm -f "$H/.baluchon-install"
ln -s "$H" "$BASE/lien-vers-domicile"
printf 'baluchon-install 1\n' > "$H/.baluchon-install"
expect_refus "un lien symbolique vers le domicile" "$BASE/lien-vers-domicile"
expect_refus "un lien symbolique vers le domicile, avec « /. » derrière" "$BASE/lien-vers-domicile/."
rm -f "$H/.baluchon-install"
ln -s "$BASE" "$H/lien-vers-parent"
expect_refus "un lien, dans le domicile, vers le PARENT du domicile" "$H/lien-vers-parent"
rm -f "$H/lien-vers-parent"

echo "== 2. refus : un dossier qui ne se déclare pas installation de Baluchon =="
mkdir -p "$H/Documents/projet"
printf 'a\n' > "$H/Documents/projet/a.txt"
expect_refus "un dossier ordinaire du domicile (sans marqueur)" "$H/Documents"
[ -f "$H/Documents/projet/a.txt" ] && verdict vrai "…et son contenu est intact" || verdict faux "…et son contenu est intact"
faire_install "$BASE/sans-marqueur"
rm -f "$BASE/sans-marqueur/.baluchon-install"
expect_refus "une installation à laquelle le marqueur manque" "$BASE/sans-marqueur"
[ -f "$BASE/sans-marqueur/config/p1/.credentials.json" ] && verdict vrai "…et ses fichiers sont intacts" || verdict faux "…et ses fichiers sont intacts"
case "$LAST_OUT" in *"marqueur"*) verdict vrai "…et le message nomme le marqueur" ;; *) verdict faux "…et le message nomme le marqueur" "$LAST_OUT" ;; esac
faire_install "$BASE/marqueur-lien"
rm -f "$BASE/marqueur-lien/.baluchon-install"
printf 'baluchon-install 1\n' > "$BASE/ailleurs.txt"
ln -s "$BASE/ailleurs.txt" "$BASE/marqueur-lien/.baluchon-install"
expect_refus "un marqueur qui est un lien symbolique" "$BASE/marqueur-lien"
faire_install "$BASE/marqueur-faux"
printf 'autre chose\n' > "$BASE/marqueur-faux/.baluchon-install"
expect_refus "un marqueur au mauvais texte" "$BASE/marqueur-faux"
faire_install "$BASE/marqueur-dossier"
rm -f "$BASE/marqueur-dossier/.baluchon-install"
mkdir "$BASE/marqueur-dossier/.baluchon-install"
expect_refus "un marqueur qui est un dossier" "$BASE/marqueur-dossier"

echo "== 3. un dossier absent n'est pas une installation =="
lancer "$BASE/n-existe-pas"
[ "$LAST_RC" -eq 1 ] && temoins_intacts && verdict vrai "dossier absent : code 1, rien n'est fait" || verdict faux "dossier absent : code 1, rien n'est fait" "$LAST_RC $LAST_OUT"

echo "== 4. une installation marquée est désinstallée =="
: > "$JOURNAL_SECURITY"; : > "$JOURNAL_NOYAU"
INST="$H/.baluchon"
faire_install "$INST"
# Les commandes courtes, comme install.sh les écrit : deux sont à nous, une est un AUTRE programme.
printf '#!/usr/bin/env bash\nexec "%s/Claude.command" "$@"\n' "$INST" > "$H/.local/bin/baluchon"
printf '#!/usr/bin/env bash\nexec "%s/Claude.command" "$@"\n' "$INST" > "$H/.local/bin/baluchon1"
printf '#!/usr/bin/env bash\necho un autre programme nommé ccp\n' > "$H/.local/bin/ccp"
lancer "@absent@"
[ "$LAST_RC" -eq 0 ] && verdict vrai "installation par défaut (~/.baluchon) : code 0" || verdict faux "installation par défaut (~/.baluchon) : code 0" "$LAST_RC $LAST_OUT"
[ ! -e "$INST" ] && verdict vrai "…le dossier est effacé" || verdict faux "…le dossier est effacé"
temoins_intacts && verdict vrai "…les témoins du domicile sont intacts" || verdict faux "…les témoins du domicile sont intacts"
[ ! -e "$H/.local/bin/baluchon" ] && [ ! -e "$H/.local/bin/baluchon1" ] && verdict vrai "…ses commandes courtes sont retirées" || verdict faux "…ses commandes courtes sont retirées"
[ -f "$H/.local/bin/ccp" ] && verdict vrai "…une commande qui n'est pas à nous (ccp) reste" || verdict faux "…une commande qui n'est pas à nous (ccp) reste"
if [ "$(uname -s)" = Darwin ]; then
  grep -q 'delete-generic-password -s Claude Code-credentials-' "$JOURNAL_SECURITY" \
    && verdict vrai "…l'item du Trousseau de chaque profil est supprimé (faux security)" \
    || verdict faux "…l'item du Trousseau de chaque profil est supprimé (faux security)" "$(cat "$JOURNAL_SECURITY")"
  if grep -qE ' Claude Code-credentials$' "$JOURNAL_SECURITY"; then
    verdict faux "…l'item SANS suffixe (le Claude de la machine) n'est jamais visé" "$(cat "$JOURNAL_SECURITY")"
  else
    verdict vrai "…l'item SANS suffixe (le Claude de la machine) n'est jamais visé"
  fi
fi
if grep -q 'accounts purge' "$JOURNAL_NOYAU" && grep -q 'remote forget-access' "$JOURNAL_NOYAU"; then
  verdict vrai "…le noyau est appelé : accounts purge et remote forget-access"
else
  verdict faux "…le noyau est appelé : accounts purge et remote forget-access" "$(cat "$JOURNAL_NOYAU")"
fi

echo "== 5. une installation atteinte par un lien symbolique =="
mkdir -p "$BASE/volume-externe"
faire_install "$BASE/volume-externe/baluchon"
ln -s "$BASE/volume-externe/baluchon" "$H/.baluchon"
lancer "@absent@"
[ "$LAST_RC" -eq 0 ] && verdict vrai "le lien .baluchon du domicile vers l'installation : code 0" || verdict faux "le lien .baluchon du domicile vers l'installation : code 0" "$LAST_RC $LAST_OUT"
[ ! -e "$BASE/volume-externe/baluchon" ] && verdict vrai "…le dossier réel est effacé" || verdict faux "…le dossier réel est effacé"
[ ! -L "$H/.baluchon" ] && [ ! -e "$H/.baluchon" ] && verdict vrai "…le lien aussi (pas de lien pendant)" || verdict faux "…le lien aussi (pas de lien pendant)"
temoins_intacts && verdict vrai "…les témoins du domicile sont intacts" || verdict faux "…les témoins du domicile sont intacts"
[ -d "$BASE/volume-externe" ] && verdict vrai "…et le dossier qui le contenait reste" || verdict faux "…et le dossier qui le contenait reste"

echo "== 6. un dossier d'installation ailleurs, donné par BALUCHON_DIR =="
faire_install "$BASE/portable"
lancer "$BASE/portable"
[ "$LAST_RC" -eq 0 ] && [ ! -e "$BASE/portable" ] && verdict vrai "BALUCHON_DIR=<dossier marqué> : désinstallé" || verdict faux "BALUCHON_DIR=<dossier marqué> : désinstallé" "$LAST_RC $LAST_OUT"
faire_install "$BASE/portable2"
lancer "portable2" "$BASE"
[ "$LAST_RC" -eq 0 ] && [ ! -e "$BASE/portable2" ] && verdict vrai "BALUCHON_DIR relatif (portable2, depuis le dossier parent) : désinstallé" || verdict faux "BALUCHON_DIR relatif : désinstallé" "$LAST_RC $LAST_OUT"
temoins_intacts && verdict vrai "…les témoins du domicile sont intacts" || verdict faux "…les témoins du domicile sont intacts"

echo
printf '%d ok, %d ko\n' "$OK" "$KO"
[ "$KO" -eq 0 ]
