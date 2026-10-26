#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$1"
BUILD_DIR="$2"
REDIS_WHEEL_URL="https://files.pythonhosted.org/packages/c5/d1/19a9c76811757684a0f74adc25765c8a901d67f9f6472ac9d57c844a23c8/redis-5.0.8-py3-none-any.whl"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp "$SOURCE_DIR"/*.py "$BUILD_DIR"/

WHEEL_FILE=$(mktemp --suffix=.whl)
curl -sL "$REDIS_WHEEL_URL" -o "$WHEEL_FILE"
python3 -c "import zipfile; zipfile.ZipFile('$WHEEL_FILE').extractall('$BUILD_DIR')"
rm -f "$WHEEL_FILE"
