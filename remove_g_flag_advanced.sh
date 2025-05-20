#!/bin/bash
echo "🔍 Searching & removing -G flags everywhere..."

# 확장자 기준 + 숨겨진 파일까지 대상 확장
extensions=("xcconfig" "rsp" "args" "tmp" "sh" "cpp" "c" "modulemap")

for ext in "${extensions[@]}"; do
  find ./macos/Pods -type f -name "*.${ext}" -print0 | while IFS= read -r -d '' file; do
    if grep -q "\-G" "$file"; then
      echo "🧽 Removing -G from $file"
      sed -i '' 's/ -G//g' "$file"
    fi
  done
done

# 🧨 .rsp 파일 전체 재탐색 (build 디렉토리까지 포함)
find ./macos -type f \( -name "*.rsp" -o -name "*.args" -o -name "*.tmp" \) -print0 | while IFS= read -r -d '' file; do
  if grep -q "\-G" "$file"; then
    echo "🧹 Removing -G from $file"
    sed -i '' 's/ -G//g' "$file"
  fi
done

echo "✅ All -G flags cleaned."

