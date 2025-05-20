#!/bin/bash
echo "🔍 Searching for -G in Pods..."

# 확장자별 대상 설정
extensions=("xcconfig" "rsp" "args" "tmp" "sh" "cpp" "c")

for ext in "${extensions[@]}"; do
  find ./macos/Pods -name "*.${ext}" -type f -print0 | while IFS= read -r -d '' file; do
    if grep -q "\-G" "$file"; then
      echo "🧽 Removing -G in $file"
      sed -i '' 's/ -G//g' "$file"
    fi
  done
done

echo "✅ Done cleaning -G flags."

