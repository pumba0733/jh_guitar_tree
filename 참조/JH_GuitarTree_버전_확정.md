## 🔖 v1.0.0 안정화 완료

### 📦 주요 내역
- ✅ macOS용 Firebase 초기화 완료
- ✅ cloud_firestore.framework 포함 정상 빌드 확인
- ✅ Deployment Target 13.0 통일 (Podfile, .xcconfig, Xcode General)
- ✅ x86_64 아키텍처 완전 제거 (Xcode Build Settings)
- ✅ 릴리즈 빌드 성공: `build/macos/Build/Products/Release/jh_guitar_tree.app`

### ⚠️ 참고 사항
- 일부 warning은 Firebase/gRPC 내부 모듈에서 발생한 것으로 기능 동작에 영향 없음
- `Flutter-Generated.xcconfig` 덮어쓰기 방지를 위해 추후 Git 관리 필요

## ✅ v1.11 (2025.05.22)

### 🔧 주요 변경사항 요약
- macOS 기준 전체 구조 재정비 및 `lib/`, `macos/` 디렉토리 충돌 해결
- Firebase 연동 정상화 (`GoogleService-Info.plist` 포함 및 Podfile 정리)
- role 파라미터 전달 오류 해결 (`staff_portal_screen.dart`, `portal_action_grid.dart`)
- `EditMemoDialog`에서 async context 문제 해결 (`mounted` 처리 포함)
- `StudentService`, `StudentListTile`, `StudentEditDialog` 기능 정상 작동 확인

### ✅ 테스트 결과
- 앱 실행 시 `로그인 화면 정상 진입` 확인
- 학생 로그인 (`조나현`) → 학생 홈 이동 정상
- 학생 홈 UI 확인:
  - ⛔ 나가기 버튼 없음 → 톱니바퀴만 보임 (작동 안함)
- 로그인 입력창에서 `엔터 → 자동 로그인 기능 미작동` (수정 필요)
- 강사/관리자 로그인 UI 구조 복잡 → 리팩토링 필요

---

### 📋 요청사항 (v1.12 예정)

#### 🔁 로그인 화면 UI 구조 개편

| 항목 | 변경사항 |
|------|----------|
| 👥 사용자 구분 | 강사/관리자 드롭박스 제거 |
| 🧑 학생 로그인 | 검색창 유지 + 엔터 또는 버튼으로 로그인 |
| 👨‍🏫 강사/관리자 로그인 | 우측 상단 톱니바퀴 → 다이얼로그 팝업 |
| 톱니바퀴 다이얼로그 | ① 드롭다운으로 강사 선택<br>② 비밀번호 입력 후 엔터 로그인<br>③ 관리자 영역도 동일하게 구성 |
| 다이얼로그 UX | 엔터 로그인 / ESC 닫기 설정 |
| 학생 홈 | '톱니바퀴' → '나가기'로 변경 (자동 로그아웃 연결) |

---

# 브랜치명 추천
feature/v1.12-login-ui-refactor
