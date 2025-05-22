파일명 : JH_Guitartree

🎸 풀버전 최종 설계서 – 1부
(작성일: 2025-05-16 기준)

해당문서의 16단계가 가장 마지막 요청사항이 반영되었다. 작업 과정중 1

1. 프로젝트 개요 및 철학
이 앱은 실제 기타 수업 현장에서 강사의 업무를 자동화하고, 학생의 복습 효율과 교육 경험을 높이기 위해 설계되었다.
🎯 철학
* 수업 중 입력을 최소화하고, 흐름을 방해하지 않도록 한다.
* 데이터는 실시간으로 자동 저장되며, 저장 버튼은 최소화한다.
* 플랫폼(macOS, Windows, iOS, Android, Web) 전체에서 일관되게 작동해야 한다.
* 강사와 학생, 보호자 모두에게 유용하고 감성적인 경험을 제공한다.

2. 사용자 유형 및 권한 구조
👤 학생
* 로그인: 이름 + 전화번호 뒷자리 4자리
* 기능: 오늘 수업 보기 / 지난 수업 복습
* 제한: AI 요약, 키워드 편집, 커리큘럼 배정 기능 없음
👨‍🏫 강사
* 로그인: 이름 선택 + 비밀번호 입력
* 기능: 수업 작성, 복습, AI 요약 요청, 커리큘럼 배정
* 설정 가능 항목: 내 학생 관리, 키워드 보기(선택적 편집), 비밀번호 변경, 백업
👑 관리자
* 로그인: Firebase Email + Password
* 기능: 전체 학생/강사/수업/요약/커리큘럼 관리, 백업 복원, 로그 열람
* 설정 가능 항목: 키워드 편집, 커리큘럼 설계 및 배포

3. 홈 화면 구성 흐름
🏠 학생 홈 화면
* 버튼 1: 📝 오늘 수업 보기
* 버튼 2: 📚 지난 수업 복습
🏠 강사 홈 화면
* 버튼 1: 오늘 수업
* 버튼 2: 지난 수업 복습
* 버튼 3: 수업 요약
* 설정 메뉴: 내 학생 관리, 키워드 열람/편집, 비밀번호 변경, 백업
🏠 관리자 홈 화면
* 위와 동일 + 버튼 4: ⚙️ 전체 관리자 기능
* 설정 메뉴: 모든 기능 접근 가능
공통 흐름
* 로그인 이후 홈으로 자동 진입
* 설정 아이콘(⚙️)은 상단 앱바 또는 우측 구석에 위치
* 향후 커리큘럼 버튼 추가 예정 (학생/강사/관리자 전용)

4. Firestore 기반 데이터 구조
📁 컬렉션 구성
students
json
복사편집
{
  "name": "김개똥",
  "gender": "남",
  "isAdult": false,
  "schoolName": "진안초",
  "grade": 4,
  "startDate": "2024-01-01",
  "instrument": "일렉기타",
  "teacherId": "teacher_123" // nullable
}
teachers
json
복사편집
{
  "name": "이재형",
  "passwordHash": "...", // SHA-256
  "email": "teacher@example.com",
  "createdAt": "...",
  "lastLogin": "...",
  "sheetId": "abc123"
}
lessons
json
복사편집
{
  "studentId": "s001",
  "teacherId": "t001",
  "date": "2025-05-16",
  "subject": "Let it be 연습",
  "keywords": ["코드 전환", "박자 맞추기"],
  "memo": "...",
  "nextPlan": "...",
  "audioPaths": ["김개똥/강남스타일.mp3"],
  "youtubeUrl": "https://youtu.be/...",
  "createdAt": "...",
  "updatedAt": "..."
}
summaries
json
복사편집
{
  "studentId": "s001",
  "teacherId": "t001",
  "type": "기간별",
  "periodStart": "...",
  "periodEnd": "...",
  "keywords": ["Let it be", "리듬"],
  "selectedLessons": ["lesson_1", "lesson_2"],
  "studentInfo": {
    "name": "...", "gender": "...", "grade": ..., ...
  },
  "resultStudent": "...",
  "resultParent": "...",
  "resultBlog": "...",
  "resultTeacher": "...",
  "visibleTo": ["teacher", "admin"]
}
feedback_keywords
json
복사편집
{
  "category": "박자연습",
  "items": [
    { "text": "박자 맞추기", "value": "박자" },
    ...
  ],
  "managedBy": "admin"
}
logs (자동 기록)
* lesson_saves, logins, errors, ai_requests 등으로 분기됨

🎸 풀버전 최종 설계서 – 2부
(작성일: 2025-05-16 기준)

5. 주요 기능 흐름 (수업 입력, 복습, 요약)

📝 오늘 수업 보기 (/today_lesson)
기능 개요:
* 수업 데이터를 날짜 기준으로 자동 생성/불러오기
* 실시간 저장 + 피드백 키워드 선택 + 메모 + 다음 계획 + 첨부파일 + 유튜브 링크
구성 요소:
1. 날짜 자동 설정
    * 오늘 날짜 기준 자동 입력
2. 주제 입력
    * 텍스트 입력 필드
    * Enter 키 입력 시 키워드 선택 영역으로 포커스 이동
3. 키워드 태그 선택
    * 펼침 버튼 → 카테고리별 태그 목록
    * 태그는 Chip 형태로 표시되고, 중복 선택 가능
    * 검색 기능 포함
4. 메모 입력
    * “✏️ 수업 메모 입력” 버튼 → 멀티라인 필드 슬라이드 등장
    * 텍스트는 자동 저장됨
5. 다음 계획 입력
    * 일반 TextField
    * 최근 계획 불러오기 기능 추가 가능
6. 유튜브 링크
    * 입력 후 Enter → 자동 실행
    * 또는 ‘접속’ 버튼 클릭 → 기본 브라우저 실행
7. 파일 첨부 (macOS/Windows 전용)
    * 음원, PDF, 영상 등 복수 첨부 가능
    * 첨부 후 하단에 클립 형태로 표시
    * ❌ 버튼으로 제거 가능
    * 클릭 시 기본 앱으로 실행
시각적 UX 원칙:
* 메모, 링크, 첨부는 기본 접힘
* 버튼 클릭 시 부드럽게 펼쳐짐 (AnimatedContainer 등 활용)
* ✅ 저장됨 (10:45AM) 표시 영역 항상 하단 고정

📚 지난 수업 복습 (/lesson_history)
기능 개요:
* 날짜순 수업 리스트 표시
* 각 항목 클릭 시 펼쳐짐
* 삭제, 파일 실행 기능 포함
세부 기능:
* 리스트 항목: 날짜, 주제, 키워드, 메모 요약
* 펼침 후 표시:
    * 전체 메모
    * 다음 계획
    * 유튜브 링크 (열기)
    * 첨부 파일 (클립 + 실행/삭제 버튼)
플랫폼 분기 처리:
OS    첨부 실행 여부
macOS/Windows    ✅ 기본앱 실행
iOS/Android/Web    ❌ 경고창 "데스크탑에서만 실행 가능합니다"

📈 수업 요약 (/lesson_summary)
흐름 구조:
1. 조건 선택 (기간 or 키워드 기반)
2. 해당 조건에 맞는 수업 리스트 표시
3. 체크박스로 선택
4. "요약 요청 및 저장" 클릭
UI 흐름:
* 2단계 구조
    * Step 1: 기간/키워드 조건 선택
    * Step 2: 수업 리스트 + 체크박스 → "다음" → 요약 요청
* 리스트는 1줄 요약으로 표시
* 수업 개수가 많을 경우 무한 스크롤 or 페이지네이션 적용

6. 자동 저장 및 실시간 동기화 구조

🎯 목적
* 수업 중 “저장”이라는 개념이 사라질 정도로 자동화
* 데이터 유실, 충돌, 누락 방지를 위한 이중 저장 구조 (Hive + Firestore)

🔁 저장 트리거 조건
항목    이벤트    트리거 방식
Text 입력    onChanged / addListener    debounce 후 저장
태그 선택    onTap    즉시 저장
파일 첨부/삭제    List 변경    저장
유튜브 링크    onSubmitted or 버튼 클릭    저장

🗃 저장 구조
1. 로컬 저장 (Hive)
* 모든 Lesson, Student, Summary 데이터를 Hive에 저장
* 저장 경로: studentId + 날짜로 key 설정
* 앱 재실행 시 Hive 캐시 우선 로드
2. 클라우드 저장 (Firestore)
* Hive 저장 이후 Firestore에 set() or update()
* 충돌 시 최근 타임스탬프 기준 우선 적용
* 실시간 반영: StreamBuilder or onSnapshot 활용

📘 상태 UI
* ✅ 저장됨 (10:45AM) (성공)
* ⏳ 저장 중... (진행 중)
* ⚠️ 저장 실패 (실패 후 재시도 중)
실패 시 동작
* 자동 재시도 (최대 3회)
* Hive에는 항상 저장됨
* 네트워크 연결 복구 시 Firestore로 재업로드

7. AI 요약 요청 구조 및 프롬프트 설계

🎯 목표
* 선택된 수업 데이터를 기반으로 Gemini에 프롬프트 요청
* 4종 요약 결과를 받아 Firestore + Sheets에 저장
* 프롬프트는 템플릿화되어, 자동 생성됨

📥 프롬프트 구성 항목
* 학생 정보 (이름, 성별, 학년/성인, 수강 시작일)
* 수업 정보 (날짜, 주제, 키워드, 메모, 다음 계획)
* 요약 조건 (기간 or 키워드 기반)
* 요청 항목:
    1. 학생용 요약 (이모지 포함)
    2. 보호자용 메시지
    3. 블로그용 텍스트
    4. 강사용 리포트

📤 응답 및 저장 처리
1. 응답 수신 → summaries 문서 저장
2. 시트 전송: 각 요약 결과를 G~J열에 각각 분리 저장
3. /summary_result 화면으로 이동 → 결과 4종 표시
4. 강사/관리자만 접근 가능 (visibleTo 필드 기준)

📌 기술 요약
항목    처리 방식
Gemini 호출    POST 요청 (프롬프트 자동 생성)
요약 ID    자동 UUID
Firestore 저장    summaryId, studentId, selectedLessons, resultStudent, ...
시트 전송    appendRow([A~J열]), 중복방지, 실패 시 재시도

🎸 풀버전 최종 설계서 – 3부
(작성일: 2025-05-16 기준)

8. Google 스프레드시트 연동 구조

🎯 목표
* AI 요약 결과 4종을 자동으로 Google Sheets에 저장
* Sheets는 강사별로 생성되며, 요약 요청 완료 시 자동으로 한 줄 추가됨
* 추후 시트 공유, 보호자용 복사, 블로그 활용이 가능하도록 구성

🔐 인증 방식
* Google OAuth 2.0 기반 1회 로그인
* 인증 후 Access Token은 안전한 로컬에 저장됨
* 시트 ID는 teachers 문서에 저장:
json
복사편집
"sheetId": "1AbCDefG..."

📋 시트 열 구조
열    내용
A    생성일
B    이름
C    학년 or 성인 여부
D    수강 기간
E    담당 강사
F    요약 조건 (기간 / 키워드)
G    학생용 요약
H    보호자용 메시지
I    블로그용 텍스트
J    강사용 분석 리포트
📌 모든 요약 결과는 G~J 열에 각각 따로 분리 입력

🧭 전송 흐름
1. 요약 요청 완료 → Gemini 응답 수신
2. 시트 ID 조회 → values.append() API 호출
3. 한 줄 단위로 데이터 삽입
4. 성공 시 Firestore에도 전송 상태 저장

🔗 학생 정보 연동 구조
앱 → Sheets 방향:
학생 등록, 수정, 삭제는 앱 내 강사/관리자 포털 화면에서 수행되며,
모든 변동 사항은 Google Sheets의 학생목록 시트에 자동 반영된다.
Sheets → 앱 방향:
Google Sheets에서 학생 정보를 직접 수정하거나 삭제하더라도 앱에는 자동 반영되지 않으며,
이 경우 앱 내 동기화 버튼을 수동 클릭해야 반영된다.
(예: 강사가 스프레드시트에서 메모 또는 이름을 바꾼 경우 → 앱에서 동기화 후 반영)
연동 방식은 추후 Admin 설정화면에서 변경 가능하도록 설계될 수 있음.

❗ 예외 처리
* 중복 전송 방지: 요약 ID 중복 검사 or alreadySaved: true로 처리
* 전송 실패 시: "⚠️ 저장 실패. 다시 시도해주세요" 안내
* pendingUpload: true 상태로 Firestore 기록 → 앱 재실행 시 자동 전송 재시도

💡 추가 기능 계획
* 📤 CSV / Excel 다운로드 버튼
* 📑 블로그용 서식 복사 버튼
* 📥 관리자 전용 ‘전체 요약 모아보기 시트’

9. 데이터 백업 및 복원 구조

🎯 목표
* 수업 데이터, 학생 정보, 요약 결과 등 핵심 데이터 전체를 JSON 파일로 백업 및 복원 가능하게 함
* 앱 재설치, 기기 변경, 실수로 인한 데이터 손실 방지

📤 백업 기능
백업 대상
* Student, Teacher, Lesson, Summary, Keyword
* JSON 구조로 묶어서 하나의 파일로 생성됨
사용 흐름
* 강사: 내 학생 데이터 백업 (본인 담당 학생만)
* 관리자: 전체 데이터 백업
* 저장 위치: 다운로드 폴더 (macOS/Windows)
파일 예시
pgsql
복사편집
backup_2025-05-16_김개똥.json
json
복사편집
{
  "student": {...},
  "lessons": [ {...} ],
  "summaries": [ {...} ],
  "keywords": { ... }
}

📥 복원 기능
* 관리자 전용 기능
* JSON 선택 → 검증 → Firestore에 업로드
* 중복 항목은 덮어쓰기 or 무시 설정 가능

❗ 예외 처리
* JSON 구조 이상: "⚠️ 백업 파일이 손상되었습니다"
* 중복 ID 발견: "⚠️ 기존 데이터와 충돌한 항목 4개가 무시되었습니다"

📌 플랫폼별 지원
플랫폼    백업    복원
macOS/Windows    ✅    ✅
Android/iOS/Web    ❌ (파일 접근 제약)    ❌

10. 로그 기록 및 시스템 추적

🎯 목표
* 저장, 삭제, 요약, 로그인 등 중요한 이벤트를 자동으로 기록하여 문제 발생 시 추적하고, 사용자 활동 흐름을 파악할 수 있도록 함

🔍 로그 유형
로그 타입    기록 항목
저장 로그    lessonId, userId, status, 시간, Firestore/Hive 구분
삭제 로그    itemType, id, 삭제자, 시간
요약 로그    summaryId, 조건, 선택 수업 수, 성공 여부
로그인 로그    userId, 역할, 기기정보, OS, 시간
오류 로그    오류 유형, 발생 함수, 시간, 재시도 여부

🧾 Firestore 구조
컬렉션 예시:
bash
복사편집
/logs/lesson_saves/{auto_id}
/logs/errors/{auto_id}
/logs/logins/{auto_id}
/logs/ai_requests/{auto_id}
각 문서는 자동 생성 ID로 저장됨

📘 로그 접근
사용자    접근 여부
학생    ❌
강사    ✅ (본인 로그만)
관리자    ✅ 전체 로그 접근 가능
→ 설정 메뉴 or 관리자 기능 화면 내 "📜 로그 보기" 버튼 제공

🧹 유지 기간 및 삭제
* 기본 유지: 90일
* 자동 삭제 설정 가능
* 관리자 수동 내보내기 기능 제공 (예: log_export_2025_05.json)

🎸 풀버전 최종 설계서 – 4부
(작성일: 2025-05-16 기준)

11. 폴더 구조 및 코드 파일 경로

🎯 설계 목적
* 기능별, 역할별, 구조별로 정확하게 분리된 폴더 구조 유지
* 코드 복붙 시 오류/중복/경로 충돌을 방지
* 향후 확장 모듈(커리큘럼 등)이 들어와도 완전히 독립되도록 구성

📂 루트 구조
별도 첨부파일 있음.

12. 플랫폼 호환성 및 빌드 전략

🎯 목표
* 5대 플랫폼(macOS, Windows, iOS, Android, Web)에서의 기능 차이를 고려하여 UI/기능/경고 메시지 등을 미리 분기 처리함

🧭 기능별 플랫폼 지원 매트릭스
기능    macOS    Windows    iOS    Android    Web
수업 저장    ✅    ✅    ✅    ✅    ✅
첨부 파일 실행    ✅    ✅    ⚠️ 제한적    ⚠️ 제한적    ❌
유튜브 링크    ✅    ✅    ✅    ✅    ✅
백업/복원    ✅    ✅    ❌    ❌    ❌
Sheets 전송    ✅    ✅    ✅    ✅    ✅
Hive 저장    ✅    ✅    ✅    ✅    ❌ (대체 필요)

💡 처리 방식
* Platform.isMacOS, Platform.isWindows, kIsWeb 등 조건으로 분기
* Web에서는 파일 실행, 백업 기능은 UI 비활성화 및 안내 메시지 표시
* iOS/Android는 파일첨부는 가능하되 실행은 안내 처리

🔨 빌드 & 배포 체크리스트
플랫폼    빌드 명령    주의사항
macOS    flutter build macos    Pod 설치, 권한 설정 필요
Windows    flutter build windows    .exe 추출, assets 포함
Web    flutter build web    Firebase Hosting or GitHub Pages
iOS/Android    각각 flutter build ios / flutter build apk    GoogleService-Info.plist, json 포함

13. 코드 작성 규칙 및 버전 관리

📐 스타일 가이드
요소    규칙
클래스명    PascalCase
변수명    camelCase
파일명    snake_case
주석    한국어, // 저장 상태 메시지 표시
함수    동사형 (loadLesson(), saveToSheets())

🧾 버전 기록 예시
dart
복사편집
// v1.0.3 | 작성일: 2025-05-16 | 작성자: GPT
* CHANGELOG.md 별도 관리
* pubspec.lock 반드시 git에 포함
* pubspec.yaml 의존성은 버전 고정 (^ 없이 명시)

🔁 개발 협업 규칙
* GPT가 모든 Dart 파일을 정확히 분리하여 순서대로 제공
* 너는 복붙만 하면 실행되게 설계
* 오류가 발생하면 파일 전체를 다시 제공받아 반영
* 수정은 절대 직접 하지 않고 GPT를 통해 반영


🎸 풀버전 최종 설계서 – 5부
(작성일: 2025-05-16 기준)

14. 향후 확장 예정: 커리큘럼 기능 설계 초안

🎯 목적
* 관리자가 설계한 전체 커리큘럼을 강사와 학생에게 배분하고, 각 학생은 자신이 배운 항목만 열람할 수 있도록 함
* 항목은 트리 구조(마인드맵 구조)로 시각화되며, 파일(mp3, pdf 등) 실행을 통해 연습/복습이 가능함

🧩 구조
관리자
* 커리큘럼 생성: 카테고리 > 하위 항목 > 파일 첨부
* 강사에게 커리큘럼 배정
강사
* 배정된 커리큘럼 구조 열람 가능
* 각 학생에게 항목별로 커리큘럼 배정
    * 예: 김개똥 학생 → 통기타 > 코드 > G key.pdf
학생
* 본인에게 배정된 커리큘럼만 트리 형태로 열람 가능
* 항목 클릭 시 기본앱으로 파일 실행

📁 Firestore 컬렉션 구조
/curriculums
json
복사편집
{
  "curriculumId": "basic_guitar",
  "title": "통기타 기본",
  "structure": [
    {
      "category": "코드",
      "children": [
        {
          "title": "기본코드",
          "children": [
            {
              "title": "G key",
              "filePath": "통기타/기본코드/Gkey.pdf"
            }
          ]
        }
      ]
    }
  ],
  "createdBy": "admin",
  "assignedTo": ["teacher_1"]
}
/curriculum_assignments
json
복사편집
{
  "studentId": "s001",
  "items": [
    {
      "curriculumId": "basic_guitar",
      "path": ["코드", "기본코드", "G key"],
      "filePath": "통기타/기본코드/Gkey.pdf"
    }
  ],
  "assignedBy": "teacher_1"
}

🌳 UI 구조
* /curriculum_overview_screen.dart
* 마인드맵 구조 또는 TreeView 구조 (ExpansionTile, flutter_treeview, 등)
* 각 항목은 잠금/활성 상태로 구분 (학생 기준)
* 파일 클릭 → macOS/Windows에서 기본앱 실행

🛡 안정성 확보 원칙
* lesson/summary 구조와 완전 분리
* 독립 모델, 독립 서비스, 독립 화면
* 설계 단계부터 screens/curriculum/ 경로로 분리 적용

15. 주요 메모 및 보완 반영 사항

🎯 입력 최소화 + UX 최적화
* 접기/펼치기 구조는 정보가 많을 때만 적용
* 메모/링크/첨부 등은 기본 숨김, 버튼 누르면 슬라이드 업
* 키보드 단축키(Enter, ESC 등)는 입력 완료/닫기 등 UX에 반영

🎯 실시간 동기화
* 모든 데이터는 Hive(로컬) + Firestore(클라우드)에 자동 저장
* 플랫폼 간 이동 시 데이터 유실 없음
* 앱을 껐다 켜도 이전 입력 상태 유지

🎯 검색 정교화
* normalize 처리 + 유사도 검색 + 자동완성
* 키워드뿐 아니라 수업 내용, 주제, 첨부파일까지 검색 가능
* 검색 필드는 최대한 UX를 방해하지 않게 드롭형 + 클립형 UI로 구성

🎯 기능이 불가능한 플랫폼에 대한 UI 안내
* Web/iOS/Android에서 파일 실행, 백업 등 제한 기능은 숨김 또는 "⚠️ 데스크탑에서만 사용 가능합니다" 안내

🎯 실수 방지
* 모든 경로는 상대경로로 저장 (학생명/파일명.mp3)
* 파일 실행은 OS별 Google Drive 루트 매핑 기반
* 첨부된 파일이 실행되지 않을 경우 로그 기록 + 안내 제공

✅ 개발 소통 방식 (너와 GPT 간 규칙)
* Dart 파일은 1:1로 정확히 제공되고, 절대 중복 없이 정렬됨
* 실수나 누락이 생기지 않도록 설계서를 기준으로만 작업됨
* 너는 코드를 수정하지 않고, 오직 요청만으로 변경 가능
* 커리큘럼 등 확장 기능은 앱 완성 이후 모듈화 구조로 통합
* 수정이 불가피한 경우 gpt가 직접 안내

📦 설계서의 목적
이 설계서는 ✔️ 앱을 직접 만들 수 없는 사용자도 ✔️ GPT에게 요청만으로 모든 기능을 완성시키고 ✔️ 오류 없이 확장 가능한 구조로 유지보수 가능한 완성도 높은 실전 앱의 기준 문서다.

16단계. 커리큘럼 기능 전체 설계

🎯 목적
* 강의 자료(음원, 영상, PDF 등)를 카테고리 구조로 관리하고, 강사/학생에게 역할에 따라 배정
* 직관적인 마인드맵 형태의 트리 구조로 시각화하고, 파일 실행/배정/열람 기능을 통합 운영
* 전체 자료를 Firebase Storage 기반으로 관리하여, 모든 OS(macOS/Windows)에서 공유 가능

✅ 전체 흐름 요약
역할    기능 요약
관리자    카테고리/파일 생성, 파일 업로드, 커리큘럼 트리 구성(드래그), 강사/학생 배정, 고립 파일 관리
강사    배정된 커리큘럼 트리 열람, 본인 학생에게 항목 배정
학생    배정된 항목만 열람 가능, 트리 UI 사용, 실행 전용
🧩 Firestore + Firebase Storage 구조
📁 컬렉션: curriculum_nodes
{
  "id": "uuid",
  "parentId": "null 또는 상위 노드 uuid",
  "type": "category" | "file",
  "title": "기타 코드 G key",
  "filePath": "...", // type == file인 경우만
  "fileUrl": "https://storage.googleapis.com/...",
  "assignedTeachers": ["t001", "t002"],
  "assignedStudents": ["s001"],
  "createdAt": "..."
}
* 트리 구조는 parentId를 통해 재귀적으로 연결됨
* 파일은 Firebase Storage에 업로드 후 fileUrl로 연결됨
* 중복 등록 허용: 하나의 fileId를 여러 category에 포함 가능
📁 Storage 경로 예시:
curriculum_files/
├── G_key.pdf
├── power_chords_A.mp3

📘 관리자 기능
1. 커리큘럼 관리 화면 (/manage_curriculum_screen)
* 트리 구조 UI: 마인드맵 or TreeView (flutter_treeview, custom painter 등)
* 카테고리 생성: 루트/하위 카테고리 모두 가능 (무한 생성 가능)
* 각 노드 클릭 → 다이얼로그 열림:
    * 이름 수정, 삭제, 파일 첨부 (pdf, mp3, mp4 등)
    * 강사 배정 (중복 선택), 학생 배정 상태 확인
    * 클립형 UI로 첨부파일 표시 → ❌버튼으로 제거 가능
* 드래그로 항목 이동 → parentId 자동 갱신 → 실시간 UI 반영
* 고립 파일 보기 필터:
    * parentId == null && type == "file" 조건으로 표시
    * 배정되지 않은 파일들을 다른 카테고리로 이동 가능
* 배정 상태 시각화:
    * 강사/학생 Chip 색상 구분 (예: 강사 연두색, 학생 하늘색)
    * 최대 2~3개 표시 + [+N명] 확장 버튼 → 전체 리스트 팝업
2. 커리큘럼 배정 화면 (/assign_curriculum_screen)
* 좌측: 배정 가능한 트리 구조 (관리자 or 강사에게 배정된 구조)
* 우측: 학생 검색 + 선택 다이얼로그
* 항목 선택 → 해당 학생에게 일괄 배정
* 배정 현황은 트리에서 실시간 시각화
3. 파일 업로드 기능
* file_picker로 로컬에서 선택
* Storage로 자동 업로드 → downloadURL 생성 → Firestore에 저장됨
* PDF/MP3/MP4 등의 파일만 허용 (포맷 필터링)

🧑‍🏫 강사 기능
* /assign_curriculum_screen 화면 접근 가능
* 본인에게 배정된 커리큘럼 트리 내에서만 작업 가능
* 학생 검색 + 선택 → 항목 배정 가능
* UI/UX는 관리자와 동일 (기능 제한만 존재)

👨‍🎓 학생 기능
* 홈화면에 📚 나의 커리큘럼 버튼 추가
* /my_curriculum_screen 화면 진입
* 배정된 커리큘럼 트리만 표시
* 트리 UI는 동일 (접기/펼치기 지원)
* 첨부된 파일만 클릭 → 기본앱 실행 (open_file)
* 수정/삭제 버튼은 비활성화

🗂 오늘 수업 / 복습 화면과 연동
* 기존의 로컬 파일 첨부 버튼을 → 다음 2가지로 분리:
    * 📁 업로드: 로컬 파일 → Storage → 자동연결
    * 🔍 불러오기: 기존 Storage 파일 검색 + 선택 첨부
* 자동완성 포함 검색창 → 파일명 기반 추천
* 선택 시 수업 데이터에 해당 파일이 연동됨 (audioPaths에 downloadURL 저장)
* 기존 수업기록/복습 기능 그대로 유지 가능

💡 기술적 고려사항
* 모든 기능은 macOS/Windows에서 완전 지원
* Web/iOS/Android에서는 업로드/실행 기능 제한 → 안내 메시지 표시
* 모든 파일 실행은 open_file + downloadURL 기반 (로컬에 복사 후 실행)
* 드래그 UI는 관리자 전용으로 활성화 가능
* 모든 리스트는 실시간 StreamBuilder 기반 자동 동기화
* 검색 기능: 자동완성 + 리스트 필터 제공 (onChanged + Firestore 쿼리)

📌 16단계는 커리큘럼 기능 전체를 독립 모듈로서 설계하며, 기존 기능과 연결될 수 있는 모든 확장성과 안정성을 갖춘 설계로 완성되었다.
(설계서 종료)


--추가사항
