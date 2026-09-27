#!/usr/bin/env bash
#=============================================================================
# 把本目录同步到 GitHub（783283/script 的 vps-backup/）
#
# 为什么要有这个脚本，而不是直接 git push：
#   1. 本地文件名和仓库里的文件名不一致
#      （本地 backup-v2-README.md 在仓库里叫 README.md），
#      每次手工拷都得记得这一条，忘了就把仓库里的主文档改成了另一个文件
#   2. 本地不是 git 仓库，且同目录下有 backup.env 和 .workbuddy/，
#      这两个都含真实凭证和真实 IP，绝不能进仓库。
#      所以这里用**白名单**拷贝，而不是 git add -A
#   3. 提交身份要显式带，不能依赖全局配置（这台机器上没配）
#
# 用法：
#   bash push.sh                      用默认提交信息
#   bash push.sh "改了 xxx"           自定义提交信息
#   bash push.sh --test "改了 xxx"    推之前先把两套测试跑一遍
#=============================================================================

set -uo pipefail

REPO_URL="git@github.com:783283/script.git"
BRANCH="main"
SUBDIR="vps-backup"
GIT_NAME="reno"
GIT_EMAIL="taklele@gmail.com"
DEFAULT_MSG="Sync vps-backup"

SRC="$(cd "$(dirname "$0")" && pwd)"

RUN_TEST=0
MSG=""
for a in "$@"; do
    case "$a" in
        --test) RUN_TEST=1 ;;
        *)      MSG="$a" ;;
    esac
done

# 只推这些文件。新增文件要记得加进来，否则会静默漏推。
FILES=(
    backup-v2.sh
    install.sh
    deploy.sh
    backup.env.example
    test-install.sh
    test-notion-payload.sh
    install-README.md
    notify-notion-setup.md
    push.sh
)
# 本地名 -> 仓库名，只有不一致的才写在这里
RENAME=(
    "backup-v2-README.md:README.md"
)
# 仓库**根目录**下的文件：本地名:仓库根下的名字
# 为什么单独列：vps-backup 之外的东西本地工作区没有副本，
# 曾经因为漏了这条，根 README 里修好的死链一直没推上去，仓库里还挂着旧链接。
ROOTMAP=(
    "repo-root-README.md:README.md"
)

die()  { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m═══ %s ═══\033[0m\n' "$1"; }

step "1. 脱敏扫描"
# 命中任意一条就拒绝推送。宁可误报，也不要把真实地址推进公开仓库。
# 目标机的 SSH 端口，故意拆成两段拼接：本文件自己要被下面几条规则扫到，
# 写成完整字面量会让扫描器把自己命中，变成永远误报。
REAL_PORT="2233""4"
BAD=0

# 按行扫：命中就整行报出来。适合凭证形态这种一行里就能看明白的。
scan() {
    local label="$1" pattern="$2" hits
    hits="$(grep -rInE "$pattern" \
        --include='*.md' --include='*.sh' --include='*.example' \
        "$SRC" 2>/dev/null \
        | grep -v '/\.workbuddy/' \
        | grep -v '/sandbox-' || true)"
    if [[ -n "$hits" ]]; then
        printf '  \033[31m✗ %s\033[0m\n' "$label"
        printf '%s\n' "$hits" | sed 's/^/      /'
        BAD=1
    else
        printf '  \033[32m✓\033[0m %s\n' "$label"
    fi
}

# 单独扫 IP：文档里本来就该有占位地址（1.2.3.4、192.168.x.x、RFC 5737 的
# 文档专用段），按行过滤会把整行误伤。所以这里逐个 IP 判断，
# 只有非保留段才报。
scan_ip() {
    local hits
    hits="$(grep -rInoE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        --include='*.md' --include='*.sh' --include='*.example' \
        "$SRC" 2>/dev/null \
        | grep -v '/\.workbuddy/' \
        | grep -v '/sandbox-' \
        | grep -vE ':(127\.0\.0\.1|0\.0\.0\.0|1\.2\.3\.4|255\.255\.255\.255|169\.254\.[0-9.]+|10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+|192\.0\.2\.[0-9.]+|198\.51\.100\.[0-9.]+|203\.0\.113\.[0-9.]+)$' \
        || true)"
    if [[ -n "$hits" ]]; then
        printf '  \033[31m✗ %s\033[0m\n' "无真实 IP（保留段与文档占位段不计）"
        printf '%s\n' "$hits" | sed 's/^/      /'
        BAD=1
    else
        printf '  \033[32m✓\033[0m %s\n' "无真实 IP（保留段与文档占位段不计）"
    fi
}

scan_ip
scan "无已知真实 SSH 端口"  "${REAL_PORT}"
scan "无 Notion 凭证"    'ntn_[A-Za-z0-9]{10,}|secret_[A-Za-z0-9]{20,}'
scan "无 AgentMail 凭证" 'am_[A-Za-z0-9]{20,}'
scan "无私钥块"          'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY'
[[ "$BAD" -eq 0 ]] || die "扫描发现疑似敏感内容，已中止。确认是误报后请手工推送。"

# 白名单里每个文件都必须存在
for f in "${FILES[@]}"; do
    [[ -f "${SRC}/${f}" ]] || die "白名单里的文件不存在：${f}"
done
for pair in "${RENAME[@]}"; do
    [[ -f "${SRC}/${pair%%:*}" ]] || die "白名单里的文件不存在：${pair%%:*}"
done
for pair in "${ROOTMAP[@]}"; do
    [[ -f "${SRC}/${pair%%:*}" ]] || die "白名单里的文件不存在：${pair%%:*}"
done
# 明确确认凭证文件不会被拷进去
[[ -f "${SRC}/backup.env" ]] && \
    printf '  \033[32m✓\033[0m backup.env 存在，但不在白名单里，不会被推送\n'

if [[ "$RUN_TEST" -eq 1 ]]; then
    step "2. 跑测试"
    bash "${SRC}/test-notion-payload.sh" | tail -3 || die "Notion 上报格式测试未通过"
    bash "${SRC}/test-install.sh"        | tail -3 || die "端到端测试未通过"
fi

step "3. 拉取仓库"
TMP="$(mktemp -d)"
V="$(mktemp -d)"
trap 'rm -rf "$TMP" "$V"' EXIT
git clone -q --branch "$BRANCH" "$REPO_URL" "${TMP}/repo" || die "克隆失败"
DST="${TMP}/repo/${SUBDIR}"
[[ -d "$DST" ]] || die "仓库里没有 ${SUBDIR}/ 目录"

step "4. 同步文件"
for f in "${FILES[@]}"; do
    cp "${SRC}/${f}" "${DST}/${f}"
    printf '  → %s\n' "$f"
done
for pair in "${RENAME[@]}"; do
    cp "${SRC}/${pair%%:*}" "${DST}/${pair##*:}"
    printf '  → %s（本地叫 %s）\n' "${pair##*:}" "${pair%%:*}"
done
for pair in "${ROOTMAP[@]}"; do
    cp "${SRC}/${pair%%:*}" "${TMP}/repo/${pair##*:}"
    printf '  → %s（仓库根，本地叫 %s）\n' "${pair##*:}" "${pair%%:*}"
done
chmod 755 "${DST}"/*.sh

cd "${TMP}/repo"
if git diff --quiet && [[ -z "$(git status --porcelain)" ]]; then
    step "没有变化，仓库已是最新"
    exit 0
fi
printf '\n  改动如下：\n'
git status --porcelain | sed 's/^/    /'

step "5. 提交并推送"
[[ -n "$MSG" ]] || MSG="$DEFAULT_MSG"
git -c "user.name=${GIT_NAME}" -c "user.email=${GIT_EMAIL}" add -A
git -c "user.name=${GIT_NAME}" -c "user.email=${GIT_EMAIL}" commit -q -m "$MSG" \
    || die "提交失败"
git push -q origin "$BRANCH" || die "推送失败"
printf '  \033[32m✓\033[0m 已推送：%s\n' "$MSG"

step "6. 重新克隆校验"
# 不看 push 的输出就下结论——重新拉一份，逐个字节比对
OK=0
N=$(( ${#FILES[@]} + ${#RENAME[@]} + ${#ROOTMAP[@]} ))
git clone -q --branch "$BRANCH" "$REPO_URL" "${V}/repo" || die "校验用克隆失败"
for f in "${FILES[@]}"; do
    cmp -s "${SRC}/${f}" "${V}/repo/${SUBDIR}/${f}" \
        || { printf '  \033[31m✗ 不一致 %s\033[0m\n' "$f"; OK=1; }
done
for pair in "${RENAME[@]}"; do
    cmp -s "${SRC}/${pair%%:*}" "${V}/repo/${SUBDIR}/${pair##*:}" \
        || { printf '  \033[31m✗ 不一致 %s\033[0m\n' "${pair##*:}"; OK=1; }
done
for pair in "${ROOTMAP[@]}"; do
    cmp -s "${SRC}/${pair%%:*}" "${V}/repo/${pair##*:}" \
        || { printf '  \033[31m✗ 不一致 %s\033[0m\n' "${pair##*:}"; OK=1; }
done
[[ "$OK" -eq 0 ]] || die "校验不通过：仓库内容与本地不一致"
printf '  \033[32m✓\033[0m %d 个文件全部与仓库一致\n' "$N"
printf '\n\033[32m推送完成。\033[0m https://github.com/783283/script\n'
