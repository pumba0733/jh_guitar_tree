#!/bin/bash

echo "🚫 VSCode가 종료된 상태인지 꼭 확인하세요!"
read -p "❓ VSCode 종료했나요? [Enter] 계속 진행"

echo "🧹 Cleaning build..."
flutter clean

echo "📦 Fetching dependencies..."
flutter pub get

echo "📁 Moving to macos and installing pods..."
cd macos
pod install
cd ..

echo "🚀 Building macOS release..."
flutter build macos --release

echo "✅ macOS 릴리즈 빌드 완료!"
