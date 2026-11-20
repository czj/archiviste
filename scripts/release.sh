#!/bin/zsh
# Builds, packages and publishes a GitHub release (tag v<version>) from a clean, pushed main.
#
#   scripts/release.sh 1.0.0 notes.md
#
# Assets, with fixed names so that releases/latest/download/<name> always works (scripts/install.sh):
#   PDF-Namer.zip         the app, signed ad hoc
#   pdf-namer-cli.tar.gz  the command
#   SHA256SUMS
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

die() { print -P "%F{red}✗%f $*" >&2; exit 1; }
(( $# == 2 )) || die "usage : scripts/release.sh <version> <notes.md>"
VERSION=${1#v}
NOTES=${2:A}
[[ -f $NOTES ]] || die "notes introuvables : $2"
[[ $(git branch --show-current) == main ]] || die "à lancer depuis main"
[[ -z $(git status --porcelain) ]] || die "copie de travail non propre"
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "main n'est pas à jour avec origin/main"
plist=$(defaults read "$ROOT/Resources/Info" CFBundleShortVersionString)
[[ $plist == $VERSION ]] || die "Info.plist indique $plist, pas $VERSION"
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "le tag v$VERSION existe déjà"

swift test
scripts/build-app.sh --no-install
BINDIR=$(swift build -c release --show-bin-path)

OUT="$ROOT/build/release"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --keepParent "$ROOT/build/PDF Namer.app" "$OUT/PDF-Namer.zip"
tar -C "$BINDIR" -czf "$OUT/pdf-namer-cli.tar.gz" pdf-namer
(cd "$OUT" && shasum -a 256 PDF-Namer.zip pdf-namer-cli.tar.gz > SHA256SUMS)

gh release create "v$VERSION" "$OUT/PDF-Namer.zip" "$OUT/pdf-namer-cli.tar.gz" "$OUT/SHA256SUMS" \
  --target main --title "PDF Namer $VERSION" --notes-file "$NOTES"
