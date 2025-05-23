// 📄 lib/main.dart

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase/firebase_options.dart';
import 'package:jh_guitar_tree/app.dart'; // MyApp 정의된 곳

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // ✅ Firebase 연동 로그 출력!
  printCurrentFirebaseApp();

  runApp(const MyApp());
}

void printCurrentFirebaseApp() {
  final app = Firebase.app();
  print('✅ Firebase App: ${app.name}');
  print('📦 Project ID: ${app.options.projectId}');
  print('🔑 API Key: ${app.options.apiKey}');
}
