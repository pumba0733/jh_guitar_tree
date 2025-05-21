v1.0.0 진행중

📦 1. macOS -G 컴파일러 옵션 오류 해결
Xcode 16에서 BoringSSL-GRPC의 -G 충돌 발생
Podfile 내 ARCHS = arm64 설정으로 x86_64 타겟 제거
post_install 훅에 -G 제거 루틴 + remove_g_flag.sh 자동 실행 포함
macOS에서 완전한 릴리즈 빌드 성공까지 거의 근접
🔧 2. CocoaPods + Xcode 설정 통합
Pods-Runner.debug/release/profile.xcconfig 파일을 Xcode에 직접 연결 대신
✅ AppInfo.xcconfig에 #include?로 CocoaPods 설정 직접 통합
✅ CocoaPods가 요구하는 base configuration 문제 완전 해결
🔥 3. Firebase 설정 및 cloud_firestore 연동 시도
firebase_core, cloud_firestore 최신 버전으로 설정
use_frameworks! :linkage => :static 명시
pod 'FirebaseCore', pod 'FirebaseFirestore' 추가
GeneratedPluginRegistrant.swift에서 cloud_firestore 수동 등록까지 시도
아직 cloud_firestore가 Swift에서 완전히 잡히지 않는 문제 최종 보류 상태
🛡️ 4. v1.0.0 안정화 커밋 및 GitHub 배포
.gitignore 포함 상태 점검
flutter clean, pod install, flutter build macos --release까지 포함된 안정화 루틴 확립
GitHub에 main 브랜치 푸시 + v1.0.0 태그 커밋 완료
맥북에서도 그대로 클론해서 이어서 개발 가능하도록 세팅 완성
