#!/usr/bin/env bash
#=============================================================================
# deploy.sh —— 在你自己的电脑上执行，把备份系统一次性装到 VPS 上
#
#   bash deploy.sh root@1.2.3.4               装到目标机（需指定）
#   bash deploy.sh root@1.2.3.4 --run-now     装完立刻跑一次真实备份
#   bash deploy.sh root@1.2.3.4 --skip-auth   跳过网盘授权（已有令牌时）
#
# 端口不是 22 时，写成 root@1.2.3.4:2222
#
# 它比在 VPS 上直接跑 install.sh 多做了两件事：
#   1. 在你本机做 Google Drive 授权——浏览器在这边，VPS 上没有浏览器
#   2. 自动把两个脚本传上去，你不需要记 scp 命令
#
# 想用自己的 OAuth 客户端（避开 rclone 共享配额的限流）：
#   WB_CLIENT_ID=xxx.apps.googleusercontent.com WB_CLIENT_SECRET=yyy bash deploy.sh
#=============================================================================

set -euo pipefail

if [[ -t 1 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
    C_B=$'\033[36m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_BOLD=""; C_0=""
fi

hr()    { printf '%s\n' "────────────────────────────────────────────────────────────"; }
head1() { printf '\n%s%s%s\n' "${C_BOLD}${C_B}" "$1" "${C_0}"; hr; }
ok()    { printf '  %s✓%s %s\n' "${C_G}" "${C_0}" "$1"; }
warn()  { printf '  %s!%s %s\n' "${C_Y}" "${C_0}" "$1"; }
err()   { printf '  %s✗%s %s\n' "${C_R}" "${C_0}" "$1" >&2; }
die()   { err "$1"; exit 1; }

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="/root/wb-backup"

TARGET=""; RUN_NOW=0; SKIP_AUTH=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-now)   RUN_NOW=1 ;;
        --skip-auth) SKIP_AUTH=1 ;;
        -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          die "未知参数：$1" ;;
        *)           TARGET="$1" ;;
    esac
    shift
done
TARGET="${TARGET:-${WB_TARGET:-}}"
[[ -n "${TARGET}" ]] || die "没指定目标机。用法：bash deploy.sh root@你的服务器"

# 支持 root@host:port 写法，取出端口塞进 ssh 参数
SSH_PORT=""
if [[ "${TARGET}" == *:* ]]; then
    SSH_PORT="${TARGET##*:}"
    TARGET="${TARGET%:*}"
fi

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
if [[ -n "${SSH_PORT}" ]]; then
    SSH_OPTS+=(-p "${SSH_PORT}")
fi

# 结尾提示里要给用户可复制的命令，端口得带上
SSH_HINT="ssh"
if [[ -n "${SSH_PORT}" ]]; then
    SSH_HINT="ssh -p ${SSH_PORT}"
fi

#=============================================================================
head1 "第 1 步 / 检查本机与目标机"
#=============================================================================

for f in install.sh backup-v2.sh; do
    [[ -f "${WORK}/${f}" ]] || die "工作目录里找不到 ${f}"
done
ok "本地脚本齐全（install.sh / backup-v2.sh）"

command -v ssh >/dev/null 2>&1 || die "本机没有 ssh"
command -v tar >/dev/null 2>&1 || die "本机没有 tar"
ok "本机具备 ssh 与 tar"

printf '  连接 %s ...\n' "${TARGET}"
if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" 'echo ok' >/dev/null 2>&1; then
    warn "免密登录不通，接下来会提示你输入密码（首次连接还会问是否信任主机指纹）"
    ssh "${SSH_OPTS[@]}" "$TARGET" 'echo ok' >/dev/null \
        || die "连不上 ${TARGET}，检查地址 / 端口 / 密钥"
fi

REMOTE_INFO="$(ssh "${SSH_OPTS[@]}" "$TARGET" \
    '. /etc/os-release 2>/dev/null && printf "%s" "$PRETTY_NAME"; printf "|%s|%s" "$(uname -m)" "$(id -un)"')" 2>/dev/null || true
ok "已连接：${REMOTE_INFO:-未知系统}"
[[ "${REMOTE_INFO##*|}" == "root" ]] || warn "远程用户不是 root，install.sh 会拒绝运行"

#=============================================================================
head1 "第 2 步 / Google Drive 授权"
#=============================================================================

TOKEN=""
RCLONE_LOCAL=""

ensure_local_rclone() {
    if command -v rclone >/dev/null 2>&1; then
        RCLONE_LOCAL="$(command -v rclone)"
        return
    fi
    local cache="${HOME}/.cache/wb-backup-deploy"
    mkdir -p "$cache"
    if [[ -x "${cache}/rclone" ]]; then
        RCLONE_LOCAL="${cache}/rclone"
        return
    fi

    local arch url tmp
    case "$(uname -m)" in
        arm64|aarch64) arch="arm64" ;;
        x86_64|amd64)  arch="amd64" ;;
        *)             die "不认识的 CPU 架构：$(uname -m)" ;;
    esac
    case "$(uname -s)" in
        Darwin) url="https://downloads.rclone.org/rclone-current-osx-${arch}.zip" ;;
        Linux)  url="https://downloads.rclone.org/rclone-current-linux-${arch}.zip" ;;
        *)      die "不支持的系统：$(uname -s)" ;;
    esac

    printf '  本机没有 rclone，下载一份临时用（不会改动系统）...\n'
    tmp="$(mktemp -d)"
    curl -fsSL --max-time 120 -o "${tmp}/r.zip" "$url" || die "rclone 下载失败，检查网络或代理"
    ( cd "$tmp" && unzip -q r.zip ) || die "解压失败"
    cp "$(find "$tmp" -name rclone -type f | head -1)" "${cache}/rclone"
    chmod +x "${cache}/rclone"
    rm -rf "$tmp"
    # macOS 会给下载的二进制打隔离标记，去掉才能执行
    xattr -d com.apple.quarantine "${cache}/rclone" 2>/dev/null || true
    RCLONE_LOCAL="${cache}/rclone"
}

# 从 rclone authorize 的输出里抠出 token JSON
# 单独成函数，方便离线验证：喂它一段真实的 authorize 输出，看能不能捞对
#
# 两种输出形态都要能对付：
#   1. 裸 JSON 独占一行（常见）
#   2. 行首被 rclone 的日志前缀污染，如 "2026/09/27 08:45:09 NOTICE: {...}"
# 所以先按 refresh_token 定位行，再砍掉第一个 { 之前的所有字符。
extract_token() {
    printf '%s\n' "$1" |
        awk '/"refresh_token"/{t=$0} END{print t}' |
        sed 's/^[^{]*//'
}

if [[ ${SKIP_AUTH} -eq 1 ]]; then
    warn "按参数要求跳过授权，VPS 上会走「粘贴令牌」的交互流程"
else
    ensure_local_rclone
    ok "本地 rclone：$("${RCLONE_LOCAL}" version | head -1)"

    printf '\n'
    printf '  %s接下来浏览器会弹出 Google 授权页，登录后点「允许」。%s\n' "${C_BOLD}" "${C_0}"
    printf '  如果没自动打开，终端里会打印一个 http://127.0.0.1:53682/... 的地址，手动打开即可。\n'
    printf '  授权完这段命令会自己结束。\n\n'
    printf '  %s注意：这一步授权的是「备份脚本要写入哪个网盘账号」，会一直等到你操作完。%s\n\n' \
        "${C_Y}" "${C_0}"
    read -r -p "  准备好了就回车，或输入 s 跳过：" ans || ans=""
    if [[ "${ans}" == "s" || "${ans}" == "S" ]]; then
        warn "已跳过，VPS 上会走「粘贴令牌」流程"
    else
        AUTH_RAW=""
        # 这段命令在前台等浏览器，用 2>&1 把提示和结果都收下来
        AUTH_RAW="$("${RCLONE_LOCAL}" authorize "drive" \
            ${WB_CLIENT_ID:+"${WB_CLIENT_ID}"} ${WB_CLIENT_SECRET:+"${WB_CLIENT_SECRET}"} \
            2>&1)" || true
        TOKEN="$(extract_token "${AUTH_RAW}")"
        if [[ "${TOKEN}" == \{*\} && "${TOKEN}" == *'"refresh_token"'* ]]; then
            ok "拿到授权令牌（${#TOKEN} 字节）"
        else
            TOKEN=""
            warn "没解析到令牌，回到 VPS 上手动粘贴"
            printf '\n  授权命令的原始输出（供排查）：\n'
            printf '%s\n' "${AUTH_RAW}" | tail -12 | sed 's/^/    /'
            printf '\n'
        fi
    fi
fi

#=============================================================================
head1 "第 3 步 / 上传脚本"
#=============================================================================

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

cp "${WORK}/install.sh" "${WORK}/backup-v2.sh" "${STAGE}/"
if [[ -n "${TOKEN}" ]]; then
    printf '%s' "${TOKEN}" > "${STAGE}/rclone-token.json"
    chmod 600 "${STAGE}/rclone-token.json"
    ok "令牌随包一起传（装在临时文件里，装完就删）"
else
    warn "不带令牌上传，VPS 上会提示你粘贴"
fi

tar czf - -C "${STAGE}" . \
    | ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ${REMOTE_DIR} && tar xzf - -C ${REMOTE_DIR} && chmod 755 ${REMOTE_DIR}/install.sh ${REMOTE_DIR}/backup-v2.sh" \
    || die "上传失败"

UPLOADED="$(ssh "${SSH_OPTS[@]}" "$TARGET" "ls -1 ${REMOTE_DIR}")"
ok "已传到 ${TARGET}:${REMOTE_DIR}（$(printf '%s' "${UPLOADED}" | tr '\n' ' ')）"

#=============================================================================
head1 "第 4 步 / 在 VPS 上安装"
#=============================================================================
printf '  接下来是安装向导，在你原来的终端里回答几个问题就行（直接回车＝用默认值）。\n\n'

EXTRA=""
[[ ${RUN_NOW} -eq 1 ]] && EXTRA="--run-now"

set +e
ssh "${SSH_OPTS[@]}" -t "$TARGET" "cd ${REMOTE_DIR} && bash install.sh ${EXTRA}"
INSTALL_RC=$?
set -e

# 令牌是最敏感的东西，用完立刻从服务器上抹掉
ssh "${SSH_OPTS[@]}" "$TARGET" "rm -f ${REMOTE_DIR}/rclone-token.json" >/dev/null 2>&1 || true

#=============================================================================
head1 "完成"
#=============================================================================

if [[ ${INSTALL_RC} -eq 0 ]]; then
    ok "安装成功"
else
    err "安装过程退出码 ${INSTALL_RC}，往上翻看是哪一步红了"
fi

cat <<EOF

  常用命令（在你的电脑上执行）：

    立刻跑一次备份
      ${SSH_HINT} -t ${TARGET} 'systemctl start backup-v2.service && journalctl -u backup-v2 -n 50'

    看排期
      ${SSH_HINT} ${TARGET} 'systemctl list-timers backup-v2.timer'

    看日志
      ${SSH_HINT} ${TARGET} 'tail -50 /opt/backups/backup.log'

    改配置（改完不用重启，下一次跑就生效）
      ${SSH_HINT} -t ${TARGET} 'vi /etc/backup.env'

    卸载（保留备份数据与密钥）
      ${SSH_HINT} -t ${TARGET} 'bash ${REMOTE_DIR}/install.sh --uninstall'

EOF

printf '  %s最后提醒：把加密口令存进密码管理器。它在 /etc/backup.env 里，%s\n' "${C_Y}" "${C_0}"
printf '  %s机器丢了以后，网盘上那些 .enc 文件只有这个口令能解开，没有第二条路。%s\n\n' "${C_Y}" "${C_0}"
