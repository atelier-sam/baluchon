#!/usr/bin/env bash
# ============================================================
#  garde-lecture-seule.test.sh <dossier-vide-absolu>
#
#  Épreuves de `garde-lecture-seule.sh` sur des arbres et des « binaires » JETABLES,
#  un sous-dossier par scénario, tous sous <dossier-vide-absolu>. Rien n'est jamais
#  supprimé : le dossier doit exister, être vide, et c'est à l'appelant de le jeter.
#  Aucune épreuve ne lit un jeton ni ne lance quoi que ce soit d'autre que la garde.
#
#  POURQUOI : une garde qui ne peut pas échouer ne prouve rien. Chaque motif a donc son
#  épreuve ROUGE (le motif seul dans un arbre, la garde refuse et le nomme), et chaque
#  exception a son épreuve VERTE (l'accesseur `refresh_token()`, `delete_all`...). Une
#  régression de la garde elle-même est déjà arrivée : un tube vers `grep -q` + `pipefail`
#  rendait le test faux sur un gros binaire contenant le motif (le binaire d'une édition
#  qui sait écrire passait vert). L'épreuve « gros binaire » la rejoue.
#
#  Sortie : « N ok, M ko » ; code 0 seulement si M = 0.
# ============================================================
# SC2015 : `verdict` rend toujours 0, le « A && ok || ko » est donc un vrai si-sinon.
# shellcheck disable=SC2015
set -uo pipefail

# Plafond de processus : une épreuve qui boucle ne doit pas saturer le compte.
ulimit -u "$(( $(ps -A | wc -l) + 300 ))" 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GARDE="$HERE/garde-lecture-seule.sh"
RACINE_REELLE="$(cd "$HERE/.." && pwd)"
[ -x "$GARDE" ] || { echo "garde-lecture-seule.sh introuvable ou non exécutable" >&2; exit 2; }

BASE_IN="${1:-}"
[ -n "$BASE_IN" ] || { echo "usage : garde-lecture-seule.test.sh <dossier-vide-absolu>" >&2; exit 2; }
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
garde() { # garde <args...> : capture sortie (stdout+stderr) et code
  LAST_RC=0
  LAST_OUT="$("$GARDE" "$@" 2>&1)" || LAST_RC=$?
}

# attendu <libellé> <code> [motif-dans-la-sortie] : juge la dernière exécution.
attendu() {
  local label="$1" want="$2" motif="${3:-}"
  if [ "$LAST_RC" != "$want" ]; then
    verdict faux "$label" "code $LAST_RC au lieu de $want ; sortie : $LAST_OUT"
  elif [ -n "$motif" ] && ! printf '%s' "$LAST_OUT" | grep -qF -e "$motif"; then
    verdict faux "$label" "la sortie ne nomme pas « $motif » : $LAST_OUT"
  else
    verdict vrai "$label"
  fi
}

# arbre <nom> <contenu-rust> : crée BASE/<nom>/core/src/lib.rs
arbre() {
  mkdir -p "$BASE/$1/core/src"
  printf '%s\n' "$2" >"$BASE/$1/core/src/lib.rs"
}

# --- arbre propre ------------------------------------------------------------------
arbre propre 'pub fn lire() -> u32 { 1 }'
garde --racine "$BASE/propre"
attendu "arbre propre -> vert" 0 "propre"

# --- un motif à la fois : ROUGE et nommé ------------------------------------------
rouge() { # rouge <nom> <motif-attendu> <contenu-rust>
  arbre "$1" "$3"
  garde --racine "$BASE/$1"
  attendu "motif $2 -> refusé et nommé" 1 "REFUSÉ  $2"
}
rouge m-postjson PostJson 'pub enum Method { Get, PostJson }'
rouge m-write-login write_login 'pub fn write_login() {}'
rouge m-upsert upsert 'pub fn upsert() {}'
rouge m-apply apply_renewal 'fn f(b: &mut B) { b.apply_renewal(1); }'
rouge m-reserved Reserved 'pub struct Reserved;'
rouge m-grant grant_type 'const B: &str = "grant_type";'
rouge m-add add-generic-password 'const C: &str = "add-generic-password";'
rouge m-url /v1/oauth/token 'const U: &str = "https://exemple.invalide/v1/oauth/token";'
rouge m-refresh-cle refresh_token 'const K: &str = "refresh_token";'
rouge m-refresh-champ refresh_token 'fn f(r: R) -> u32 { r.refresh_token }'

# --- exceptions : VERT --------------------------------------------------------------
arbre ok-accesseur 'pub fn refresh_token(&self) -> u32 { 1 }
fn g(b: &B) -> u32 { b.refresh_token() }
fn refresh_token_end_of_life_makes_it_renewable() {}'
garde --racine "$BASE/ok-accesseur"
attendu "l'accesseur refresh_token() et les identifiants qui le contiennent restent permis" 0

arbre ok-bornes 'fn upserted() {}
fn unreserved() {}
fn write_login_helper() {}
fn my_apply_renewal_x() {}'
garde --racine "$BASE/ok-bornes"
attendu "un autre mot qui CONTIENT un identifiant n'est pas visé (mots bornés)" 0

# --- delete-generic-password : seulement dans `fn delete_all` ------------------------
mkdir -p "$BASE/del-ok/core/src"
cat >"$BASE/del-ok/core/src/lib.rs" <<'EOF'
mod mac {
    pub fn delete_all(svc: &str) -> usize {
        let _ = ["delete-generic-password", "-s", svc];
        1
    }
}
EOF
garde --racine "$BASE/del-ok"
attendu "delete-generic-password DANS delete_all -> permis" 0

mkdir -p "$BASE/del-hors/core/src"
cat >"$BASE/del-hors/core/src/lib.rs" <<'EOF'
mod mac {
    pub fn delete_all(svc: &str) -> usize {
        let _ = ["delete-generic-password", "-s", svc];
        1
    }

    pub fn autre(svc: &str) {
        let _ = ["delete-generic-password", "-s", svc];
    }
}
EOF
garde --racine "$BASE/del-hors"
attendu "delete-generic-password HORS delete_all (après elle) -> refusé" 1 "delete-generic-password hors delete_all"

mkdir -p "$BASE/del-avant/core/src"
cat >"$BASE/del-avant/core/src/lib.rs" <<'EOF'
mod mac {
    pub fn avant(svc: &str) {
        let _ = ["delete-generic-password", "-s", svc];
    }

    pub fn delete_all(svc: &str) -> usize {
        let _ = svc;
        1
    }
}
EOF
garde --racine "$BASE/del-avant"
attendu "delete-generic-password HORS delete_all (avant elle) -> refusé" 1 "delete-generic-password hors delete_all"

mkdir -p "$BASE/del-deux/core/src"
cp "$BASE/del-ok/core/src/lib.rs" "$BASE/del-deux/core/src/a.rs"
printf 'pub fn b() { let _ = "delete-generic-password"; }\n' >"$BASE/del-deux/core/src/b.rs"
garde --racine "$BASE/del-deux"
attendu "l'exception d'un fichier ne couvre pas un autre fichier" 1 "b.rs"

# --- binaires -------------------------------------------------------------------------
binaire() { # binaire <nom> <texte...> : fichier avec du bruit binaire autour du texte
  mkdir -p "$BASE/bin"
  { head -c 200 /dev/urandom; printf '\0%s\0' "$2"; head -c 200 /dev/urandom; } >"$BASE/bin/$1"
}
arbre b-src 'pub fn lire() {}'
binaire propre.bin 'https://api.anthropic.com/api/oauth/profile'
garde --racine "$BASE/b-src" "$BASE/bin/propre.bin"
attendu "binaire sans motif -> vert" 0 "1 binaire"

binaire url.bin 'https://platform.claude.com/v1/oauth/token'
garde --racine "$BASE/b-src" "$BASE/bin/url.bin"
attendu "binaire avec /v1/oauth/token -> refusé et nommé" 1 "REFUSÉ  /v1/oauth/token"

binaire grant.bin 'grant_type'
garde --racine "$BASE/b-src" "$BASE/bin/grant.bin"
attendu "binaire avec grant_type -> refusé" 1 "REFUSÉ  grant_type"

binaire add.bin 'add-generic-password'
garde --racine "$BASE/b-src" "$BASE/bin/add.bin"
attendu "binaire avec add-generic-password -> refusé" 1 "REFUSÉ  add-generic-password"

binaire del.bin 'delete-generic-password'
garde --racine "$BASE/b-src" "$BASE/bin/del.bin"
attendu "binaire avec delete-generic-password seul -> vert (la purge le porte)" 0

# Régression du tube vers `grep -q` : motif tout au début d'un gros fichier.
{ printf '/v1/oauth/token\n'; awk 'BEGIN { for (i = 0; i < 300000; i++) print "ligne de remplissage numero " i }'; } >"$BASE/bin/gros.bin"
garde --racine "$BASE/b-src" "$BASE/bin/gros.bin"
attendu "gros binaire, motif au début (régression SIGPIPE + pipefail) -> refusé" 1 "REFUSÉ  /v1/oauth/token"

# Un seul motif ne cache pas les autres : les trois sont nommés.
binaire trois.bin 'https://x/v1/oauth/token grant_type=refresh add-generic-password'
garde --racine "$BASE/b-src" "$BASE/bin/trois.bin"
attendu "plusieurs motifs dans un binaire -> « 3 motif(s) »" 1 "3 motif(s)"

# --- la porte FERME sur une entrée illisible -------------------------------------------
garde --racine "$BASE/inexistante"
attendu "dossier source absent -> code 2 (jamais vert)" 2

mkdir -p "$BASE/vide/core/src"
garde --racine "$BASE/vide"
attendu "aucun .rs -> code 2 (jamais vert)" 2

garde --racine "$BASE/b-src" "$BASE/bin/absent.bin"
attendu "binaire introuvable -> code 2 (jamais vert)" 2

garde --option-inconnue
attendu "option inconnue -> code 2" 2

# --- l'arbre RÉEL -----------------------------------------------------------------------
garde --racine "$RACINE_REELLE"
attendu "l'arbre réel de ce dépôt est propre" 0 "propre"

printf '\n%d ok, %d ko\n' "$OK" "$KO"
[ "$KO" -eq 0 ]
