#!/bin/bash

set -eo pipefail

echo "🔨 Building Seedling..."

BUILD_LOG=$(mktemp)
trap "rm -f $BUILD_LOG" EXIT

# Build and capture raw output, pipe through xcbeautify for display
xcodebuild -project Seedling.xcodeproj \
    -scheme Seedling \
    -configuration Debug \
    -derivedDataPath ./build \
    build 2>&1 | tee "$BUILD_LOG" | xcbeautify 2>/dev/null || true

# Check actual build result
if grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
    echo ""
    echo "✅ Build successful!"
    echo "📦 App location: ./build/Build/Products/Debug/Seedling.app"
elif grep -q "BUILD FAILED" "$BUILD_LOG"; then
    echo ""
    echo "❌ BUILD FAILED"
    echo ""
    grep "error:" "$BUILD_LOG" | head -20
    exit 1
else
    echo ""
    echo "❌ Build status unknown — xcodebuild output did not contain BUILD SUCCEEDED or BUILD FAILED"
    exit 1
fi
