#!/usr/bin/env bash
# Compile baluchon-core pour les 5 plateformes du portable et publie dans dist/ :
#
#   dist/<plateforme>/baluchon-core[.exe]   (mêmes noms que les binaires de Claude)
#   dist/SHA256SUMS                    (chemins relatifs à dist/)
#
# Plateformes = nomenclature de `cc_detect_platform` / `claude_platform()` :
#   darwin-arm64 darwin-x64 linux-x64 linux-arm64 win32-x64
#
# Pré-requis (poste de build macOS) : rustup (cibles installées), zig, cargo-zigbuild.
#   brew install zig && cargo install cargo-zigbuild
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin \
#     x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-pc-windows-gnu
#
# Usage : scripts/build-core.sh [--only <plateforme>]... [--no-sign]
#
# Un seul script pour toute édition du noyau (jamais de copie qui dérive) : trois variables
# d'environnement, aux défauts du produit public.
#   CORE_DIR   crate à compiler, absolu ou relatif à la racine (défaut core)
#   BIN_NAME   nom du binaire Cargo (défaut baluchon-core)
#   DIST_DIR   dossier de sortie, absolu (défaut dist)
#
# Pourquoi cargo-zigbuild partout (même darwin) : un seul chemin de build, glibc
# jamais liée (cibles musl statiques : le portable tourne sur toute distribution),
# et zig fournit le lieur croisé sans SDK Windows ni toolchain Linux.
# Pourquoi `codesign -s -` : sur Apple Silicon un binaire dont la signature est
# invalide (le strip du profil release l'invalide) est tué par le noyau (SIGKILL).
# La signature ad hoc suffit : pas d'identité de développeur, pas de notarisation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${CORE_DIR:-core}" in /*) CORE="$CORE_DIR" ;; *) CORE="$ROOT/${CORE_DIR:-core}" ;; esac
DIST="${DIST_DIR:-$ROOT/dist}"
BIN="${BIN_NAME:-baluchon-core}"
[ -f "$CORE/Cargo.toml" ] || { echo "build-core : pas de Cargo.toml dans $CORE" >&2; exit 2; }

# (plateforme  cible-rust  nom-du-binaire)
TARGETS=(
  "darwin-arm64 aarch64-apple-darwin $BIN"
  "darwin-x64 x86_64-apple-darwin $BIN"
  "linux-x64 x86_64-unknown-linux-musl $BIN"
  "linux-arm64 aarch64-unknown-linux-musl $BIN"
  "win32-x64 x86_64-pc-windows-gnu $BIN.exe"
)

ONLY=()
SIGN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY+=("${2:?--only attend une plateforme}"); shift 2 ;;
    --no-sign) SIGN=0; shift ;;
    -h|--help) awk 'NR > 1 && /^set -euo/ { exit } NR > 1 { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "build-core : option inconnue : $1" >&2; exit 2 ;;
  esac
done

# rustup/cargo ne sont pas toujours dans le PATH d'un shell non interactif.
for d in "$HOME/.cargo/bin" "$HOME"/.rustup/toolchains/stable-*/bin /opt/homebrew/bin; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH

need() { command -v "$1" >/dev/null 2>&1 || { echo "build-core : « $1 » introuvable ($2)" >&2; exit 1; }; }
need cargo "installer rustup"
need cargo-zigbuild "cargo install cargo-zigbuild"
need zig "brew install zig"

wanted() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local p
  for p in "${ONLY[@]}"; do [ "$p" = "$1" ] && return 0; done
  return 1
}

if [ ${#ONLY[@]} -gt 0 ]; then
  for p in "${ONLY[@]}"; do
    ok=0; for t in "${TARGETS[@]}"; do [ "${t%% *}" = "$p" ] && ok=1; done
    [ $ok -eq 1 ] || { echo "build-core : plateforme inconnue : $p" >&2; exit 2; }
  done
fi

HOST_OS="$(uname -s)"
mkdir -p "$DIST"
built=()
for t in "${TARGETS[@]}"; do
  read -r plat triple bin <<<"$t"
  wanted "$plat" || continue
  echo "==> $plat ($triple)"
  # --locked : le Cargo.lock versionné fait foi, jamais de dépendance qui dérive en silence.
  ( cd "$CORE" && cargo zigbuild --release --locked --target "$triple" --bin "$BIN" )
  src="$CORE/target/$triple/release/$bin"
  [ -f "$src" ] || { echo "build-core : binaire introuvable : $src" >&2; exit 1; }
  mkdir -p "$DIST/$plat"
  # Copie atomique : un portable qui lit dist/ pendant un build ne voit jamais un fichier tronqué.
  cp "$src" "$DIST/$plat/.$bin.tmp"
  chmod 755 "$DIST/$plat/.$bin.tmp"
  mv -f "$DIST/$plat/.$bin.tmp" "$DIST/$plat/$bin"
  case "$plat" in
    darwin-*)
      if [ "$SIGN" -eq 1 ]; then
        if [ "$HOST_OS" = "Darwin" ]; then
          codesign -s - --force "$DIST/$plat/$bin"
          codesign --verify --verbose=0 "$DIST/$plat/$bin"
        else
          echo "    (pas de codesign hors macOS : à signer sur un Mac avant diffusion)" >&2
        fi
      fi ;;
  esac
  built+=("$plat/$bin")
done

# SHA256SUMS couvre TOUT ce qui est dans dist/ (une plateforme reconstruite seule
# ne doit pas faire disparaître les sommes des autres).
(
  cd "$DIST"
  find . -mindepth 2 -maxdepth 2 -type f \( -name "$BIN" -o -name "$BIN.exe" \) \
    | sed 's|^\./||' | LC_ALL=C sort \
    | while IFS= read -r f; do shasum -a 256 "$f"; done > SHA256SUMS.tmp
  mv -f SHA256SUMS.tmp SHA256SUMS
)

echo
echo "dist/SHA256SUMS :"
sed 's/^/  /' "$DIST/SHA256SUMS"
echo
for f in "${built[@]}"; do file "$DIST/$f" | sed 's|^'"$DIST"'/|  |'; done
