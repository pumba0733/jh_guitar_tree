#!/bin/bash

echo "🚫 Removing '-G' flags from CocoaPods build files..."

TARGET_DIR="./macos/Pods"

if [ ! -d "$TARGET_DIR" ]; then
  echo "❌ Pods directory not found: $TARGET_DIR"
  exit 1
fi

# -G 제거 대상 확장자 목록
EXTENSIONS=("xcconfig" "rsp" "sh" "modulemap" "cpp")

for ext in "${EXTENSIONS[@]}"; do
  echo "🧹 Searching for *.$ext files..."
  find "$TARGET_DIR" -name "*.$ext" -exec sed -i '' 's/\(^\|\s\)-G\($\|\s\)/\1\2/g' {} +
done

echo "✅ '-G' flags removed successfully!"
