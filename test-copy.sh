#!/bin/zsh
# Makes a throwaway copy of the built app to test with, so the copy the maintainer runs
# (the one in ~/Applications, or a release in /Applications) is never touched.
#
#   ./test-copy.sh                 prepare a copy at /private/tmp/GXTest/GhosttyTest.app
#   ./test-copy.sh --launch        prepare it and open it
#   ./test-copy.sh --build         build the app first (same clean-env build as dev-install.sh)
#   ./test-copy.sh --dir /private/tmp/foo --theme token-ultra-dark
#
# The copy gets a different bundle identifier, so macOS treats it as another app: its own saved
# window state, its own notifications, and it can run alongside the real one.
#
# Launching brings a window to the front, so it only happens with --launch — ask the maintainer
# first, they may be using the Mac.
#
# Test switches (`GHOSTTY_EXTREME_TEST_TABS`, `GHOSTTY_EXTREME_DEMO`, `GHOSTTY_EXTREME_TEST_LOG`,
# ...) ride along with `--env`, e.g. `--env GHOSTTY_EXTREME_TEST_TABS=3`.
#
# The config sandbox
# ------------------
# The copy is launched with `XDG_CONFIG_HOME` pointing at a scratch directory instead of the real
# one, so a test run can't disturb the maintainer's configuration. That has a catch: Ghostty looks
# for a theme in the config directory's `themes/` first and in the app bundle's shipped themes
# second (see the `theme` docs in src/config/Config.zig and src/config/theme.zig). A scratch
# config directory has neither, so a config that names a theme the bundle doesn't ship — like the
# maintainer's own `token-ultra-dark` — logs
#
#   theme "token-ultra-dark" not found, tried path "…/themes/token-ultra-dark"
#
# once per directory searched. So the scratch directory is given a copy of the user's themes
# (harmless colorscheme files) and a config whose theme is guaranteed to resolve.
set -u
setopt pipefail

ROOT=${0:A:h}
SRC=$ROOT/macos/build/ReleaseLocal/Ghostty.app
BUNDLE_ID=com.steventsvik.ghostty-extreme.test
FNAME=GhosttyTest.app
NAME="Ghostty Test"
BUILD_LOG=/private/tmp/ghostty-extreme-build.log

DIR=/private/tmp/GXTest
BUILD=0
LAUNCH=0
CONFIG=
THEME=
EXTRA_ENV=()

usage() {
  print "usage: ${0:t} [--build] [--launch] [--dir DIR] [--config FILE] [--theme NAME] [--env K=V]…"
  print
  print "  --build         build the app first (clean environment, as dev-install.sh does)"
  print "  --launch        open the copy once it's ready (brings a window to the front)"
  print "  --dir DIR       where to put it  (default $DIR)"
  print "  --config FILE   use this config file in the copy's sandbox instead of a generated one"
  print "  --theme NAME    theme for the generated config (default: token-ultra-dark when present,"
  print "                  else Builtin Dark — either way it resolves, so nothing warns)"
  print "  --env K=V       extra environment for the launched copy (repeatable)"
}

step() { print -P "\n%F{yellow}▸ $1%f"; }
pass() { print -P "  %F{green}✓%f $1"; }
note() { print -P "  %F{blue}•%f $1"; }
fail() { print -P "  %F{red}✗ $1%f"; exit 1; }

while (( $# )); do
  case $1 in
    --build) BUILD=1; shift ;;
    --launch) LAUNCH=1; shift ;;
    --dir) DIR=${2:?--dir needs a directory}; shift 2 ;;
    --config) CONFIG=${2:?--config needs a file}; shift 2 ;;
    --theme) THEME=${2:?--theme needs a name}; shift 2 ;;
    --env) EXTRA_ENV+=("${2:?--env needs K=V}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown option: $1" ;;
  esac
done

APP=$DIR/$FNAME
CFG=$DIR/cfg
THEMES=$HOME/.config/ghostty/themes

cd $ROOT

if (( BUILD )); then
  step "Build"
  # Not from inside the repo's nix devshell: its NIX_LDFLAGS makes the linker reject the
  # -Xlinker arguments Xcode hands it, so the build runs with a clean environment.
  env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration ReleaseLocal \
    SYMROOT=$ROOT/macos/build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build > $BUILD_LOG 2>&1 \
    || fail "build failed — see $BUILD_LOG"
  pass "built $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SRC/Contents/Info.plist")"
fi

[[ -d $SRC ]] || fail "no built app at $SRC — run ./test-copy.sh --build, or dev-install.sh first"
[[ -z $CONFIG || -f $CONFIG ]] || fail "no config file at $CONFIG"

# A copy still running from here would be replaced underneath itself.
if pgrep -f "$APP/Contents/MacOS/" >/dev/null 2>&1; then
  fail "a test copy is already running from $APP (pid $(pgrep -f "$APP/Contents/MacOS/" | head -1)) — quit it first"
fi

step "Copy"
rm -rf "$APP"
mkdir -p "$DIR"
ditto "$SRC" "$APP"
pass "$APP"

# Its own identity, so macOS keeps its saved state and notifications separate from the real app's
# — and so the two can run at the same time without fighting over either.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" \
  -c "Set :CFBundleName $NAME" -c "Set :CFBundleDisplayName $NAME" \
  "$APP/Contents/Info.plist" || fail "couldn't set the copy's bundle identity"
pass "bundle id $BUNDLE_ID, shown as \"$NAME\""

# Editing Info.plist breaks the signature Xcode made, and macOS kills an app whose signature is
# broken. Sign it again with the entitlements and flags the build had — without
# `disable-library-validation` among them the app can't load the code inside its own bundle.
codesign --force --sign - --preserve-metadata=entitlements,flags "$APP" 2>/dev/null \
  || fail "couldn't sign the copy"
codesign --verify --deep --strict "$APP" || fail "the copy's signature doesn't verify"
pass "signed ad-hoc, signature verifies"

step "Config sandbox"
rm -rf "$CFG"
mkdir -p "$CFG/ghostty/themes"
# The user's own themes, so a config naming one resolves here instead of warning twice.
if [[ -d $THEMES ]]; then
  cp -R "$THEMES/." "$CFG/ghostty/themes/"
  pass "copied $(command ls -1 "$THEMES" | wc -l | tr -d ' ') theme file(s) from $THEMES"
else
  note "no $THEMES — only the bundle's shipped themes are available"
fi

if [[ -n $CONFIG ]]; then
  cp "$CONFIG" "$CFG/ghostty/config.ghostty"
  pass "config from $CONFIG"
else
  # A theme that resolves: the user's own if we just copied it, else one Ghostty ships.
  if [[ -z $THEME ]]; then
    if [[ -f "$CFG/ghostty/themes/token-ultra-dark" ]]; then
      THEME=token-ultra-dark
    else
      THEME="Builtin Dark"
    fi
  fi
  print -r "theme = $THEME" > "$CFG/ghostty/config.ghostty"
  if [[ -f "$CFG/ghostty/themes/$THEME" ]]; then
    pass "generated config, theme $THEME (from the copied themes)"
  elif [[ -f "$APP/Contents/Resources/ghostty/themes/$THEME" ]]; then
    pass "generated config, theme $THEME (shipped with the app)"
  else
    note "theme \"$THEME\" is in neither the sandbox nor the bundle — the copy will warn about it"
  fi
fi
pass "sandbox at $CFG"

step "Launch"
RUN=(env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin:/usr/sbin:/sbin "XDG_CONFIG_HOME=$CFG")
if (( ${#EXTRA_ENV} )); then
  for e in $EXTRA_ENV; do RUN+=("$e"); done
fi
RUN+=(/usr/bin/open -na "$APP")

if (( LAUNCH )); then
  "${RUN[@]}" || fail "couldn't open the copy"
  pass "opened \"$NAME\""
  note "its windows are separate from the real app's; quit it when you're done"
else
  note "not launching — that brings a window to the front, so ask first. To run it:"
  print -r "      ${(j: :)RUN}"
  print "    …or re-run with --launch."
fi
