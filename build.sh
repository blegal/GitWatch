#!/bin/zsh
# Compile l'application et produit build/GitWatch.app
# Variables facultatives :
#   UNIVERSAL=1        binaire universel (Apple Silicon + Intel)
#   VERSION=1.2.0      numéro de version écrit dans Info.plist
#   BUILD_NUMBER=42    numéro de build écrit dans Info.plist
#   SIGN_IDENTITY=…    identité de signature (par défaut : « GitWatch Local » s'il existe, voir
#                      Tools/make-local-cert.sh, sinon signature ad hoc « - »)
set -euo pipefail
cd "${0:A:h}"
CONFIG=${1:-release}
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    SLICES=()
    mkdir -p build/slices
    for ARCH in arm64 x86_64; do
        TRIPLE="$ARCH-apple-macosx15.0"
        swift build -c "$CONFIG" --triple "$TRIPLE"
        cp "$(swift build -c "$CONFIG" --triple "$TRIPLE" --show-bin-path)/GitWatch" "build/slices/$ARCH"
        SLICES+=("build/slices/$ARCH")
    done
    BIN=build/GitWatch-universal
    lipo -create -output "$BIN" "${SLICES[@]}"
else
    swift build -c "$CONFIG"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/GitWatch"
fi
APP=build/GitWatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitWatch"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Polices embarquées (OpenDyslexic), enregistrées par ATSApplicationFontsPath.
cp -R Resources/Fonts "$APP/Contents/Resources/"
# Traductions de l'interface (en.lproj généré par Tools/l10n.py build ; fr.lproj : le français est la langue du code).
cp -R Resources/*.lproj "$APP/Contents/Resources/"
PLIST="$APP/Contents/Info.plist"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
# Sans identité donnée : le certificat personnel créé par Tools/make-local-cert.sh s'il existe
# (signature stable, macOS garde les autorisations d'un build à l'autre), sinon signature ad hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-certificate -c "GitWatch Local" >/dev/null 2>&1; then
    if ! codesign --force --timestamp=none --sign "GitWatch Local" "$APP" >/dev/null 2>&1; then
        # Trousseau verrouillé (session SSH…) : signature ad hoc pour ne pas bloquer le build.
        echo "Signature « GitWatch Local » impossible, signature ad hoc." >&2
        codesign --force --timestamp=none --sign - "$APP" >/dev/null
    fi
else
    codesign --force --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP" >/dev/null
fi
echo "$APP"
