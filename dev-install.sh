#!/bin/zsh
# Builds the app and installs it as "Ghostty Ex" in ~/Applications — the copy to run and
# test with.
#
#   ./dev-install.sh
#
# It's an ordinary local build: same bundle identifier as the released app and no release
# stamp, so it shares the release's settings and never checks for updates by itself (see the
# note on local builds in AppDelegate.swift). Nothing here writes to /Applications: the
# installed release is left exactly as it is. Since the two are the same app as far as macOS
# is concerned — same saved window state, same notifications — quit one before running the
# other.
#
# Only the app is built. Run the zig build first (see CLAUDE.md) if anything outside macos/
# changed.
set -u
setopt pipefail

ROOT=${0:A:h}
NAME="Ghostty Ex"
BUILT=$ROOT/macos/build/ReleaseLocal/Ghostty.app
DEST=$HOME/Applications/$NAME.app
LOG=/private/tmp/ghostty-extreme-build.log

step() { print -P "\n%F{yellow}▸ $1%f"; }
pass() { print -P "  %F{green}✓%f $1"; }
fail() { print -P "  %F{red}✗ $1%f"; exit 1; }

cd $ROOT

step "Build"
# Not from inside the repo's nix devshell: its NIX_LDFLAGS makes the linker reject the
# -Xlinker arguments Xcode hands it and the link step fails, so the build runs with a clean
# environment. swiftlint is looked for on PATH and skipped when it isn't there.
env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration ReleaseLocal \
  SYMROOT=$ROOT/macos/build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build > $LOG 2>&1 \
  || fail "build failed — see $LOG"
[[ -d $BUILT ]] || fail "the build produced no app at $BUILT"
pass "built $NAME, version $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $BUILT/Contents/Info.plist)"

if pgrep -f "$DEST/Contents/MacOS/" >/dev/null 2>&1; then
  fail "$NAME is running — quit it first"
fi

step "Install"
mkdir -p $HOME/Applications
rm -rf $DEST
ditto $BUILT $DEST
# Xcode names the app after the target ("Ghostty"); the menu bar and the Dock read these.
/usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME" -c "Set :CFBundleDisplayName $NAME" \
  $DEST/Contents/Info.plist
# Editing Info.plist breaks the signature Xcode made, and macOS kills an app whose signature
# is broken. Sign it again with the entitlements and flags the build had — without
# `disable-library-validation` among them the app can't load the code inside its own bundle.
codesign --force --sign - --preserve-metadata=entitlements,flags $DEST 2>/dev/null \
  || fail "couldn't sign the copy"
codesign --verify --deep --strict $DEST || fail "the copy's signature doesn't verify"
pass "signed ad-hoc, signature verifies"

pass "$DEST"
print "  Run it with: open \"$DEST\""
