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


## v1.11 (2025.05.22 기준)

- ✅ 오류 0 상태 기준 전체 백업 및 커밋 완료
- ✅ macOS 빌드 정상 완료 (단, 일부 CocoaPods 관련 warning 존재)
- ✅ 로그인 → StaffPortalScreen 흐름 정상 작동
- ✅ role 전달 오류 및 async context 문제 해결 완료
- ✅ EditMemoDialog 최종반영 및 context 문제 제거
- ✅ 다음 테스트 항목: Student 추가/수정/삭제 기능, 강사 관리, Portal 버튼 연동
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

📌 [v1.12] 버전 확정 요약 (2025-05-23)

🔢 브랜치명: feature/v1.12-login-ui-refactor
🛠 주요 작업: 로그인 화면 전체 리팩토링 및 구조 분리

✅ 주요 변경 사항
로그인 화면 UI 구조 확정(중앙 정렬, 인풋 필드, 로딩 처리)
학생 로그인 시 Enter 키 대응 구조 추가 시도
파일 구조 리팩토링:
login_input_field.dart: 입력 필드 위젯 분리
login_controller.dart: 로그인 로직 별도 관리
student_selector_dialog.dart: 동명이인 선택 다이얼로그
staff_login_dialog.dart: 강사/관리자 로그인 다이얼로그 분리
Firebase 연동: 이름 기준 학생 조회 구현

🧪 테스트 결과

학생 로그인 UI ✅ 완료 기능. 정상 작동
학생 로그인 Enter 키 ⛔ 미작동. v1.13에서 확인 예정
강사/관리자 로그인 ⛔ UI만 있음. 실제 동작 테스트 안됨
로그인 후 홈 진입 ⛔ 실패. Firebase 초기화 문제로 추정

### 📦 v1.13 버전 확정 (2025-05-23)

**주요 변경사항**
- 학생/강사/관리자 공통 로그인 화면 구현
- 강사 로그인 UI 개편: 역할 선택 라디오 버튼 + 이름 드롭다운 + 이메일/비번 입력 필드 구성
- 강사 리스트 Firestore 연동으로 전환 (더 이상 하드코딩되지 않음)
- `StudentHomeScreen` UI 개선: 버튼 위치 조정, 로그아웃 버튼 우측 상단 아이콘 추가
- 학생 로그인 로직 개선: 대소문자 구분 이슈 방지를 위해 `name_lowercase` 필드 검색 방식 적용
- 로그인 텍스트필드 → 엔터 입력시 자동 로그인 시도 가능하도록 개선
로그인 화면 리팩토링 완료 (학생 / 강사 / 관리자 공통 구조)
강사 로그인 UI 구성: 역할 선택 + 이름 드롭다운 + 이메일/비번 입력
강사 목록: Firestore 연동 방식 전환 (TeacherService.fetchAll() 기준)
StudentHomeScreen UI 개선: 버튼 크기 및 정렬 개선, 로그아웃 버튼 우측 상단 아이콘으로 변경
LoginController 학생 로그인 로직 개선:
이름 입력 시 자동으로 소문자 변환 후 name_lowercase 필드 기준 Firestore 검색
동명이인 선택 시 StudentSelectorDialog 호출
엔터 입력 시 자동 로그인 시도 가능하도록 개선
main.dart에 Firebase 초기화 디버깅 로그 추가

-현재 이슈
Firestore 연결은 성공했으나, students 컬렉션에서 검색 결과가 0건으로 나타남
name_lowercase 필드가 있음에도 불구하고 검색이 실패함
다음 버전 v1.14에서 Firestore 쿼리, 인덱싱, 초기화 순서 등 점검 예정
- 현재 `학생 로그인` 시 Firestore 연결 실패 문제(`검색된 문서 수: 0`)가 발생 중이며,  
  다음 버전 `v1.14`에서 Firebase Firestore 연결 문제 해결을 최우선 과제로 진행 예정.

