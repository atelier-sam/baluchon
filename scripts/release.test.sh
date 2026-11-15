#!/usr/bin/env bash
# ============================================================
#  release.test.sh <dossier-vide-absolu>
#
#  Épreuves de scripts/release.sh dans un arbre JETABLE : une copie du script, un faux
#  core/Cargo.toml, une fausse bibliothèque qui porte une clé publique d'ESSAI, et une paire
#  de clés d'essai générée ici (jamais la vraie clé de signature, jamais lue). Hors ligne :
#  `CCP_DENY_DIRS=` éteint cargo-deny, qui a sa propre porte dans la vraie release.
#
#  Ce qui est prouvé : la release se REFUSE sans clé, sans tag, avec un tag qui ne vaut pas
#  v<version>, avec une clé publique qui diffère d'une copie à l'autre, avec une porte qui
#  échoue, avec un actif manquant, avec une sortie mal visée (et ne supprime alors rien) ;
#  et elle PRODUIT, quand tout est bon, un SHA256SUMS dont la signature se vérifie avec la
#  clé publique embarquée et qui ne se vérifie plus si un octet change.
#
#  Rien n'est jamais supprimé hors de <dossier-vide-absolu> : il doit exister et être vide,
#  c'est à l'appelant de le jeter.
#  Sortie : « N ok, M ko » ; code 0 seulement si M = 0.
# ============================================================
# SC2015 : `verdict` rend toujours 0, le « A && ok || ko » est donc un vrai si-sinon.
# SC2016 : les petits `bash -c '...'` d'essai s'écrivent volontairement entre apostrophes.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

ulimit -u "$(( $(ps -A | wc -l) + 300 ))" 2>/dev/null || true
for v in $(git rev-parse --local-env-vars 2>/dev/null); do unset "$v"; done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="$HERE/release.sh"
GARDE="$HERE/garde-lecture-seule.sh"
[ -f "$RELEASE" ] || { echo "release.sh introuvable" >&2; exit 2; }
[ -f "$GARDE" ] || { echo "garde-lecture-seule.sh introuvable" >&2; exit 2; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen est requis" >&2; exit 2; }

BASE_IN="${1:-}"
[ -n "$BASE_IN" ] || { echo "usage : release.test.sh <dossier-vide-absolu>" >&2; exit 2; }
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
run() { LAST_RC=0; LAST_OUT="$("$@" 2>&1)" || LAST_RC=$?; }
expect() { # expect <libellé> <code attendu> <commande...>
  local label="$1" want="$2"
  shift 2
  run "$@"
  local good=faux
  [ "$LAST_RC" -eq "$want" ] && good=vrai
  verdict "$good" "$label (code $LAST_RC, attendu $want)" "$LAST_OUT"
}
dit() { # dit <libellé> <fragment attendu dans la dernière sortie>
  case "$LAST_OUT" in *"$2"*) verdict vrai "$1" ;; *) verdict faux "$1" "attendu « $2 » dans : $LAST_OUT" ;; esac
}

# Paire de clés d'ESSAI (sans phrase secrète) : la vraie clé de signature n'est jamais touchée.
KEYS="$BASE/cles"
mkdir -p "$KEYS"
ssh-keygen -q -t ed25519 -N "" -C essai -f "$KEYS/essai" >/dev/null || { echo "ssh-keygen a échoué" >&2; exit 2; }
PUB="$(cut -d' ' -f1,2 "$KEYS/essai.pub")"

# Arbre jetable : arbre <nom> -> écrit T. Version 7.8.9, identité « essai-release ».
arbre() {
  T="$BASE/$1"
  mkdir -p "$T/scripts" "$T/core" "$T/lib" "$T/dist"
  cp "$RELEASE" "$T/scripts/release.sh"
  printf '[package]\nname = "x"\nversion = "7.8.9"\n' > "$T/core/Cargo.toml"
  printf "CCP_SIGNER='essai-release %s'\n" "$PUB" > "$T/lib/common.sh"
  printf "CCP_SIGNER='essai-release %s'\n" "$PUB" > "$T/install.sh"
  printf 'x\n' > "$T/install.ps1"; printf "%s\n" "$PUB" >> "$T/install.ps1"
  printf 'un\n' > "$T/a.txt"; printf 'deux\n' > "$T/b.txt"
  printf 'a.txt\ta.txt\nb.txt\tb.txt\n' > "$T/assets.tsv"
  # La garde lecture seule s'applique dès que la release porte la clé (ou l'identité) PUBLIQUE du
  # produit, ce qui est le cas de toutes ces releases d'essai : elle a besoin de ses sources.
  cp "$GARDE" "$T/scripts/garde-lecture-seule.sh"
  mkdir -p "$T/core/src"
  printf 'fn main() {}\n' > "$T/core/src/x.rs"
}
# Environnement commun d'une release d'essai.
rel() { # rel <arbre> [VAR=valeur]... : lance release.sh de l'arbre
  local t="$1"
  shift
  env CCP_SIGN_KEY="$KEYS/essai" CCP_SIGNER_ID=essai-release CCP_ASSETS="$t/assets.tsv" \
    CCP_DENY_DIRS= CCP_TAG=v7.8.9 CCP_OUT="$t/sortie" "$@" bash "$t/scripts/release.sh"
}

echo "== 0. syntaxe =="
expect "bash -n release.sh" 0 bash -n "$RELEASE"
expect "bash -n release.test.sh" 0 bash -n "${BASH_SOURCE[0]}"

echo "== 1. refus =="
arbre sans-cle
expect "sans clé de signature" 1 rel "$T" CCP_SIGN_KEY="$KEYS/absente"
dit "…et il nomme la clé" "clé de signature absente"
arbre sans-tag
expect "sans tag (arbre hors dépôt, CCP_TAG vide)" 1 rel "$T" CCP_TAG=
dit "…et il dit comment faire" "aucun tag"
arbre mauvais-tag
expect "tag qui ne vaut pas v<version>" 1 rel "$T" CCP_TAG=v9.9.9
dit "…et il nomme les deux" "divergent"
arbre autre-identite
expect "identité de la clé publique différente de celle attendue" 1 rel "$T" CCP_SIGNER_ID=autre-release
dit "…et il la nomme" "n'est pas autre-release"
arbre copie-differente
printf "CCP_SIGNER='essai-release ssh-ed25519 AAAAAUTRECLE'\n" > "$T/install.sh"
expect "une copie de la clé publique diffère" 1 rel "$T"
dit "…et il nomme le fichier" "install.sh différente"
arbre porte-rouge
printf '#!/usr/bin/env bash\nexit 7\n' > "$T/porte.sh"
expect "une porte supplémentaire qui échoue" 1 rel "$T" CCP_GATES=porte.sh
dit "…et il la nomme" "la porte porte.sh refuse"
[ ! -e "$T/sortie" ] && verdict vrai "…et rien n'a été produit" || verdict faux "…et rien n'a été produit"
arbre porte-absente
expect "une porte supplémentaire introuvable" 1 rel "$T" CCP_GATES=inconnue.sh
arbre actif-manquant
printf 'a.txt\ta.txt\nz.txt\tz.txt\n' > "$T/assets.tsv"
expect "un actif de la liste manque" 1 rel "$T"
dit "…et il le nomme" "actif manquant"
arbre liste-vide
: > "$T/assets.tsv"
expect "liste d'actifs vide" 1 rel "$T"

echo "== 2. sortie mal visée : refus, et rien n'est supprimé =="
arbre sortie-relative
expect "CCP_OUT relatif" 1 rel "$T" CCP_OUT=sortie
dit "…et il demande un chemin absolu" "chemin absolu"
arbre sortie-home
expect "CCP_OUT = le dossier personnel" 1 rel "$T" CCP_OUT="$HOME"
arbre sortie-racine-arbre
expect "CCP_OUT = la racine de l'arbre" 1 rel "$T" CCP_OUT="$T"
arbre sortie-etrangere
mkdir -p "$T/sortie"; printf 'important\n' > "$T/sortie/precieux.txt"
expect "CCP_OUT existe, n'est pas vide, n'est pas une release" 1 rel "$T"
[ "$(cat "$T/sortie/precieux.txt" 2>/dev/null)" = important ] && verdict vrai "…et le fichier qu'elle contenait est intact" || verdict faux "…et le fichier qu'elle contenait est intact"

echo "== 3. production =="
arbre ok
expect "release complète" 0 rel "$T"
S="$T/sortie"
[ -f "$S/SHA256SUMS" ] && [ -f "$S/SHA256SUMS.sig" ] && [ -f "$S/a.txt" ] && [ -f "$S/b.txt" ] \
  && verdict vrai "la sortie porte les actifs, SHA256SUMS et sa signature" || verdict faux "la sortie porte les actifs, SHA256SUMS et sa signature" "$(ls -A "$S" 2>&1)"
printf 'essai-release %s\n' "$PUB" > "$KEYS/allowed"
expect "la signature se vérifie avec la clé publique embarquée" 0 \
  bash -c 'ssh-keygen -Y verify -f "$1" -I essai-release -n file -s "$2" < "$3"' _ "$KEYS/allowed" "$S/SHA256SUMS.sig" "$S/SHA256SUMS"
expect "…et refuse la mauvaise identité" 255 \
  bash -c 'ssh-keygen -Y verify -f "$1" -I autre -n file -s "$2" < "$3"' _ "$KEYS/allowed" "$S/SHA256SUMS.sig" "$S/SHA256SUMS"
cp "$S/SHA256SUMS" "$KEYS/alteree"
printf 'x' >> "$KEYS/alteree"
expect "…et refuse un SHA256SUMS dont un octet a changé" 255 \
  bash -c 'ssh-keygen -Y verify -f "$1" -I essai-release -n file -s "$2" < "$3"' _ "$KEYS/allowed" "$S/SHA256SUMS.sig" "$KEYS/alteree"
expect "les sommes correspondent aux fichiers" 0 bash -c 'cd "$1" && shasum -a 256 -c SHA256SUMS' _ "$S"
expect "une seconde release remplace la première (sortie de release reconnue)" 0 rel "$T"

echo "== 4. la garde lecture seule suit l'IDENTITÉ de publication, pas le choix des actifs =="
# Revue Codex terminale : avec CCP_ASSETS, la garde passait toujours, et une liste personnalisée
# pouvait faire signer un noyau écrivant des identifiants comme une release PUBLIQUE.
ECRIT='grant_type=refresh_token'   # un motif que la garde refuse dans un actif
pub_arbre() { # pub_arbre <nom> : un arbre dont la bibliothèque porte l'identité PUBLIQUE
  arbre "$1"
  printf "CCP_SIGNER='baluchon-release %s'\n" "$PUB" > "$T/lib/common.sh"
}
pub_arbre pub-propre
expect "identité publique + liste personnalisée propre" 0 rel "$T" CCP_SIGNER_ID=baluchon-release
pub_arbre pub-contamine
printf '%s\n' "$ECRIT" > "$T/a.txt"
expect "identité publique + liste personnalisée dont un actif sait écrire un identifiant" 1 rel "$T" CCP_SIGNER_ID=baluchon-release
dit "…la garde lecture seule la refuse" "la garde lecture seule refuse la release"
[ ! -e "$T/sortie" ] && verdict vrai "…et rien n'a été produit ni signé" || verdict faux "…et rien n'a été produit ni signé"
# Le même actif, signé avec la CLÉ du produit sous un AUTRE nom : la clé publique du produit
# vérifie ce que tout client public vérifie, quel que soit le nom qu'on lui donne ici.
arbre cle-publique-autre-nom
printf "CCP_SIGNER='autre-release %s'\n" "$PUB" > "$T/lib/autre.sh"
printf '%s\n' "$ECRIT" > "$T/a.txt"
expect "clé publique du produit sous une autre identité + actif qui écrit" 1 rel "$T" CCP_SIGNER_ID=autre-release CCP_SIGNER_SRC=lib/autre.sh
dit "…la garde lecture seule la refuse aussi" "la garde lecture seule refuse la release"
# Une édition privée : sa propre clé, sa propre identité, son propre fichier de clé publique. La
# garde du public ne la concerne pas (son noyau écrit des identifiants, c'est sa raison d'être).
ssh-keygen -q -t ed25519 -N "" -C prive -f "$KEYS/prive" >/dev/null || { echo "ssh-keygen a échoué" >&2; exit 2; }
PUB2="$(cut -d' ' -f1,2 "$KEYS/prive.pub")"
pub_arbre edition-privee
printf "CCP_SIGNER='prive-release %s'\n" "$PUB2" > "$T/lib/prive.sh"
printf '%s\n' "$ECRIT" > "$T/a.txt"
expect "édition privée (sa clé, son identité) : la garde du public ne s'applique pas" 0 \
  rel "$T" CCP_SIGN_KEY="$KEYS/prive" CCP_SIGNER_ID=prive-release CCP_SIGNER_SRC=lib/prive.sh CCP_SIGNER_COPIES=
# La liste PAR DÉFAUT : les installeurs sont des actifs signés, et la garde juge chaque actif.
defaut_arbre() { # defaut_arbre <nom> : tous les fichiers de la liste publique, factices
  pub_arbre "$1"
  local plat exe
  printf 'x\n' > "$T/Claude.command"; printf 'x\n' > "$T/claude.cmd"; printf 'x\n' > "$T/claude-classic.cmd"
  printf 'x\n' > "$T/uninstall.sh"
  for plat in darwin-arm64 darwin-x64 linux-x64 linux-arm64 win32-x64; do
    exe=""; [ "$plat" = win32-x64 ] && exe=.exe
    mkdir -p "$T/dist/$plat"; printf 'binaire factice\n' > "$T/dist/$plat/baluchon-core$exe"
  done
}
defaut_arbre defaut-propre
expect "liste par défaut (CCP_ASSETS vide) : release complète" 0 rel "$T" CCP_SIGNER_ID=baluchon-release CCP_ASSETS=
grep -q ' install\.sh$' "$T/sortie/SHA256SUMS" && grep -q ' install\.ps1$' "$T/sortie/SHA256SUMS" \
  && verdict vrai "…install.sh et install.ps1 figurent dans SHA256SUMS (actifs signés)" \
  || verdict faux "…install.sh et install.ps1 figurent dans SHA256SUMS (actifs signés)" "$(cat "$T/sortie/SHA256SUMS" 2>&1)"
# Le désinstalleur est un actif signé : l'entrée « Partir » du menu l'exécute depuis l'installation.
grep -q ' uninstall\.sh$' "$T/sortie/SHA256SUMS" \
  && verdict vrai "…uninstall.sh figure dans SHA256SUMS (actif signé, exécuté par « Partir »)" \
  || verdict faux "…uninstall.sh figure dans SHA256SUMS (actif signé, exécuté par « Partir »)" "$(cat "$T/sortie/SHA256SUMS" 2>&1)"
defaut_arbre defaut-contamine
printf '%s\n' "$ECRIT" > "$T/dist/linux-x64/baluchon-core"
expect "liste par défaut dont un binaire sait écrire" 1 rel "$T" CCP_SIGNER_ID=baluchon-release CCP_ASSETS=
dit "…la garde lecture seule la refuse" "la garde lecture seule refuse la release"

echo "== 5. la garde suit la clé RÉELLEMENT utilisée, la ligne du signataire est stricte (re-revue Codex) =="
# Re-revue Codex : `CCP_SIGNER='autre namespaces="file" ssh-ed25519 <clé du produit>'` est valide pour
# allowed_signers mais son 3e champ vaut « ssh-ed25519 » : la garde, qui lisait ce champ, était sautée,
# et la signature restait acceptée par les clients publics (le principal n'est pas lié à la signature).
# Chaque attaque est d'abord rejouée contre l'ANCIEN release.sh (commit 9975006, lu dans l'historique
# git) : elle doit RÉUSSIR là. Sans historique (archive exportée), ces contrôles sont sautés et dits tels.
ANCIEN="$BASE/release-ancien.sh"
if git -C "$HERE" show 9975006:scripts/release.sh > "$ANCIEN" 2>/dev/null && [ -s "$ANCIEN" ]; then
  A_ANCIEN=1
else
  A_ANCIEN=0; rm -f "$ANCIEN"
  echo "(!) historique git absent : les contrôles positifs sur l'ancien release.sh (9975006) sont sautés"
fi
produit_arbre() { # produit_arbre <nom> [ancien] : lib/common.sh = clé du produit ; a.txt sait écrire un identifiant
  arbre "$1"
  [ "${2:-}" != ancien ] || cp "$ANCIEN" "$T/scripts/release.sh"
  printf "CCP_SIGNER='baluchon-release %s'\n" "$PUB" > "$T/lib/common.sh"
  printf '%s\n' "$ECRIT" > "$T/a.txt"
}
verifie_comme_un_client() { # la signature de $1/sortie passe-t-elle chez un client PUBLIC (identité baluchon-release) ?
  printf 'baluchon-release %s\n' "$PUB" > "$KEYS/allowed-public"
  ssh-keygen -Y verify -f "$KEYS/allowed-public" -I baluchon-release -n file -s "$1/sortie/SHA256SUMS.sig" < "$1/sortie/SHA256SUMS" >/dev/null 2>&1
}
# 5a. Le scénario exact de Codex.
codex_autre() { # lance le scénario sur l'arbre courant
  printf "CCP_SIGNER='autre namespaces=\"file\" %s'\n" "$PUB" > "$T/lib/autre.sh"
  rel "$T" CCP_SIGNER_ID=autre CCP_SIGNER_SRC=lib/autre.sh CCP_SIGNER_COPIES= CCP_SIGN_KEY="$KEYS/essai"
}
if [ "$A_ANCIEN" = 1 ]; then
  produit_arbre codex-ancien ancien
  run codex_autre
  if [ "$LAST_RC" -eq 0 ] && grep -q ' a\.txt$' "$T/sortie/SHA256SUMS" && verifie_comme_un_client "$T"; then
    verdict vrai "CONTRÔLE POSITIF : l'ANCIEN release.sh signe l'actif qui écrit un identifiant, et un client public accepte la signature"
  else
    verdict faux "CONTRÔLE POSITIF : l'ancien release.sh aurait dû laisser passer le scénario de Codex" "code $LAST_RC : $LAST_OUT"
  fi
fi
produit_arbre codex-nouveau
expect "ligne « autre namespaces=… » (scénario de Codex, copies désactivées, clé du produit)" 1 codex_autre
dit "…refusée pour son format" "format strict"
[ ! -e "$T/sortie" ] && verdict vrai "…et rien n'a été produit ni signé" || verdict faux "…et rien n'a été produit ni signé" "$(ls -A "$T/sortie" 2>&1)"
# 5b. Format strict, mais la clé embarquée n'est pas celle qui signe : avant, la signature (de la clé du
# produit, sur un actif qui écrit) était produite, la contre-vérification échouait APRÈS, et la sortie
# signée restait sur le disque, valide pour tout client public.
embarque_autre() {
  printf "CCP_SIGNER='prive-release %s'\n" "$PUB2" > "$T/lib/autre.sh"
  rel "$T" CCP_SIGNER_ID=prive-release CCP_SIGNER_SRC=lib/autre.sh CCP_SIGNER_COPIES= CCP_SIGN_KEY="$KEYS/essai"
}
if [ "$A_ANCIEN" = 1 ]; then
  produit_arbre embarque-ancien ancien
  run embarque_autre
  if [ "$LAST_RC" -ne 0 ] && [ -f "$T/sortie/SHA256SUMS.sig" ] && verifie_comme_un_client "$T"; then
    verdict vrai "CONTRÔLE POSITIF : l'ANCIEN release.sh échoue mais LAISSE une sortie signée de la clé du produit, valide pour un client public"
  else
    verdict faux "CONTRÔLE POSITIF : l'ancien release.sh aurait dû laisser une sortie signée" "code $LAST_RC : $LAST_OUT"
  fi
fi
produit_arbre embarque-nouveau
expect "clé embarquée ≠ clé qui signe (clé du produit, sous l'identité d'une édition privée)" 1 embarque_autre
dit "…refusée avant tout travail" "ne correspond pas à la clé publique embarquée"
[ ! -e "$T/sortie" ] && verdict vrai "…et aucune sortie signée ne reste" || verdict faux "…et aucune sortie signée ne reste" "$(ls -A "$T/sortie" 2>&1)"
# 5c. La garde se décide sur la clé dérivée, quelle que soit l'identité : la clé du produit sous une
# autre identité, ligne stricte (le cas de la section 4 passe maintenant par la clé dérivée).
produit_arbre derivee-nouveau
printf "CCP_SIGNER='autre-release %s'\n" "$PUB" > "$T/lib/autre.sh"
expect "clé du produit (dérivée de la clé privée) sous une autre identité + actif qui écrit" 1 \
  rel "$T" CCP_SIGNER_ID=autre-release CCP_SIGNER_SRC=lib/autre.sh CCP_SIGNER_COPIES= CCP_SIGN_KEY="$KEYS/essai"
dit "…la garde lecture seule la refuse" "la garde lecture seule refuse la release"
# 5d. Une seule ligne CCP_SIGNER= par fichier, au format strict, aussi dans la référence du produit.
produit_arbre deux-lignes
printf "CCP_SIGNER='autre-release %s'\nCCP_SIGNER='autre-release %s'\n" "$PUB" "$PUB" > "$T/lib/autre.sh"
expect "deux lignes CCP_SIGNER= dans le fichier du signataire" 1 \
  rel "$T" CCP_SIGNER_ID=autre-release CCP_SIGNER_SRC=lib/autre.sh CCP_SIGNER_COPIES= CCP_SIGN_KEY="$KEYS/essai"
dit "…refusées" "UNE SEULE ligne"
produit_arbre ligne-indentee
printf "  CCP_SIGNER='autre-release %s'\n" "$PUB" > "$T/lib/autre.sh"
expect "ligne CCP_SIGNER= indentée (pas au format strict)" 1 \
  rel "$T" CCP_SIGNER_ID=autre-release CCP_SIGNER_SRC=lib/autre.sh CCP_SIGNER_COPIES= CCP_SIGN_KEY="$KEYS/essai"
produit_arbre produit-illisible
printf "# plus de ligne ici\n" > "$T/lib/common.sh"
printf "CCP_SIGNER='prive-release %s'\n" "$PUB2" > "$T/lib/prive.sh"
expect "la référence du produit (lib/common.sh) n'a pas sa ligne : refus (on ne saurait pas quelle clé est publique)" 1 \
  rel "$T" CCP_SIGN_KEY="$KEYS/prive" CCP_SIGNER_ID=prive-release CCP_SIGNER_SRC=lib/prive.sh CCP_SIGNER_COPIES=
dit "…et il le dit" "lib/common.sh doit porter"
# 5e. Une clé de signature qui n'en est pas une, ou qui n'est pas celle de la ligne.
produit_arbre cle-invalide
printf 'pas une clé\n' > "$KEYS/faux"; chmod 600 "$KEYS/faux"
expect "CCP_SIGN_KEY n'est pas une clé privée" 1 rel "$T" CCP_SIGN_KEY="$KEYS/faux" CCP_SIGNER_ID=baluchon-release
dit "…et il le dit" "impossible de dériver"
[ ! -e "$T/sortie" ] && verdict vrai "…et rien n'a été produit" || verdict faux "…et rien n'a été produit"
# 5f. Le chemin légitime reste ouvert : l'édition privée (sa clé, sa ligne stricte) n'est pas gênée.
pub_arbre edition-privee-2
printf "CCP_SIGNER='prive-release %s'\n" "$PUB2" > "$T/lib/prive.sh"
printf '%s\n' "$ECRIT" > "$T/a.txt"
expect "édition privée (clé dérivée ≠ clé du produit) : release produite, la garde du public ne s'applique pas" 0 \
  rel "$T" CCP_SIGN_KEY="$KEYS/prive" CCP_SIGNER_ID=prive-release CCP_SIGNER_SRC=lib/prive.sh CCP_SIGNER_COPIES=

echo
printf '%d ok, %d ko\n' "$OK" "$KO"
[ "$KO" -eq 0 ]
