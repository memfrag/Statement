#!/bin/bash
set -euo pipefail

# ----- Config -----
SCHEME="Statement (Release)"
APP_NAME="Statement"
KEYCHAIN_PROFILE="notary"
SPARKLE_VERSION="2.9.0"
GH_REPO="memfrag/Statement"
TEAM_ID="DR5YAK7GKS"

# ----- Paths -----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
SPARKLE_TOOLS_DIR="$PROJECT_DIR/Sparkle-tools"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"

# ----- Helpers -----
error() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo ""
    echo "==> $*"
}

tail_log_on_fail() {
    local log="$1"
    if [ -f "$log" ]; then
        echo "--- Last 30 lines of $log ---" >&2
        tail -30 "$log" >&2
    fi
}

# ----- Sanity checks -----
command -v xcodebuild >/dev/null 2>&1 || error "xcodebuild not found"
command -v gh >/dev/null 2>&1 || error "gh CLI not found. Install with: brew install gh"
command -v hdiutil >/dev/null 2>&1 || error "hdiutil not found"
command -v /usr/libexec/PlistBuddy >/dev/null 2>&1 || error "PlistBuddy not found"

# ----- Clean and prepare -----
info "Preparing build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ----- Ensure Sparkle tools -----
if [ ! -x "$SPARKLE_TOOLS_DIR/bin/sign_update" ]; then
    info "Downloading Sparkle $SPARKLE_VERSION tools"
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        -o "$BUILD_DIR/Sparkle.tar.xz" || error "Failed to download Sparkle"
    mkdir -p "$SPARKLE_TOOLS_DIR"
    tar -xf "$BUILD_DIR/Sparkle.tar.xz" -C "$SPARKLE_TOOLS_DIR" || error "Failed to extract Sparkle"
    rm "$BUILD_DIR/Sparkle.tar.xz"
fi
[ -x "$SPARKLE_TOOLS_DIR/bin/sign_update" ] || error "Sparkle sign_update tool not found after download"
[ -x "$SPARKLE_TOOLS_DIR/bin/generate_appcast" ] || error "Sparkle generate_appcast tool not found after download"

# ----- Discover Info.plist path -----
INFO_PLIST="$PROJECT_DIR/Statement/macOS/Info.plist"
[ -f "$INFO_PLIST" ] || error "Info.plist not found at $INFO_PLIST"

# ----- Version check -----
info "Checking version"
CURRENT_VERSION=""
MV_FROM_PBXPROJ=$(xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" -scheme "$SCHEME" -showBuildSettings -configuration Release 2>/dev/null | grep -E "^\s*MARKETING_VERSION\s*=" | head -1 | awk -F'= ' '{print $2}' | xargs || true)
if [ -n "$MV_FROM_PBXPROJ" ]; then
    CURRENT_VERSION="$MV_FROM_PBXPROJ"
else
    CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "")
fi
[ -n "$CURRENT_VERSION" ] || error "Could not determine current version"
echo "Current version: $CURRENT_VERSION"

LATEST_TAG=$(gh release view --repo "$GH_REPO" --json tagName -q '.tagName' 2>/dev/null || echo "")
if [ -n "$LATEST_TAG" ]; then
    echo "Latest GitHub release: $LATEST_TAG"
else
    echo "No previous GitHub releases found"
fi

version_gt() {
    # returns 0 if $1 > $2
    [ "$1" = "$2" ] && return 1
    local highest
    highest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)
    [ "$highest" = "$1" ]
}

NEEDS_BUMP=0
if [ -z "$LATEST_TAG" ]; then
    NEEDS_BUMP=0
elif version_gt "$CURRENT_VERSION" "$LATEST_TAG"; then
    NEEDS_BUMP=0
else
    NEEDS_BUMP=1
fi

if [ "$NEEDS_BUMP" = "1" ]; then
    echo "Current version ($CURRENT_VERSION) is not newer than latest release ($LATEST_TAG)."
    read -r -p "Enter new version: " NEW_VERSION
    [ -n "$NEW_VERSION" ] || error "No version entered"
    if ! version_gt "$NEW_VERSION" "$LATEST_TAG"; then
        error "New version $NEW_VERSION is not newer than $LATEST_TAG"
    fi
    VERSION="$NEW_VERSION"
else
    VERSION="$CURRENT_VERSION"
fi
echo "Building version: $VERSION"

DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

# ----- Update versions -----
info "Updating version in project files"
# Update MARKETING_VERSION and CURRENT_PROJECT_VERSION in pbxproj if present
PBXPROJ="$PROJECT_DIR/$APP_NAME.xcodeproj/project.pbxproj"
if grep -q "MARKETING_VERSION" "$PBXPROJ"; then
    /usr/bin/sed -i '' -E "s/(MARKETING_VERSION = )[^;]+;/\1$VERSION;/g" "$PBXPROJ"
fi
if grep -q "CURRENT_PROJECT_VERSION" "$PBXPROJ"; then
    /usr/bin/sed -i '' -E "s/(CURRENT_PROJECT_VERSION = )[^;]+;/\1$VERSION;/g" "$PBXPROJ"
fi

# Always update Info.plist (this is what generate_appcast reads)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$INFO_PLIST"

# Commit version bump if anything changed
cd "$PROJECT_DIR"
if ! git diff --quiet -- "$PBXPROJ" "$INFO_PLIST"; then
    git add "$PBXPROJ" "$INFO_PLIST"
    git commit -m "Bump version to $VERSION"
    git push origin HEAD
fi

# ----- Archive -----
info "Archiving"
xcodebuild archive \
    -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -archivePath "$ARCHIVE_PATH" \
    -configuration Release \
    -arch arm64 \
    ENABLE_HARDENED_RUNTIME=YES \
    2>&1 | tee "$BUILD_DIR/archive.log" | tail -5 \
    || { tail_log_on_fail "$BUILD_DIR/archive.log"; error "Archive failed"; }
[ -d "$ARCHIVE_PATH" ] || { tail_log_on_fail "$BUILD_DIR/archive.log"; error "Archive not created at $ARCHIVE_PATH"; }

# ----- Export -----
info "Exporting archive"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    2>&1 | tee "$BUILD_DIR/export.log" | tail -5 \
    || { tail_log_on_fail "$BUILD_DIR/export.log"; error "Export failed"; }

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
[ -d "$APP_PATH" ] || { tail_log_on_fail "$BUILD_DIR/export.log"; error "Exported app not found at $APP_PATH"; }

# Verify codesign
info "Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" || error "Code signature verification failed"

# Double-check version from the built app
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
echo "Built app version: $BUILT_VERSION"
[ "$BUILT_VERSION" = "$VERSION" ] || error "Version mismatch: built app is $BUILT_VERSION, expected $VERSION"

# ----- Create DMG -----
info "Creating DMG"
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -a "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" \
    || error "DMG creation failed"
rm -rf "$DMG_STAGING"
[ -f "$DMG_PATH" ] || error "DMG not found at $DMG_PATH"

# ----- Notarize -----
info "Submitting DMG for notarization"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait \
    2>&1 | tee "$BUILD_DIR/notarize.log" \
    || { tail_log_on_fail "$BUILD_DIR/notarize.log"; error "Notarization failed"; }

# ----- Staple -----
info "Stapling DMG"
xcrun stapler staple "$DMG_PATH" || error "Stapling failed"
xcrun stapler validate "$DMG_PATH" || error "Stapler validation failed"

# ----- Sparkle signature -----
info "Signing DMG with Sparkle"
SPARKLE_SIG=$("$SPARKLE_TOOLS_DIR/bin/sign_update" "$DMG_PATH") \
    || error "Sparkle sign_update failed"
echo "Sparkle signature: $SPARKLE_SIG"

# ----- Create GitHub release -----
TAG="$VERSION"
read -r -p "Enter release title (default: $APP_NAME $VERSION): " RELEASE_TITLE
if [ -z "$RELEASE_TITLE" ]; then
    RELEASE_TITLE="$APP_NAME $VERSION"
fi

info "Tagging and pushing $TAG"
cd "$PROJECT_DIR"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists locally"
else
    git tag "$TAG"
    git push origin "$TAG"
fi

info "Creating GitHub release"
gh release create "$TAG" \
    --repo "$GH_REPO" \
    --title "$RELEASE_TITLE" \
    --generate-notes \
    "$DMG_PATH" \
    || error "Failed to create GitHub release"

# ----- Generate appcast -----
info "Generating appcast"
APPCAST_DIR="$BUILD_DIR/appcast-assets"
mkdir -p "$APPCAST_DIR"
if [ -f "$PROJECT_DIR/appcast.xml" ]; then
    cp "$PROJECT_DIR/appcast.xml" "$APPCAST_DIR/"
fi
cp "$DMG_PATH" "$APPCAST_DIR/"

"$SPARKLE_TOOLS_DIR/bin/generate_appcast" \
    --download-url-prefix "https://github.com/$GH_REPO/releases/download/$TAG/" \
    -o "$APPCAST_DIR/appcast.xml" \
    "$APPCAST_DIR" \
    || error "generate_appcast failed"

cp "$APPCAST_DIR/appcast.xml" "$PROJECT_DIR/appcast.xml"
cd "$PROJECT_DIR"
git add appcast.xml
if ! git diff --cached --quiet; then
    git commit -m "Update appcast for $VERSION"
    git push origin HEAD
fi

info "Done. Released $APP_NAME $VERSION."
echo "DMG: $DMG_PATH"
echo "Release: https://github.com/$GH_REPO/releases/tag/$TAG"
