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
#    - un marqueur posé dans le domicile ne rend pas le domicile effaçable ;
#    - (2e passe Codex) le bilan du ménage remonte : un effacement de jetons ou de sessions incomplet
#      donne un code non nul (10 / 11 / 12) et un message qui NOMME ce qui reste, jamais « Plus aucune
#      trace » ; contrôle positif joué contre l'ANCIEN script (commit 9975006, lu dans l'historique git) ;
#    - un ancêtre modifiable par d'autres (777, 775 sans bit sticky) est refusé, un ancêtre « sticky »
#      (1777, comme /tmp) est accepté ;
#    - un maillon du chemin (ancêtre ou dossier) ÉCHANGÉ contre un lien entre le jugement et l'effacement
#      — par le crochet de la couche, ou en dernier recours par le noyau, juste avant l'effacement —
#      donne un refus (code 2) et la cible du lien (un faux « domicile ») reste intacte ; le même
#      échange rejoué contre l'ANCIEN script supprime la cible (contrôle positif).
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
  local dir="$1" cwd="${2:-$BASE}" script="${SCRIPT_SOUS_TEST:-$UNINSTALL}"
  LAST_RC=0
  if [ "$dir" = "@absent@" ]; then
    LAST_OUT="$(cd "$cwd" && env -i HOME="$H" PATH="$FAUX:/usr/bin:/bin:/usr/sbin:/sbin" bash "$script" --oui 2>&1 < /dev/null)" || LAST_RC=$?
  else
    LAST_OUT="$(cd "$cwd" && env -i HOME="$H" PATH="$FAUX:/usr/bin:/bin:/usr/sbin:/sbin" BALUCHON_DIR="$dir" bash "$script" --oui 2>&1 < /dev/null)" || LAST_RC=$?
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

# ── L'ANCIEN script (commit 9975006), pour les CONTRÔLES POSITIFS des sections 7 et 9 ───────────────
# Une épreuve qui n'a jamais été vue rouge sur le vrai défaut ne prouve rien : on rejoue donc la même
# attaque contre le script d'avant la 2e revue Codex et on exige qu'elle RÉUSSISSE. Il vient de
# l'historique git ; sans historique (archive exportée), les contrôles sont sautés et DITS tels.
ANCIEN="$BASE/uninstall-ancien.sh"
if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$HERE" show 9975006:uninstall.sh > "$ANCIEN" 2>/dev/null && [ -s "$ANCIEN" ]; then
  A_ANCIEN=1
else
  A_ANCIEN=0; rm -f "$ANCIEN"
  echo "(!) historique git absent : les contrôles positifs sur l'ancien script (9975006) sont sautés"
fi

echo "== 7. le bilan du ménage remonte : jamais « Plus aucune trace » quand des jetons restent =="
# Revue Codex, 2e passe : uninstall.sh jetait la sortie de `remote forget-access`, ignorait son échec
# et annonçait « Plus aucune trace » alors qu'un jeton Access restait utilisable.
faire_noyau() { # faire_noyau <dossier> <code de accounts purge> <code de remote forget-access>
  local d="$1"
  mkdir -p "$d/bin/plat"
  cat > "$d/bin/plat/baluchon-core" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = "--contract" ] && exit 0
printf '%s\n' "\$*" >> "$JOURNAL_NOYAU"
case "\$*" in
  *"accounts purge"*)
    [ "$2" = 0 ] || echo "purge : profil p1 non effacé (PermissionDenied)" >&2
    exit $2 ;;
  *"remote forget-access"*)
    if [ "$3" != 0 ]; then
      echo "effacement INCOMPLET des jetons Cloudflare Access" >&2
      echo "mac-app-token : non effacé (PermissionDenied)" >&2
    fi
    exit $3 ;;
esac
exit 0
EOF
  chmod +x "$d/bin/plat/baluchon-core"
}
INST7="$BASE/bilan-forget"
faire_install "$INST7"; faire_noyau "$INST7" 0 10
lancer "$INST7"
[ "$LAST_RC" -eq 10 ] && verdict vrai "forget-access incomplet (code 10 du noyau) : uninstall.sh sort en 10" || verdict faux "forget-access incomplet : uninstall.sh sort en 10" "$LAST_RC $LAST_OUT"
case "$LAST_OUT" in *"mac-app-token"*) verdict vrai "…et le bilan NOMME ce qui reste" ;; *) verdict faux "…et le bilan NOMME ce qui reste" "$LAST_OUT" ;; esac
case "$LAST_OUT" in *"Plus aucune trace"*) verdict faux "…et ne dit JAMAIS « Plus aucune trace »" "$LAST_OUT" ;; *) verdict vrai "…et ne dit JAMAIS « Plus aucune trace »" ;; esac
case "$LAST_OUT" in *"UTILISABLES"*) verdict vrai "…et avertit que les jetons restent utilisables" ;; *) verdict faux "…et avertit que les jetons restent utilisables" "$LAST_OUT" ;; esac
[ ! -e "$INST7" ] && temoins_intacts && verdict vrai "…le dossier est quand même supprimé, les témoins du domicile intacts" || verdict faux "…le dossier est quand même supprimé, les témoins du domicile intacts"

INST7B="$BASE/bilan-ok"
faire_install "$INST7B"; faire_noyau "$INST7B" 0 0
lancer "$INST7B"
[ "$LAST_RC" -eq 0 ] && verdict vrai "forget-access complet : code 0" || verdict faux "forget-access complet : code 0" "$LAST_RC $LAST_OUT"
case "$LAST_OUT" in *"Plus aucune trace"*) verdict vrai "…et « Plus aucune trace » est dit" ;; *) verdict faux "…et « Plus aucune trace » est dit" "$LAST_OUT" ;; esac

INST7C="$BASE/bilan-sans-noyau"
faire_install "$INST7C"; rm -f "$INST7C/bin/plat/baluchon-core"
printf 'host = mac.example.test\n' > "$INST7C/config/remote.conf"
lancer "$INST7C"
[ "$LAST_RC" -eq 10 ] && verdict vrai "aucun noyau ne répond mais un Mac est configuré : code 10" || verdict faux "aucun noyau ne répond mais un Mac est configuré : code 10" "$LAST_RC $LAST_OUT"
case "$LAST_OUT" in *"Aucun noyau"*) verdict vrai "…et il le dit" ;; *) verdict faux "…et il le dit" "$LAST_OUT" ;; esac

if [ "$(uname -s)" = Darwin ]; then
  INST7D="$BASE/bilan-purge"
  faire_install "$INST7D"; faire_noyau "$INST7D" 11 0
  lancer "$INST7D"
  [ "$LAST_RC" -eq 11 ] && verdict vrai "purge des sessions incomplète (code 11 du noyau) : uninstall.sh sort en 11" || verdict faux "purge des sessions incomplète : uninstall.sh sort en 11" "$LAST_RC $LAST_OUT"
  case "$LAST_OUT" in *"Plus aucune trace"*) verdict faux "…sans « Plus aucune trace »" "$LAST_OUT" ;; *"PermissionDenied"*) verdict vrai "…sans « Plus aucune trace », avec le bilan" ;; *) verdict faux "…avec le bilan" "$LAST_OUT" ;; esac
fi

if [ "$A_ANCIEN" = 1 ]; then
  INST7E="$BASE/bilan-ancien"
  faire_install "$INST7E"; faire_noyau "$INST7E" 0 10
  SCRIPT_SOUS_TEST="$ANCIEN" lancer "$INST7E"
  case "$LAST_OUT" in
    *"Plus aucune trace"*) [ "$LAST_RC" -eq 0 ] && verdict vrai "CONTRÔLE POSITIF : l'ANCIEN script annonçait « Plus aucune trace » (code 0) malgré un jeton resté" || verdict faux "contrôle positif (ancien script)" "$LAST_RC $LAST_OUT" ;;
    *) verdict faux "CONTRÔLE POSITIF : l'ANCIEN script aurait dû mentir (« Plus aucune trace »)" "$LAST_RC $LAST_OUT" ;;
  esac
fi

echo "== 8. un ancêtre que d'autres utilisateurs peuvent modifier : refus =="
# Un autre utilisateur qui peut écrire dans un ancêtre peut y remplacer un maillon par un lien APRÈS
# le jugement. Les cas « propriétaire étranger » ne se jouent pas sans un second compte : seuls les
# bits de mode se prouvent ici.
mkdir -p "$BASE/ouvert" && chmod 777 "$BASE/ouvert"
faire_install "$BASE/ouvert/inst"
expect_refus "ancêtre inscriptible par tout le monde, sans bit sticky (777)" "$BASE/ouvert/inst"
case "$LAST_OUT" in *"ancêtre"*) verdict vrai "…le message nomme l'ancêtre" ;; *) verdict faux "…le message nomme l'ancêtre" "$LAST_OUT" ;; esac
[ -f "$BASE/ouvert/inst/config/p1/.credentials.json" ] && verdict vrai "…l'installation est intacte" || verdict faux "…l'installation est intacte"
mkdir -p "$BASE/groupe" && chmod 775 "$BASE/groupe"
faire_install "$BASE/groupe/inst"
expect_refus "ancêtre inscriptible par le groupe, sans bit sticky (775)" "$BASE/groupe/inst"
mkdir -p "$BASE/haut/milieu" && chmod 777 "$BASE/haut" && chmod 755 "$BASE/haut/milieu"
faire_install "$BASE/haut/milieu/inst"
expect_refus "ancêtre LOINTAIN inscriptible (777, deux niveaux au-dessus)" "$BASE/haut/milieu/inst"
mkdir -p "$BASE/colle" && chmod 1777 "$BASE/colle"
faire_install "$BASE/colle/inst"
lancer "$BASE/colle/inst"
[ "$LAST_RC" -eq 0 ] && [ ! -e "$BASE/colle/inst" ] && verdict vrai "ancêtre inscriptible mais avec le bit sticky (1777, comme /tmp) : accepté, désinstallé" || verdict faux "ancêtre avec bit sticky : accepté" "$LAST_RC $LAST_OUT"
# Le crochet de la couche s'exécute entre le jugement et l'effacement : c'est le moment où un tiers
# échangerait un maillon. On joue cet échange EXACT (un ancêtre devient un lien vers le dossier qui
# contient la cible visée) et on exige un refus, la cible visée intacte.
echo "== 9. un maillon du chemin échangé entre le jugement et l'effacement =="
scenario_ancetre() { # scenario_ancetre <nom> <script> : l'installation est $BASE/<nom>/p/<nom>v ; le crochet échange p
  local n="$1" ext="$BASE/$1" victime="$BASE/$1v"
  mkdir -p "$ext/p" "$victime"
  printf 'precieux\n' > "$victime/temoin.txt"
  faire_install "$ext/p/${n}v"
  mkdir -p "$ext/p/${n}v/overlay/hooks"
  # Après l'échange, $ext/p/<n>v désigne $BASE/<n>v : la VICTIME (le « domicile » de l'attaque de Codex).
  printf '#!/usr/bin/env bash\nmv "%s/p" "%s/p.reel" && ln -s "%s" "%s/p"\n' "$ext" "$ext" "$BASE" "$ext" > "$ext/p/${n}v/overlay/hooks/uninstall"
  SCRIPT_SOUS_TEST="$2" lancer "$ext/p/${n}v"
}
scenario_ancetre echange-nouveau "$UNINSTALL"
[ "$LAST_RC" -eq 2 ] && verdict vrai "ancêtre échangé après le jugement : refus (code 2)" || verdict faux "ancêtre échangé après le jugement : refus (code 2)" "$LAST_RC $LAST_OUT"
[ "$(cat "$BASE/echange-nouveauv/temoin.txt" 2>/dev/null)" = precieux ] && verdict vrai "…la cible visée par le lien (le « domicile ») est INTACTE" || verdict faux "…la cible visée par le lien est INTACTE" "$LAST_OUT"
[ -f "$BASE/echange-nouveau/p.reel/echange-nouveauv/config/p1/.credentials.json" ] && verdict vrai "…et l'installation d'origine n'a pas été touchée par le lien" || verdict faux "…et l'installation d'origine n'a pas été touchée"
case "$LAST_OUT" in *"a changé"*) verdict vrai "…et le message dit que le dossier a changé" ;; *) verdict faux "…et le message dit que le dossier a changé" "$LAST_OUT" ;; esac
if [ "$A_ANCIEN" = 1 ]; then
  scenario_ancetre echange-ancien "$ANCIEN"
  [ ! -e "$BASE/echange-ancienv/temoin.txt" ] \
    && verdict vrai "CONTRÔLE POSITIF : le même échange fait supprimer la cible par l'ANCIEN script (l'attaque de Codex réussissait)" \
    || verdict faux "CONTRÔLE POSITIF : l'ancien script aurait dû supprimer la cible" "$LAST_RC $LAST_OUT"
fi
# Le dernier maillon (le dossier lui-même) remplacé par un lien vers la victime.
fn=feuille-nouveau; ext="$BASE/$fn"; mkdir -p "$ext/p" "$BASE/${fn}v"
printf 'precieux\n' > "$BASE/${fn}v/temoin.txt"
faire_install "$ext/p/inst"
mkdir -p "$ext/p/inst/overlay/hooks"
printf '#!/usr/bin/env bash\nmv "%s/p/inst" "%s/p/inst.reel" && ln -s "%s/%sv" "%s/p/inst"\n' "$ext" "$ext" "$BASE" "$fn" "$ext" > "$ext/p/inst/overlay/hooks/uninstall"
lancer "$ext/p/inst"
[ "$LAST_RC" -eq 2 ] && [ "$(cat "$BASE/${fn}v/temoin.txt" 2>/dev/null)" = precieux ] \
  && verdict vrai "dossier remplacé par un lien après le jugement : refus (code 2), cible intacte" \
  || verdict faux "dossier remplacé par un lien après le jugement : refus, cible intacte" "$LAST_RC $LAST_OUT"
# La fenêtre la plus étroite : l'échange arrive APRÈS la dernière revérification (c'est le noyau, appelé
# juste avant l'effacement, qui l'opère). Seul l'effacement ancré sur le dossier PARENT figé y résiste.
scenario_fenetre() { # scenario_fenetre <nom> <script> : le faux noyau échange un ancêtre pendant forget-access
  local n="$1" ext="$BASE/$1" victime="$BASE/$1v"
  mkdir -p "$ext/p" "$victime"
  printf 'precieux\n' > "$victime/temoin.txt"
  faire_install "$ext/p/${n}v"
  cat > "$ext/p/${n}v/bin/plat/baluchon-core" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = "--contract" ] && exit 0
case "\$*" in
  *"remote forget-access"*) mv "$ext/p" "$ext/p.reel" && ln -s "$BASE" "$ext/p" ;;
esac
exit 0
EOF
  SCRIPT_SOUS_TEST="$2" lancer "$ext/p/${n}v"
}
scenario_fenetre fenetre-nouveau "$UNINSTALL"
[ "$LAST_RC" -eq 2 ] && [ "$(cat "$BASE/fenetre-nouveauv/temoin.txt" 2>/dev/null)" = precieux ] \
  && verdict vrai "échange pendant le ménage, après la dernière revérification : l'effacement ancré refuse (code 2), cible intacte" \
  || verdict faux "échange après la dernière revérification : refus, cible intacte" "$LAST_RC $LAST_OUT"
if [ "$A_ANCIEN" = 1 ]; then
  scenario_fenetre fenetre-ancien "$ANCIEN"
  [ ! -e "$BASE/fenetre-ancienv/temoin.txt" ] \
    && verdict vrai "CONTRÔLE POSITIF : le même échange fait supprimer la cible par l'ANCIEN script (résolution en double)" \
    || verdict faux "CONTRÔLE POSITIF : l'ancien script aurait dû supprimer la cible" "$LAST_RC $LAST_OUT"
fi

echo
printf '%d ok, %d ko\n' "$OK" "$KO"
[ "$KO" -eq 0 ]
