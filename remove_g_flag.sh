#!/bin/bash

echo "🔍 Searching for -G in Pods..."

find ./macos/Pods -type f \( -name "*.xcconfig" -o -name "*.rsp" -o -name "*.cpp" -o -name "*.sh" -o -name "*.modulemap" \) | while read -r file; do
  if grep -q '\-G' "$file"; then
    echo "🧽 Removing -G in $file"
    sed -i '' 's/\s\-G\s*/ /g' "$file"
  fi
done

echo "✅ Done cleaning -G flags."
