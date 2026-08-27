# BURTY GitOps

BURTY 배포 인프라의 단일 진실 공급원. **클러스터에 떠 있는 것의 정의는 전부 여기 있다.**

`docker compose` + `global-nginx` + `Jenkins가 직접 배포` 구성을 Kubernetes + Istio + ArgoCD로
옮긴 매니페스트다.

## 두 레포의 역할

| 레포 | 소유하는 것 |
|---|---|
| [FINNECT-BURTY/BURTY_Interface_V2](https://github.com/FINNECT-BURTY/BURTY_Interface_V2) | 애플리케이션 코드, `Dockerfile`, `Jenkinsfile` |
| **이 레포** | K8s 매니페스트, Istio 정책, ArgoCD 정의, 플랫폼 Helm values |

흐름은 한 방향이다.

```
앱 레포 push
  → Jenkins: 테스트 → 이미지 빌드(kaniko) → Trivy 스캔 → GHCR push
  → Jenkins: 이 레포의 overlays/<env>/kustomization.yaml 이미지 태그 커밋
  → ArgoCD: 이 레포를 보고 클러스터에 반영
```

**사람이 `kubectl apply` 하거나 `newTag` 를 손으로 고치지 않는다.** 클러스터를 직접 고치면
ArgoCD가 되돌린다(dev는 selfHeal 켜짐). 롤백도 여기서 한다 — `argocd app rollback` 또는 revert.

## 무엇이 무엇을 대체했나

| 기존 | 대체 | 비고 |
|---|---|---|
| `docker-compose.yml` (burty 서비스) | `base/deployment.yaml`, `base/service.yaml` | env → ConfigMap/Secret 분리 |
| `infra/global-nginx/nginx.conf` server 블록 | `base/istio/gateway.yaml` | TLS 종단, HTTP→HTTPS 리다이렉트 |
| nginx `location` 블록 | `base/istio/virtualservice.yaml` | ⚠️ nginx는 최장일치, Istio는 **위에서 첫 매치** |
| nginx `limit_req_zone` | `base/istio/ratelimit.yaml` | per-IP → per-gateway. 의미가 다름(아래 참고) |
| nginx `location /actuator/ { return 404; }` | VirtualService `directResponse` + `AuthorizationPolicy` | L7 정책으로 승격 |
| `certbot` 컨테이너 + 12h renew 루프 | `platform/clusterissuer.yaml`, `platform/certificates.yaml` | cert-manager. reload 불필요 |
| `upstream burty_backend` | `base/istio/destinationrule.yaml` | 커넥션 풀 + outlier detection 추가 |
| compose `healthcheck` | `livenessProbe` / `readinessProbe` / `startupProbe` | 아래 "프로브 설계" 참고 |
| `prometheus.yml` static_configs | `base/observability/podmonitor.yaml` | 서비스 디스커버리 |
| `promtail-config.yml` (파일 tail) | `platform/values/promtail-values.yaml` | stdout 수집(DaemonSet) |
| Grafana provisioning + dashboards | kube-prometheus-stack sidecar + `base/observability/dashboards/` | 대시보드 JSON 원본 유지 |
| `otel-collector-config.yml` | `platform/values/otel-collector-values.yaml` | exporter를 logging → Tempo로 |
| `Jenkinsfile` (compose up -d) | `Jenkinsfile` (빌드/스캔/태그 커밋) + ArgoCD | 기존 파일은 `Jenkinsfile.compose`로 보존 |
| EC2 Jenkins (8081) | `platform/jenkins.yaml` + `platform/values/jenkins-values.yaml` | 에이전트가 파드로 뜨고 죽음 |
| `alert-rules.yml` | `base/observability/prometheusrule.yaml` | 이체/아웃박스/마이데이터 알람 전부 이식 |
| `infra/scripts/backup-mariadb.sh` | `overlays/prod/backup-cronjob.yaml` | 덤프 → S3. 1차 백업은 RDS PITR |
| `conf.d/grafana.conf` (서브패스) | `platform/platform-ingress.yaml` | 서브도메인 + 소스 IP 허용목록 |
| Jenkins credential `.env` 파일 | `overlays/prod/externalsecret.yaml` | AWS Secrets Manager → ESO |
| `docker-compose.local.yml` MariaDB/Redis | `overlays/dev/{mariadb,redis}.yaml` | dev만. prod는 RDS/ElastiCache |
| `.env` (Jenkins credential file) | Secret (SealedSecrets / External Secrets) | `base/secret.example.yaml` 참고 |

## 디렉터리

```
.
├── k8s/
│   ├── base/                 앱 공통 — Deployment/Service/HPA/PDB/NetworkPolicy
│   │   ├── istio/            Gateway·VirtualService·DestinationRule·mTLS·AuthZ·RateLimit
│   │   └── observability/    PodMonitor·PrometheusRule·Grafana 대시보드
│   ├── overlays/
│   │   ├── dev/              burty-dev — in-cluster MariaDB/Redis, replicas=1, HPA/PDB 없음
│   │   └── prod/             burty-prod — 외부 RDS/ElastiCache, HPA, RWX 업로드 PVC, 백업 CronJob
│   ├── platform/             cert-manager·게이트웨이·운영도구 노출·Jenkins 부속
│   │   └── values/           istiod, istio-gateway, kube-prometheus-stack, loki, promtail, otel, tempo, jenkins
│   └── argocd/               AppProject + Application(dev/prod/platform)
├── docs/                     전환 가이드, 클러스터 런북
├── scripts/                  gh 부트스트랩, 로컬 검증
└── .github/                  검증 워크플로, 이슈·PR 템플릿, 라벨 정의
```

## 로컬 검증

```bash
./scripts/validate.sh          # kustomize build + kubeconform + 정책 검사
```

PR 을 열면 같은 검사가 `.github/workflows/validate.yml` 로 자동 실행된다.

## GitHub 부트스트랩

레포·라벨·마일스톤·이슈·프로젝트·PR 을 한 번에 만든다. 멱등하므로 다시 돌려도 안전하다.

```bash
gh auth login                  # 최초 1회 (브라우저 필요)
./scripts/gh-bootstrap.sh all

# 개별 실행
./scripts/gh-bootstrap.sh labels
./scripts/gh-bootstrap.sh issues
```

기본값은 `RosieOh/BURTY-GitOps`, private. 바꾸려면 환경변수로:
`GITOPS_OWNER`, `GITOPS_REPO_NAME`, `GITOPS_VISIBILITY`.

전환 진행 상황은 [docs/migration-checklist.md](docs/migration-checklist.md) 를 따라간다.

## 최초 설치 순서

순서를 지킬 것. 사이드카 주입은 **네임스페이스 라벨이 먼저** 붙어야 동작한다.

```bash
# 1) 플랫폼 컴포넌트
helm repo add istio https://istio-release.storage.googleapis.com/charts
kubectl create namespace istio-system
helm upgrade --install istio-base istio/base -n istio-system
helm upgrade --install istiod istio/istiod -n istio-system -f k8s/platform/values/istiod-values.yaml
helm upgrade --install istio-ingressgateway istio/gateway -n istio-system \
  -f k8s/platform/values/istio-gateway-values.yaml

helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager \
  --create-namespace --set crds.enabled=true

kubectl create namespace observability
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability -f k8s/platform/values/kube-prometheus-stack-values.yaml
helm upgrade --install loki grafana/loki -n observability -f k8s/platform/values/loki-values.yaml
helm upgrade --install promtail grafana/promtail -n observability -f k8s/platform/values/promtail-values.yaml
helm upgrade --install tempo grafana/tempo -n observability -f k8s/platform/values/tempo-values.yaml
helm upgrade --install opentelemetry-collector open-telemetry/opentelemetry-collector \
  -n observability -f k8s/platform/values/otel-collector-values.yaml

# 시크릿 반입 (ESO 를 쓸 경우)
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

# Jenkins
helm upgrade --install jenkins jenkins/jenkins -n jenkins -f k8s/platform/values/jenkins-values.yaml

# 2) ArgoCD
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace
kubectl apply -f k8s/argocd/project.yaml
kubectl apply -f k8s/argocd/application-platform.yaml
kubectl apply -f k8s/argocd/application-dev.yaml
kubectl apply -f k8s/argocd/application-prod.yaml

# 3) prod Secret — Git 에 없다.
#    ESO 를 쓰면 overlays/prod/externalsecret.yaml 이 AWS Secrets Manager 에서 자동 반입한다
#    (Secrets Manager 에 `burty/prod/app` 키로 JSON 한 덩어리를 넣어 둘 것).
#    ESO 를 안 쓴다면 kustomization 에서 externalsecret.yaml 을 빼고 수동 생성:
kubectl create namespace burty-prod
kubectl -n burty-prod create secret generic burty-secret --from-env-file=.env.prod

# Jenkins 가 이미지를 푸시하려면 레지스트리 자격증명이 필요하다
kubectl -n jenkins create secret docker-registry ghcr-docker-config \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<PAT>

# 4) 첫 sync
argocd app sync burty-platform && argocd app sync burty-dev
```

## 반드시 바꿔야 하는 placeholder

| 위치 | 값 |
|---|---|
| `base/kustomization.yaml`, `overlays/*/kustomization.yaml` | `ghcr.io/finnect-burty/burty-api` → 실제 레지스트리 |
| `overlays/prod/kustomization.yaml` | `newTag: REPLACE-BY-JENKINS` (첫 배포 전 수동 1회) |
| `overlays/prod/external-datastores.yaml` | RDS / ElastiCache 엔드포인트 |
| `overlays/prod/uploads-pvc.yaml` | `storageClassName: efs-sc` |
| `platform/clusterissuer.yaml` | ACME 이메일, Route53 hosted zone |
| `platform/values/loki-values.yaml` | S3 버킷명 |
| `argocd/*.yaml` | `repoURL`, `ARGOCD_SERVER` |
| `Jenkinsfile` | `IMAGE_REPO`, `GITOPS_REPO`, `ARGOCD_SERVER` |
| `overlays/prod/backup-cronjob.yaml` | S3 버킷명, IRSA role ARN |
| `overlays/prod/externalsecret.yaml` | IRSA role ARN, Secrets Manager 키 경로 |
| `platform/platform-ingress.yaml` | 사내/VPN CIDR (기본값은 예시다 — 반드시 좁힐 것) |
| `platform/jenkins.yaml` | RWX `storageClassName` |
| `platform/values/tempo-values.yaml` | S3 버킷, IRSA role ARN |

## 설계 결정과 함정

왜 이렇게 했는지, 무엇을 건드리면 조용히 깨지는지는 [docs/decisions.md](docs/decisions.md) 에 정리했다.
**매니페스트를 고치기 전에 한 번은 읽을 것.** 특히 프로브 설계, rate limit 의미 차이,
mTLS 와 Prometheus 스크랩, PodSecurity 수준은 되돌리기 쉬운 실수를 부른다.

## 롤백

```bash
argocd app history burty-prod
argocd app rollback burty-prod <REVISION>
# 또는 Git에서 이미지 태그 커밋을 revert (권장 — Git이 진실 공급원)
```

## 검증

```bash
kustomize build k8s/overlays/dev  | kubectl apply --dry-run=server -f -
kustomize build k8s/overlays/prod | kubectl apply --dry-run=server -f -
istioctl analyze -n burty-prod
istioctl proxy-config route deploy/istio-ingressgateway.istio-system   # 라우트 순서 확인
```
