#!/bin/bash

echo "🧼 Cleaning Flutter build artifacts..."
flutter clean

echo "🧹 Removing previous Pod install files..."
rm -rf macos/Pods macos/Podfile.lock macos/Runner.xcworkspace

echo "📦 Getting Flutter packages..."
flutter pub get

echo "📁 Running pod install..."
cd macos
pod install
cd ..

echo "🧽 Removing all -G flags in xcconfig, rsp, cpp..."
./remove_g_flag.sh

echo "🚀 Building macOS app..."
flutter build macos
