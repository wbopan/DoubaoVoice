#!/bin/bash

set -e

echo "🔨 Building Seedling..."
xcodebuild -project Seedling.xcodeproj \
    -scheme Seedling \
    -configuration Debug \
    -derivedDataPath ./build \
    build | xcbeautify || cat

APP_PATH="./build/Build/Products/Debug/Seedling.app"

if [ -d "$APP_PATH" ]; then
    echo ""
    echo "✅ Build successful!"
    echo "📦 App location: $APP_PATH"
else
    echo "❌ Build failed - app not found at $APP_PATH"
    exit 1
fi
