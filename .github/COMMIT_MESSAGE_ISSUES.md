# 커밋 메시지와 GitHub 이슈 연결 규칙

애플리케이션 레포([FINNECT-BURTY/BURTY_Interface_V2](https://github.com/FINNECT-BURTY/BURTY_Interface_V2))와
동일한 규칙을 쓴다. 두 레포를 오가며 작업하므로 컨벤션이 갈라지면 안 된다.

## 커밋 메시지 형식

- 제목과 본문은 빈 줄로 구분
- 제목은 50자 이내 작성
- 제목 첫 글자는 대문자 시작, 마침표 미사용
- 제목은 명령문 사용, 과거형 미사용
- 본문 각 줄은 72자 이내 작성
- 본문은 **무엇**과 **왜** 중심 작성

예시:

`FEAT: Istio 트래픽·보안 정책 추가`

```
무엇: Gateway·VirtualService·DestinationRule·mTLS·AuthorizationPolicy 추가
왜: nginx 가 담당하던 TLS 종단·라우팅·rate limit 을 메시로 이관하기 위함
```

## 타입 + gitmoji 매핑

- FEAT: ✨
- FIX: 🐛
- REFACTOR: ♻️
- CHORE: 🔧

## 이슈 연동 규칙

- 커밋 제목 끝에 이슈 번호 표기: `CHORE: 템플릿 정비 반영 (#12)`
- PR 본문에 `Closes #12` 또는 `Refs #12` 표기
- 이슈 생성 시 타입에 맞는 라벨(`type:feat` 등) 부여

## 이 레포에만 적용되는 추가 규칙

- **이미지 태그 갱신 커밋은 Jenkins 가 만든다.** 사람이 손으로 `newTag` 를 바꾸지 않는다.
  (`CHORE: prod 이미지 태그를 ... 로 갱신` — 작성자 `burty-ci`)
- **prod overlay 변경 PR 은 롤백 절차를 본문에 적는다.** `argocd app rollback` 만으로
  되돌아가지 않는 변경(Secret, PVC, DB 스키마)이 있으면 반드시 명시한다.
- **렌더링 diff 를 PR 에 붙인다.** 매니페스트 diff 와 클러스터에 실제로 적용되는 diff 는 다르다.
