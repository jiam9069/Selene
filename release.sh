#!/usr/bin/env bash
# 一键发布 Selene（MoonTVPlus 适配分支）
#
# 解决 README-迁移总览 §5 记录的发布三步坑与签名回环缺失：
#   1) bump 源码仓库 pubspec 版本并推送 main（CI 只克隆默认分支，不推就发的是旧代码）
#   2) 在发布仓库 jiam9069/Selene 上打同名 tag 并触发 workflow_dispatch
#      （直接推 tag 不会触发构建，必须显式 dispatch）
#   3) 轮询构建完成 → 下载 armv8 APK → 用 signing/verify_apk.py 比对 expected_fp.txt
#
# 用法:
#   release.sh <version> [--dry-run] [--skip-local-tests]
#   release.sh 1.6.12                 # build 号自动 +1（1.6.11+2161 → 1.6.12+2162）
#   release.sh 1.6.12+2200            # 显式指定 build 号
#   release.sh 1.6.12 --dry-run       # 只做本地门禁并展示将执行的动作，不推送不发布
#
# 依赖: git, curl, jq, python3; 本地门禁需要 flutter（可用 FLUTTER_BIN 覆盖）。
# 凭据: 优先 $GH_TOKEN，其次从 selene-ci 的 origin 远端 URL 中提取 PAT，
#       再其次 /root/DSH/githubtoken.txt。源码仓库/发布仓库的 push 凭据
#       已内嵌在各自 origin 远端 URL 中。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # selene-moontvplus/
SRC_DIR="$ROOT/selene-source"
CI_DIR="$ROOT/selene-ci"
SIGN_DIR="$ROOT/signing"

SRC_REPO="jiam9069/Selene-Source"
CI_REPO="jiam9069/Selene"
API="https://api.github.com"
POLL_INTERVAL=30
TIMEOUT=3600

log()  { printf '\033[1;36m[release]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[release][错误]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- 参数解析
VERSION_INPUT=""
DRY_RUN=0
SKIP_LOCAL_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-local-tests) SKIP_LOCAL_TESTS=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "未知参数: $arg" ;;
    *) [ -n "$VERSION_INPUT" ] && die "多余参数: $arg"; VERSION_INPUT="$arg" ;;
  esac
done
[ -n "$VERSION_INPUT" ] || die "缺少版本号，用法见 --help"

case "$VERSION_INPUT" in
  *+*) VERSION="${VERSION_INPUT%%+*}"; BUILD="${VERSION_INPUT##*+}" ;;
  *)   VERSION="$VERSION_INPUT"; BUILD="" ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 X.Y.Z，收到: $VERSION"
[ -z "$BUILD" ] || [[ "$BUILD" =~ ^[0-9]+$ ]] || die "build 号应为整数，收到: $BUILD"

# ---------------------------------------------------------------- 凭据
extract_pat() {
  # 从 git remote URL 提取内嵌 PAT，绝不回显
  git -C "$1" remote get-url origin 2>/dev/null \
    | sed -n 's|.*://\([A-Za-z0-9_]\{1,\}\)@github\.com/.*|\1|p'
}
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$TOKEN" ]; then TOKEN="$(extract_pat "$CI_DIR")"; fi
if [ -z "$TOKEN" ] && [ -f /root/DSH/githubtoken.txt ]; then
  TOKEN="$(tr -d '[:space:]' < /root/DSH/githubtoken.txt)"
fi
[ -n "$TOKEN" ] || die "未找到 GitHub 凭据（GH_TOKEN / selene-ci origin / githubtoken.txt）"

gh_api() {  # gh_api METHOD PATH [DATA] → 响应体
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -X "$method" -H "Authorization: Bearer $TOKEN"
              -H "Accept: application/vnd.github+json")
  if [ -n "$data" ]; then args+=(-d "$data"); fi
  curl "${args[@]}" "$API$path"
}

# ---------------------------------------------------------------- 仓库前置检查
[ -d "$SRC_DIR/.git" ] || die "未找到源码仓库: $SRC_DIR"
[ -d "$CI_DIR/.git" ]  || die "未找到发布仓库: $CI_DIR"

CURRENT_VERSION="$(grep '^version:' "$SRC_DIR/pubspec.yaml" | sed 's/version: //' | tr -d ' ')"
CURRENT_VER="${CURRENT_VERSION%%+*}"
CURRENT_BUILD="${CURRENT_VERSION##*+}"
[ -n "$BUILD" ] || BUILD="$((CURRENT_BUILD + 1))"

if [ "$VERSION" = "$CURRENT_VER" ]; then
  log "版本不变（$CURRENT_VERSION），仅递增 build → $VERSION+$BUILD"
else
  log "版本升级 $CURRENT_VERSION → $VERSION+$BUILD"
fi

if [ "$DRY_RUN" = 0 ]; then
  [ -z "$(git -C "$SRC_DIR" status --porcelain)" ] || die "源码仓库有未提交改动，先提交或暂存"
  git -C "$SRC_DIR" fetch origin main --quiet
  LOCAL_SHA="$(git -C "$SRC_DIR" rev-parse HEAD)"
  REMOTE_SHA="$(git -C "$SRC_DIR" rev-parse origin/main)"
  [ "$LOCAL_SHA" = "$REMOTE_SHA" ] || die "源码仓库 main 与 origin 不同步（$LOCAL_SHA vs $REMOTE_SHA），先 push/pull"
fi

# ---------------------------------------------------------------- 本地门禁
run_local_gates() {
  if [ "$SKIP_LOCAL_TESTS" = 1 ]; then
    log "已跳过本地门禁（--skip-local-tests）"
    return
  fi
  local flutter_bin="${FLUTTER_BIN:-flutter}"
  if ! command -v "$flutter_bin" >/dev/null 2>&1 \
     && [ -x /root/DSH/tools/flutter/bin/flutter ]; then
    flutter_bin=/root/DSH/tools/flutter/bin/flutter
  fi
  # 必须解析成绝对路径：FLUTTER_BIN 未设时 flutter_bin 只是相对名 "flutter"，
  # 而下面的 dart_bin 由 dirname "$flutter_bin" 推导，相对名会让 dirname 返回 "."
  # 并把 dart 拼成 <当前工作区>/cache/dart-sdk/bin/dart（不存在，exit 127）。
  if command -v "$flutter_bin" >/dev/null 2>&1; then
    flutter_bin="$(command -v "$flutter_bin")"
  fi
  log "本地门禁: shell 测试"
  bash "$SRC_DIR/test/ci_config_test.sh"
  bash "$SRC_DIR/test/build_sh_parallel_failure_test.sh"
  if command -v "$flutter_bin" >/dev/null 2>&1 || [ -x "$flutter_bin" ]; then
    # analyze 用 dart 而不是 flutter analyze：flutter analyze 走 LSP，
    # 在含 CJK 的路径（/root/DSH/应用/...）下 Content-Length 帧长度错位，
    # 分析服务必现崩溃（255）；dart analyze 同一套诊断、经典协议，稳定。
    # 口径与 CI 一致：warning 致命、info 不致命。
    local dart_bin
    dart_bin="$(cd "$(dirname "$flutter_bin")" && pwd)/cache/dart-sdk/bin/dart"
    log "本地门禁: dart analyze / flutter test"
    (cd "$SRC_DIR" && "$flutter_bin" pub get >/dev/null
     "$dart_bin" analyze
     "$flutter_bin" test)
  else
    if [ "$DRY_RUN" = 1 ]; then
      log "未找到 flutter，跳过 analyze/test（dry-run 可接受；正式发布不建议跳过）"
    else
      die "未找到 flutter，无法执行本地门禁（装 SDK 或显式 --skip-local-tests）"
    fi
  fi
}

# ---------------------------------------------------------------- 发布步骤
do_build_gate() {
  run_local_gates
}

do_bump() {
  log "bump pubspec: $VERSION+$BUILD"
  sed -i -E "s/^version: .*/version: ${VERSION}+${BUILD}/" "$SRC_DIR/pubspec.yaml"
  git -C "$SRC_DIR" add pubspec.yaml
  git -C "$SRC_DIR" commit -m "Bump version to $VERSION+$BUILD"
  git -C "$SRC_DIR" push origin main
}

do_tag_dispatch() {
  # 1. 发布仓库打 tag（指向发布仓库自身 HEAD；工作流会另行克隆源码默认分支）
  git -C "$CI_DIR" fetch origin --quiet || true
  local tag="v$VERSION"
  if git -C "$CI_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    log "发布仓库已存在 tag $tag，复用"
  else
    log "发布仓库打 tag $tag"
    git -C "$CI_DIR" tag "$tag"
    git -C "$CI_DIR" push origin "$tag"
  fi

  # 2. 触发 workflow_dispatch（直接推 tag 不会触发构建）
  log "触发 workflow_dispatch ($tag)"
  gh_api POST "/repos/$CI_REPO/actions/workflows/build.yml/dispatches" \
    "{\"ref\":\"refs/tags/$tag\"}" >/dev/null
  DISPATCH_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "已触发，开始轮询（上限 ${TIMEOUT}s）"
}

wait_for_run() {
  local run_id="" elapsed=0
  while [ -z "$run_id" ]; do
    run_id="$(gh_api GET "/repos/$CI_REPO/actions/runs?event=workflow_dispatch&per_page=10" \
      | jq -r --arg t "$DISPATCH_AT" \
          '[.workflow_runs[] | select(.created_at >= $t and (.name == "Build Selene"))] | .[0].id // empty')"
    [ -n "$run_id" ] || { sleep "$POLL_INTERVAL"; elapsed=$((elapsed + POLL_INTERVAL)); }
    [ "$elapsed" -lt "$TIMEOUT" ] || die "等待 workflow run 出现超时"
  done
  log "workflow run id=$run_id"

  local status conclusion
  while :; do
    local info
    info="$(gh_api GET "/repos/$CI_REPO/actions/runs/$run_id")"
    status="$(echo "$info" | jq -r .status)"
    conclusion="$(echo "$info" | jq -r .conclusion)"
    if [ "$status" = "completed" ]; then
      [ "$conclusion" = "success" ] || die "构建失败（conclusion=$conclusion）→ $API/repos/$CI_REPO/actions/runs/$run_id"
      log "构建成功"
      break
    fi
    log "构建进行中（$status）…"
    sleep "$POLL_INTERVAL"; elapsed=$((elapsed + POLL_INTERVAL))
    [ "$elapsed" -lt "$TIMEOUT" ] || die "构建等待超时（${TIMEOUT}s）"
  done
}

download_and_verify() {
  local tag="v$VERSION"
  local release asset_id url apk
  release="$(gh_api GET "/repos/$CI_REPO/releases/tags/$tag")"
  [ "$(echo "$release" | jq -r .id)" != "null" ] || die "未找到 Release: $tag"
  asset_id="$(echo "$release" | jq -r --arg n "selene-$VERSION-armv8.apk" \
    '[.assets[] | select(.name == $n)][0].id // empty')"
  [ -n "$asset_id" ] || die "Release $tag 中缺少 selene-$VERSION-armv8.apk"

  apk="$ROOT/release-verify/selene-$VERSION-armv8.apk"
  mkdir -p "$(dirname "$apk")"
  url="/repos/$CI_REPO/releases/assets/$asset_id"
  log "下载 $apk"
  curl -sSL -H "Authorization: Bearer $TOKEN" \
       -H "Accept: application/octet-stream" \
       -o "$apk" "$API$url"
  [ -s "$apk" ] || die "APK 下载失败（空文件）"

  log "签名回环校验"
  local fp
  fp="$(tr -d '[:space:]' < "$SIGN_DIR/expected_fp.txt")"
  python3 "$SIGN_DIR/verify_apk.py" "$apk" "$fp"
  log "✅ 发布完成并校验通过: https://github.com/$CI_REPO/releases/tag/$tag"
}

# ---------------------------------------------------------------- 主流程
do_build_gate
if [ "$DRY_RUN" = 1 ]; then
  log "DRY-RUN 摘要（未执行任何推送/发布）:"
  echo "  1. selene-source: pubspec version → $VERSION+$BUILD，commit 并 push origin main"
  echo "  2. selene (发布仓库): tag v$VERSION → push"
  echo "  3. workflow_dispatch refs/tags/v$VERSION → 轮询 ≤${TIMEOUT}s"
  echo "  4. 下载 selene-$VERSION-armv8.apk → verify_apk.py 对比 expected_fp.txt"
  exit 0
fi
do_bump
do_tag_dispatch
wait_for_run
download_and_verify
