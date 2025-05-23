주요 파일 및 경로 설명 (JH_GuitarTree)

설계서 기준 기능 구현을 위한 핵심 Dart 파일 목록입니다.
실제 작업이 진행될 때, 새로운 경로나 파일을 생성할 경우 설계 구조에 없던 폴더 혹은 파일이라고 자동으로 안내해 주세요. 이 내용은 추후 사용자가 요약 요청시 꼭 반영해줘야 합니다.
새 채팅으로 넘어가는 주요 파일 및 경로 설계에 변동된 사항이 있는 경우에는 [주요 파일 및 경로 설계] 파일 을 업데이트 해야 한다고 입력해 주세요.

📂 lib/
main.dart → 앱 진입점, Firebase 초기화 포함
app.dart → MaterialApp 및 라우팅 초기 설정

📂 lib/routes/
app_routes.dart → 전체 화면 라우팅 정의 (/login, /staff_portal 등록됨)

📂 lib/models/
student.dart → 학생 모델 정의, Firestore/Hive 변환 포함
teacher.dart → 강사 모델 정의
lesson.dart → 수업 데이터 모델
summary.dart → 요약 결과 모델

📂 lib/services/
auth_service.dart → 로그인 상태 및 권한 관리
firestore_service.dart → Firestore 연동 공통 서비스
student_service.dart → 학생 CRUD 처리
teacher_service.dart → 강사 목록 불러오기 서비스
log_service.dart → 저장/오류/로그인 로그 기록
sheet_service.dart → Google Sheets 연동
student_mock_service.dart → 테스트용 더미 데이터 제공 (옵션)

📂 lib/screens/auth/
login_screen.dart → 로그인 UI 구성, 로딩 상태만 유지
login_controller.dart → 학생 로그인 로직 및 Firestore 연동

📂 lib/dialogs/
staff_login_dialog.dart → 관리자/강사 로그인 다이얼로그 UI
student_selector_dialog.dart → 동명이인 선택 다이얼로그 UI
student_edit_dialog.dart → 학생 등록 및 정보 수정 다이얼로그
edit_memo_dialog.dart → 학생 메모 수정 다이얼로그
confirm_delete_dialog.dart → 학생 삭제 확인 다이얼로그

📂 lib/widgets/
login_input_field.dart → 재사용 가능한 로그인 입력 필드 위젯 (TextField 공통화)
staff_portal/student_list_tile.dart → 학생 항목 UI (수정/삭제/메모 버튼 포함)
staff_portal/portal_action_grid.dart → 관리자 기능 버튼 그리드
staff_portal/search_bar_with_button.dart → 검색창 + 버튼 UI

📂 lib/ui/components/
keyword_chip.dart → 키워드 태그 선택 칩 UI
save_status_indicator.dart → 저장 상태 UI 표시
empty_state.dart → 데이터 없음 표시용 컴포넌트
error_view.dart → 에러 발생 시 UI
rounded_button.dart → 공통 버튼 컴포넌트
info_message_box.dart → 경고창/도움말용 메시지 박스
toggle_section_box.dart → 접힘/펼침 UI 구성

📂 lib/ui/layout/
base_scaffold.dart → 공통 Scaffold 구조
centered_column.dart → 가운데 정렬 레이아웃

📂 lib/screens/home/
student_home_screen.dart → 학생용 홈 화면
staff_portal_screen.dart → 강사/관리자 포털 홈 화면 (좌우 분할 레이아웃)

📂 lib/screens/lesson/
today_lesson_screen.dart → 오늘 수업 입력 화면
lesson_history_screen.dart → 지난 수업 복습 화면

📂 lib/screens/summary/
summary_result_screen.dart → 요약 결과 화면

📂 lib/screens/settings/
change_password_screen.dart → 비밀번호 변경 UI
logs_screen.dart → 로그 열람 화면
export_screen.dart → 백업 UI
import_screen.dart → 복원 UI

📂 lib/firebase/
firebase_options.dart → Firebase 초기화 옵션
firestore_refs.dart → 컬렉션 참조 상수 정의

📂 lib/constants/
platform_utils.dart → mac/Win/iOS/Android 분기 함수

📂 lib/data/
local_hive_boxes.dart → Hive 초기화 및 어댑터 등록
