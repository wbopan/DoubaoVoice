#!/bin/bash

set -e

# 先构建
./build.sh

echo ""
echo "🚀 Running Seedling with logs..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

APP_PATH="./build/Build/Products/Debug/Seedling.app"

# 运行应用并显示日志
"$APP_PATH/Contents/MacOS/Seedling" 2>&1
