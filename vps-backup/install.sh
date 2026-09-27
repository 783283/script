#!/usr/bin/env bash
#=============================================================================
# backup-v2 一键安装脚本
#
# 用法：
#   bash install.sh                  交互式向导（推荐）
#   bash install.sh --yes            非交互，全部取默认值 / 环境变量
#   bash install.sh --check          只做环境预检，不改动任何文件
#   bash install.sh --run-now        装完立刻跑一次真实备份
#   bash install.sh --uninstall      卸载（保留备份数据与配置）
#
# 配合 --yes 使用的环境变量：
#   WB_BACKUP_PATHS    空格分隔，如 "/opt/app/data /etc/nginx"
#   WB_DB_TYPE         none | mysql | docker-mysql
#   WB_MYSQL_PASSWORD  数据库 root 密码
#   WB_BACKUP_PASSWORD 加密口令；不填则自动生成 48 位随机串
#   WB_RCLONE_NAME     rclone remote 名，默认 gdrive
#   WB_RCLONE_FOLDER   网盘里的目录，默认 backup/<主机名>
#   WB_RCLONE_TOKEN_B64  base64 编码的 rclone token JSON（deploy.sh 自动传）
#   WB_NOTIFY_TYPE     none | notion | webhook
#   WB_NOTION_TOKEN / WB_NOTION_TARGET_ID / WB_NOTION_TARGET
#   WB_WEBHOOK_URL / WB_WEBHOOK_TOKEN
#   WB_SCHEDULE        HH:MM，默认 03:00
#   WB_PREFIX          装到指定前缀下（沙箱测试用，会跳过 root/依赖/定时器）
#=============================================================================

set -euo pipefail

VERSION="1.0.0"
ASSUME_YES=0
PREFIX=""
MODE="install"          # install | check | uninstall
RUN_NOW=0
SKIP_DEPS=0
REMOTE_TYPE="drive"
SCHEDULE_DEFAULT="03:00"

#=============================================================================
# 输出辅助
#=============================================================================

if [[ -t 1 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
    C_B=$'\033[36m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_BOLD=""; C_0=""
fi

hr()   { printf '%s\n' "────────────────────────────────────────────────────────────"; }
head1() { printf '\n%s%s%s\n' "${C_BOLD}${C_B}" "$1" "${C_0}"; hr; }
ok()   { printf '  %s✓%s %s\n' "${C_G}" "${C_0}" "$1"; }
warn() { printf '  %s!%s %s\n' "${C_Y}" "${C_0}" "$1"; }
err()  { printf '  %s✗%s %s\n' "${C_R}" "${C_0}" "$1" >&2; }
info() { printf '    %s\n' "$1"; }
die()  { err "$1"; exit 1; }

# 把 KB 数说成人话
human_kb() {
    local kb="${1:-0}"
    if   (( kb >= 1048576 )); then printf '%.1f GB' "$(echo "${kb} 1048576" | awk '{printf "%.1f", $1/$2}')"
    elif (( kb >= 1024 ));    then printf '%.1f MB' "$(echo "${kb} 1024" | awk '{printf "%.1f", $1/$2}')"
    else                           printf '%d KB' "${kb}"
    fi
}

# 把值包装成可直接被 bash source 的单引号字面量
sq() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

#=============================================================================
# 参数解析
#=============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)      ASSUME_YES=1 ;;
        --check)       MODE="check" ;;
        --uninstall)   MODE="uninstall" ;;
        --run-now)     RUN_NOW=1 ;;
        --skip-deps)   SKIP_DEPS=1 ;;
        --prefix)      PREFIX="${2:-}"; shift ;;
        --prefix=*)    PREFIX="${1#*=}" ;;
        --remote-type) REMOTE_TYPE="${2:-drive}"; shift ;;
        --remote-type=*) REMOTE_TYPE="${1#*=}" ;;
        -h|--help)     sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "未知参数：$1（用 --help 看用法）" ;;
    esac
    shift
done

#=============================================================================
# 路径布局：PREFIX 为空时就是真实系统路径
#=============================================================================

ETC_DIR="${PREFIX}/etc"
BIN_DIR="${PREFIX}/usr/local/bin"
VAR_DIR="${PREFIX}/var"
SYSTEMD_DIR="${ETC_DIR}/systemd/system"
RCLONE_DIR="${PREFIX}/root/.config/rclone"

CONFIG_FILE="${ETC_DIR}/backup.env"
SCRIPT_DST="${BIN_DIR}/backup-v2.sh"
LOCKFILE="${VAR_DIR}/run/backup.lock"
LOCALDIR_DEFAULT="${PREFIX}/opt/backups"
RCLONE_CONF="${RCLONE_DIR}/rclone.conf"

if [[ -n "${PREFIX}" ]]; then
    IS_SANDBOX=1
else
    IS_SANDBOX=0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#=============================================================================
# 环境预检
#=============================================================================

detect_pkg_mgr() {
    for m in apt-get dnf yum apk zypper; do
        command -v "$m" >/dev/null 2>&1 && { printf '%s' "$m"; return; }
    done
    printf ''
}

preflight() {
    head1 "第 1 步 / 环境预检"

    if [[ $IS_SANDBOX -eq 0 ]]; then
        [[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $0"
        ok "以 root 运行"
    else
        info "沙箱模式（PREFIX=${PREFIX}），跳过 root 检查"
    fi

    local os=""
    if [[ -r /etc/os-release ]]; then
        os="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")"
    else
        os="$(uname -s) $(uname -r)"
    fi
    ok "系统：${os}（$(uname -m)）"

    PKG_MGR="$(detect_pkg_mgr)"
    if [[ -n "${PKG_MGR}" ]]; then
        ok "包管理器：${PKG_MGR}"
    else
        warn "没识别到包管理器，缺什么依赖得手动装"
    fi

    # 必需命令
    local missing=()
    for c in curl openssl tar gzip find date; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "缺少基础命令：${missing[*]}（下一步尝试安装）"
    else
        ok "基础命令齐全"
    fi

    if command -v flock >/dev/null 2>&1; then
        ok "flock 可用（防重入生效）"
    else
        warn "没有 flock，脚本会退化成「不防重入」——建议装上 util-linux"
    fi

    if [[ $IS_SANDBOX -eq 0 ]]; then
        if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
            ok "systemd 可用（定时用 systemd timer）"
            HAS_SYSTEMD=1
        else
            warn "没检测到 systemd，定时改用 cron"
            HAS_SYSTEMD=0
        fi
    else
        info "沙箱模式：定时文件只会生成，不会真的启用"
        HAS_SYSTEMD=1
    fi

    # 时区，直接影响备份文件的时间戳和 03:00 到底是什么时候
    local tz
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || date +%Z)"
    ok "时区：${tz}（定时按这个时间走）"
}

# 单独一个函数：卸载时机器上可能已经没有这个脚本了，不能因此中断
locate_backup_src() {
    local c
    for c in "${WB_BACKUP_SCRIPT:-}" "${SCRIPT_DIR}/backup-v2.sh" \
             "${BIN_DIR}/backup-v2.sh" "/usr/local/bin/backup-v2.sh"; do
        if [[ -n "${c}" && -f "${c}" ]]; then
            BACKUP_SRC="${c}"
            ok "备份脚本：${BACKUP_SRC}（$(wc -l < "${BACKUP_SRC}" | tr -d ' ') 行）"
            return 0
        fi
    done
    die "找不到 backup-v2.sh。请把它和 install.sh 放在同一目录后再运行"
}

#=============================================================================
# 依赖安装
#=============================================================================

install_deps() {
    head1 "第 2 步 / 依赖"

    if [[ $IS_SANDBOX -eq 1 || $SKIP_DEPS -eq 1 ]]; then
        info "跳过依赖安装"
        return
    fi

    if [[ -n "${PKG_MGR}" ]]; then
        local pkgs=()
        command -v curl    >/dev/null 2>&1 || pkgs+=(curl)
        command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
        command -v flock   >/dev/null 2>&1 || pkgs+=(util-linux)
        command -v unzip   >/dev/null 2>&1 || pkgs+=(unzip)
        if [[ ${#pkgs[@]} -gt 0 ]]; then
            info "安装：${pkgs[*]}"
            case "${PKG_MGR}" in
                apt-get) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" ;;
                dnf|yum) "${PKG_MGR}" install -y -q "${pkgs[@]}" ;;
                apk)     apk add --no-cache "${pkgs[@]}" ;;
                zypper)  zypper --non-interactive install "${pkgs[@]}" ;;
            esac
            ok "基础依赖就绪"
        else
            ok "基础依赖已全部存在"
        fi
    fi

    if command -v rclone >/dev/null 2>&1; then
        ok "rclone 已安装：$(rclone version | head -1)"
    else
        info "正在安装 rclone（官方脚本，取最新版）..."
        if curl -fsSL https://rclone.org/install.sh | bash >/tmp/wb-rclone-install.log 2>&1; then
            ok "rclone 安装完成：$(rclone version | head -1)"
        else
            warn "官方脚本失败，尝试包管理器"
            if [[ -n "${PKG_MGR}" ]]; then
                case "${PKG_MGR}" in
                    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rclone ;;
                    dnf|yum) "${PKG_MGR}" install -y -q rclone ;;
                    apk)     apk add --no-cache rclone ;;
                esac
            fi
            command -v rclone >/dev/null 2>&1 \
                || die "rclone 装不上。日志：/tmp/wb-rclone-install.log"
            ok "rclone（包管理器版本）：$(rclone version | head -1)"
        fi
    fi
}

#=============================================================================
# 交互取参数
#=============================================================================

# ask <变量名> <提示> <默认值> [required]
ask() {
    local __var=$1 prompt=$2 default=${3-} required=${4-}
    local envname="WB_${__var}" ans=""

    if [[ -n "${!envname-}" ]]; then
        printf -v "$__var" '%s' "${!envname}"
        info "${prompt} → ${!__var}"
        return 0
    fi
    if [[ $ASSUME_YES -eq 1 ]]; then
        if [[ -z "${default}" && -n "${required}" ]]; then
            die "${prompt} 没有默认值，--yes 模式下必须用环境变量 WB_${__var} 提供"
        fi
        printf -v "$__var" '%s' "${default}"
        info "${prompt} → ${default:-（留空）}"
        return 0
    fi

    while :; do
        if [[ -n "${default}" ]]; then
            printf '  %s [%s]: ' "${prompt}" "${default}"
        else
            printf '  %s: ' "${prompt}"
        fi
        IFS= read -r ans || ans=""
        [[ -z "${ans}" ]] && ans="${default}"
        if [[ -z "${ans}" && -n "${required}" ]]; then
            err "这项必填"
            continue
        fi
        printf -v "$__var" '%s' "${ans}"
        return 0
    done
}

# 自动探测值得备份的目录
detect_paths() {
    local found=()
    for d in /opt/app/data /opt/data /srv/data /var/www /etc/nginx /etc/caddy /home; do
        [[ -d "$d" ]] && found+=("$d")
    done
    printf '%s' "${found[*]:-}"
}

# 自动探测数据库
detect_db() {
    if command -v docker >/dev/null 2>&1; then
        local c
        c="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'mysql|mariadb' | head -1 || true)"
        [[ -n "${c}" ]] && { printf 'docker-mysql|%s' "${c}"; return; }
    fi
    if command -v mysqldump >/dev/null 2>&1; then
        printf 'mysql|'
        return
    fi
    if command -v pg_dump >/dev/null 2>&1; then
        printf 'pg|'
        return
    fi
    printf 'none|'
}

collect_params() {
    head1 "第 3 步 / 备份参数"

    local detected_paths detected_db db_container
    detected_paths="$(detect_paths)"
    detected_db="$(detect_db)"
    db_container="${detected_db#*|}"
    detected_db="${detected_db%%|*}"

    info "自动探测结果："
    info "  候选目录：${detected_paths:-（没找到常见目录）}"
    info "  数据库：${detected_db}${db_container:+（容器 ${db_container}）}"
    printf '\n'

    # 这一项的变量名是 BACKUP_PATHS（数组），提示里输入的是一串空格分隔的路径，
    # 所以单独处理，不用 ask 的通用逻辑
    if [[ -n "${WB_BACKUP_PATHS:-}" ]]; then
        BACKUP_PATHS_STR="${WB_BACKUP_PATHS}"
        info "要备份哪些目录（空格分隔） → ${BACKUP_PATHS_STR}"
    else
        ask BACKUP_PATHS_STR "要备份哪些目录（空格分隔）" "${detected_paths}" required
    fi
    # read 在读到空行时返回 1，会触发 set -e，所以必须兜住
    read -r -a BACKUP_PATHS <<< "${BACKUP_PATHS_STR}" || true

    if [[ "${detected_db}" == "pg" ]]; then
        warn "这台机器上装的是 PostgreSQL，但 backup-v2.sh 目前只支持 MySQL/MariaDB"
        warn "先把数据库部分留空（none），需要的话我再加 pg_dump 分支"
        detected_db="none"
    fi

    ask DB_TYPE "数据库类型 none/mysql/docker-mysql" "${detected_db}"
    MYSQL_PASSWORD=""
    if [[ "${DB_TYPE}" == "mysql" ]]; then
        ask MYSQL_PASSWORD "MySQL root 密码" "" required
    elif [[ "${DB_TYPE}" == "docker-mysql" ]]; then
        ask MYSQL_CONTAINER "MySQL 容器名" "${db_container}" required
        ask MYSQL_PASSWORD "MySQL root 密码（容器内）" "" required
    fi

    printf '\n'
    info "加密口令是恢复数据的唯一钥匙，丢了数据就等于没备份。"
    ask BACKUP_PASSWORD "加密口令（回车=自动生成 48 位随机）" ""
    local generated=0
    if [[ -z "${BACKUP_PASSWORD}" ]]; then
        BACKUP_PASSWORD="$(openssl rand -hex 24)"
        generated=1
    fi

    ask KEEP_LOCAL_DAYS  "本地保留天数（省磁盘）" "7"
    ask KEEP_REMOTE_DAYS "云端保留天数（保命那份）" "90"

    printf '\n'
    ask RCLONE_NAME   "rclone remote 名" "gdrive"
    ask RCLONE_FOLDER "网盘里的备份目录" "backup/$(hostname -s 2>/dev/null || printf 'vps')"

    printf '\n'
    info "通知：none 不通知 / notion 写进 Notion 表格 / webhook 推到自建服务"
    ask NOTIFY_TYPE "通知方式" "notion"
    if [[ "${NOTIFY_TYPE}" == "notion" ]]; then
        ask NOTION_TOKEN "Notion integration token" "" required
        ask NOTION_TARGET "写入方式 database/page" "database"
        ask NOTION_TARGET_ID "Notion 数据库/页面 ID（32 位）" "" required
    elif [[ "${NOTIFY_TYPE}" == "webhook" ]]; then
        ask WEBHOOK_URL "上报地址（http://host:8899）" "" required
        ask WEBHOOK_TOKEN "写入 token" "" required
    fi

    printf '\n'
    ask SCHEDULE "每天几点跑（HH:MM）" "${SCHEDULE_DEFAULT}"

    ENC_PW_WAS_GENERATED=${generated}
}

#=============================================================================
# rclone 配置
#=============================================================================

setup_rclone() {
    head1 "第 4 步 / rclone 与 Google Drive"

    mkdir -p "${RCLONE_DIR}"
    chmod 700 "${RCLONE_DIR}"

    # 已经配好同名的就复用
    if [[ -f "${RCLONE_CONF}" ]] && rclone --config "${RCLONE_CONF}" listremotes 2>/dev/null \
        | grep -qx "${RCLONE_NAME}:"; then
        ok "remote「${RCLONE_NAME}」已存在，复用现有配置"
        return
    fi

    [[ "${REMOTE_TYPE}" == "drive" ]] || {
        info "非 drive 类型（${REMOTE_TYPE}），跳过授权"
        {
            printf '[%s]\n' "${RCLONE_NAME}"
            printf 'type = %s\n' "${REMOTE_TYPE}"
        } > "${RCLONE_CONF}"
        chmod 600 "${RCLONE_CONF}"
        return
    }

    local token=""
    if [[ -n "${WB_RCLONE_TOKEN_B64:-}" ]]; then
        token="$(printf '%s' "${WB_RCLONE_TOKEN_B64}" | base64 -d 2>/dev/null || true)"
        [[ -n "${token}" ]] && ok "拿到授权令牌（由本地 deploy.sh 传入）"
    fi
    # deploy.sh 走这条：令牌放在临时文件里随包上传，装完由它负责删掉。
    # 比塞进环境变量好——环境变量会出现在服务器上的进程列表里。
    if [[ -z "${token}" && -f "${SCRIPT_DIR}/rclone-token.json" ]]; then
        token="$(cat "${SCRIPT_DIR}/rclone-token.json")"
        [[ -n "${token}" ]] && ok "拿到授权令牌（来自 rclone-token.json）"
    fi

    if [[ -z "${token}" ]]; then
        printf '\n'
        warn "Google Drive 授权必须用浏览器点一次，这是唯一没法全自动的环节。"
        info "在任意一台有浏览器的电脑上装好 rclone，执行："
        printf '\n      %srclone authorize "%s"%s\n\n' "${C_BOLD}" "${REMOTE_TYPE}" "${C_0}"
        info "浏览器登录并授权后，终端会输出一段 {\"access_token\":...} 的 JSON。"
        info "把那段 JSON 整段粘贴到下面（可以连 <---End paste 一起粘），然后按回车："
        printf '\n'
        local acc="" line=""
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            [[ -z "${line}" ]] && continue
            [[ "${line}" == *"Paste the following"* ]] && continue
            acc+="${line}"
            [[ "${acc}" == \{*\} ]] && break
        done
        token="${acc}"
    fi

    if [[ "${token}" != \{*\} || "${token}" != *'"refresh_token"'* ]]; then
        die "令牌格式不对，应该是一段以 { 开头、含 refresh_token 的 JSON"
    fi

    {
        printf '[%s]\n' "${RCLONE_NAME}"
        printf 'type = drive\n'
        printf 'scope = drive\n'
        printf 'token = %s\n' "${token}"
    } > "${RCLONE_CONF}"
    chmod 600 "${RCLONE_CONF}"
    ok "已写入 ${RCLONE_CONF}"

    if [[ "${REMOTE_TYPE}" == "drive" ]]; then
        if rclone --config "${RCLONE_CONF}" lsd "${RCLONE_NAME}:" --max-depth 1 >/dev/null 2>&1; then
            ok "授权验证通过，能读到网盘根目录"
        else
            warn "读不到网盘根目录。常见原因：Drive API 未启用 / 令牌已失效 / 网络受限"
            warn "先继续，装完可以用「rclone lsd ${RCLONE_NAME}:」复查"
        fi
    fi
}

#=============================================================================
# 生成配置文件
#=============================================================================

write_config() {
    head1 "第 5 步 / 写入配置"

    mkdir -p "${ETC_DIR}"

    local tmp
    tmp="$(mktemp)"
    chmod 600 "${tmp}"

    {
        printf '# backup-v2 配置 —— 由 install.sh v%s 于 %s 生成\n' \
            "${VERSION}" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# 里面有数据库密码和加密密钥，权限必须是 600，不要进 git。\n\n'

        printf '#--- 路径 -----------------------------------------------------------\n'
        printf 'LOCALDIR=%s\n'        "$(sq "${LOCALDIR_DEFAULT}")"
        printf 'TEMPDIR=%s\n'        "$(sq "${LOCALDIR_DEFAULT}/temp")"
        printf 'LOGFILE=%s\n'        "$(sq "${LOCALDIR_DEFAULT}/backup.log")"
        printf 'LOCKFILE=%s\n\n'     "$(sq "${LOCKFILE}")"

        printf '#--- 保留策略 -------------------------------------------------------\n'
        printf 'KEEP_LOCAL_DAYS=%s\n'  "${KEEP_LOCAL_DAYS}"
        printf 'KEEP_REMOTE_DAYS=%s\n\n' "${KEEP_REMOTE_DAYS}"

        printf '#--- 数据库 ---------------------------------------------------------\n'
        printf 'DB_TYPE=%s\n'            "$(sq "${DB_TYPE}")"
        printf 'MYSQL_ROOT_USER="root"\n'
        printf 'MYSQL_ROOT_PASSWORD=%s\n' "$(sq "${MYSQL_PASSWORD}")"
        printf 'MYSQL_DATABASE_NAMES=()\n'
        printf 'MYSQL_DOCKER_CONTAINER=%s\n\n' "$(sq "${MYSQL_CONTAINER:-}")"

        printf '#--- 备份内容 -------------------------------------------------------\n'
        printf 'BACKUP_PATHS=(\n'
        local p
        for p in ${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"}; do
            printf '    %s\n' "$(sq "${p}")"
        done
        printf ')\n\n'

        printf '#--- 加密 -----------------------------------------------------------\n'
        printf 'ENCRYPT=true\n'
        printf 'BACKUP_PASSWORD=%s\n\n' "$(sq "${BACKUP_PASSWORD}")"

        printf '#--- 上传 -----------------------------------------------------------\n'
        printf 'RCLONE_ENABLED=true\n'
        printf 'RCLONE_NAME=%s\n'      "$(sq "${RCLONE_NAME}")"
        printf 'RCLONE_REMOTE=%s\n'    "$(sq "${RCLONE_NAME}")"
        printf 'RCLONE_FOLDER=%s\n'    "$(sq "${RCLONE_FOLDER}")"
        printf 'RCLONE_BWLIMIT="off"\n'
        printf 'RCLONE_TRANSFERS=4\n'
        printf 'RCLONE_TPSLIMIT=8\n\n'

        printf '#--- 通知 -----------------------------------------------------------\n'
        if [[ "${NOTIFY_TYPE}" == "none" ]]; then
            printf 'NOTIFY_ENABLED=false\n'
            printf 'NOTIFY_TYPE="webhook"\n\n'
        else
            printf 'NOTIFY_ENABLED=true\n'
            printf 'NOTIFY_TYPE=%s\n' "$(sq "${NOTIFY_TYPE}")"
            printf 'NOTIFY_SUBJECT=%s\n' "$(sq '[备份] {{STATUS_CN}} - {{HOSTNAME}}')"
            printf 'NOTIFY_BODY=%s\n' "$(sq '主机: {{HOSTNAME}}
状态: {{STATUS_CN}}
时间: {{DATE}}
耗时: {{DURATION}} 秒
大小: {{TAR_SIZE}}
数据库: {{DB_STATUS}}
加密: {{ENC_STATUS}}
上传: {{UPLOAD_STATUS}}
失败原因: {{ERROR}}')"
            printf 'NOTIFY_NO_PROXY="*"\n'
            printf 'NOTIFY_TIMEOUT=20\n\n'
        fi

        if [[ "${NOTIFY_TYPE}" == "notion" ]]; then
            printf 'NOTION_TOKEN=%s\n'       "$(sq "${NOTION_TOKEN}")"
            printf 'NOTION_TARGET=%s\n'      "$(sq "${NOTION_TARGET}")"
            printf 'NOTION_TARGET_ID=%s\n'   "$(sq "${NOTION_TARGET_ID}")"
            printf 'NOTION_VERSION="2022-06-28"\n'
            printf 'NOTION_TITLE_PROP="名称"\n'
            printf 'NOTION_STATUS_PROP="状态"\n'
            printf 'NOTION_DATE_PROP="时间"\n'
            printf 'NOTION_API_BASE="https://api.notion.com"\n\n'
        elif [[ "${NOTIFY_TYPE}" == "webhook" ]]; then
            printf 'NOTIFY_WEBHOOK_URL=%s\n'   "$(sq "${WEBHOOK_URL}")"
            printf 'NOTIFY_WEBHOOK_TOKEN=%s\n\n' "$(sq "${WEBHOOK_TOKEN}")"
        fi
    } > "${tmp}"

    mv "${tmp}" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    [[ $IS_SANDBOX -eq 0 ]] && chown root:root "${CONFIG_FILE}" 2>/dev/null || true
    ok "配置写入 ${CONFIG_FILE}（权限 600）"

    # 装之前先确认这份配置能被 bash 正常读进来
    if ! ( set -a; . "${CONFIG_FILE}"; set +a; : ) 2>/dev/null; then
        die "生成的配置有语法错误，请把 ${CONFIG_FILE} 发我看看"
    fi
    ok "配置语法校验通过"
}

#=============================================================================
# 安装脚本本体
#=============================================================================

install_script() {
    head1 "第 6 步 / 安装备份脚本"

    mkdir -p "${BIN_DIR}"
    install -m 755 "${BACKUP_SRC}" "${SCRIPT_DST}"
    ok "${SCRIPT_DST}（755）"

    mkdir -p "${LOCALDIR_DEFAULT}" "${LOCALDIR_DEFAULT}/temp" "${VAR_DIR}/run"
    chmod 700 "${VAR_DIR}/run" 2>/dev/null || true
    ok "数据目录 ${LOCALDIR_DEFAULT}"

    # 备份目录套在备份源里会导致无限自我复制
    local p real_p real_local
    real_local="$(cd "${LOCALDIR_DEFAULT}" && pwd -P)"
    for p in ${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"}; do
        [[ -e "${p}" ]] || { warn "备份源不存在，会被跳过：${p}"; continue; }
        real_p="$(cd "${p}" 2>/dev/null && pwd -P || printf '%s' "${p}")"
        if [[ "${real_local}" == "${real_p}" || "${real_local}" == "${real_p}"/* ]]; then
            die "备份目录 ${real_local} 位于备份源 ${real_p} 内部，会无限自我复制。请把 LOCALDIR 挪出去"
        fi
    done
    ok "备份目录与备份源无嵌套冲突"
}

#=============================================================================
# 定时任务
#=============================================================================

parse_hhmm() {
    local s="$1"
    [[ "${s}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || die "时间格式应为 HH:MM，收到：${s}"
    SCHED_H="${BASH_REMATCH[1]#0}"
    SCHED_M="${BASH_REMATCH[2]#0}"
    [[ -n "${SCHED_H}" ]] || SCHED_H=0
    [[ -n "${SCHED_M}" ]] || SCHED_M=0
    (( SCHED_H >= 0 && SCHED_H <= 23 )) || die "小时必须在 0-23"
    (( SCHED_M >= 0 && SCHED_M <= 59 )) || die "分钟必须在 0-59"
}

setup_schedule() {
    head1 "第 7 步 / 定时任务"

    parse_hhmm "${SCHEDULE}"

    if [[ $HAS_SYSTEMD -eq 1 ]]; then
        mkdir -p "${SYSTEMD_DIR}"

        cat > "${SYSTEMD_DIR}/backup-v2.service" <<EOF
[Unit]
Description=backup-v2 备份任务
Documentation=file://${CONFIG_FILE}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DST}
Environment=BACKUP_CONFIG=${CONFIG_FILE}
Nice=10
IOSchedulingClass=idle
# 兜底：单次最长 6 小时，防止卡死占着锁不放
TimeoutStartSec=6h
EOF

        cat > "${SYSTEMD_DIR}/backup-v2.timer" <<EOF
[Unit]
Description=每日触发 backup-v2 备份

[Timer]
OnCalendar=*-*-* ${SCHED_H}:$(printf '%02d' "${SCHED_M}"):00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

        if [[ $IS_SANDBOX -eq 1 ]]; then
            info "沙箱模式：单元文件已生成，未启用"
            info "${SYSTEMD_DIR}/backup-v2.{service,timer}"
        else
            systemctl daemon-reload
            systemctl enable --now backup-v2.timer >/dev/null 2>&1
            ok "systemd timer 已启用：每天 $(printf '%02d:%02d' "${SCHED_H}" "${SCHED_M}")（含随机延迟）"
            info "查看排期：systemctl list-timers backup-v2.timer"
            info "手动触发：systemctl start backup-v2.service"
        fi
    else
        local line="${SCHED_M} ${SCHED_H} * * * BACKUP_CONFIG=${CONFIG_FILE} ${SCRIPT_DST} >> ${VAR_DIR}/log/backup-cron.log 2>&1"
        mkdir -p "${VAR_DIR}/log"
        if crontab -l 2>/dev/null | grep -qF "# backup-v2 managed"; then
            crontab -l 2>/dev/null | sed '/# backup-v2 managed/,+1d' | crontab -
        fi
        { crontab -l 2>/dev/null; printf '# backup-v2 managed\n%s\n' "${line}"; } | crontab -
        ok "cron 已写入：每天 $(printf '%02d:%02d' "${SCHED_H}" "${SCHED_M}")"
    fi
}

#=============================================================================
# 自检
#=============================================================================

self_check() {
    head1 "第 8 步 / 装完自检"

    local fails=0

    # 1. 配置能被读进来，关键项不空
    ( set -a; . "${CONFIG_FILE}"; set +a
      [[ -n "${BACKUP_PASSWORD}" ]] && [[ -n "${RCLONE_NAME}" ]] ) \
        && ok "配置可加载，关键项齐全" || { err "配置缺少关键项"; fails=$((fails+1)); }

    # 2. 加密往返：这是最容易被忽略、恢复时才发现的一条
    local pt="wb-selftest-$(date +%s)" ct rt
    ct="$(printf '%s' "${pt}" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
            -salt -pass "pass:${BACKUP_PASSWORD}" 2>/dev/null | base64 | tr -d '\n')" || true
    rt="$(printf '%s' "${ct}" | base64 -d 2>/dev/null | openssl enc -d -aes-256-cbc -pbkdf2 \
            -iter 100000 -pass "pass:${BACKUP_PASSWORD}" 2>/dev/null || true)"
    if [[ "${rt}" == "${pt}" ]]; then
        ok "加密/解密往返校验通过（用你这份口令试的）"
    else
        err "加密往返校验失败，这套配置恢复不出来"
        fails=$((fails+1))
    fi

    # 3. 磁盘空间：加密后还要再写一份同样大的文件，所以留 2.2 倍余量
    local need_kb=0 free_kb
    local p
    for p in ${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"}; do
        [[ -e "${p}" ]] && need_kb=$(( need_kb + $(du -sk "${p}" 2>/dev/null | cut -f1) ))
    done
    free_kb="$(df -Pk "${LOCALDIR_DEFAULT}" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "${free_kb}" ]]; then
        local need_all=$(( need_kb * 22 / 10 ))
        if (( free_kb >= need_all )); then
            ok "磁盘空间充足（源数据 $(human_kb "${need_kb}")，可用 $(human_kb "${free_kb}")）"
        else
            err "磁盘可能不够：源数据约 $(human_kb "${need_kb}")，加密后要再占用一份，建议至少 $(human_kb "${need_all}")，当前可用 $(human_kb "${free_kb}")"
            fails=$((fails+1))
        fi
    fi

    # 4. 网盘连通性与写入
    if [[ "${REMOTE_TYPE}" == "drive" ]] && command -v rclone >/dev/null 2>&1; then
        if rclone --config "${RCLONE_CONF}" lsd "${RCLONE_NAME}:" --max-depth 1 >/dev/null 2>&1; then
            ok "Google Drive 连通"
        else
            warn "Google Drive 暂时读不到（令牌或网络问题），上传会失败"
            fails=$((fails+1))
        fi
    fi

    # 5. 通知打通了没（真发一条测试记录）
    if [[ "${NOTIFY_TYPE}" == "notion" ]]; then
        info "往 Notion 发一条测试记录..."
        local tmpf out rc=0
        tmpf="$(mktemp)"
        {
            printf 'set -a\n. %s\nset +a\n' "$(sq "${CONFIG_FILE}")"
            printf 'STATUS="SUCCESS"\nSTATUS_CN="测试"\nERROR_DETAIL=""\n'
            printf 'log() { printf "      %%s\\n" "$*"; }\n'
            printf 'fail() { printf "      %%s\\n" "$*"; return 1; }\n'
            # 从真实脚本里抠出需要的函数，跑的就是生产代码，不是复制品
            sed -n '/^json_escape()/,/^}$/p'   "${BACKUP_SRC}"
            sed -n '/^notify_notion()/,/^}$/p' "${BACKUP_SRC}"
            printf 'notify_notion "[备份] 安装自检" "来自 install.sh 的测试记录，可删除。"\n'
        } > "${tmpf}"
        out="$(bash "${tmpf}" 2>&1)" || rc=$?
        rm -f "${tmpf}"
        [[ -n "${out}" ]] && printf '%s\n' "${out}" | sed 's/^/    /'
        if (( rc == 0 )); then
            ok "Notion 写入通道正常（表格里会出现一条「安装自检」记录，可以删掉）"
        else
            warn "Notion 写入失败，看上面的报错；对照 notify-notion-setup.md 末尾的排错表"
            fails=$((fails+1))
        fi
    elif [[ "${NOTIFY_TYPE}" == "webhook" ]]; then
        info "往上报服务 POST 一条测试记录..."
        local wh_rc=0
        curl -sS -f --noproxy '*' --max-time 20 -X POST \
            "${WEBHOOK_URL%/}/api/report?token=${WEBHOOK_TOKEN}" \
            -H 'Content-Type: application/json' \
            -d '{"host":"install-selfcheck","status":"success","duration":0,"body":"来自 install.sh 的安装自检"}' \
            >/dev/null 2>&1 || wh_rc=$?
        if (( wh_rc == 0 )); then
            ok "上报服务接收正常"
        else
            warn "上报服务没响应（curl 退出码 ${wh_rc}）；确认服务在跑、地址和 token 填对了"
            fails=$((fails+1))
        fi
    fi

    printf '\n'
    if (( fails == 0 )); then
        printf '  %s全部自检通过%s\n' "${C_G}${C_BOLD}" "${C_0}"
    else
        printf '  %s%d 项需要留意%s（上面标 ✗ 和 ! 的）\n' "${C_Y}${C_BOLD}" "${fails}" "${C_0}"
    fi
    return 0
}

#=============================================================================
# 卸载
#=============================================================================

do_uninstall() {
    head1 "卸载 backup-v2"

    if [[ $IS_SANDBOX -eq 0 ]]; then
        [[ $EUID -eq 0 ]] || die "请用 root 运行"
        if systemctl list-unit-files 2>/dev/null | grep -q '^backup-v2.timer'; then
            systemctl disable --now backup-v2.timer >/dev/null 2>&1 || true
            ok "已停用 systemd timer"
        fi
        rm -f "${SYSTEMD_DIR}/backup-v2.service" "${SYSTEMD_DIR}/backup-v2.timer"
        systemctl daemon-reload 2>/dev/null || true
        if crontab -l 2>/dev/null | grep -qF "# backup-v2 managed"; then
            crontab -l 2>/dev/null | sed '/# backup-v2 managed/,+1d' | crontab -
            ok "已移除 cron 条目"
        fi
    fi

    rm -f "${SCRIPT_DST}"
    ok "已删除 ${SCRIPT_DST}"

    printf '\n保留未动的：\n'
    printf '  %s   （你的配置与密钥）\n' "${CONFIG_FILE}"
    printf '  %s   （历史备份，需要自己决定删不删）\n' "${LOCALDIR_DEFAULT}"
    printf '  %s   （网盘授权）\n' "${RCLONE_CONF}"
    printf '\n要彻底清干净，手动执行：\n'
    printf '  rm -rf %s %s %s\n' "${CONFIG_FILE}" "${LOCALDIR_DEFAULT}" "${RCLONE_DIR}"
    printf '\n%s提醒：删之前确认真实数据不在这套备份里，或者你已经把加密口令存好了。%s\n' "${C_Y}" "${C_0}"
}

#=============================================================================
# 主流程
#=============================================================================

main() {
    printf '\n%s%sbackup-v2 一键安装%s  v%s\n' "${C_BOLD}" "${C_B}" "${C_0}" "${VERSION}"
    printf '把 VPS 数据加密后同步到 Google Drive，并把结果写进 Notion。\n'

    if [[ "${MODE}" == "uninstall" ]]; then
        PKG_MGR="$(detect_pkg_mgr)"
        HAS_SYSTEMD=1
        do_uninstall
        exit 0
    fi

    preflight
    locate_backup_src

    if [[ "${MODE}" == "check" ]]; then
        install_deps
        head1 "预检结束"
        printf '  没有改动任何文件。正式安装请去掉 --check 重跑。\n\n'
        exit 0
    fi

    install_deps
    collect_params
    setup_rclone
    write_config
    install_script
    setup_schedule
    self_check

    head1 "安装完成"
    printf '  安装位置：%s\n'   "${SCRIPT_DST}"
    printf '  配置文件：%s\n'   "${CONFIG_FILE}"
    printf '  备份目录：%s\n'   "${LOCALDIR_DEFAULT}"
    printf '  上网盘：  %s:%s\n' "${RCLONE_NAME}" "${RCLONE_FOLDER}"
    printf '  定时：    每天 %s\n' "${SCHEDULE}"
    printf '  日志：    %s\n'   "${LOCALDIR_DEFAULT}/backup.log"

    if [[ ${ENC_PW_WAS_GENERATED:-0} -eq 1 ]]; then
        printf '\n'
        printf '  %s%s下面是自动生成的加密口令，现在就存进密码管理器：%s\n' "${C_Y}" "${C_BOLD}" "${C_0}"
        printf '\n      %s%s%s\n\n' "${C_BOLD}" "${BACKUP_PASSWORD}" "${C_0}"
        printf '  %s丢了它，网盘上那些 .enc 文件就是一堆废字节——没有任何后门能救。%s\n' "${C_Y}" "${C_0}"
    else
        printf '\n  %s确认你手里的加密口令和配置文件里的一致，并且另存了一份。%s\n' "${C_Y}" "${C_0}"
    fi

    if [[ $IS_SANDBOX -eq 1 ]]; then
        printf '\n  %s沙箱模式，没有启用定时任务。%s\n\n' "${C_Y}" "${C_0}"
        return 0
    fi

    printf '\n手动跑一次看效果：\n'
    printf '  %s\n\n' "${SCRIPT_DST}"

    if [[ ${RUN_NOW} -eq 1 ]]; then
        head1 "立刻执行一次真实备份"
        local allow_nonroot=""
        [[ $IS_SANDBOX -eq 1 ]] && allow_nonroot="true"
        BACKUP_CONFIG="${CONFIG_FILE}" BACKUP_ALLOW_NONROOT="${allow_nonroot}" \
            "${SCRIPT_DST}" || \
            warn "这次退出码非零，看上面日志和通知里的失败原因"
    fi
}

main "$@"
