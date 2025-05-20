#!/bin/bash

flutter clean
flutter pub get
cd macos
pod install
cd ..
./remove_g_flag.sh
flutter build macos
