# 요새 마지막 보스를 벽돌 골렘으로 교체

## 목표

요새 모험의 마지막 시나리오(13)의 보스 `PveVineWitch` 를 새 보스 `PveBrickGolem` 으로 바꾼다.
골렘은 요새 성벽 벽돌로 된 거대한 골렘이다. 상반신만 땅 위로 나와 있고 움직이지 않으며, 두 팔로 공격한다.

- 내려찍기: 사거리 안의 지상 적 하나를 골라, 그 자리에 바닥 균열 경고를 1초 보여 준 뒤 원형 범위 피해를 준다.
- 휩쓸기: 몸 가까이 붙은 지상 적들을 부채꼴로 쳐서 피해를 주고 뒤로 밀어낸다.

## 이야기

마녀는 요새 이야기에서 뺀다(사용자 결정, 2026-10-12). 요새 성벽에는 오래전부터 수호 골렘이 박혀 있었고,
요새를 뒤덮은 덩굴의 오염이 그 골렘을 깨운다. 골렘은 말하지 않는다(`PveEvilEnt` 와 같다):
시나리오 13 의 이벤트는 `speaker_installer_id` 와 `message_key` 를 비우고 `pve_scenario_event_lines` 를 두지 않는다.
경기 전 이야기(client `scenarioStories`)는 마녀 없이 플레이어 쪽 대사로 다시 쓴다.
시나리오 4(숲)의 마녀는 그대로 둔다.

## 저장소별 작업

### game (server)

- `PrefabType.PveBrickGolem("pve_brick_golem_prefab")` 와 `GameObjectKey.PVE_BRICK_GOLEM("pve_brick_golem")`.
- `PveBrickGolemPrefabInitializer`: `RigidBody`, `ZPhysics`, trigger `CircleCollider`, Rock 원소, `CommonEffectReceiver`,
  `PveBrickGolemMob`. `PveEvilEntPrefabInitializer` 를 본뜬다. `SetSpawner` action 이 이 installer 에 동작해야 한다.
- `PveBrickGolemMob`: 속도 0 인 `BehaviorMob`, `PveObjectiveTarget` 구현.
  - 내려찍기: `attack_interval` 마다, `attack_range` 안의 지상 적. 경고 projection 을 보내고 1.0 초 뒤
    그 위치에서 반경 `effect_radius` 안의 적에게 `damage`.
  - 휩쓸기: `sub_attack_interval` 마다, `sub_attack_range` 안의 지상 적이 있으면 부채꼴 판정으로 `sub_damage`
    와 넉백. `SprayingAttacker.getCollidedMobs` 를 본뜬다.
  - 두 공격 모두 `Status.Attack` 을 보낸다.

### client ↔ server 계약 (고정)

| projection type | 언제 | 시작 → 끝 | duration |
|---|---|---|---|
| `BrickGolemSlamWarning` | 내려찍기 시작 | 목표 위치 → 목표 위치 | 1.0 초 |
| `BrickGolemSlam` | 내려찍기 착지 | 골렘 → 목표 위치 | 0.3 초 |
| `BrickGolemSweep` | 휩쓸기 | 골렘 → 휩쓴 방향의 끝점 | 0.4 초 |

client 는 `Resources/Projectiles/{type}` 에서 같은 이름의 prefab 을 찾는다.

### database

- `pve_brick_golem` 을 V029 방식으로 등록한다: `game_objects`, `parameter_values`
  (`hp`, `radius`, `mass`, `damage`, `attack_interval`, `attack_range`, `effect_radius`,
  `sub_damage`, `sub_attack_interval`, `sub_attack_range`), `prefab_elements` Rock, `-- no-tags`.
- 시나리오 13: installer `witch` 를 `golem`(`PveBrickGolem`)으로 바꾸고, objectives, events, actions 의
  `witch` 참조를 모두 `golem` 으로 바꾼다. 대사 4 줄을 지우고 speaker 와 message key 를 비운다. 체력 단계는 70/40/15 를 유지한다.
- server 배포보다 먼저 적용돼야 한다.

### client

- 그림: codex 로 `PveBrickGolem.png`(기본)와 `PveBrickGolem2.png`(팔을 든 공격 프레임)를 한 캔버스에서 함께 생성.
  크기 등급 big 256, Bottom Center pivot. 경고·내려찍기·휩쓸기 효과 그림.
- `Resources/Prefabs/PveBrickGolem.prefab`: `PveEvilEnt.prefab` 처럼 `AbstractRangeMob` variant,
  motion controller 없음, `AttackSpriteSwapController` 로 공격 프레임.
- `Resources/Projectiles/` 에 위 세 projection prefab. 내려찍기는 `TitanFistPresenter` 의 바닥 균열 연출을 재사용.
- 시나리오 13 경기 전 이야기를 마녀 없이 다시 쓰고, 보스 이름 `PveBrickGolem` 을 `Adventure` localization 에 추가 (영어, 한국어).
- 효과음 catalog 항목.

## 순서와 병렬

세 저장소의 작업은 위 계약만 지키면 서로 독립적이라 동시에 진행한다. 배포 순서는 database → game → client 다.

## 검증

- game: 새 mob 단위 테스트(사거리, 경고 뒤 피해, 넉백), 기존 테스트 통과.
- database: 빈 Postgres 에 V001 부터 재생, `validate-migrations.sh origin/dev`.
- client: Editor 를 쓸 수 없으므로 prefab fileID 검증과 Roslyn 컴파일 검사, 그림은 합성 이미지로 크기 확인.
- 통합: test-env 에서 시나리오 13 을 직접 플레이.
