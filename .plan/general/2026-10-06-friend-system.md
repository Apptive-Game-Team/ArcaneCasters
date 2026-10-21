# 2026-10-06 — 친구 기능 구현 (친구 추가, 친구랑 플레이, 친구 리스트, 친구 관리)

- Date: 2026-10-06
- GitHub Issue: None
- Status: Draft

## Goal

- 플레이어가 다른 사용자를 친구로 추가하고 관리할 수 있는 친구 시스템을 구축합니다.
- 친구 목록에서 친구의 접속 상태(온라인, 매칭 중, 게임 중, 오프라인)를 실시간으로 확인합니다.
- 친구에게 친선전 초대를 보내고, 수락 시 즉시 1v1 게임 세션을 생성하여 함께 플레이할 수 있도록 합니다.
- 보낸 친구 요청, 받은 친구 요청의 수락/거절/취소 및 기존 친구 삭제 기능을 제공합니다.

## Non-goals

- 다인 파티 매칭(3인 이상) 및 팀전 모드 (현재 게임 엔진 및 세션 모델은 1v1 대전 기반).
- 친구 간 인게임 텍스트 채팅 / 다이렉트 메시지 기능 (본 작업에서는 친구 상태 확인 및 대전 초대에 집중).
- 소셜 플랫폼(Steam, Google Play Games 등) 외부 연동.

## Context / Constraints

- **데이터베이스 분리 구조**:
  - `account` 서버는 독립된 데이터베이스를 사용하며 회원 인증(JWT) 및 계정 정보(`member`)를 담당합니다.
  - `lobby` 및 `game` 서버는 공용 게임 데이터베이스(`database/migration`)를 공유합니다.
  - 친구 관계(`friendships`) 및 친구 요청(`friend_requests`)은 게임 서비스와 세션 제어를 담당하는 `lobby`와 공용 데이터베이스에서 관리하는 것이 아키텍처 원칙에 부합합니다.
- **Lobby 서버 기술 스택**:
  - Kotlin + Coroutines + Spring WebFlux + Spring Data R2DBC.
  - 새로운 코드는 반드시 Kotlin과 `suspend` 함수로 작성하며 Reactor 체인(`flatMap`, `zip`)을 새로 조립하지 않습니다 (`lobby/AGENTS.md`).
- **세션 생성 및 클라이언트 진입 흐름**:
  - 두 플레이어의 친선전 대전은 `LegacyGameMatchService.createSession(SessionDto.PVP(sessionId, userA, userB))`를 통해 게임 서버에 직접 세션을 생성합니다.
  - 생성된 세션 정보(`MatchedInfoDto`)를 양측 플레이어에게 전달하면 클라이언트는 기존 `GameScene` 전환 파이프라인을 그대로 재사용할 수 있습니다.
- **Unity 클라이언트 작업 제약**:
  - 현재 로컬 환경에서는 Unity 에디터 실행이 불가능하므로 C# 스크립트 작성 및 씬/프리팹 구성 시 기존 네이밍과 에셋 구조를 엄격히 준수해야 합니다.
  - 사용자 작업 영역(`client/Assets/Scripts/DeckScene/...` 등)에 존재하는 미커밋 변경 사항을 반드시 보존합니다.

## Approach (Checklist)

- [ ] **Step 0: Recon (기존 구조 조사 및 분석)**
  - [x] 계정 및 사용자 데이터 모델 검토 (`users`, `member`)
  - [x] 로비 매칭 및 세션 생성 플로우 검토 (`LegacyGameMatchService`, `MatchTicketRepository`)
  - [x] 클라이언트 로비 UI 및 이벤트 스트림 구조 검토 (`MatchmakingCoordinator`, `MatchEventStream`)
- [ ] **Step 1: Database Migration (`database`)**
  - [ ] `database/migration/V033_20261006__add_friend_system.sql` 작성
    - `friendships` 테이블: `user_id`, `friend_id`, `created_at`, 복합 기본키
    - `friend_requests` 테이블: `id`, `sender_id`, `receiver_id`, `status` (PENDING, ACCEPTED, REJECTED, CANCELED), 타임스탬프
    - 조회 성능을 위한 인덱스 생성
- [ ] **Step 2: Account Server Enhancements (`account`)**
  - [ ] 닉네임 검색 API (`GET /api/members/search?name={name}`) 추가하여 친구 검색 지원
- [ ] **Step 3: Lobby Server Implementation (`lobby`)**
  - [ ] `com.wordonline.matching.friend` 패키지 구성 (Kotlin)
  - [ ] Domain / Entity / DTO:
    - `Friendship`, `FriendRequest`, `FriendRequestStatus`
    - `FriendSummaryResponse`: friendId, name, mmr, status (Online, OnMatching, OnPlaying, Offline)
    - `FriendInviteDto`, `FriendInviteStatus`
  - [ ] Repositories:
    - `FriendRepository`, `FriendRequestRepository`
  - [ ] Services:
    - `FriendService`: 친구 목록 조회, 친구 삭제, 요청 보내기, 수락, 거절, 취소
    - `FriendPresenceService`: 친구별 실시간 상태(`UserService.getStatus` 연동) 조합
    - `FriendMatchService`: 친선전 초대 생성, 수락, 거절, 타임아웃 관리 및 `SessionDto.PVP` 세션 즉시 생성
  - [ ] Controllers:
    - `FriendController` (`/api/friends/**`)
      - `GET /api/friends`: 친구 목록 조회 (접속 상태 포함)
      - `DELETE /api/friends/{friendId}`: 친구 삭제
      - `GET /api/friends/search?query={query}`: 닉네임(부분 일치) 또는 이메일(정확한 일치)로 사용자 검색 (사용자 ID 직접 노출 방지)
      - `GET /api/friends/requests/received`: 받은 친구 요청 목록
      - `GET /api/friends/requests/sent`: 보낸 친구 요청 목록
      - `POST /api/friends/requests`: 친구 요청 발송 (대상 회원 검색 결과 기준)
      - `POST /api/friends/requests/{requestId}/accept`: 친구 요청 수락
      - `POST /api/friends/requests/{requestId}/reject`: 친구 요청 거절
      - `DELETE /api/friends/requests/{requestId}`: 보낸 친구 요청 취소
      - `POST /api/friends/{friendId}/invite`: 친선전 대전 초대 발송 (30초 만료)
      - `POST /api/friends/invites/{inviteId}/accept`: 친선전 대전 초대 수락 -> 1v1 PVP 세션 즉시 생성
      - `POST /api/friends/invites/{inviteId}/reject`: 친선전 대전 초대 거절
      - `GET /api/friends/events`: Server-Sent Events(SSE) 실시간 이벤트 스트림 (초대 수신, 친구 요청 도착/수락, 상태 변화 push)
- [ ] **Step 4: Client Implementation (`client`)**
  - [ ] 데이터 계약 DTO 추가 (`Assets/Scripts/Contracts/Data/FriendDto.cs`)
  - [ ] `FriendApiClient.cs`: 로비 친구 REST API 통신 코루틴
  - [ ] `FriendManager.cs` / `FriendViewModel.cs`: 로비 내 친구 상태, 초대 수신 폴링/수신 이벤트 관리
  - [ ] `FriendModalUIController.cs`:
    - 친구 팝업 모달 UI (친구 목록 탭, 요청 관리 탭, 친구 추가 탭)
    - 각 항목별 버튼 액션 (초대, 삭제, 수락, 거절, 요청 전송)
  - [ ] `FriendMatchInviteDialog.cs`:
    - 다른 플레이어로부터 친선전 초대가 도착했을 때 표시되는 모달 다이얼로그 (수락 / 거절 / 카운트다운)
    - 수락 시 매치 정보 수신 후 `GameScene`으로 씬 전환

## Validation

- **Commands to run:**
  - `(cd database && ./gradlew test)` 또는 Flyway 검증
  - `(cd account && ./gradlew test)`
  - `(cd lobby && ./gradlew compileKotlin test)`
- **Expected output:**
  - 로비 및 어카운트 서버의 모든 단위/통합 테스트 통과 (`BUILD SUCCESSFUL`).
  - 마이그레이션 문법 및 제약 조건 충돌 없음.

## Risks & Rollback

- **Risks:**
  - 동시 초대 또는 중복 친구 요청 레이스 컨디션: 데이터베이스 유니크 제약 조건 및 낙관적 락/상태 검사로 방어.
  - 친선전 세션 생성 시 한쪽 사용자가 오프라인이거나 응답하지 않는 경우: 30초 초대 타임아웃 및 세션 할당 전 상태 확인.
- **Rollback steps:**
  - 신규 마이그레이션 롤백 및 신규 엔드포인트/컨트롤러 비활성화.
  - 클라이언트 로비 내 친구 UI 진입 버튼 숨김 처리.

## Open Questions

- 친구 추가 시 검색 방식: 닉네임 검색과 플레이어 고유 번호(User ID / Tag) 중 어떤 방식을 우선할지 결정 필요.
- 친선전 초대 실시간 알림 방식: 별도 SSE 스트림 연결 vs 3초 주기 가벼운 폴링 중 선호 방식.
