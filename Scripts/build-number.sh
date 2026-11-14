#!/bin/sh
# Numéro de build : entier qui augmente de 1 quand le code source a changé depuis le build précédent.
# Le compteur est conservé dans .build-number (empreinte des sources + numéro) et écrit dans le Info.plist du produit.
set -e

state="${PROJECT_DIR}/.build-number"
plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

hash=$(cd "$PROJECT_DIR" && find iABView -type f \
    \( -name '*.swift' -o -name '*.js' -o -name 'Info.plist' -o -name '*.xcassets' -o -name '*.entitlements' \) -print0 \
    | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1)

last_hash=""
number=0
if [ -f "$state" ]; then
    read -r last_hash number < "$state" || true
fi

if [ "$hash" != "$last_hash" ]; then
    number=$((number + 1))
    echo "$hash $number" > "$state"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $number" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $number" "$plist"
