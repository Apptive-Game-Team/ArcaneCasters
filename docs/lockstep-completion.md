# Lockstep 구현 정책과 적용 절차

2026-10-29 기준으로 잔여 구현과 로컬 검증을 완료했다. 원본 simulation 915/915와 model 127/127은 현재 소스에 결속된 실행 증거로 strict 검사를 통과했다. .NET·Unity Editor·WebGL replay와 실제 두 Unity의 로비→전투→결과를 검증했다. 세부 범위와 증거는 [완료 계획](../.plan/general/2026-10-29-lockstep-completion.md)을 따른다. 운영 적용은 별도다.

## 상태 checkpoint

새 경기의 `SessionStart.stateHashVersion`은 `1`이다. `lockstep-v1`은 PVP·규칙 봇·PVE를, `lockstep-v2`는 모델 봇 프로토콜을 지원한다. simulationVersion, 초기 콘텐츠 해시, 참가자, tickRate와 확정 입력의 연속성을 검증한다. lockstep tickRate는 20이다.

`SimulationCheckpoint`는 tick 실행을 마친 규칙 상태를 정규화한 binary에 SHA256을 적용한다. RNG, ID 할당, 시계, 덱·경제, 객체와 component의 private field, 상태효과, 예약 작업과 논리 callback, 봇·PVE 상태를 포함한다. 규칙 field는 자동으로 발견하며, 명시적 제외 목록은 표시 출력·외부 통지·monitor에 한정한다. 게임 논리 callback의 대상 상태는 포함한다. 알 수 없는 외부 상태나 지원하지 않는 타입은 조용히 생략하지 않고 실패한다.

타입명은 generic 인자의 assembly 이름 차이를 제거하고, dictionary는 정규화한 key 순서로 기록한다. `Fix64`는 raw 정수로 기록한다. runtime 주소나 process hashcode를 출력값으로 사용하지 않는다. 내용이 없는 배열과 읽기 전용 collection wrapper의 플랫폼별 공유 방식은 값으로 정규화한다. Unity의 IL2CPP 보존 설정과 field inventory·mutation 검사가 이 계약을 보완한다.

서버는 해당 tick의 모든 인간 참가자가 같은 hash를 제출해야 다음 tick을 공개한다. 봇은 각 인간 replica에서 실행되며 별도 투표자가 아니다. 관전자는 hash를 제출하거나 입력·완료를 요청할 수 없다. 같은 tick/hash의 재전송은 멱등이며, 다른 hash는 영속 `desync` 중단으로 이어진다. hash 누락도 입력 timeout 정책에 포함된다.

`POST /api/lockstep/{id}/complete`는 모든 checkpoint가 합의된 서버 보관 이력을 verifier로 처음부터 재생한 뒤에만 결과를 저장한다. nonempty 이력이 있고 상대 checkpoint만 기다리는 경우는 `202`로 재시도한다. 이 단계에서는 verifier 실행·보상·outbox 기록이 없다. 0 frame 완료나 desync는 거부한다. 한 명 경기 역시 verifier 재생을 통과해야 한다. `stateHashVersion` 없는 예전 replay의 읽기 호환과 새 경기의 검증 계약은 구분한다.

## 물리 지속 상태

`PhysicsWorld.WriteCheckpoint`와 `BattlePhysicsSystem.WriteCheckpoint`는 다음 tick 계산에 영향을 주는 엔진 상태를 명시적 writer로 기록한다.

- body의 위치·회전·속도·질량·관성·중력·damping, shape와 material, adapter의 body 연결과 contact 상태.
- sleep 누적 상태와 simulation island 관계·순서, broadphase tree·bounds·volume·overlap 순서.
- narrowphase pair, persistent contact와 manifold, GJK simplex·분리축 cache.
- solver 설정·constraint 처리 순서·warm start의 누적 impulse, 다음 pool take에서 사용하는 지속 설정.

다음 tick의 `Update`가 읽기 전에 덮어쓰는 Jacobian·iteration scratch, collection capacity, profiling과 rendering interpolation은 제외한다. 미사용 pool의 allocation identity도 제외하며 실제 향후 처리 순서와 필요한 설정은 보존한다. pool node의 `maximumVolume`과 pair tester의 `localDirection`은 재사용 시 초기화해 앞선 경기의 흔적이 새 world에 영향을 주지 않게 했다.

엔진 private state는 같은 `ArcaneCasters.FixedPhysics` assembly의 partial accessor로 접근한다. 물리 runtime은 reflection이나 Simulation assembly 역참조에 의존하지 않는다. 신규 엔진 field는 manifest 검사로 검출하며, 지원하지 않는 shape·constraint·collision group은 실패한다. 세부 포함·제외 근거와 mutation 범위는 [물리 checkpoint 문서](../client/Tools/LockstepProbe/PHYSICS_CHECKPOINT.md)를 따른다.

**checkpoint는 중간 복원 파일이 아니다.** 재접속과 서버 교체는 최초 상태와 확정 입력·모델 이벤트를 처음부터 재생한다. 위치만 기록한 기존 10,000 tick 물리 관측 해시는 별도 회귀 검사이며 전체 checkpoint를 대신하지 않는다.

## 내구 저장과 서버 교체

V121은 서버 lease, 세션 초기 상태와 생성 응답, 미확정 상태와 revision, 확정 frame, 종료 outbox를 저장한다. V120의 완료 결과 저장이 선행되어 있어야 한다.

생성 readiness 응답과 확정 frame은 DB commit 이후 공개한다. 동일 생성 attempt의 재시도는 최초 배치의 session·`placement_instance_id`를 유지한다. 서버 교체 후에도 이 값으로 종료 통지를 보내므로 현재 프로세스의 instance ID로 바뀌지 않는다.

서버 소유 key는 configured server URL이며, 프로세스마다 새 lease token을 갖는다. 초기 복구에서만 acquire하고 실행 중에는 live token의 renew만 허용한다. 이미 만료된 token은 같은 worker가 되살릴 수 없다. 모든 쓰기 transaction은 살아 있는 token으로 fencing하며, lease 상실은 해당 프로세스에서 sticky 상태다. 오래된 worker는 새 소유자의 상태를 쓰거나 frame을 공개하지 못한다. takeover하려면 유효한 새 소유권으로 DB 상태를 다시 읽어야 한다.

COMMIT은 끝났으나 응답만 유실될 수 있다. `PendingPersistence`는 revision·state·frame·종료 상태를 보관하고 정확히 같은 operation을 ACK까지 재시도한다. 뒤에 도착한 입력은 후속 저장으로 남긴다. 같은 staged frame 재전송으로 시전을 다시 pending에 넣지 않는다. history·active·room list는 commit을 확인한 종료 상태만 공개한다.

서버 교체는 같은 owner의 DB 기록을 복구한다. downtime 동안 tick을 진행하지 않으며 최초 생성으로부터의 30분 보존 기간을 초기화하지 않는다. DB를 사용할 수 없거나 lease가 유효하지 않으면 가용성 오류로 실패하며, 저장 없이 경기를 계속 공개하지 않는다.

모델 요청 admission은 외부 실행 전에 저장한다. 이미 확정된 응답은 재생한다. 재시작 시 accepted 상태만 있고 terminal 응답이 없으면 provider를 다시 호출하지 않고 `serverRestart` 실패 이벤트를 확정한다. generation·sequence는 재사용하지 않는다. 외부 provider 호출의 exactly-once를 보장하지 않는다.

## 결과·중단·종료 통지

verifier는 서버가 보관한 최초 상태와 확정 로그를 받아 별도 .NET 프로세스에서 재생한다. 클라이언트가 제출한 승패나 임의 로그로 보상을 승인하지 않는다. 서버는 프로세스 시간과 동시 실행 수를 제한하며, 격리된 runtime 오류나 잘못된 이력은 거부한다.

완료 결과·MMR·보상·통계와 종료 outbox는 같은 transaction으로 저장한다. 동일 세션의 완료 재요청은 저장된 응답을 반환한다. 프로세스 교체 후에도 참가자가 완료 결과를 다시 조회할 수 있다.

`POST /api/lockstep/{id}/abort`의 `simulationFailure`는 해당 경기의 인간 참가자에게만 허용한다. runtime 실패·desync·timeout 중단은 성공 결과나 보상을 만들지 않는다. abort와 complete는 공통 gate 및 저장 결과 확인으로 경합을 제어하며, 이미 commit된 완료 결과를 중단으로 덮어쓰지 않는다. 종료 상태 저장이 실패하면 재시도 전까지 공개 종료로 취급하지 않는다.

outbox worker는 lease·재시도·ACK로 종료를 전달한다. 송신 뒤 ACK 전에 중단되면 중복 전달할 수 있다. lobby 수신 효과는 session ID로 멱등 처리하며, 최초 placement generation을 확인한다. 현재 host의 재시작만으로 lockstep 경기의 종료 통지를 거부하지 않는다.

## 검증 명령과 증거 경계

명령은 별도 표기가 없으면 root에서 실행한다. 일회용 PostgreSQL과 로컬 account/lobby/mock provider를 사용하는 integration fixture는 실행 전에 각 테스트의 환경 변수를 준비해야 한다. 인증 값은 로그나 Git 산출물에 남기지 않는다. 테스트용 임시 토큰은 격리한 fixture에서만 사용하고 종료 후 제거한다.

```powershell
# 현재 client 원본 대응·core·물리 검사와 서버용 verifier 빌드
dotnet run --project client/Tools/LockstepProbe -c Release
dotnet build client/Tools/LockstepVerifier/LockstepVerifier.csproj -c Release

# 원본 model의 서버·클라이언트 실행과 strict 증거 수집
python tools/lockstep-model-test-inventory.py --run-server --run-client --strict

# 별도로 수집한 원본·서버 replacement 증거를 현재 소스와 대조
python tools/lockstep-test-coverage.py --strict

# 최신 테스트 inventory 이후 source ownership 증거 갱신
python tools/lockstep-source-inventory.py
python tools/lockstep-source-inventory.py --check
```

simulation strict 도구의 `--run-rust PACKAGE TARGET FILTER`는 필요한 replacement 테스트를 실행하고 현재 입력 hash·명령·exit code·로그 hash를 기록한다. 필요한 조합은 [replacement 목록](../.plan/general/2026-10-29-lockstep-test-replacements.json)의 `checks`를 기준으로 한다. 단순히 성공 로그를 복사해서 현재 소스의 증거로 사용할 수 없다.

다음은 `game-rust`에서 실행한다. DB fixture 검사는 `AC_LOCKSTEP_DURABILITY_DATABASE_URL`, `AC_LOCKSTEP_DURABILITY_MIGRATION`과 결과 검사용 `AC_LOCKSTEP_RESULT_MIGRATION`을 준비한다. network 검사는 빌드한 DLL을 `AC_LOCKSTEP_VERIFIER_DLL`로 전달한다. 운영 실행 설정 이름은 `LOCKSTEP_VERIFIER_DLL`이다.

```powershell
cargo fmt --all -- --check
cargo check --workspace
cargo test -j1 -p ac-data --test lockstep_durability -- --ignored --nocapture
cargo test -j1 -p ac-game-server --test lockstep_recovery -- --ignored --nocapture
cargo test -j1 -p ac-game-server --test lockstep_client_network -- --include-ignored --nocapture
```

로컬 DB 회귀에서는 frame commit 후 서버 교체, 동일 attempt readiness와 최초 placement 보존, 만료 token renew 거부와 takeover, 실제 PostgreSQL COMMIT 응답 유실, 새 입력 보존과 중복 시전 방지, 종료 저장 실패 후 공개 지연, checkpoint 대기 중 complete 재시도를 확인했다. [마지막 복구 회귀 로그](../.generated/lockstep-durability/review-checkpoint-pending-test.log)는 local fixture의 결과다.

.NET·Unity Editor·WebGL은 같은 입력의 매 tick checkpoint를 비교한다. WebGL은 빌드 성공에 더해 브라우저에서 실행한 console 결과가 필요하다. 데스크톱 thread 전용 제외는 통과 수로 세지 않으며 별도 플랫폼 실행으로 확인한다. [WebGL replay 로그](../client/Tools/LockstepProbe/.generated/completion-webgl-replay.log)와 [probe 실행 안내](../client/Tools/LockstepProbe/README.md)를 참고한다. 이 로그의 C# 893개·model 38개만으로 원본 915개·127개 전부가 통과했다고 판정하지 않는다.

실제 GameScene fixture는 PVE 승리, 규칙 봇 패배, PVP 카드 시전·상대 재생·결과 저장을 구분한다. `AC_LOCKSTEP_UNITY_MODE`의 `pve`·`bot`·`cast`는 fixture 방식이며 마우스 조작이나 실제 로비 매칭 전체를 대체하지 않는다. 로비 진입→매칭→양쪽 GameScene→카드 입력→결과는 별도 최종 UI gate다. 별도 로비 검사에서 실제 매칭 버튼을 눌러 Unity↔.NET, Unity↔Unity 경기를 각각 완료했다. 양쪽 GameScene·CardUI 입력·Win/Lose ResultScene과 DB 결과·통계·시전 합계 각1회, outbox ACK, 양쪽 Online·로비 active 해제를 확인했다. 일반 EditMode는43pass/0fail/fixture전용2skip이며 해당 fixture는 설정을 넣어 별도 실행했다.

668개 source inventory는 소유·대응 위치를 설명하는 architecture 증거다. client 575개, server-retained 6개, shared-contract 38개, structural 40개, testfixture 9개로 분류했다. 직접 연결된 원본 테스트가 없는 483개 source도 명시한다. 파일 수나 owner 분류를 동작 검증 통과 수로 바꾸지 않는다.

유료 외부 모델 호출, 운영 배포, 운영 DB migration, 다른 CPU 아키텍처와 서비스 규모의 부하 검증은 수행 범위에 포함하지 않는다. 로컬 mock provider 검증을 실제 외부 서비스의 신뢰성 증거로 사용하지 않는다.

## 적용 순서와 롤백

이 절차는 운영에서 실행한 이력이 아니라 적용 시 지켜야 할 순서다.

1. 신규 lockstep 매칭을 비활성화한 상태에서 database의 V120 선행 여부를 확인하고 V121을 적용한다. migration을 기존 파일 덮어쓰기나 수동 table 삭제로 대체하지 않는다.
2. 같은 simulation 소스로 빌드한 Rust server와 .NET 8 verifier를 준비한다. 서버의 `LOCKSTEP_VERIFIER_DLL`에 DLL 절대 경로를 설정한다. 서버 owner URL과 DB를 유지하고 lease·복구·완료 결과 조회를 확인한다. lobby의 종료 알림 멱등 처리와 placement 보존 코드도 활성화 전에 반영한다.
3. 호환 client를 제공하고 simulationVersion·stateHashVersion·초기 콘텐츠 해시·모델 policy snapshot을 맞춘다. lobby의 `gameserver.lockstep.simulation-version`과 실제 생성하는 버전도 일치시킨다. 모델 봇 v2를 v1 경기로 강제 변환하지 않는다.
4. strict inventory, 대상 플랫폼 replay, 실제 UI gate를 확정한 뒤 lobby의 `gameserver.lockstep.enabled=true`로 신규 매칭을 켠다. 기본값은 `false`다. 환경 변수 방식에서는 Spring relaxed binding의 `GAMESERVER_LOCKSTEP_ENABLED`를 사용한다.

롤백은 먼저 lobby의 `gameserver.lockstep.enabled=false`로 신규 lockstep 라우팅을 중지한다. 이미 생성된 경기는 호환 server·verifier·client로 종료하거나 영속 중단 처리하고, 기존 결과 조회와 outbox 재시도를 유지한다. 이 flag는 lobby의 신규 매칭 선택을 제어하므로 모든 서버 API를 차단하는 전역 중단 장치로 취급하지 않는다.

V120/V121 데이터와 완료 결과·확정 로그·outbox는 보존한다. 진행 중 경기와 미전달 outbox가 남아 있는 동안 복구 계약을 모르는 서버로 내리거나 owner URL을 바꾸지 않는다. 저장 데이터를 삭제하는 down migration은 롤백 절차에 포함하지 않는다.
