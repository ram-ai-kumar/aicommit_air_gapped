#!/usr/bin/env bash
# aicommit — Installer / Sync Script
# Syncs repository contents to ~/.aicommit/

set -e

# Configuration
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${AICOMMIT_DIR:-$HOME/.aicommit}"
BACKUP_DIR="${TARGET_DIR}.backup_$(date +%Y%m%d_%H%M%S)"

echo "🚀 Syncing aicommit from $SOURCE_DIR to $TARGET_DIR..."

# 1. Create target structure
mkdir -p -m 700 "$TARGET_DIR"
mkdir -p "$TARGET_DIR/bin"
mkdir -p "$TARGET_DIR/lib"
mkdir -p "$TARGET_DIR/templates"
mkdir -p "$TARGET_DIR/config"
mkdir -p "$TARGET_DIR/completions"

# 2. Sync files
cp "$SOURCE_DIR/../aicommit.sh" "$TARGET_DIR/"
[ -f "$SOURCE_DIR/../init.sh" ] && cp "$SOURCE_DIR/../init.sh" "$TARGET_DIR/"
[ -d "$SOURCE_DIR/../bin" ] && cp -r "$SOURCE_DIR/../bin/"* "$TARGET_DIR/bin/"
cp -r "$SOURCE_DIR/../lib/"* "$TARGET_DIR/lib/"
cp -r "$SOURCE_DIR/../templates/"* "$TARGET_DIR/templates/"
cp -r "$SOURCE_DIR/../config/"* "$TARGET_DIR/config/"
[ -d "$SOURCE_DIR/../completions" ] && cp -r "$SOURCE_DIR/../completions/"* "$TARGET_DIR/completions/"

# 3. Set permissions
chmod -R 700 "$TARGET_DIR"
chmod 755 "$TARGET_DIR/bin/"* 2>/dev/null || true
chmod 644 "$TARGET_DIR/init.sh" 2>/dev/null || true

echo "✅ Sync complete!"
echo "💡 To apply changes in your current shell: source $TARGET_DIR/init.sh"
