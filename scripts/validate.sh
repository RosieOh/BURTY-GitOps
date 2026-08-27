#!/usr/bin/env bash
# 로컬 매니페스트 검증 — CI(.github/workflows/validate.yml)와 같은 검사를 돌린다.
#
#   ./scripts/validate.sh
#
# 필요: kustomize, kubeconform (없으면 해당 단계를 건너뛰고 경고만 남긴다)

set -euo pipefail
cd "$(dirname "$0")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
fail=0

step() { printf '\n%s==> %s%s\n' "$YEL" "$1" "$RST"; }

step "kustomize build"
if ! command -v kustomize >/dev/null; then
  echo "${YEL}kustomize 없음 — 건너뜀 (brew install kustomize)${RST}"
else
  mkdir -p .rendered
  for overlay in k8s/overlays/dev k8s/overlays/prod k8s/platform; do
    out=".rendered/$(basename "$overlay").yaml"
    if kustomize build "$overlay" > "$out"; then
      printf '  %s✓%s %-22s → %s (%s docs)\n' "$GRN" "$RST" "$overlay" "$out" \
        "$(grep -c '^kind:' "$out" || true)"
    else
      printf '  %s✗%s %s\n' "$RED" "$RST" "$overlay"; fail=1
    fi
  done
fi

step "kubeconform"
if ! command -v kubeconform >/dev/null; then
  echo "${YEL}kubeconform 없음 — 건너뜀 (brew install kubeconform)${RST}"
elif [ -d .rendered ]; then
  for f in .rendered/*.yaml; do
    # CRD(Istio/cert-manager/Prometheus Operator/ESO)는 기본 스키마에 없다 → 카탈로그 추가
    kubeconform -strict -summary -verbose=false \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      -skip CustomResourceDefinition \
      "$f" || fail=1
  done
fi

step "평문 Secret 커밋 방지"
if grep -rn --include='*.yaml' -E '^\s*(JWT_SECRET|DB_PASSWORD|BURTY_FIELD_ENCRYPTION_KEY|OPENAI_API_KEY):' k8s/ \
   | grep -vE 'REPLACE|dev-only|secretKeyRef|configMapKeyRef|k8s/overlays/dev/|:\s*""\s*$'; then
  printf '  %s✗%s 실제 시크릿으로 보이는 값이 있습니다\n' "$RED" "$RST"; fail=1
else
  printf '  %s✓%s 평문 시크릿 없음\n' "$GRN" "$RST"
fi

step "prod 이미지 태그 불변성"
if grep -qE 'newTag:\s*(latest|main|develop)\s*$' k8s/overlays/prod/kustomization.yaml; then
  printf '  %s✗%s prod 에 floating 태그가 있습니다\n' "$RED" "$RST"; fail=1
else
  printf '  %s✓%s 불변 태그\n' "$GRN" "$RST"
fi

step "미치환 placeholder"
grep -rn 'REPLACE' k8s/ | sed 's/^/  - /' || echo "  없음"

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '%s검증 통과%s\n' "$GRN" "$RST"
else
  printf '%s검증 실패%s\n' "$RED" "$RST"; exit 1
fi
