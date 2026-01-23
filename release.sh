#!/bin/bash

set -e

APP_NAME="DoubaoVoice"
BUILD_DIR="./build"
DEST="/Applications"

echo "🔨 Building $APP_NAME (Release)..."
xcodebuild -scheme "$APP_NAME" -configuration Release -derivedDataPath "$BUILD_DIR" -quiet

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed: $APP_PATH not found"
    exit 1
fi

echo "📦 Installing to $DEST..."
rm -rf "$DEST/$APP_NAME.app"
cp -R "$APP_PATH" "$DEST/"

echo "✅ Installed: $DEST/$APP_NAME.app"
