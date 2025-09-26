#!/bin/bash
set -euo pipefail

# 變數
URL="https://hosted.weblate.org/download/keycloak/?format=zip"
TMP_DIR="/tmp/weblate_sync"
TARGET_DIR="./themes"
SRC_SUBDIR="keycloak/admin-ui/themes/src/main/resources-community/theme/base"
MSG_SRC="keycloak/admin-ui/js/apps/admin-ui/maven-resources-community/theme/keycloak.v2/admin/messages/messages_zh_Hant.properties"
MSG_TARGET="$TARGET_DIR/admin/messages/messages_zh_TW.properties"
MSG_ACCOUNT_SRC="keycloak/admin-ui/js/apps/account-ui/maven-resources-community/theme/keycloak.v3/account/messages/messages_zh_Hant.properties"
MSG_ACCOUNT_TARGET="$TARGET_DIR/account/messages/messages_zh_TW.properties"

# 建立暫存資料夾
mkdir -p "$TMP_DIR"

# 下載 zip
ZIP_FILE="$TMP_DIR/weblate.zip"
curl -L "$URL" -o "$ZIP_FILE"

# 解壓縮
unzip -q "$ZIP_FILE" -d "$TMP_DIR"

# 同步檔案（不刪除目標多餘檔案）
rsync -av "$TMP_DIR/$SRC_SUBDIR/" "$TARGET_DIR/"

# 檔案重新命名
# find "$TARGET_DIR" -type f -name "messages_zh_Hant.properties" \
#   -exec bash -c 'for f; do chmod 644 "$f"; mv "$f" "${f%/*}/messages_zh_TW.properties"; done' _ {} +

# 追加 messages 內容
if [ -f "$TMP_DIR/$MSG_SRC" ]; then
  mkdir -p "$(dirname "$MSG_TARGET")"
  cat "$TMP_DIR/$MSG_SRC" >> "$MSG_TARGET"
fi

# Add account
if [ -f "$TMP_DIR/$MSG_ACCOUNT_SRC" ]; then
  mkdir -p "$(dirname "$MSG_ACCOUNT_TARGET")"
  cat "$TMP_DIR/$MSG_ACCOUNT_SRC" >> "$MSG_ACCOUNT_TARGET"
fi

# 清理
rm -rf "$TMP_DIR"

echo "同步完成"
