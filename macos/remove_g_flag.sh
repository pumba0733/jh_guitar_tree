#!/bin/bash
echo "🔍 Searching & force-removing -G flags in: $(pwd)"

extensions=("xcconfig" "rsp" "args" "tmp" "sh" "cpp" "c" "modulemap" "swift" "pbxproj" "plist")

for ext in "${extensions[@]}"; do
  find ./macos/Pods -type f -name "*.${ext}" -print0 | while IFS= read -r -d '' file; do
    if grep -q "\-G" "$file"; then
      echo "🧨 Cleaning -G in $file"
      # 쌍따옴표 내부 포함 모든 -G 제거 (탭 포함 처리, 여분 공백 정리)
      sed -i '' -E 's/([[:space:]]|")-G([[:space:]]|")/ /g' "$file"
      sed -i '' -E 's/  +/ /g' "$file"
    fi
  done
done

echo "✅ Final clean: All -G flags attempted to remove."
