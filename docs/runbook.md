# 클러스터 운영 런북

당직이 실제로 치는 명령만. 배경 설명은 [decisions.md](decisions.md), 전체 구조는
[README](../README.md) 를 본다.

애플리케이션 레벨 운영(Grafana 임베딩 API, prod 필수 env, 앱 장애 대응)은
[앱 레포의 runbook](https://github.com/FINNECT-BURTY/BURTY_Interface_V2/blob/main/docs/operations-runbook.md) 에 있다.

## 어디에 무엇이 있나

| 대상 | 위치 |
|---|---|
| 앱 | `burty-prod` / `burty-dev`, Deployment `burty-api` |
| 인그레스 | `istio-system` 의 `istio-ingressgateway`, Gateway `burty-gateway` |
| 관측 | `observability` — Prometheus / Grafana / Loki / Tempo / OTel Collector |
| CD | `argocd` — Application `burty-prod`, `burty-dev`, `burty-platform` |
| CI | `jenkins` |

## 상태 확인

```bash
kubectl -n burty-prod get pods,hpa,pdb
kubectl -n burty-prod logs -l app.kubernetes.io/name=burty-api --tail=100 -c burty-api
argocd app get burty-prod
istioctl proxy-status
istioctl analyze -n burty-prod
```

## 배포 / 롤백

배포의 진실 공급원은 이 레포다. 클러스터를 직접 고치면 ArgoCD 가 되돌린다(dev 는 selfHeal 켜짐).

```bash
# 정상 배포 — Jenkins 가 이미지 태그를 커밋한 뒤 승인 단계에서 대기한다
argocd app sync burty-prod && argocd app wait burty-prod --health --sync

# 즉시 롤백
argocd app history burty-prod
argocd app rollback burty-prod <REVISION>

# 항구적 롤백 — Git 이 진실이므로 이쪽이 정석
git revert <이미지-태그-커밋> && git push
```

`kubectl rollout undo` 는 쓰지 않는다. 다음 sync 에서 되돌아온다.

## 긴급 스케일

```bash
kubectl -n burty-prod scale deploy/burty-api --replicas=6
```

HPA 가 소유한 값이라 곧 되돌아간다. 지속시키려면 `k8s/base/hpa.yaml` 의 `minReplicas` 를
올려 커밋한다.

## 장애 대응

### 1. 502/503 from gateway

```bash
istioctl proxy-config route deploy/istio-ingressgateway.istio-system
```

VirtualService 는 nginx 와 달리 **위에서 첫 매치**다. 규칙 순서가 바뀌면 조용히 오라우팅된다.

### 2. 파드는 Running 인데 트래픽이 안 감

`AuthorizationPolicy: allow-nothing` 이 네임스페이스 기본 거부다. 새 워크로드를 올렸다면
그 워크로드용 ALLOW 정책이 있는지 먼저 본다. `istioctl analyze` 가 대부분 잡아 준다.

### 3. CreateContainerConfigError

대개 `burty-secret` 미존재다.

```bash
kubectl -n burty-prod get externalsecret burty-secret -o wide
kubectl -n burty-prod describe externalsecret burty-secret
```

### 4. 메트릭이 Grafana 에 안 보임

순서대로 확인한다.

1. 파드에 `prometheus.io/{scrape,port,path}` 애노테이션이 있는가
2. istiod values 의 `enablePrometheusMerge: true` 인가
3. PodMonitor 가 **15020** 을 보는가 (15090 이 아니라)
4. `kubectl -n burty-prod exec <pod> -c istio-proxy -- curl -s localhost:15020/stats/prometheus | head`

### 5. 로그가 Loki 에 안 보임

K8s 에서는 파일이 아니라 **stdout** 을 수집한다.

```bash
kubectl -n observability logs -l app.kubernetes.io/name=promtail --tail=50
```

컨테이너 안 `/app/logs` 는 emptyDir 이며 수집 대상이 아니다.

### 6. 사이드카 없이 뜬 파드 (`BurtySidecarMissing`)

네임스페이스의 `istio-injection=enabled` 라벨이 빠졌거나, PSA 를 `restricted` 로 올려
`istio-init` 이 거부된 경우다. prod 네임스페이스는 `baseline` 이어야 한다.

### 7. 인증서 문제 (`BurtyTlsCertExpiringSoon`, `BurtyCertNotReady`)

```bash
kubectl -n istio-system get certificate,certificaterequest,order,challenge
kubectl -n cert-manager logs deploy/cert-manager --tail=100
```

### 8. HPA 가 최대치에서 안 내려옴

CPU 만 보게 되어 있다. **메모리 메트릭을 다시 넣지 말 것** — 이유는 [decisions.md](decisions.md).

### 9. 이체 결과 미확정 (`BurtyTransferResultUnknown`)

인프라 문제가 아니다. 앱 레포 런북의 이체 정산 절차를 따른다. 인프라 쪽에서 확인할 것은
오픈뱅킹 egress 가 막히지 않았는지다.

```bash
kubectl -n burty-prod exec deploy/burty-api -c istio-proxy -- \
  curl -s -o /dev/null -w '%{http_code}\n' https://testapi.openbanking.or.kr
istioctl proxy-config cluster deploy/burty-api.burty-prod | grep openbanking
```

## DB 백업 / 복구

1차는 RDS 자동 백업(PITR). 2차 논리 덤프는 CronJob `burty-db-backup` 이 매일 03:20 KST 에
S3 로 올린다.

```bash
kubectl -n burty-prod get cronjob burty-db-backup
kubectl -n burty-prod create job --from=cronjob/burty-db-backup manual-$(date +%s)

# 복구
aws s3 cp s3://<버킷>/mariadb/burty_burty_YYYYMMDD_HHMMSS.sql.gz .
gunzip -c burty_*.sql.gz | mariadb -h <RDS> -u <user> -p burty
```

보존은 S3 Lifecycle 로 건다.

> 검증되지 않은 백업은 백업이 아니다. 분기 1회 복구 리허설을 돈다.
