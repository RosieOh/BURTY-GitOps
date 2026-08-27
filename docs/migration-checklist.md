# compose → Kubernetes 전환 체크리스트

이슈와 마일스톤이 이 문서를 그대로 따라간다. 항목을 추가하면 이슈도 같이 만든다.

## M1 클러스터 부트스트랩

앱을 올리기 전에 끝나야 하는 것들.

- [ ] EKS 클러스터 + 노드그룹 (RWX StorageClass 포함 — EFS CSI)
- [ ] Istio (base / istiod / gateway) — `k8s/platform/values/istiod-values.yaml`
- [ ] cert-manager + ClusterIssuer (Route53 DNS-01, IRSA)
- [ ] kube-prometheus-stack / Loki / Tempo / Promtail / OTel Collector
- [ ] External Secrets Operator + IRSA
- [ ] ArgoCD + AppProject(`burty`, `burty-platform`) + Application 3종
- [ ] Jenkins + `ghcr-docker-config` 시크릿 + gradle 캐시 PVC
- [ ] **placeholder 전부 치환** — `./scripts/validate.sh` 의 목록이 비어야 한다
- [ ] 운영도구 노출 CIDR 을 실제 대역으로 (기본값은 예시라 사실상 열려 있음)

검증: `argocd app sync burty-platform` → Healthy, `kubectl -n istio-system get certificate` → Ready

## M2 dev 전환

- [ ] `argocd app sync burty-dev` → Healthy
- [ ] `https://dev.burty.co.kr/health` 200 + `"status":"UP"`
- [ ] `/actuator/prometheus` 외부에서 404
- [ ] Grafana 에 JVM/HTTP 메트릭 (15020 병합 스크랩)
- [ ] Loki 에 로그 (stdout 수집, `level`·`logger` 라벨)
- [ ] Tempo 에 트레이스, 로그↔트레이스 상호 점프
- [ ] Flyway 마이그레이션이 in-cluster MariaDB 에 적용
- [ ] 소셜 로그인 왕복 (스텁 모드)
- [ ] 프론트엔드 배포 (없으면 `/` 가 503)
- [ ] Jenkins 파이프라인 end-to-end 1회 (빌드 → 태그 커밋 → ArgoCD sync → 스모크)

## M3 prod 전환

- [ ] RDS / ElastiCache 준비, 보안그룹에서 노드 대역 허용
- [ ] Secrets Manager 에 `burty/prod/app` 등록, ESO 동기화 확인
- [ ] prod 파드 기동 후 게이트웨이 IP 직접 스모크 (hosts 오버라이드)
- [ ] 부하 테스트 — HPA 스케일아웃 동작, p95 확인
- [ ] DNS TTL 을 60s 로 하향 (컷오버 24h 전)
- [ ] **DNS 컷오버**
- [ ] 10분 관찰: 5xx 비율, p95, 서킷브레이커, 이체 성공률
- [ ] EC2 compose 스택 **1주 유지** 후 폐기
- [ ] 백업 CronJob 1회 성공 확인

> 롤백은 DNS 를 EC2 로 되돌리는 것이다. TTL 60s 라 수 분 내 복귀.
> 그래서 compose 스택을 바로 내리지 않는다.

## M4 운영 안정화

- [ ] per-IP rate limit (`envoyproxy/ratelimit` + Redis) — 현재는 게이트웨이당 전역 버킷
- [ ] 업로드 저장소 S3 전환 — RWX PVC 는 임시방편
- [ ] Istio CNI 전환 → PSA `restricted`
- [ ] 카나리 배포 활성화
- [ ] 백업 복구 리허설, RTO 문서화
- [ ] `outboundTrafficPolicy: REGISTRY_ONLY` 로 조이기 (ServiceEntry 누락 확인 후)
- [ ] Alertmanager 수신자 연결 (Slack/webhook)

## 의미가 달라지는 지점

전환하면서 동작이 **같지 않은** 것들. 운영 중 혼란의 원인이 되므로 미리 안다.

| 항목 | compose | K8s |
|---|---|---|
| rate limit | 클라이언트 IP 단위 | 게이트웨이 파드 단위 (M4 에서 해소) |
| 라우팅 우선순위 | nginx 최장일치 | Istio 첫 매치 (순서 의존) |
| 로그 수집 | 호스트 볼륨 파일 tail | 컨테이너 stdout |
| 인증서 갱신 | certbot 12h 루프 + nginx reload | cert-manager, reload 불필요 |
| 배포 주체 | Jenkins 가 직접 | ArgoCD (Jenkins 는 커밋만) |
| 업로드 파일 | 호스트 볼륨 단일 경로 | RWX PVC (다중 replica 공유) |
| `/actuator` 차단 | nginx `return 404` | VirtualService `directResponse` + AuthZ |
