#!/bin/bash

set -e

# 先构建
./build.sh

echo ""
echo "🚀 Running DoubaoVoice with logs..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

APP_PATH="./build/Build/Products/Debug/DoubaoVoice.app"

# 运行应用并显示日志
"$APP_PATH/Contents/MacOS/DoubaoVoice" 2>&1
