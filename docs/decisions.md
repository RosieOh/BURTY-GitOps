# 설계 결정 기록

compose 구성을 그대로 옮기지 않고 다르게 만든 지점들. 각 항목은 "무엇을 바꿨나"가 아니라
**"왜 그렇게 했고, 되돌리면 무슨 일이 생기나"** 를 남긴다.

**프로브** — liveness/readiness 모두 DB를 보지 않는다(`/actuator/health/{liveness,readiness}`).
DB가 흔들릴 때 readiness에 DB를 물리면 전 파드가 동시에 endpoint에서 빠져 503이 아니라 연결
거부가 되고, liveness에 물리면 전 파드가 동시에 재시작한다. 어느 쪽도 DB 장애를 고치지 못하고
장애만 증폭시킨다. DB 상태는 `/health`(커스텀 컨트롤러)와 `BurtyDbConnectionPoolExhausted` 알림으로 본다.

**Rate limit** — nginx는 `$binary_remote_addr` 기준 per-IP였지만, `ratelimit.yaml`의 Envoy
local rate limit은 **게이트웨이 파드당 전역 버킷**이다. 게이트웨이가 2대면 실질 한도가 2배가 된다.
per-IP가 필요하면 `envoyproxy/ratelimit` + Redis를 배포하고 descriptor에 `remote_address`를 넣어야 한다.
지금 것은 크리덴셜 스터핑 완화용 1차 방어선이다.

**mTLS STRICT + Prometheus** — 사이드카 없는 Prometheus가 8080을 직접 긁으면 전부 거부된다.
그래서 파드에 `prometheus.io/*` 애노테이션을 달아 Istio가 앱 메트릭을 envoy 메트릭과 합쳐
**15020**에 평문 노출하게 하고, PodMonitor는 15020을 긁는다. `enablePrometheusMerge: true`를
끄면 JVM/HTTP 메트릭이 통째로 사라진다.

**AuthorizationPolicy allow-nothing** — 네임스페이스 전체 기본 거부다. 같은 네임스페이스에
frontend 등 다른 워크로드를 올리면 게이트웨이에서의 접근까지 막히므로, 그 워크로드용 ALLOW
정책을 반드시 함께 추가할 것.

**PodSecurity** — prod 네임스페이스는 `baseline`이다. `restricted`로 올리면 `istio-init`이
NET_ADMIN을 요구해 사이드카 주입이 거부된다. `restricted`를 쓰려면 Istio CNI 플러그인이나
ambient 모드로 먼저 전환해야 한다.

**배치/스케줄러 다중 replica** — 앱이 이미 ShedLock + `SELECT ... FOR UPDATE SKIP LOCKED`로
보호돼 있어 replicas를 늘려도 아웃박스/배치가 중복 실행되지 않는다. 그래서 HPA를 켤 수 있다.

**HPA는 CPU만 본다** — JVM은 `MaxRAMPercentage=75`만큼 힙을 잡고 GC 후에도 OS에 반환하지 않는다.
HPA의 memory utilization은 limits가 아니라 **requests** 기준이라, 부하와 무관하게 항상 100%를 넘겨
파드가 `maxReplicas`에 영구 고정된다. 메모리 압박은 `BurtyJvmHeapHigh` / `BurtyPodOOMKilled` 알람으로 잡는다.

**알람 중복** — dev/prod 양쪽에 같은 PrometheusRule이 배포된다. Prometheus의 룰 평가는 네임스페이스
스코프가 아니라서 그대로 두면 dev 장애로 운영 온콜이 깨어난다. kube-prometheus-stack values의
`enforcedNamespaceLabel: namespace`가 모든 expr에 namespace 매처를 자동 주입해 이걸 막는다.

**Job/CronJob과 사이드카** — 백업 CronJob은 `sidecar.istio.io/inject: "false"`다. 사이드카가 살아
있으면 Job이 Complete로 넘어가지 못하고 영원히 Running으로 남는다. K8s 1.29+ native sidecar를 쓰는
Istio 버전이면 불필요하다.

**업로드 디렉터리** — `file.storage.upload-dir`가 로컬 파일시스템이라 다중 replica에서
RWX PVC(EFS)가 필요하다. 중기적으로는 S3 어댑터로 옮기는 게 맞다. dev는 emptyDir다.

**로그** — logback의 FILE appender는 컨테이너 안 emptyDir로만 남는다(수집 경로 아님).
수집은 CONSOLE appender → stdout → Promtail → Loki다. `requestId`는 Loki 라벨이 아니라
structured metadata로 넣었다 — 라벨로 넣으면 인덱스 카디널리티가 폭발한다.


---

## 되돌리기 전에 확인할 것

아래는 "좋아 보이지만 넣으면 깨지는" 변경들이다. 이미 한 번씩 검토하고 뺀 것들이다.

| 하고 싶어지는 변경 | 결과 |
|---|---|
| HPA 에 메모리 메트릭 추가 | JVM 이 힙을 반환하지 않아 `maxReplicas` 에 영구 고정 |
| readiness 프로브에 DB 체크 추가 | DB 장애 시 전 파드가 동시에 endpoint 에서 빠짐 |
| prod 네임스페이스를 PSA `restricted` 로 | `istio-init` 의 NET_ADMIN 요구로 사이드카 주입 거부 |
| `enablePrometheusMerge: false` | 앱 메트릭(JVM/HTTP)이 통째로 사라짐 |
| PodMonitor 를 `port: http-envoy-prom` 으로 | envoy 메트릭만 잡히고 앱 메트릭 누락 (15020 이 아닌 15090) |
| prod overlay 에 `replicas:` 고정 | sync 마다 HPA 스케일아웃이 되돌려짐 |
| 백업 Job 에 사이드카 주입 | Job 이 Complete 로 넘어가지 못하고 영원히 Running |
| `commonLabels` 사용 | Deployment `spec.selector`(immutable) 오염 |
| VirtualService 라우트 순서 변경 | Istio 는 최장일치가 아니라 첫 매치 — 조용히 오라우팅 |
| dev overlay 에 PDB 유지 | replicas=1 이라 노드 드레인이 영구히 막힘 |
