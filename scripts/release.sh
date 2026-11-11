#!/usr/bin/env bash
# ============================================================
#  Assemble et SIGNE les fichiers d'une release dans dist/release/.
#  Usage : scripts/build-core.sh && scripts/release.sh
#
#  Les installeurs (install.sh, install.ps1) et le wizard (cc_download_core,
#  cc_update_portable) ne posent un fichier QUE s'il figure dans SHA256SUMS et
#  que SHA256SUMS porte une signature valide de la clé du produit. Ce script
#  produit exactement cet ensemble, à plat (noms = ceux attendus par
#  `releases/latest/download/<nom>`), puis revérifie la signature avec la clé
#  publique EMBARQUÉE dans le fichier de référence : une release que les clients
#  refuseraient n'est jamais produite.
#
#  Un seul script pour toute édition (le fork d'un script de release dérive en silence) :
#  ce qui change d'une édition à l'autre tient en variables d'environnement. Les défauts
#  sont ceux de la release publique.
#
#    CCP_SIGN_KEY       clé privée de signature (défaut ~/.ssh/baluchon-release_ed25519).
#                       Jamais dans le dépôt, jamais affichée.
#    CCP_SIGNER_ID      identité du signataire (défaut baluchon-release)
#    CCP_SIGNER_SRC     fichier qui embarque la clé publique : UNE seule ligne
#                       CCP_SIGNER='<id> ssh-ed25519 <clé>' au format strict (aucune option, aucun
#                       autre champ ; sinon refus). Cette clé doit être celle DÉRIVÉE de CCP_SIGN_KEY.
#                       (défaut lib/common.sh ; relatif à la racine, ou absolu)
#    CCP_SIGNER_COPIES  autres fichiers qui doivent porter la MÊME clé publique, séparés par des
#                       espaces (défaut « install.sh install.ps1 » ; vide = aucun)
#    CCP_ASSETS         fichier « nom publié <TAB> source » (source relative à la racine ou
#                       absolue) qui REMPLACE la liste d'actifs publique. Elle ne change RIEN à la
#                       garde lecture seule : celle-ci est imposée selon la clé et l'identité de
#                       publication, jamais selon la façon dont la liste est choisie (voir plus bas).
#    CCP_OUT            dossier de sortie (défaut dist/release) ; recréé à chaque exécution
#    CCP_DENY_DIRS      crates passées à `cargo deny` (défaut « core ») : chacune a son Cargo.lock.
#                       Vide = aucune (épreuves de ce script seulement)
#    CCP_GATES          scripts supplémentaires lancés avant toute signature (chemins relatifs à
#                       la racine, séparés par des espaces) ; un seul échec refuse la release
#    CCP_TAG            tag de la release (défaut : le tag exact de HEAD). Doit valoir
#                       v<version de core/Cargo.toml> : c'est la règle de versionnage.
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${CCP_SIGN_KEY:-$HOME/.ssh/baluchon-release_ed25519}"
SIGNER_ID="${CCP_SIGNER_ID:-baluchon-release}"
SIGNER_SRC="${CCP_SIGNER_SRC:-lib/common.sh}"
SIGNER_COPIES="${CCP_SIGNER_COPIES-install.sh install.ps1}"
OUT="${CCP_OUT:-$ROOT/dist/release}"
DENY_DIRS="${CCP_DENY_DIRS-core}"   # `-` et non `:-` : une valeur vide veut dire « aucune crate »
GATES="${CCP_GATES:-}"
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

# La sortie est recréée plus bas : on ne supprime qu'une sortie de release précédente (elle
# porte un SHA256SUMS) ou un dossier vide, jamais un chemin que CCP_OUT aurait mal visé.
# Jugé d'entrée, avant tout travail.
case "$OUT" in /*) ;; *) die "CCP_OUT doit être un chemin absolu : $OUT" ;; esac
case "$OUT" in "/"|"$HOME"|"$HOME/"|"$ROOT"|"$ROOT/") die "CCP_OUT vise un dossier qu'on n'efface pas : $OUT" ;; esac
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ] && [ ! -f "$OUT/SHA256SUMS" ]; then
  die "CCP_OUT existe, n'est pas vide et n'est pas une sortie de release (pas de SHA256SUMS) : $OUT"
fi

[ -f "$KEY" ] || die "clé de signature absente : $KEY"

# Règle de versionnage : la version vit dans core/Cargo.toml ; le tag de la release lui est
# égal ou la release est refusée. Avant tout le reste : inutile de compiler ou de juger une
# release qui ne portera pas le bon numéro.
version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$ROOT/core/Cargo.toml" | head -1)"
[ -n "$version" ] || die "version introuvable dans core/Cargo.toml"
tag="${CCP_TAG:-$(git -C "$ROOT" describe --exact-match --tags HEAD 2>/dev/null || true)}"
[ -n "$tag" ] || die "aucun tag sur HEAD : une release se fait sur un commit taggé v$version (ou CCP_TAG=v$version pour une répétition)"
[ "$tag" = "v$version" ] || die "le tag « $tag » et core/Cargo.toml (version $version) divergent : corrige l'un des deux"

# La ligne du signataire d'un fichier : UNE seule ligne CCP_SIGNER=, au format STRICT
#   CCP_SIGNER='<identité> ssh-ed25519 <clé en base64>'
# (identité en [A-Za-z0-9._-], aucune option comme namespaces="…", aucun autre champ). Écrit
# « <identité> ssh-ed25519 <clé> » ; échoue sinon. Revue Codex, 2e passe : une ligne valide pour
# allowed_signers mais mal rangée (`autre namespaces="file" ssh-ed25519 <clé>`) faisait lire autre
# chose que la clé au 3e champ, et la garde lecture seule était sautée. Ce qui n'est pas strict est
# REFUSÉ, jamais interprété ; et la garde ne se fie de toute façon plus à cette ligne (voir plus bas).
ligne_signataire() { # ligne_signataire <fichier>
  local n l re
  re="^CCP_SIGNER='([A-Za-z0-9._-]+) ssh-ed25519 ([A-Za-z0-9+/]+={0,2})'\$"
  n="$(grep -cE '(^|[^A-Za-z0-9_])CCP_SIGNER=' "$1" || true)"
  [ "$n" = 1 ] || return 1
  l="$(grep -E '(^|[^A-Za-z0-9_])CCP_SIGNER=' "$1")"
  [[ "$l" =~ $re ]] || return 1
  printf '%s ssh-ed25519 %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

case "$SIGNER_SRC" in /*) SIGNER_FILE="$SIGNER_SRC" ;; *) SIGNER_FILE="$ROOT/$SIGNER_SRC" ;; esac
[ -f "$SIGNER_FILE" ] || die "fichier de la clé publique absent : $SIGNER_FILE"
signer="$(ligne_signataire "$SIGNER_FILE")" \
  || die "$SIGNER_SRC doit porter UNE SEULE ligne CCP_SIGNER='<identité> ssh-ed25519 <clé>' au format strict (aucune option, aucun autre champ, rien d'autre qui contienne « CCP_SIGNER= »)"
[ "${signer%% *}" = "$SIGNER_ID" ] || die "l'identité de $SIGNER_SRC (${signer%% *}) n'est pas $SIGNER_ID"
cle_signataire="${signer##* }"
# Les copies de la clé publique doivent être identiques.
for f in $SIGNER_COPIES; do
  grep -qF "${signer#"$SIGNER_ID" }" "$ROOT/$f" || die "clé publique de $f différente de $SIGNER_SRC"
done

# La clé RÉELLEMENT utilisée pour signer : sa partie publique est DÉRIVÉE de la clé privée passée à
# ssh-keygen (`-y` n'écrit que la partie publique), pas lue dans un fichier qui pourrait mentir.
# Deux conséquences, toutes deux jugées avant le moindre travail :
#   - elle doit être celle que la ligne embarquée annonce, sinon les clients ne pourraient pas
#     vérifier ce qu'on signe (et, avant ce contrôle, la signature était produite puis la sortie
#     laissée sur le disque quand la contre-vérification échouait) ;
#   - elle sert à décider de la garde lecture seule (plus bas), quelle que soit l'identité ou la
#     façon dont la ligne est écrite.
PUBLIC_ID="baluchon-release"
cle_utilisee="$(ssh-keygen -y -f "$KEY" | awk 'NR == 1 && $1 == "ssh-ed25519" { print $2 }')" || cle_utilisee=""
[ -n "$cle_utilisee" ] || die "impossible de dériver une clé publique ed25519 de la clé de signature : $KEY (clé protégée, illisible, ou d'un autre type)"
[ "$cle_utilisee" = "$cle_signataire" ] \
  || die "la clé de signature ne correspond pas à la clé publique embarquée dans $SIGNER_SRC : les clients ne pourraient pas vérifier la release"
# La clé publique du PRODUIT : celle de lib/common.sh, que tout client public vérifie.
[ -f "$ROOT/lib/common.sh" ] || die "lib/common.sh absent : la garde lecture seule ne saurait pas quelle clé est publique"
produit="$(ligne_signataire "$ROOT/lib/common.sh")" \
  || die "lib/common.sh doit porter UNE SEULE ligne CCP_SIGNER='<identité> ssh-ed25519 <clé>' au format strict"
cle_produit="${produit##* }"

# Porte P5 : licences, avis de sécurité RUSTSEC, sources et crates interdits
# (deny.toml de chaque crate). Avant tout `rm`/signature : une release refusée ne laisse rien
# dans la sortie. Fermée par défaut, sans variable de contournement ; hors ligne
# elle échoue aussi (la base d'avis se récupère), ce qui est voulu.
[ -d "$HOME/.cargo/bin" ] && PATH="$HOME/.cargo/bin:$PATH"   # absent du PATH d'un shell non interactif
export PATH
if [ -n "$DENY_DIRS" ]; then
  command -v cargo-deny >/dev/null 2>&1 \
    || die "cargo-deny absent : cargo install cargo-deny --locked"
fi
for d in $DENY_DIRS; do
  ( cd "$ROOT/$d" && cargo deny --locked check ) \
    || die "cargo-deny refuse la release dans $d (licence, avis de sécurité, source ou crate interdit) : voir ci-dessus"
done

# Portes supplémentaires de l'édition (par exemple la grille des identifiants personnels).
for g in $GATES; do
  [ -f "$ROOT/$g" ] || die "porte introuvable : $g"
  bash "$ROOT/$g" || die "la porte $g refuse la release : voir ci-dessus"
done

# Liste d'actifs « nom publié<TAB>source ».
assets=()
if [ -n "${CCP_ASSETS:-}" ]; then
  [ -f "$CCP_ASSETS" ] || die "liste d'actifs absente : $CCP_ASSETS"
  while IFS=$'\t' read -r nom src; do
    [ -n "$nom" ] || continue
    case "$src" in /*) ;; *) src="$ROOT/$src" ;; esac
    [ -f "$src" ] || die "actif manquant : $src"
    assets+=("$nom"$'\t'"$src")
  done <"$CCP_ASSETS"
  [ "${#assets[@]}" -gt 0 ] || die "liste d'actifs vide : $CCP_ASSETS"
else
  assets+=("Claude.command"$'\t'"$ROOT/Claude.command" "common.sh"$'\t'"$ROOT/lib/common.sh")
  assets+=("claude.cmd"$'\t'"$ROOT/claude.cmd" "claude-classic.cmd"$'\t'"$ROOT/claude-classic.cmd")
  # Les installeurs sont des actifs SIGNÉS de la release : un script qui installe Baluchon depuis
  # ailleurs que d'une branche (une amorce de déploiement, par exemple) les prend ICI, vérifiés contre
  # SHA256SUMS, au lieu d'exécuter ce que `main` contient ce jour-là (revue Codex terminale).
  assets+=("install.sh"$'\t'"$ROOT/install.sh" "install.ps1"$'\t'"$ROOT/install.ps1")
  for plat in darwin-arm64 darwin-x64 linux-x64 linux-arm64 win32-x64; do
    exe=""; [ "$plat" = win32-x64 ] && exe=.exe
    src="$ROOT/dist/$plat/baluchon-core$exe"
    [ -f "$src" ] || die "binaire manquant : $src (lancer scripts/build-core.sh)"
    assets+=("baluchon-core-$plat$exe"$'\t'"$src")
  done
fi

# Porte P6 : le noyau PUBLIC ne sait pas ÉCRIRE un identifiant. Motifs de renouvellement et
# d'écriture refusés dans core/src ET dans CHAQUE actif à livrer (strings). Fermée, sans variable
# de contournement ; ses épreuves : scripts/garde-lecture-seule.test.sh et release.test.sh.
#
# Imposée selon l'IDENTITÉ de ce qui est publié, JAMAIS selon la façon dont la liste d'actifs est
# choisie : avec `CCP_ASSETS`, la garde passait autrefois pour toujours, et une liste personnalisée
# pouvait faire signer un noyau privé comme release publique (revue Codex terminale). Elle
# s'applique donc si la release porte l'identité publique OU si la clé qui SIGNE est celle du
# produit (dérivée de la clé privée réellement passée à ssh-keygen, voir plus haut : ni l'identité
# annoncée ni le format de la ligne ne peuvent plus la contourner). Une édition privée, qui signe
# avec SA clé sous SA propre identité, n'est pas concernée.
publique=0
[ "$SIGNER_ID" = "$PUBLIC_ID" ] && publique=1
[ "$cle_utilisee" = "$cle_produit" ] && publique=1
if [ "$publique" = 1 ]; then
  juges=()
  for a in "${assets[@]}"; do juges+=("${a#*$'\t'}"); done
  "$ROOT/scripts/garde-lecture-seule.sh" "${juges[@]}" \
    || die "la garde lecture seule refuse la release (le public ne doit pas savoir écrire un identifiant) : voir ci-dessus"
fi

rm -rf "$OUT"; mkdir -p "$OUT"
for a in "${assets[@]}"; do
  cp "${a#*$'\t'}" "$OUT/${a%%$'\t'*}"
done

( cd "$OUT" && shasum -a 256 -- * > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS )
ssh-keygen -q -Y sign -f "$KEY" -n file "$OUT/SHA256SUMS" >/dev/null
[ -f "$OUT/SHA256SUMS.sig" ] || die "signature non produite"

# Contre-vérification avec la clé publique embarquée (ce que fera chaque client).
printf '%s\n' "$signer" > "$OUT/.allowed_signers"
ssh-keygen -Y verify -f "$OUT/.allowed_signers" -I "$SIGNER_ID" -n file -s "$OUT/SHA256SUMS.sig" < "$OUT/SHA256SUMS" >/dev/null \
  || die "la signature produite ne se vérifie pas avec la clé embarquée"
rm -f "$OUT/.allowed_signers"
( cd "$OUT" && shasum -a 256 -c SHA256SUMS >/dev/null ) || die "SHA256SUMS incohérent"

printf '✓ Release %s signée dans %s :\n' "$tag" "$OUT"
for f in "$OUT"/*; do printf "   %s\n" "${f##*/}"; done
