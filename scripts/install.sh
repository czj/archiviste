#!/bin/zsh
# Installs PDF Namer from its GitHub release: the app in ~/Applications, the command in ~/.local/bin.
#
#   curl -fsSL https://raw.githubusercontent.com/czj/pdf-namer/main/scripts/install.sh | zsh
#
# A given version: PDF_NAMER_VERSION=1.0.0 (default: the latest release). Running it again updates.
# The app is signed ad hoc, not notarized: a file fetched by curl carries no quarantine, so macOS
# opens it without the "unidentified developer" block a browser download would get.
set -euo pipefail

REPO=czj/pdf-namer
VERSION=${PDF_NAMER_VERSION:-latest}
APPS=~/Applications
BIN=~/.local/bin

say() { print -P "%F{green}==>%f $*"; }
die() { print -P "%F{red}✗%f $*" >&2; exit 1; }

[[ $(uname -s) == Darwin ]] || die "PDF Namer est une app macOS."
[[ $(uname -m) == arm64 ]] || die "PDF Namer demande un Mac Apple silicon (Apple Intelligence)."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 27 )) || die "PDF Namer demande macOS 27 ou plus récent (ce Mac : $(sw_vers -productVersion))."

if [[ -n ${PDF_NAMER_BASE_URL:-} ]]; then  # tests: a folder of assets (file://…)
  base=$PDF_NAMER_BASE_URL
elif [[ $VERSION == latest ]]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/v${VERSION#v}"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
say "Téléchargement de PDF Namer ($VERSION)…"
for asset in PDF-Namer.zip pdf-namer-cli.tar.gz SHA256SUMS; do
  curl -fsSL --retry 2 "$base/$asset" -o "$tmp/$asset" || die "Impossible de télécharger $asset depuis $base"
done
(cd "$tmp" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "Somme de contrôle incorrecte : téléchargement abîmé."

ditto -x -k "$tmp/PDF-Namer.zip" "$tmp/app"
tar -xzf "$tmp/pdf-namer-cli.tar.gz" -C "$tmp"
[[ -d "$tmp/app/PDF Namer.app" && -x "$tmp/pdf-namer" ]] || die "Archive inattendue."

# A running copy is quit first (an Apple event: no "keep running in the background?" question).
if pgrep -xq PDFNamerApp; then
  say "Arrêt de la version en cours…"
  osascript -e 'tell application id "com.github.czj.pdf-namer" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq PDFNamerApp || break; sleep 0.5; done
fi

mkdir -p "$APPS" "$BIN"
rm -rf "$APPS/PDF Namer.app"
ditto "$tmp/app/PDF Namer.app" "$APPS/PDF Namer.app"
install -m 755 "$tmp/pdf-namer" "$BIN/pdf-namer"
xattr -dr com.apple.quarantine "$APPS/PDF Namer.app" 2>/dev/null || true

installed=$(defaults read "$APPS/PDF Namer.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
say "PDF Namer $installed installé : $APPS/PDF Namer.app et $BIN/pdf-namer"
[[ ":$PATH:" == *":$BIN:"* ]] || print "   Ajoutez $BIN à votre PATH pour la commande pdf-namer."
print "   Apple Intelligence doit être activé (Réglages Système › Apple Intelligence et Siri)."
open "$APPS/PDF Namer.app"
