#!/bin/zsh
# Installs Archiviste from its GitHub release: the app in /Applications, the command in ~/.local/bin.
#
#   curl -fsSL https://raw.githubusercontent.com/czj/archiviste/main/scripts/install.sh | zsh
#
# A given version: ARCHIVISTE_VERSION=1.1.0 (default: the latest release). Running it again updates.
# The app is signed ad hoc, not notarized: a file fetched by curl carries no quarantine, so macOS
# opens it without the "unidentified developer" block a browser download would get.
set -euo pipefail

REPO=czj/archiviste
VERSION=${ARCHIVISTE_VERSION:-latest}
APPS=/Applications
OLD_APPS=~/Applications  # up to 1.0: an older copy there would open instead of this one
BIN=~/.local/bin

say() { print -P "%F{green}==>%f $*"; }
die() { print -P "%F{red}✗%f $*" >&2; exit 1; }

[[ $(uname -s) == Darwin ]] || die "Archiviste est une app macOS."
[[ $(uname -m) == arm64 ]] || die "Archiviste demande un Mac Apple silicon (Apple Intelligence)."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 27 )) || die "Archiviste demande macOS 27 ou plus récent (ce Mac : $(sw_vers -productVersion))."
[[ -w $APPS ]] || die "Impossible d’écrire dans $APPS : un compte administrateur est nécessaire."

if [[ -n ${ARCHIVISTE_BASE_URL:-} ]]; then  # tests: a folder of assets (file://…)
  base=$ARCHIVISTE_BASE_URL
elif [[ $VERSION == latest ]]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/v${VERSION#v}"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
say "Téléchargement d’Archiviste ($VERSION)…"
for asset in Archiviste.zip archiviste-cli.tar.gz SHA256SUMS; do
  curl -fsSL --retry 2 "$base/$asset" -o "$tmp/$asset" || die "Impossible de télécharger $asset depuis $base"
done
(cd "$tmp" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "Somme de contrôle incorrecte : téléchargement abîmé."

ditto -x -k "$tmp/Archiviste.zip" "$tmp/app"
tar -xzf "$tmp/archiviste-cli.tar.gz" -C "$tmp"
[[ -d "$tmp/app/Archiviste.app" && -x "$tmp/archiviste" ]] || die "Archive inattendue."

# A running copy is quit first (an Apple event: no "keep running in the background?" question).
if pgrep -xq ArchivisteApp; then
  say "Arrêt de la version en cours…"
  osascript -e 'tell application id "com.github.czj.archiviste" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq ArchivisteApp || break; sleep 0.5; done
fi

# Up to 1.0 the app was "PDF Namer": quit and remove it. Its settings, rules and history move over
# on Archiviste's first launch; if it opened at login, Archiviste takes its place.
if [[ -d "$APPS/PDF Namer.app" || -d "$OLD_APPS/PDF Namer.app" || -x "$BIN/pdf-namer" ]]; then
  say "Remplacement de PDF Namer, l'ancien nom d'Archiviste…"
  if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q "PDF Namer"; then
    defaults write com.github.czj.archiviste replaceLoginItem -bool true
    osascript -e 'tell application "System Events" to delete login item "PDF Namer"' >/dev/null 2>&1 || true
  fi
  osascript -e 'tell application id "com.github.czj.pdf-namer" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq PDFNamerApp || break; sleep 0.5; done
  rm -rf "$APPS/PDF Namer.app" "$OLD_APPS/PDF Namer.app" "$BIN/pdf-namer"
fi

mkdir -p "$APPS" "$BIN"
rm -rf "$APPS/Archiviste.app" "$OLD_APPS/Archiviste.app"
ditto "$tmp/app/Archiviste.app" "$APPS/Archiviste.app"
install -m 755 "$tmp/archiviste" "$BIN/archiviste"
xattr -dr com.apple.quarantine "$APPS/Archiviste.app" 2>/dev/null || true

installed=$(defaults read "$APPS/Archiviste.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
say "Archiviste $installed installé : $APPS/Archiviste.app et $BIN/archiviste"
[[ ":$PATH:" == *":$BIN:"* ]] || print "   Ajoutez $BIN à votre PATH pour la commande archiviste."
print "   Apple Intelligence doit être activé (Réglages Système › Apple Intelligence et Siri)."
open "$APPS/Archiviste.app"
