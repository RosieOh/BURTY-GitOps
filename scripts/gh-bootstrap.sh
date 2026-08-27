#!/usr/bin/env bash
# GitHub 레포 부트스트랩 — 레포 생성, 라벨, 마일스톤, 이슈, 프로젝트, PR.
#
#   gh auth login            # 최초 1회 (브라우저 필요)
#   ./scripts/gh-bootstrap.sh all
#
# 개별 실행:
#   ./scripts/gh-bootstrap.sh repo|labels|milestones|issues|project|pr
#
# 전부 멱등하게 만들었다. 두 번 돌려도 중복 생성되지 않는다.

set -euo pipefail
cd "$(dirname "$0")/.."

OWNER="${GITOPS_OWNER:-RosieOh}"
REPO="${GITOPS_REPO_NAME:-BURTY-GitOps}"
SLUG="$OWNER/$REPO"
VIS="${GITOPS_VISIBILITY:-private}"
PROJECT_TITLE="BURTY 인프라 전환"

log()  { printf '\n\033[33m==> %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s (이미 존재)\n' "$1"; }

require_auth() {
  gh auth status >/dev/null 2>&1 || {
    echo "gh 로그인이 필요합니다: gh auth login" >&2
    exit 1
  }
}

# ── 레포 ────────────────────────────────────────────────────────────────────
cmd_repo() {
  log "레포 생성 ($SLUG, $VIS)"
  if gh repo view "$SLUG" >/dev/null 2>&1; then
    skip "$SLUG"
  else
    gh repo create "$SLUG" --"$VIS" \
      --description "BURTY 배포 인프라 — Kubernetes / Istio / ArgoCD / Jenkins GitOps" \
      --disable-wiki
    ok "$SLUG 생성"
  fi

  git remote get-url origin >/dev/null 2>&1 \
    && git remote set-url origin "https://github.com/$SLUG.git" \
    || git remote add origin "https://github.com/$SLUG.git"

  git push -u origin main
  ok "main 푸시"

  # 매니페스트 검증이 통과해야 병합되도록 강제. private 레포는 플랜에 따라 실패할 수 있어 무시한다.
  gh api -X PUT "repos/$SLUG/branches/main/protection" \
    -H "Accept: application/vnd.github+json" \
    -f 'required_status_checks[strict]=true' \
    -f 'required_status_checks[contexts][]=매니페스트 검증' \
    -f 'required_status_checks[contexts][]=정책 검사' \
    -F 'enforce_admins=false' \
    -F 'required_pull_request_reviews[required_approving_review_count]=1' \
    -F 'restrictions=null' >/dev/null 2>&1 \
    && ok "main 브랜치 보호 설정" \
    || echo "  · 브랜치 보호 실패 (private 레포 플랜 제한일 수 있음 — 수동 설정 필요)"
}

# ── 라벨 ────────────────────────────────────────────────────────────────────
cmd_labels() {
  log "라벨 생성"
  python3 - <<'PY' | while IFS=$'\t' read -r name color desc; do
import re, pathlib
txt = pathlib.Path('.github/labels.yml').read_text()
cur = {}
for line in txt.splitlines():
    line = line.rstrip()
    if line.startswith('- name:'):
        if cur: print(f"{cur.get('name','')}\t{cur.get('color','')}\t{cur.get('description','')}")
        cur = {'name': line.split(':',1)[1].strip().strip('"')}
    elif line.strip().startswith('color:'):
        cur['color'] = line.split(':',1)[1].strip().strip('"')
    elif line.strip().startswith('description:'):
        cur['description'] = line.split(':',1)[1].strip().strip('"')
if cur: print(f"{cur.get('name','')}\t{cur.get('color','')}\t{cur.get('description','')}")
PY
    if [ -z "$name" ]; then continue; fi
    if gh label create "$name" --repo "$SLUG" --color "$color" --description "$desc" >/dev/null 2>&1; then
      ok "$name"
    else
      gh label edit "$name" --repo "$SLUG" --color "$color" --description "$desc" >/dev/null 2>&1 \
        && skip "$name" || true
    fi
  done
}

# ── 마일스톤 ────────────────────────────────────────────────────────────────
milestone_number() {
  gh api "repos/$SLUG/milestones?state=all" --jq \
    ".[] | select(.title == \"$1\") | .number" 2>/dev/null | head -1
}

cmd_milestones() {
  log "마일스톤 생성"
  # 순서가 곧 전환 순서다. 앞 단계가 끝나야 다음이 의미가 있다.
  while IFS='|' read -r title due desc; do
    if [ -z "$title" ]; then continue; fi
    if [ -n "$(milestone_number "$title")" ]; then
      skip "$title"
    else
      gh api -X POST "repos/$SLUG/milestones" \
        -f title="$title" -f description="$desc" -f due_on="$due" >/dev/null
      ok "$title"
    fi
  done <<'EOF'
M1 클러스터 부트스트랩|2026-09-12T00:00:00Z|Istio·cert-manager·ArgoCD·관측 스택 설치와 placeholder 치환. 앱을 올리기 전 단계.
M2 dev 전환|2026-09-26T00:00:00Z|burty-dev 네임스페이스로 앱을 올리고 스모크·부하 검증.
M3 prod 전환|2026-10-17T00:00:00Z|DNS 전환과 EC2 compose 스택 폐기. 롤백 계획 포함.
M4 운영 안정화|2026-11-14T00:00:00Z|per-IP rate limit, S3 업로드 전환, PSA restricted, DR 훈련.
EOF
}

# ── 이슈 ────────────────────────────────────────────────────────────────────
issue_exists() {
  gh issue list --repo "$SLUG" --state all --search "$1 in:title" --json title \
    --jq '.[].title' 2>/dev/null | grep -Fqx "$1"
}

create_issue() {
  local title="$1" milestone="$2" labels="$3" body="$4"
  if issue_exists "$title"; then skip "$title"; return; fi
  gh issue create --repo "$SLUG" \
    --title "$title" \
    --milestone "$milestone" \
    --label "$labels" \
    --body "$body" >/dev/null
  ok "$title"
}

cmd_issues() {
  log "이슈 생성"

  create_issue "CHORE: 매니페스트 placeholder 를 실제 값으로 치환" \
    "M1 클러스터 부트스트랩" "type:chore,env:platform,priority:P0,blocked" \
'무엇: `REPLACE` 로 남아 있는 값 전부를 실제 값으로 치환한다.

- [ ] 이미지 레지스트리 (`ghcr.io/rosieoh/burty-api`)
- [ ] RDS / ElastiCache 엔드포인트 (`k8s/overlays/prod/external-datastores.yaml`, Secret 의 `DB_HOST`/`REDIS_HOST`)
- [ ] RWX StorageClass (`uploads-pvc.yaml`, `jenkins.yaml`)
- [ ] ACME 이메일 · Route53 hosted zone (`clusterissuer.yaml`)
- [ ] S3 버킷 3종 (loki, tempo, db-backup) + IRSA role ARN
- [ ] ArgoCD 서버 주소 (`Jenkinsfile`, 앱 레포)

왜: 이 값들이 채워지기 전에는 어떤 환경에도 배포할 수 없다. 전환의 선행 조건이다.

확인: `./scripts/validate.sh` 의 "미치환 placeholder" 목록이 비어야 한다.

Refs: README 의 placeholder 표'

  create_issue "CHORE: 운영도구 노출 CIDR 을 사내 대역으로 좁히기" \
    "M1 클러스터 부트스트랩" "type:chore,area:security,env:platform,priority:P0" \
'무엇: `k8s/platform/platform-ingress.yaml` 의 `notRemoteIpBlocks` 를 실제 VPC/VPN 대역으로 교체한다.

현재 값은 예시(`10.0.0.0/8`, `192.168.0.0/16`)라 사실상 사내 전체에 열려 있다.

왜: Grafana·ArgoCD·Jenkins 가 그대로 노출되면 배포 파이프라인 장악으로 직결된다.
ArgoCD 는 클러스터 전체에 대한 쓰기 권한을 가진 주체다.

추가 검토:
- [ ] 소스 IP 가 실제로 보이는지 확인 (NLB proxy-protocol 또는 `externalTrafficPolicy: Local`)
- [ ] IP 허용목록 대신 oauth2-proxy(OIDC) 를 앞단에 둘지 결정'

  create_issue "FEAT: External Secrets 로 prod 시크릿 반입 구성" \
    "M1 클러스터 부트스트랩" "type:feat,area:security,env:prod,priority:P1" \
'무엇: AWS Secrets Manager 에 `burty/prod/app` 키로 시크릿 JSON 을 넣고, ESO 가 `burty-secret` 을 만들게 한다.

- [ ] External Secrets Operator 설치
- [ ] IRSA 역할 생성 (`secretsmanager:GetSecretValue` 만)
- [ ] Secrets Manager 에 값 등록 (키 이름은 `k8s/base/secret.example.yaml` 과 일치해야 함)
- [ ] `kubectl -n burty-prod get externalsecret` 이 `SecretSynced` 인지 확인

왜: 지금은 `kubectl create secret --from-env-file` 수동 부트스트랩이라 로테이션이 반영되지 않고,
누가 언제 무엇을 넣었는지 추적되지 않는다.

주의: `ProdStartupValidator` 가 stub/기본 시크릿이면 기동을 막는다. 값이 비면 파드가 뜨지 않는다.'

  create_issue "FEAT: dev 네임스페이스 전환 및 스모크 검증" \
    "M2 dev 전환" "type:feat,area:k8s,env:dev,priority:P1,migration" \
'무엇: `burty-dev` 에 앱을 올리고 실제로 동작하는지 확인한다.

- [ ] `argocd app sync burty-dev` → Healthy
- [ ] `https://dev.burty.co.kr/health` 200 + `"status":"UP"`
- [ ] `/actuator/prometheus` 가 외부에서 404
- [ ] Grafana 에 JVM/HTTP 메트릭이 보임 (15020 병합 스크랩 확인)
- [ ] Loki 에 로그가 보임 (stdout 수집)
- [ ] Flyway 마이그레이션이 in-cluster MariaDB 에 적용됨
- [ ] 소셜 로그인 스텁 모드로 로그인 왕복

왜: prod 전환 전에 프로브·mTLS·라우팅·관측이 실제로 도는지 한 번은 확인해야 한다.
매니페스트가 렌더링된다는 것과 동작한다는 것은 다르다.'

  create_issue "FEAT: 프론트엔드 배포 매니페스트 추가" \
    "M2 dev 전환" "type:feat,area:k8s,priority:P2" \
'무엇: VirtualService 의 catch-all(`/`) 이 `frontend` 서비스로 가는데 그 워크로드가 아직 없다.

- [ ] frontend Deployment/Service 추가
- [ ] `allow-ingressgateway-frontend` AuthorizationPolicy 가 실제로 매칭되는지 확인
      (base 의 `allow-nothing` 이 네임스페이스 기본 거부라 정책 없으면 게이트웨이도 막힌다)

왜: 지금 상태로는 `/` 요청이 503 이다. compose 구성에서 502 였던 것과 같은 상황이다.'

  create_issue "FEAT: prod 전환 및 DNS 컷오버" \
    "M3 prod 전환" "type:feat,env:prod,priority:P0,migration,breaking" \
'무엇: `burty.co.kr` 을 EC2 compose 스택에서 Istio 인그레스로 넘긴다.

절차:
- [ ] prod 파드를 띄우고 게이트웨이 IP 로 직접 스모크 (hosts 파일 오버라이드)
- [ ] DNS TTL 을 60s 로 미리 낮춤 (컷오버 최소 24h 전)
- [ ] 인증서 발급 확인 (`kubectl -n istio-system get certificate`)
- [ ] DNS 를 NLB 로 전환
- [ ] 10분 관찰: 5xx 비율, p95, 서킷브레이커, 이체 성공률
- [ ] EC2 compose 스택은 **최소 1주 유지** 후 폐기

롤백: DNS 를 EC2 로 되돌린다. TTL 60s 라 수 분 내 복귀. 그래서 compose 스택을 바로 내리지 않는다.

주의: 진행 중인 이체가 있는 시간대를 피한다. 야간 이체 차단 구간(23:00~06:00) 직후가 무난하다.'

  create_issue "FEAT: Istio 카나리 배포 구성" \
    "M3 prod 전환" "type:feat,area:istio,env:prod,priority:P2" \
'무엇: DestinationRule 에 `stable`/`canary` subset 은 선언돼 있는데 아무도 쓰지 않는다.
가중치 기반 카나리를 kustomize component 로 만들어 opt-in 하게 한다.

- [ ] `k8s/components/canary/` 컴포넌트 추가
- [ ] prod overlay 에서 주석 해제만으로 활성화되게
- [ ] 카나리 파드 전용 알람 (5xx 비율을 stable 과 비교)

왜: 지금은 롤링 업데이트뿐이라 나쁜 빌드가 전량에 즉시 노출된다. 금융 API 에서는
5% 로 먼저 흘려보고 판단할 수 있어야 한다.'

  create_issue "FEAT: per-IP rate limit 도입" \
    "M4 운영 안정화" "type:feat,area:istio,area:security,priority:P1,migration" \
'무엇: 현재 `k8s/base/istio/ratelimit.yaml` 은 Envoy **local** rate limit 이라
게이트웨이 파드당 전역 버킷이다. nginx 의 `limit_req_zone $binary_remote_addr` 와 의미가 다르다.

- [ ] `envoyproxy/ratelimit` + Redis 배포
- [ ] descriptor 에 `remote_address` 포함
- [ ] 게이트웨이가 실제 클라이언트 IP 를 보는지 확인 (proxy-protocol)
- [ ] 기존 local rate limit 은 2차 방어선으로 유지할지 결정

왜: 게이트웨이가 N대면 실질 한도가 N배가 된다. 크리덴셜 스터핑 방어로는 부족하다.

Refs: README "Rate limit" 절'

  create_issue "FEAT: 업로드 저장소를 S3 로 전환" \
    "M4 운영 안정화" "type:feat,area:storage,priority:P1" \
'무엇: `file.storage.upload-dir` 이 로컬 파일시스템이라 다중 replica 에서 RWX PVC(EFS)가 필요하다.

- [ ] `FileUtil` / `FileStorageProperties` 에 S3 어댑터 추가 (앱 레포 작업)
- [ ] 기존 업로드 파일 마이그레이션
- [ ] `uploads-pvc.yaml` 제거, Deployment 의 volume 을 emptyDir 로 되돌림

왜: RWX PVC 는 지연·비용·정합성 전부에서 임시방편이다. 계약서 PDF 같은 파일이
파드 로컬 경로에 묶여 있으면 스케일아웃과 노드 교체가 계속 발목을 잡는다.'

  create_issue "CHORE: Istio CNI 전환하여 PSA restricted 적용" \
    "M4 운영 안정화" "type:chore,area:security,priority:P2" \
'무엇: `burty-prod` 네임스페이스가 PodSecurity `baseline` 이다. `restricted` 로 올리고 싶지만
`istio-init` 이 NET_ADMIN/NET_RAW 를 요구해 사이드카 주입이 거부된다.

- [ ] Istio CNI 플러그인 도입 (또는 ambient 모드 검토)
- [ ] `pod-security.kubernetes.io/enforce: restricted` 로 상향
- [ ] jenkins 네임스페이스는 kaniko(root) 때문에 별도 판단 — buildah rootless 검토

왜: 앱 컨테이너 자체는 이미 restricted 를 만족한다(non-root, no-privilege, seccomp,
readOnlyRootFilesystem). 사이드카 주입 방식 때문에만 한 단계 낮게 운영 중이다.'

  create_issue "CHORE: 백업 복구 리허설 절차 수립" \
    "M4 운영 안정화" "type:chore,area:storage,env:prod,priority:P1" \
'무엇: `burty-db-backup` CronJob 이 S3 에 덤프를 올리지만, 복구를 한 번도 해본 적이 없다.

- [ ] 스테이징 RDS 에 최신 덤프 복원
- [ ] Flyway `validate` 통과 확인
- [ ] 복구 소요 시간 측정 → RTO 문서화
- [ ] 분기 1회 리허설을 런북에 고정

왜: 검증되지 않은 백업은 백업이 아니다. 개인 금융정보를 다루는 서비스에서
복구 불가는 서비스 중단이 아니라 사고다.'
}

# ── 프로젝트 (Projects v2) ──────────────────────────────────────────────────
cmd_project() {
  log "프로젝트 생성 및 이슈 연결"
  local num
  num=$(gh project list --owner "$OWNER" --format json \
        --jq ".projects[] | select(.title == \"$PROJECT_TITLE\") | .number" 2>/dev/null | head -1)

  if [ -z "$num" ]; then
    num=$(gh project create --owner "$OWNER" --title "$PROJECT_TITLE" --format json --jq '.number')
    ok "프로젝트 #$num 생성"
  else
    skip "프로젝트 #$num"
  fi

  # 이 레포의 모든 이슈를 프로젝트에 넣는다.
  gh issue list --repo "$SLUG" --state all --limit 100 --json url --jq '.[].url' \
  | while read -r url; do
      gh project item-add "$num" --owner "$OWNER" --url "$url" >/dev/null 2>&1 \
        && ok "추가: $url" || skip "$url"
    done

  echo
  echo "  Status 필드(Todo/In Progress/Done)와 뷰 구성은 웹에서:"
  echo "  https://github.com/users/$OWNER/projects/$num"
}

# ── PR ──────────────────────────────────────────────────────────────────────
cmd_pr() {
  log "PR 생성"
  local branch="feat/canary-rollout"

  git rev-parse --verify "$branch" >/dev/null 2>&1 || {
    echo "  브랜치 $branch 가 없습니다. 먼저 생성·커밋하세요." >&2
    return 1
  }

  git push -u origin "$branch"

  local issue
  issue=$(gh issue list --repo "$SLUG" --state all \
          --search "Istio 카나리 배포 구성 in:title" --json number --jq '.[0].number')

  if gh pr view "$branch" --repo "$SLUG" >/dev/null 2>&1; then
    skip "PR ($branch)"
    return
  fi

  gh pr create --repo "$SLUG" \
    --base main --head "$branch" \
    --title "FEAT: Istio 카나리 배포 컴포넌트 추가" \
    --label "type:feat,area:istio,env:prod,priority:P2" \
    --milestone "M3 prod 전환" \
    --body "$(cat <<PRBODY
<!-- 커밋·이슈 연동 규칙: .github/COMMIT_MESSAGE_ISSUES.md -->

## 🏫 PR 타입
- [x] FEAT (✨) 기능 추가

## 🏫 관련 이슈
Closes #${issue}

## 🏫 대상 환경
- [x] prod (\`k8s/overlays/prod\`) — **opt-in. 이 PR 만으로는 동작이 바뀌지 않는다.**

## 🏫 변경 사항

DestinationRule 에 \`stable\`/\`canary\` subset 이 선언돼 있는데 쓰는 곳이 없었다.
가중치 카나리를 kustomize component 로 추가한다.

- \`k8s/components/canary/\` — 카나리 Deployment + VirtualService 가중치 패치
- \`k8s/base/istio/destinationrule.yaml\` — subset 주석에 사용처 명시
- prod overlay 는 \`components:\` 를 **주석 처리된 상태로** 둔다

## 🏫 렌더링 diff

컴포넌트를 켜지 않았으므로 \`kustomize build k8s/overlays/prod\` 출력은 변하지 않는다.

\`\`\`bash
# 활성화했을 때의 diff 확인 — prod kustomization 의 components 주석을 해제한 뒤
kustomize build k8s/overlays/prod > /tmp/after.yaml
git stash && kustomize build k8s/overlays/prod > /tmp/before.yaml && git stash pop
diff -u /tmp/before.yaml /tmp/after.yaml
\`\`\`

활성화 시 추가되는 것: Deployment \`burty-api-canary\` 1개, VirtualService 의
auth/docs/health 라우트에 \`subset: stable\` 명시, api 라우트가 95/5 가중치로 분리.

## 🏫 배포 영향
- [ ] 파드 재시작이 발생한다
- [x] 무중단이다 — 이 PR 은 렌더링 결과를 바꾸지 않는다

## 🏫 롤백 절차

prod overlay 의 \`components:\` 줄을 다시 주석 처리하고 sync. 카나리 Deployment 가 prune 된다.
트래픽은 \`stable\` subset 으로 100% 돌아간다.

## 🏫 To Reviewer

- VirtualService 패치가 **인덱스 기반**(JSON6902 \`/http/2\`)이다. base 의 라우트 순서를
  바꾸면 조용히 엉뚱한 라우트를 건드린다. 라우트 추가 시 이 패치를 같이 봐야 한다.
- 카나리에도 \`auth-ratelimited\` 라우트를 흘릴지는 열어 뒀다. 인증 경로는 stable 고정이
  안전하다고 판단했는데, 이견 있으면 알려 주세요.
PRBODY
)"
  ok "PR 생성"
}

# ── 엔트리포인트 ────────────────────────────────────────────────────────────
require_auth
case "${1:-all}" in
  repo)       cmd_repo ;;
  labels)     cmd_labels ;;
  milestones) cmd_milestones ;;
  issues)     cmd_issues ;;
  project)    cmd_project ;;
  pr)         cmd_pr ;;
  all)        cmd_repo; cmd_labels; cmd_milestones; cmd_issues; cmd_project; cmd_pr ;;
  *)          echo "사용법: $0 [all|repo|labels|milestones|issues|project|pr]" >&2; exit 1 ;;
esac

printf '\n\033[32m완료\033[0m — https://github.com/%s\n' "$SLUG"
