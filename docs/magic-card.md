# magic-card — 카드 하나가 마법 하나가 되는 개편

이 문서는 `magic-card` 브랜치가 무엇을 바꾸는지 설명한다. 저장소 6개가 같은 이름의 브랜치와 같은 이름의 마일스톤을 쓴다.

- 루트 이슈: [Apptive-Game-Team/WordOnline#23](https://github.com/Apptive-Game-Team/WordOnline/issues/23)
- 계획: [`.plan/issues/2026-09-08-issue-23-magic-card-redesign.md`](../.plan/issues/2026-09-08-issue-23-magic-card-redesign.md)

## 왜 브랜치를 나누는가

이 개편은 데이터베이스 스키마, 게임 서버의 시전 프로토콜, 덱 API, admin 화면, 클라이언트 UI 를 한꺼번에 바꾼다. 절반만 들어간 상태에서는 어떤 마법도 시전되지 않는다. 그래서 `main` 에 조금씩 넣지 않고, 저장소마다 `magic-card` 브랜치를 두고 거기에만 쌓는다. 다 끝나면 default branch 를 옮기거나 한 번에 병합한다.

`main` 은 그동안 그대로 살아 있다. 개편을 접기로 하면 브랜치를 버리면 된다. 단 dev 데이터베이스에 마이그레이션을 한 번 적용한 뒤에는 forward-fix 마이그레이션으로만 되돌릴 수 있다.

## 지금 모델

카드는 원소이고, 마법은 카드 조합의 결과다.

- `cards` 는 11장이다. 원소 6장(Fire, Water, Lightning, Rock, Nature, Wind)과 시전 종류 5장(Shoot, Build, Spawn, Explode, Drop).
- `magics` 는 69개다. `magic_cards` 가 마법과 카드를 잇고, 카드를 정렬한 목록이 곧 조합의 키다. 조합 대부분이 카드 2장이고, 가장 긴 것이 5장이다. 같은 카드가 두 장 필요한 조합은 행을 두 번 넣어서 표현한다.
- 덱은 15장이고, 같은 카드 최대 3장, 원소 카드 2종 이상, 시전 종류 카드 3종 이상이어야 한다.
- 손패는 6장이고 1초마다 한 장씩 뽑는다. fever 동안 간격이 절반이 된다.
- 마나 비용은 낸 카드들의 `mana_cost` 합이다. 사거리는 시전 종류 이름으로 `parameter_values` 에서 읽는다. `parameters.getValue("Shoot", "range")` 같은 식이다.
- 소유가 두 갈래다. `user_cards` 는 카드를 3장씩 갖고, `user_magics` 는 마법 해금 여부를 갖는다. 조합이 맞아도 그 마법을 갖고 있지 않으면 시전이 거부된다.
- 시전은 세 단계다. 카드를 하나씩 고르면 select 와 unselect 메시지가 오가고, 조합이 성립하면 조준으로 넘어가고, 위치를 찍으면 카드 목록과 위치를 담은 메시지를 보낸다.

## 새 모델

카드 한 장이 마법 하나다.

- `magics` 가 카드 목록이 된다. `magic_cards` 와 `cards` 는 없어진다.
- 원소는 마법의 속성으로 남는다. `magics.element` 에 `Fire`~`Wind` 와 `None` 이 들어간다. 원소 상성표 7x7(`ElementalChart`)은 그대로 쓴다.
- 시전 종류는 없앤다. `Shoot`, `Drop` 같은 5개짜리 축이 사라지므로 마나 비용과 사거리는 시전 종류 이름이 아니라 마법 이름으로 키를 옮긴다. `game_objects.name` 이 `magics.name` 과 같아지고, 값은 `parameter_values` 에 그대로 남는다.
- 조준 표시 모양은 마법별로 `magics.indicator` jsonb 문서에 담는다. 지금은 `castType == Shoot` 인지로 판단하고 있다. 값 하나로는 반지름과 offset, 그리고 도형 여러 개를 한 번에 담을 수 없어서 문서로 간다. 내용은 [조준 indicator 문서](#조준-indicator-문서) 에 적었다.
- 소유가 한 갈래가 된다. `user_magics` 에 `count` 가 생기고 `user_cards` 는 없어진다.
- 시전이 두 단계가 된다. 손패에서 카드를 고르면 그 마법이 정해지고, 위치를 찍으면 시전한다. 조합 조립, 조합 취소, 조합 미리보기, 조합 추천 UI 가 전부 없어진다.
- 덱 규칙은 15장, 같은 마법 카드 최대 3장, 서로 다른 원소 2종 이상이다. 앞의 두 숫자는 지금 값 그대로다. 원소 2종 이상은 지금의 "원소 카드 2종 이상"을 옮긴 것이다.
- 손패 6장과 1초 draw 간격, fever 는 그대로 둔다.

## 밸런스는 개편 직후 그대로 유지한다

마이그레이션이 옛 조합에서 초기값을 계산한다.

| 값 | 초기값 |
| --- | --- |
| `magics.element` | 조합에 가장 많이 든 원소 카드. 같으면 `cards.id` 가 작은 쪽. 원소 카드가 없으면 `None` |
| `mana_cost` | 조합에 든 카드들의 `mana_cost` 합. 같은 카드가 두 번 들었으면 두 번 더한다 |
| `range` | 조합에 든 시전 종류 카드의 `range` |
| `magics.indicator` | 조합에 `Shoot` 이 있으면 lane layer 하나, 아니면 circle layer 하나. 두 경우 모두 크기는 `radius` parameter 를 가리킨다 |
| `user_magics.count` | 3. 지금 첫 로그인 지급이 카드마다 3장을 주는 것과 같은 수 |

그래서 개편 직후 어떤 마법의 마나와 사거리도 지금과 같다. 이후 밸런스 조정은 이 개편 밖의 일이다.

한 가지 주의할 점이 있다. 조합 SQL 이 이 저장소에 있는 마법은 19개뿐이고 나머지 약 50개의 조합은 운영 데이터베이스에만 있다. 위 계산은 SQL 로 하므로 운영과 dev 에서는 전부 채워지지만, 빈 데이터베이스에서 마이그레이션 체인을 재생해서 확인할 수는 없다. `V000` 이 `create database` 로 시작하는 `pg_catalog` 덤프라는 기존 제약과 같은 이유다.

## 조준 indicator 문서

`magics.indicator` 는 클라이언트가 시전 전에 필드에 그릴 도형을 담는 jsonb 문서다. version 1 의 모양은 이렇다.

```json
{"version": 1, "layers": [{"shape": "circle", "origin": "target", "radius": {"parameter": "radius"}}]}
```

`layers` 는 순서가 있는 목록이고 클라이언트가 앞에서부터 전부 그린다. 뒤에 온 layer 가 위에 얹힌다.

layer 공통 항목

| 항목 | 필수 | 값 |
| --- | --- | --- |
| `shape` | 예 | `circle` 또는 `lane` |
| `origin` | 아니오 (기본 `target`) | `caster` 는 시전자 위치, `target` 은 커서가 가리키는 조준점 |

`shape` 가 `circle` 일 때

| 항목 | 필수 | 값 |
| --- | --- | --- |
| `radius` | 예 | 반지름 |
| `forwardOffset` | 아니오 (기본 0) | 중심을 시전자 전방으로 밀어내는 거리 |
| `edgeWidth` | 아니오 (기본 0) | 0 이면 채운 원, 0 보다 크면 그 굵기의 테두리만 |

`shape` 가 `lane` 일 때

| 항목 | 필수 | 값 |
| --- | --- | --- |
| `end` | 예 | `target`, `aim`, `forward` 중 하나. 아래 표 참고 |
| `length` | `end` 가 `forward` 일 때만 | lane 길이. `target` 에서는 선택 항목이다 |
| `halfWidth` | 예 | lane 절반 폭 |

`end` 가 정하는 것은 방향과 길이다.

| `end` | 방향 | 길이 |
| --- | --- | --- |
| `target` | 조준점 쪽 | `length` 가 있으면 그 값, 없으면 마법의 cast range |
| `aim` | 조준점 쪽 | origin 에서 조준점까지 거리 그대로 |
| `forward` | 시전자 진영이 보는 쪽(+X 또는 -X) | `length` |

`target` 과 `aim` 의 차이가 중요하다. 조준점을 지나 계속 날아가는 투사체는 `target` 이다 — `wind_blade` 는 맵 끝까지 관통하므로 cast range 만큼 그리는 게 맞다. 조준점에서 끝나는 것은 `aim` 이다 — `spirit_bomb` 의 빔은 시전자와 조준점 사이 거리만큼만 뻗는다. 사거리가 둘 중 어느 것도 아닌 고정 값이면 `target` 에 `length` 를 적는다 — `vine_toss` 의 넝쿨은 조준 방향으로 언제나 6 만큼 나간다.

크기를 나타내는 값은 넷 중 하나다.

- 숫자 그대로. 예: `0.08`
- `{"parameter": "attack_range"}` — 클라이언트가 `/api/data/parameters` 에서 그 마법의 parameter 를 읽는다
- `{"object": "electric_shot", "parameter": "radius"}` — 그 이름의 game object 에서 읽는다
- 어느 쪽이든 `"fallback": 0` 을 덧붙이면 값을 못 찾았을 때 쓸 숫자가 된다

문서를 쓸 때는 parameter 이름 참조를 기본으로 한다. 대응하는 parameter 가 없는 값만 숫자로 적는다. 밸런스 수치가 `parameter_values` 한 곳에만 남아서, 수치를 고칠 때 문서를 다시 쓸 일이 없다.

`object` 를 적는 이유는 마법 이름과 값이 들어 있는 game object 이름이 다른 경우가 많기 때문이다. `lightning_shot` 의 숫자는 `electric_shot` 에, `vine_toss` 의 숫자는 `vine` 에, `crater` 가 닿는 거리는 `crater_ember` 에 있다. `object` 없이 쓰면 클라이언트는 `magic_id` 로 이어진 object 를, 없으면 이름이 같은 object 를 보는데 두 경로 다 실패해서 그 layer 가 통째로 사라진다. 값을 `parameter_values` 에 복사해 두는 것은 답이 아니다 — 밸런스를 고칠 때 한쪽만 고쳐지고 조준 표시가 조용히 어긋난다.

도형이 뜻하는 것은 두 가지로 나눈다. 속을 채운 도형은 시전하면 그 자리에 실제로 들어가는 범위이고, `edgeWidth` 를 준 테두리 원은 조건이 맞아야 닿는 범위다 — 건물의 공격 사거리, chain 의 다음 hop, 맞았을 때만 생기는 폭발이 여기 해당한다.

설치 지점과 실제로 때리는 지점이 다른 타워는 layer 를 하나 더 얹는다.

```json
{"shape": "circle", "origin": "target", "forwardOffset": {"parameter": "attack_offset", "fallback": 0}, "radius": {"parameter": "attack_range"}, "edgeWidth": 0.08}
```

클라이언트는 이 문서를 `/api/data/magics` 응답 안에서 통째로 받아 `MagicInfoData` 라는 PlayerPrefs 키에 저장해 두고, 다음 요청에 `currentVersion` 을 실어 보내 `requiresRefresh` 가 `true` 일 때만 교체한다. 마법 데이터가 이미 쓰던 방식 그대로라 새로 만든 것은 없다. version 이나 `shape` 이나 `origin` 이나 `end` 값을 클라이언트가 모르면 그 layer 만 건너뛰고 나머지를 그린다. 그래서 계약에 항목을 더하는 쪽이 데이터보다 먼저 나갈 필요가 없다 — 모르는 client 는 지금 그리던 것을 계속 그린다.

## 덱과 소유 데이터는 새로 만든다

기존 덱 15장은 전부 원소·시전 종류 카드라 새 모델에서 의미가 없다. 마이그레이션이 모든 덱의 내용을 지우고 `access_type = 'DEFAULT'` 인 마법으로 15장짜리 기본 덱을 다시 채운다. `users.selected_deck_id` 와 덱 자체는 살아 있고 내용만 바뀐다. 되돌릴 수 없는 변경이다.

## 저장소별 영향

| 저장소 | 핵심 변경 | 이슈 |
| --- | --- | --- |
| [WordOnlineDatabase](https://github.com/Apptive-Game-Team/WordOnlineDatabase) | `magics` 에 `element` 추가, 마법별 parameter 값 seed, 덱·소유 이전, 통계 합치기, 옛 표 삭제, `magics.indicator` 추가 | #99 #100 #101 #102 #103 #137 |
| [WordOnlineServer](https://github.com/Apptive-Game-Team/WordOnlineServer) | 조합 해석 제거, 시전 입력을 마법 id 하나로, parameter 키 이동, 봇, 통계 | #495 #496 #497 #498 #499 |
| [WordOnlineMatching](https://github.com/Apptive-Game-Team/WordOnlineMatching) | 덱 검증 규칙, 카드 목록 API, `/api/data/magics` 응답, 지급과 보상, indicator 문서 전달 | #116 #117 #118 #129 |
| [WordOnlineAdmin](https://github.com/Apptive-Game-Team/WordOnlineAdmin) | 조합 편집기, 밸런스 화면의 마나 계산, 봇 덱, 통계 화면 | #105 #106 #107 #108 |
| [WordOnlineClient](https://github.com/Apptive-Game-Team/WordOnlineClient) | 카드 자료형과 아트, 손패와 시전, 덱 화면, 도감, 튜토리얼, 번역표, indicator 문서로 조준 표시 그리기 | #575 #576 #577 #578 #579 #580 #653 |
| [WordOnline](https://github.com/Apptive-Game-Team/WordOnline) | 문서, 서브모듈 포인터, 전환 | #23 #24 #25 |

account, website, infra 는 바뀌지 않는다.

## 바꾸지 않는 것

- 원소 상성표 7x7. 서버 `ElementalChart` 와 클라이언트 `ElementChartView` 양쪽에 같은 값이 하드코딩되어 있고, 그대로 둔다.
- 마법 구현 클래스 구조. `AbstractShotMagic`, `AbstractDropMagic`, `AbstractSpawnMagic`, `AbstractSummonMagic`, `AbstractExplosionMagic` 은 그대로다. 없어지는 것은 데이터 쪽의 시전 종류 축이지 코드 구조가 아니다.
- 마법 bean 이름과 `magics.name` 이 같아야 한다는 규칙.
- 손패 6장, 1초 draw, fever 간격 절반.
- 매칭이 게임 서버에 넘기는 payload. 지금도 세션 식별자와 사용자 id 만 넘기고 덱 내용은 게임 서버가 데이터베이스에서 직접 읽는다.

## 작업 규칙

- 각 저장소의 이슈 브랜치는 `magic-card` 에서 따고 `magic-card` 로 병합한다. base 를 `main` 으로 두지 않는다.
- 브랜치 이름과 label 규칙(`<label>/<번호>`), assignee 와 label 필수 규칙은 각 저장소의 `AGENTS.md` 를 그대로 따른다.
- WordOnlineDatabase 는 pull request 를 한 줄로 쌓는다. 마이그레이션 번호는 `main` 의 최고 번호보다 커야 한다. 작성 시점 기준 `main` 의 최고 번호는 `V067` 이다. `validate_migrations.yml` 은 pull request 의 base branch 기준으로만 순서를 검사하므로, `magic-card` 안에서만 번호를 맞추면 나중에 `main` 병합에서 순서가 깨진다.
- 버전은 pull request 마다 올리지 않는다. promotion 때 `deploy` 스킬이 한 번 올린다. 프로토콜이 깨지는 변경이므로 commit 메시지를 정확히 써야 MAJOR 로 올라간다.

## 전환 순서

1. 각 저장소 magic-card 마일스톤의 이슈를 전부 닫는다.
2. 각 저장소 magic-card 에 `main` 을 병합해서 그동안의 변경을 흡수한다.
3. WordOnlineDatabase 의 마이그레이션 번호가 `main` 의 최고 번호보다 큰지 다시 확인한다.
4. WordOnlineDatabase 의 magic-card 를 `main` 에 병합한다. push 즉시 dev 데이터베이스가 마이그레이션된다.
5. `test-env` 스킬로 복제본에서 game, lobby, admin, client 를 한 판 돌려 확인한다.
6. 나머지 4개 저장소를 병합하거나 default branch 를 옮긴다.
7. `deploy` 스킬로 promotion 한다. 데이터베이스가 먼저, 그다음 서버, 마지막이 클라이언트다.

전환 계획은 [WordOnline#25](https://github.com/Apptive-Game-Team/WordOnline/issues/25) 에서 관리한다.
