
# 🌿 JH_GuitarTree 브랜치 전략 지침서

이 문서는 GPT가 새 채팅에서 프로젝트를 이어받을 때,  
사용자가 첨부한 `.md` 파일을 통해 자동으로 브랜치 전략 및 작업 기점을 파악할 수 있도록 만든 지침 파일입니다.

---

## 📦 브랜치 전략 구조

| 브랜치명 | 역할 |
|----------|------|
| main | 최종 릴리스 버전 (테스트 통과된 코드만 유지) |
| develop | 기능 브랜치 통합 및 테스트용 브랜치 |
| feature/vX.X-기능명 | 기능 단위 개발 브랜치 (설계서 단계 기반) |

---

## 🧭 설계서 기반 브랜치 기준표

| 브랜치명 | 포함 기능 | 설계서 단계 |
|----------|-----------|-------------|
| feature/v1.0-login | 로그인/권한 구조 | 1~2단계 |
| feature/v1.1-routing | 홈 화면 분기 + 라우팅 | 3단계 |
| feature/v2.0-autosave | 자동 저장 구조 | 6단계 |
| feature/v2.1-staff-home | 강사/관리자 홈 + 학생 관리 | 10단계 보완사항 |
| feature/v2.2-backup | 백업/복원 기능 | 9단계 |
| feature/v2.3-logging | 로그 기록 시스템 | 10단계 |
| feature/v3.0-curriculum-tree | 커리큘럼 열람 트리 구조 | 14단계 |
| feature/v3.1-curriculum-edit | 커리큘럼 생성/배정 + 파일업로드 | 16단계 |
| feature/v3.2-ai-summary | AI 요약 요청 구조 | 7단계 |
| feature/v3.3-sheets-upload | Google Sheets 연동 | 8단계 |

---

## ✅ 지침 사용 예시

- 새 채팅에서 이 `.md` 파일을 첨부하면,  
  GPT는 현재 개발 범위와 브랜치 기점을 자동으로 판단하여 안내합니다.

- 예시:
  ```
  📌 현재 브랜치 추천: feature/v2.1-staff-home
  🛠 이유: StaffHomeScreen, 학생 메모/편집 기능 개발 기점
  ```

---

## 📘 참고
- 이 지침은 `JH_GuitarTree 설계서.md` 및 `설계서 보완사항 정리.md`를 기준으로 작성되었습니다.
- 브랜치는 기능 단위로 세분화되어야 하며, 항상 develop → main 병합 흐름을 따릅니다.
