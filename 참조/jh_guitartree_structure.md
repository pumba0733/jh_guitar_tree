# 📁 JH_GuitarTree 전체 폴더 및 Dart 파일 구조 (2025-05-19 기준)

> 설계서 1~16단계 및 보완사항 전체 반영 기준

---

## ✅ lib/
- main.dart (앱 진입점, Firebase 초기화)
- app.dart (MaterialApp, 라우트 연결)
- routes/app_routes.dart (전체 화면 라우팅 정의)

---

## 📂 constants/
- app_strings.dart (텍스트 상수)
- app_styles.dart (스타일 상수)
- app_keys.dart (키 값 상수)
- platform_utils.dart (플랫폼 분기 유틸 함수)
- app_colors.dart (공통 색상 정의)

---

## 📂 firebase/
- firebase_options.dart (Firebase 초기화 옵션)
- firestore_refs.dart (컬렉션/문서 참조)

---

## 📂 data/
- local_hive_boxes.dart (Hive 초기화 및 박스 오픈)

---

## 📂 models/
- student.dart / student.g.dart (학생 모델)
- teacher.dart / teacher.g.dart (강사 모델)
- lesson.dart / lesson.g.dart (수업 모델)
- summary.dart / summary.g.dart (AI 요약 모델)
- keyword.dart (피드백 키워드 모델)

---

## 📂 services/
- auth_service.dart (로그인 처리)
- firestore_service.dart (Firestore CRUD)
- log_service.dart (저장/로그 기록)
- sheet_service.dart (Google Sheets 연동)
- student_mock_service.dart (테스트용 목데이터)

### 📂 services/ai/
- ai_service.dart (Gemini 요약 요청/응답)

---

## 📂 screens/auth/
- login_screen.dart (로그인 분기)
- teacher_login.dart (강사 로그인)
- admin_login.dart (관리자 로그인)

---

## 📂 screens/home/
- student_home_screen.dart (학생 홈)
- teacher_home_screen.dart (강사 홈)
- admin_home_screen.dart (관리자 홈)
- staff_home_screen.dart (공용 홈)

---

## 📂 screens/lesson/
- today_lesson_screen.dart (오늘 수업 입력)
- lesson_history_screen.dart (지난 수업 복습)
- lesson_summary_screen.dart (AI 요약 조건 선택)

---

## 📂 screens/summary/
- summary_result_screen.dart (요약 결과 4종 표시)

---

## 📂 screens/manage/
- manage_students_screen.dart (학생 관리)
- manage_teachers_screen.dart (강사 관리)
- manage_keywords_screen.dart (키워드 관리)
- manage_curriculum_screen.dart (커리큘럼 관리)

---

## 📂 screens/settings/
- logs_screen.dart (로그 열람)
- change_password_screen.dart (비밀번호 변경)
- export_screen.dart (백업)
- import_screen.dart (복원)

---

## 📂 screens/curriculum/
- curriculum_overview_screen.dart (학생용 커리큘럼 보기)
- curriculum_tree_view.dart (트리 UI - 예정)

---

## 📂 ui/components/
- keyword_chip.dart (태그 선택 칩)
- file_clip.dart (첨부파일 표시)
- save_status_indicator.dart (저장 상태 아이콘)
- empty_stat.dart (빈 상태 UI)
- error_view.dart (에러 UI)
- rounded_button.dart (버튼)
- section_title.dart (섹션 타이틀)
- info_message_box.dart (메시지 박스)
- toggle_section_box.dart (접기/펼치기 UI)

---

## 📂 ui/layout/
- base_scaffold.dart (기본 레이아웃)
- centered_column.dart (중앙 정렬)
- responsive_padding.dart (반응형 여백)

---

## 📂 ui/theme/
- app_colors.dart (색상 정의)
- app_text_styles.dart (텍스트 스타일)
- app_theme.dart (앱 테마)

---
