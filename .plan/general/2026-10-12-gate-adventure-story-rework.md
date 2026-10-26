# 차원문 모험 (adventure 3) 이야기 재구성

## 목표

시나리오 14~18 이 모두 "차원문 두꺼비를 부수면 올챙이가 나온다" 로 반복된다. 사용자가 준 이야기에
맞춰 다섯 판의 구성을 바꾼다.

1. 지옥 것들이 마을로 몰려온다. "내가 막을게, 다들 도망쳐!"
2. "어디서 나오는 거지?" 차원문을 발견한다.
3. 차원문에서 타락한 정령들이 나온다 (evil ent 보다 약한 졸병, 기존 정령이 더 기괴해진 모습).
4. 차원을 여는 두꺼비들을 처치한다.
5. 마지막 차원문이 부서지면 evil ent 가 나타나 플레이어 소환수를 전부 끌어가 죽인다.
   보스 BGM 으로 바뀌고 보스전이 시작된다.

## 의존

- 보스 BGM: game `feature/106` (ArcaneCastersGame#111, `PlayBgm` action), client `feature/275`
  (ArcaneCastersClient#296, `bgmEntries` 의 `boss` key 와 `boss_battle_v1.wav`). 둘 다 아직 열려 있고
  곧 merge 된다. game 과 client 작업은 이 두 branch 위에 쌓고, merge 뒤 dev 로 rebase 한다.
- database: `bgm_key` column 과 `PlayBgm` 은 V035, 보스 intro BGM 은 V041 로 이미 dev 에 있다.
  V041 이 scenario 17, 18 의 intro 에 넣은 `PlayBgm boss` 는 이번 재구성에서 지우고,
  18 은 evil ent 가 등장하는 event 로 옮긴다.

## 계약 (세 저장소가 같은 이름을 쓴다)

| 항목 | 값 |
|---|---|
| 새 action | `action_type = 'PullPlayerUnits'`, `installer_id` = 끌어갈 목적지 installer |
| 동작 | 그 순간 살아 있는 `LeftPlayer` 의 이동 유닛(소환수) 전부의 AI 를 끄고 목적지 installer 쪽으로 약 1.5초 동안 끌어온 뒤 파괴한다. 플레이어 본체와 건물은 건드리지 않는다. 위치는 frame 정보로 client 에 가므로 끌려가는 모습은 client 변경 없이 보인다 |
| 새 prefab 1 | `PveCorruptedVineSpirit`, parameter object `pve_corrupted_vine_spirit`: 지상 근접, `VineSpirit` 을 바탕으로 한 PVE 전용 변형 |
| 새 prefab 2 | `PveCorruptedWindSpirit`, parameter object `pve_corrupted_wind_spirit`: 공중, `WindSpirit` 을 바탕으로 한 PVE 전용 변형 |
| 보스 BGM key | `boss` (V041 과 같음) |

Unit 의 parameter 는 PVP 와 공유하지 않는 새 object 에만 쓴다. 기존 `vine_spirit`, `wind_spirit` 행은 바꾸지 않는다.

## 설계 표

Pressure 는 `adventure-check.py` 로 확인한다. 첫 시나리오 0.45–0.75, 중간 0.75–1.2,
stage 마지막 1.2–1.5 (peak 1.8), 모험 마지막 1.2–1.5 (peak ≤ 2.0, 20초 이하).

| id | stage | 새 요소 | 승리 조건 | 구조물 (hp) | 웨이브 | phase |
|---|---|---|---|---|---|---|
| 14 | 5 | 버티기, 차원문이 보이지 않음 | `Survive` 90 s | 차원문 없음 (엔진이 installer 0개를 허용해야 한다. 안 되면 화면 밖 x=16 에 objective 아닌 표식) | 올챙이 2종, 세 lane 을 번갈아 | 없음 |
| 15 | 5 | 경기 중간에 차원문 등장 | `DestroyObjectives` | `gate_a` 두꺼비 900, 25 s 에 `InstallObject` | 0–25 s 화면 밖 웨이브, 그 뒤 차원문 spawner | 없음 |
| 16 | 5 | 타락한 덩굴 정령 | `DestroyObjectives` | `great_gate` 두꺼비 2200 | 올챙이 + 타락한 덩굴 정령 | 60 % `SetSpawner` → 타락한 덩굴 정령, 30 % 웨이브 + 대사 |
| 17 | 6 | 타락한 바람 정령 (공중), 차원문 세 개 | `DestroyObjectives` (세 개) | `gate_a`/`gate_b`/`gate_c` 두꺼비 각 800, evil ent 없음 | 공중 + 지상 혼합, lane 분산 | 없음 |
| 18 | 6 | evil ent 등장, `PullPlayerUnits`, 보스 BGM | `DestroyObjectives` (`corrupted`, 경기 중 설치) | `rift` 두꺼비 1600 → 부서지면 `corrupted` `PveEvilEnt` 3000 설치 | `rift` 가 부서지기 전 혼합 웨이브. 등장 직후 12 s 동안 웨이브 없음 (소환수를 잃은 플레이어의 마나가 다시 차는 시간) | 등장: `PullPlayerUnits` + `PlayBgm boss`. 60 % `SetSpawner` + 웨이브, 30 % 차원문 두 개 `InstallObject` + shield |

V041 이 17 의 intro 에 넣은 `PlayBgm boss` 는 17 에 보스가 없어지므로 함께 사라진다.

## 저장소별 작업

- game (`feature/106` 위): `PullPlayerUnits` action, 두 prefab, 필요하면 installer 0개 `Survive` 허용.
- database (`origin/dev` 위, V042): action_type CHECK 에 `PullPlayerUnits` 추가, 두 prefab parameter,
  scenario 14–18 내용 재작성 (scenario id 유지).
- client 그림 (`feature/275` 위): 두 prefab 의 sprite 와 Unity prefab, `PrefabType` 대응.
- client 이야기 (`feature/275` 위): scenario 14–18 의 `scenarioStories` 와 새 `message_key` 의 영어·한국어 localization.
