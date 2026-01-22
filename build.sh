#!/bin/bash

set -e

echo "🔨 Building DoubaoVoice..."
xcodebuild -project DoubaoVoice.xcodeproj \
    -scheme DoubaoVoice \
    -configuration Debug \
    -derivedDataPath ./build \
    build | xcbeautify || cat

APP_PATH="./build/Build/Products/Debug/DoubaoVoice.app"

if [ -d "$APP_PATH" ]; then
    echo ""
    echo "✅ Build successful!"
    echo "📦 App location: $APP_PATH"
else
    echo "❌ Build failed - app not found at $APP_PATH"
    exit 1
fi
