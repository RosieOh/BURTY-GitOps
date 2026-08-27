<!-- 커밋·이슈 연동 규칙: .github/COMMIT_MESSAGE_ISSUES.md -->

## 🏫 PR 타입
- [ ] FEAT (✨) 기능 추가
- [ ] FIX (🐛) 버그 수정
- [ ] REFACTOR (♻️) 구조 개선
- [ ] CHORE (🔧) 빌드·설정·문서·운영 반영

## 🏫 관련 이슈
<!-- Closes #42 — 병합 시 이슈 종료 / Refs #42 — 참조만 -->

## 🏫 대상 환경
- [ ] dev (`k8s/overlays/dev`)
- [ ] prod (`k8s/overlays/prod`)
- [ ] platform (`k8s/platform`)

## 🏫 변경 사항

## 🏫 렌더링 diff
<!-- 클러스터에 실제로 무엇이 바뀌는지. 아래 출력 요약을 붙여 주세요.
     kustomize build k8s/overlays/prod > /tmp/after.yaml
     git stash && kustomize build k8s/overlays/prod > /tmp/before.yaml && git stash pop
     diff -u /tmp/before.yaml /tmp/after.yaml -->

```diff
```

## 🏫 배포 영향
- [ ] 파드 재시작이 발생한다
- [ ] 무중단이다 (maxUnavailable=0 롤링)
- [ ] 데이터 마이그레이션이 필요하다
- [ ] 롤백 시 수동 조치가 필요하다 (필요하면 절차 명시)

## 🏫 롤백 절차
<!-- prod 변경이면 필수. `argocd app rollback` 으로 충분한지, Secret/PVC 수동 조치가 필요한지. -->

## 🏫 To Reviewer
<!-- VirtualService 순서, AuthorizationPolicy 영향 범위 등 놓치기 쉬운 지점 -->
