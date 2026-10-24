#!/bin/zsh

set -euo pipefail

SRCROOT=$(realpath "$1")
TARGET_IPA=$2

WORKSPACE="$SRCROOT/Asspp.xcworkspace"
SCHEME="Asspp"
BUILD_PRODUCT="Asspp.app"

cd $SRCROOT

git clean -fdx -f
git reset --hard

# Generate Developer.xcconfig for CI (codesign completely disabled)
cat >"$SRCROOT/Configuration/Developer.xcconfig" <<'EOF'
// CI-generated Developer.xcconfig
// Code signing is completely disabled for CI builds
DEVELOPMENT_TEAM =
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY =
CODE_SIGN_IDENTITY[sdk=macosx*] =
CODE_SIGNING_REQUIRED = NO
CODE_SIGNING_ALLOWED = NO
EOF

xcodebuild -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$SRCROOT/build/DerivedDataApp" \
    -destination 'generic/platform=macOS' \
    build \
    DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO" \
    GCC_GENERATE_DEBUGGING_SYMBOLS=YES STRIP_INSTALLED_PRODUCT=NO \
    COPY_PHASE_STRIP=NO UNSTRIPPED_PRODUCT=NO \
    | xcbeautify

BUILD_PRODUCT_PATH=""
for i in $(find "$SRCROOT/build/DerivedDataApp" -name "$BUILD_PRODUCT"); do
    BUILD_PRODUCT_PATH=$i
    break
done
BUILD_PRODUCT_PATH=$(realpath "$BUILD_PRODUCT_PATH")

if [ -z "$BUILD_PRODUCT_PATH" ]; then
    echo "[-] build product not found"
    exit 1
fi

echo "[+] build product path: $BUILD_PRODUCT_PATH"

# Ad-hoc signing requires no paid Apple Developer account. Sign embedded
# libraries/frameworks and the outer app so macOS has a stable signed bundle
# and can use the regular local login Keychain. Do not add a team Keychain group.
# Bundle SHA256-pinned official ipatool 2.7.0 macOS ARM64 + Intel binaries.
echo "[+] downloading verified ipatool 2.7.0..."
IPATOOL_VERSION=2.7.0
IPATOOL_TMP=$(mktemp -d)
trap 'rm -rf "$IPATOOL_TMP"' EXIT
for ARCH in arm64 amd64; do
    ARCHIVE="$IPATOOL_TMP/ipatool-$ARCH.tar.gz"
    curl -fL --retry 3 "https://github.com/majd/ipatool/releases/download/v${IPATOOL_VERSION}/ipatool-${IPATOOL_VERSION}-macos-${ARCH}.tar.gz" -o "$ARCHIVE"
    case "$ARCH" in
        arm64) DIGEST=5ae100d4520cf4b3f4374239e5925a9ad9a8dc02abc16bae27479e7ae99aca33 ;;
        amd64) DIGEST=05f48994d8b3cfefe7ea1172a0ac0b28715888e9df0af38cf3e490d2ed592263 ;;
    esac
    echo "$DIGEST  $ARCHIVE" | shasum -a 256 -c -
    mkdir -p "$IPATOOL_TMP/$ARCH"
    tar -xzf "$ARCHIVE" -C "$IPATOOL_TMP/$ARCH"
done
IPATOOL_HELPER="$BUILD_PRODUCT_PATH/Contents/Resources/ipatool"
lipo -create \
    "$IPATOOL_TMP/arm64/bin/ipatool-${IPATOOL_VERSION}-macos-arm64" \
    "$IPATOOL_TMP/amd64/bin/ipatool-${IPATOOL_VERSION}-macos-amd64" \
    -output "$IPATOOL_HELPER"
chmod 755 "$IPATOOL_HELPER"
lipo -info "$IPATOOL_HELPER"
codesign --force --sign - --timestamp=none "$IPATOOL_HELPER"

echo "[+] ad-hoc signing macOS app..."
codesign --force --deep --sign - --timestamp=none "$BUILD_PRODUCT_PATH"
codesign --verify --deep --strict --verbose=2 "$BUILD_PRODUCT_PATH"
codesign --display --verbose=2 "$BUILD_PRODUCT_PATH" 2>&1 | grep -E 'Signature=|TeamIdentifier=' || true

echo "[+] packaging..."
pushd "$SRCROOT/build/DerivedDataApp/Build/Products/Release"
zip -r "$TARGET_IPA" "$BUILD_PRODUCT"
popd

echo "[+] done"
