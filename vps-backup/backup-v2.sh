#!/usr/bin/env bash
#
# backup-v2.sh — VPS 备份脚本（基于 teddysun/across backup.sh 改造）
#
# 主要改动：
#   1. 配置全部外置到 /etc/backup.env，脚本本体可独立升级
#   2. set -euo pipefail，任何步骤失败立即中断，退出码非零
#   3. 【关键】加密失败不再删除明文归档，且校验产物非空后才删
#   4. 打包前做磁盘空间预检，避免 tar/加密把磁盘写满
#   5. flock 防重入，上一轮没跑完不会叠跑
#   6. trap 统一清理临时文件（含明文 sql dump），中断也不残留
#   7. 保留策略解耦：本地与云端各自独立天数
#   8. 文件年龄改用 mtime 计算，不再解析文件名
#      （原版按 hostname_日期 解析，hostname 含下划线就永久不清理）
#   9. mysqldump 加 --single-transaction，不再锁表阻塞业务
#  10. 数据库密码走 MYSQL_PWD 环境变量，不出现在进程列表
#  11. rclone 带限流参数，规避 Google Drive 的 API 配额
#  12. 成功与失败都发通知，失败通知携带失败步骤与退出码
#
# 配置说明见同目录 backup.env.example
#
set -euo pipefail

#=============================================================================
# 启动检查
#=============================================================================

SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="${BACKUP_CONFIG:-/etc/backup.env}"

if [[ "${EUID}" -ne 0 ]]; then
    # BACKUP_ALLOW_NONROOT 是为了能在笔记本上把整条链路完整彩排一遍
    # （install.sh --prefix 沙箱就是这么跑的），不影响生产使用。
    # 生产环境不要设它：非 root 跑出来的包，属主和文件权限都是错的。
    if [[ "${BACKUP_ALLOW_NONROOT:-}" == "true" ]]; then
        printf '警告：BACKUP_ALLOW_NONROOT=true，以非 root 身份继续（仅用于本地彩排）\n' >&2
        ALLOW_NONROOT=1
    else
        printf '错误：本脚本需要以 root 身份运行\n' >&2
        exit 1
    fi
fi

if [[ ! -r "${CONFIG_FILE}" ]]; then
    printf '错误：找不到可读的配置文件 %s\n' "${CONFIG_FILE}" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

#=============================================================================
# 默认值
#=============================================================================

LOCALDIR="${LOCALDIR:-/opt/backups}"
TEMPDIR="${TEMPDIR:-${LOCALDIR}/temp}"
LOGFILE="${LOGFILE:-${LOCALDIR}/backup.log}"
LOCKFILE="${LOCKFILE:-/var/run/backup.lock}"

KEEP_LOCAL_DAYS="${KEEP_LOCAL_DAYS:-7}"
KEEP_REMOTE_DAYS="${KEEP_REMOTE_DAYS:-90}"

DB_TYPE="${DB_TYPE:-none}"
MYSQL_ROOT_USER="${MYSQL_ROOT_USER:-root}"

ENCRYPT="${ENCRYPT:-true}"
BACKUP_PASSWORD="${BACKUP_PASSWORD:-}"

RCLONE_ENABLED="${RCLONE_ENABLED:-false}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
RCLONE_FOLDER="${RCLONE_FOLDER:-}"
RCLONE_BWLIMIT="${RCLONE_BWLIMIT:-off}"
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-4}"
RCLONE_TPSLIMIT="${RCLONE_TPSLIMIT:-8}"

NOTIFY_ENABLED="${NOTIFY_ENABLED:-false}"
NOTIFY_TYPE="${NOTIFY_TYPE:-smtp}"

# webhook 模式（POST 到你自备的接收端）用这两个
NOTIFY_WEBHOOK_URL="${NOTIFY_WEBHOOK_URL:-}"
NOTIFY_WEBHOOK_TOKEN="${NOTIFY_WEBHOOK_TOKEN:-}"

# 通知目标通常是自建的内网/本机服务，走系统代理没有意义，反而会被代理拦掉。
# 默认 '*' 表示绕过所有代理；确实需要经代理访问时改成具体地址或留空。
NOTIFY_NO_PROXY="${NOTIFY_NO_PROXY:-*}"

# Notion 模式（把上报写成数据库的一行，或用流水方式追加到页面）
NOTION_TOKEN="${NOTION_TOKEN:-}"
# database（推荐，表格视图）或 page（追加流水，不需要列名，但没法筛选）
NOTION_TARGET="${NOTION_TARGET:-database}"
# 数据库 ID 或页面 ID。从 Notion 链接里取，见 README
NOTION_TARGET_ID="${NOTION_TARGET_ID:-}"
# 固定 API 版本。Notion 改过数据库的寻址方式，不 pin 版本容易被上游改动打崩。
NOTION_VERSION="${NOTION_VERSION:-2022-06-28}"
# 三个列名必须和数据库里**完全一致**（含大小写和空格）。
# Notion 是按列名寻址的：列名对不上会直接 400，改名后也会静默失效。
NOTION_TITLE_PROP="${NOTION_TITLE_PROP:-名称}"
NOTION_STATUS_PROP="${NOTION_STATUS_PROP:-状态}"
NOTION_DATE_PROP="${NOTION_DATE_PROP:-时间}"
# API 基地址，仅测试时改成 mock 地址，平时不要动
NOTION_API_BASE="${NOTION_API_BASE:-https://api.notion.com}"

# 备份路径列表（数组从配置文件来，这里只是兜底）
BACKUP_PATHS=(${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"})
MYSQL_DATABASE_NAMES=(${MYSQL_DATABASE_NAMES[@]+"${MYSQL_DATABASE_NAMES[@]}"})

#=============================================================================
# 运行时状态（通知模板会用到）
#=============================================================================

SHORT_HOST="$(hostname -s 2>/dev/null || hostname)"
BACKUPDATE="$(date +%Y%m%d%H%M%S)"
STARTTIME="$(date +%s)"
DURATION=0

STATUS="UNKNOWN"
STATUS_CN="未知"
ERROR_DETAIL=""
CURRENT_STEP="初始化"

STEP_DB="未执行"
STEP_TAR="未执行"
STEP_ENC="未执行"
STEP_UPLOAD="未执行"
TAR_SIZE="未知"
OUT_FILE=""

SQL_FILES=()

#=============================================================================
# 目录
#=============================================================================

mkdir -p "${LOCALDIR}" "${TEMPDIR}"
LOGDIR="$(dirname "${LOGFILE}")"
mkdir -p "${LOGDIR}"

#=============================================================================
# 日志
#=============================================================================

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "${msg}"
    printf '%s\n' "${msg}" >> "${LOGFILE}"
}

fail() {
    ERROR_DETAIL="$*"
    log "错误：$*"
    return 1
}

calculate_size() {
    local f="$1" size
    size="$(du -h "${f}" 2>/dev/null | awk '{print $1}')"
    printf '%s' "${size:-未知}"
}

# 文件年龄（天），基于 mtime —— 不解析文件名，避免 hostname 含下划线时失效
file_age_days() {
    local f="$1" mtime now
    if stat -c %Y "${f}" >/dev/null 2>&1; then
        mtime="$(stat -c %Y "${f}")"
    else
        mtime="$(stat -f %m "${f}")"
    fi
    now="$(date +%s)"
    printf '%s' "$(( (now - mtime) / 86400 ))"
}

#=============================================================================
# 防重入
#=============================================================================

# 上一轮还没跑完就直接退出，避免两次备份叠跑把磁盘打满
if command -v flock >/dev/null 2>&1; then
    exec 200>"${LOCKFILE}"
    if ! flock -n 200; then
        log "另一个备份进程正在运行，本次退出"
        exit 0
    fi
else
    log "警告：系统未提供 flock，跳过防重入检查"
fi

#=============================================================================
# 收尾：无论成败都走这里
#=============================================================================

cleanup_temp() {
    local f
    # 只清理 TEMPDIR 下的内容，TEMPDIR 为空或为 / 时直接跳过，防误删
    if [[ -z "${TEMPDIR}" || "${TEMPDIR}" == "/" ]]; then
        return 0
    fi
    for f in "${TEMPDIR}"/*; do
        [[ -e "${f}" ]] || continue
        rm -rf -- "${f}"
    done
}

on_exit() {
    local rc=$?

    DURATION=$(( $(date +%s) - STARTTIME ))

    if (( rc != 0 )); then
        STATUS="FAILED"
        STATUS_CN="失败"
        [[ -n "${ERROR_DETAIL}" ]] || ERROR_DETAIL="步骤「${CURRENT_STEP}」失败（退出码 ${rc}）"
    else
        STATUS="SUCCESS"
        STATUS_CN="成功"
    fi

    # 先清理，防止明文 dump 残留
    cleanup_temp

    if [[ "${NOTIFY_ENABLED}" == "true" ]]; then
        if ! send_notification; then
            log "警告：通知发送失败（备份本身的状态不受影响）"
        fi
    fi

    log "备份结束：${STATUS}，耗时 ${DURATION} 秒"

    # 通知失败不应该改变备份本身的退出码
    exit "${rc}"
}

trap on_exit EXIT

#=============================================================================
# 步骤包装：失败时记录是哪个步骤挂的
#=============================================================================

run_step() {
    local name="$1"; shift
    CURRENT_STEP="${name}"
    log "开始：${name}"
    local rc=0
    "$@" || rc=$?
    if (( rc == 0 )); then
        log "完成：${name}"
    else
        log "失败：${name}（退出码 ${rc}）"
        ERROR_DETAIL="步骤「${name}」失败（退出码 ${rc}）"
    fi
    return "${rc}"
}

#=============================================================================
# 1. 磁盘空间预检
#=============================================================================

check_disk_space() {
    local src_kb need_kb avail_kb

    if [[ ${#BACKUP_PATHS[@]} -eq 0 ]]; then
        return 0
    fi

    src_kb="$(du -sk "${BACKUP_PATHS[@]}" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    # 打包后约等于源大小，加密再产出一份同样大小的文件，留 2.5 倍余量
    need_kb=$(( src_kb * 25 / 10 ))
    avail_kb="$(df -Pk "${LOCALDIR}" | awk 'NR==2 {print $4}')"

    log "空间预检：源约 $(( src_kb / 1024 )) MB，预计需要约 $(( need_kb / 1024 )) MB，可用 $(( avail_kb / 1024 )) MB"

    if (( avail_kb < need_kb )); then
        fail "磁盘空间不足：预计需要约 $(( need_kb / 1024 )) MB，当前可用 $(( avail_kb / 1024 )) MB"
        return 1
    fi
    return 0
}

#=============================================================================
# 2. 数据库导出
#=============================================================================

dump_mysql_local() {
    local dumpfile="${TEMPDIR}/mysql_${BACKUPDATE}.sql"
    local opts=(
        --single-transaction --quick --routines --triggers --events
        --default-character-set=utf8mb4
    )
    local targets=()

    if [[ ${#MYSQL_DATABASE_NAMES[@]} -eq 0 ]]; then
        targets=(--all-databases)
    else
        targets=("${MYSQL_DATABASE_NAMES[@]}")
    fi

    if MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysqldump -u "${MYSQL_ROOT_USER}" \
        "${opts[@]}" "${targets[@]}" > "${dumpfile}"
    then
        SQL_FILES+=("${dumpfile}")
        STEP_DB="成功（$(calculate_size "${dumpfile}")）"
        log "数据库导出完成：${dumpfile}"
    else
        rm -f -- "${dumpfile}"
        STEP_DB="失败"
        fail "数据库导出失败"
        return 1
    fi
}

dump_mysql_docker() {
    local dumpfile="${TEMPDIR}/mysql_${BACKUPDATE}.sql"
    local cname="${MYSQL_DOCKER_CONTAINER}"

    if ! docker ps --format '{{.Names}}' | grep -qx "${cname}"; then
        STEP_DB="失败"
        fail "找不到运行中的容器 ${cname}"
        return 1
    fi

    local opts="--single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4"
    local targets="--all-databases"
    if [[ ${#MYSQL_DATABASE_NAMES[@]} -gt 0 ]]; then
        targets="${MYSQL_DATABASE_NAMES[*]}"
    fi

    # shellcheck disable=SC2086
    if docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "${cname}" \
        mysqldump -u "${MYSQL_ROOT_USER}" ${opts} ${targets} > "${dumpfile}"
    then
        SQL_FILES+=("${dumpfile}")
        STEP_DB="成功（$(calculate_size "${dumpfile}")）"
        log "数据库导出完成（容器 ${cname}）：${dumpfile}"
    else
        rm -f -- "${dumpfile}"
        STEP_DB="失败"
        fail "容器 ${cname} 内数据库导出失败"
        return 1
    fi
}

db_backup() {
    case "${DB_TYPE}" in
        none)
            STEP_DB="未启用"
            log "未启用数据库备份（DB_TYPE=none）"
            return 0
            ;;
        mysql)
            if [[ -z "${MYSQL_ROOT_PASSWORD}" ]]; then
                STEP_DB="失败"
                fail "DB_TYPE=mysql 但未配置 MYSQL_ROOT_PASSWORD"
                return 1
            fi
            if ! command -v mysqldump >/dev/null 2>&1; then
                STEP_DB="失败"
                fail "mysqldump 未安装"
                return 1
            fi
            dump_mysql_local
            ;;
        docker-mysql)
            if [[ -z "${MYSQL_ROOT_PASSWORD}" || -z "${MYSQL_DOCKER_CONTAINER}" ]]; then
                STEP_DB="失败"
                fail "DB_TYPE=docker-mysql 需要同时配置 MYSQL_ROOT_PASSWORD 和 MYSQL_DOCKER_CONTAINER"
                return 1
            fi
            dump_mysql_docker
            ;;
        *)
            STEP_DB="失败"
            fail "未知的 DB_TYPE：${DB_TYPE}（可选 none / mysql / docker-mysql）"
            return 1
            ;;
    esac
}

#=============================================================================
# 3. 打包
#=============================================================================

do_tar() {
    local targets=()
    local p

    for p in "${BACKUP_PATHS[@]}"; do
        if [[ ! -e "${p}" ]]; then
            STEP_TAR="失败"
            fail "备份路径不存在：${p}"
            return 1
        fi
        targets+=("${p}")
    done

    for p in ${SQL_FILES[@]+"${SQL_FILES[@]}"}; do
        targets+=("${p}")
    done

    if [[ ${#targets[@]} -eq 0 ]]; then
        STEP_TAR="失败"
        fail "没有可打包的内容，请检查 BACKUP_PATHS 与数据库配置"
        return 1
    fi

    CURRENT_STEP="打包"
    if ! tar -zcPf "${LOCALDIR}/${SHORT_HOST}_${BACKUPDATE}.tgz" "${targets[@]}"; then
        STEP_TAR="失败"
        fail "tar 打包失败"
        return 1
    fi

    TARFILE="${LOCALDIR}/${SHORT_HOST}_${BACKUPDATE}.tgz"
    TAR_SIZE="$(calculate_size "${TARFILE}")"
    STEP_TAR="成功（${TAR_SIZE}）"
    log "打包完成：${TARFILE}（${TAR_SIZE}）"
}

#=============================================================================
# 4. 加密
#=============================================================================

do_encrypt() {
    if [[ "${ENCRYPT}" != "true" ]]; then
        STEP_ENC="未启用"
        OUT_FILE="${TARFILE}"
        log "未启用加密（ENCRYPT=false）"
        return 0
    fi

    if [[ -z "${BACKUP_PASSWORD}" ]]; then
        STEP_ENC="失败"
        fail "ENCRYPT=true 但未配置 BACKUP_PASSWORD"
        return 1
    fi

    local encfile="${TARFILE}.enc"
    log "开始加密：${TARFILE}"

    if ! openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -md sha256 \
        -in "${TARFILE}" -out "${encfile}" -pass pass:"${BACKUP_PASSWORD}"
    then
        STEP_ENC="失败"
        # 关键：加密失败时绝不删除明文归档，保留残件供排查
        rm -f -- "${encfile}"
        fail "加密失败，已保留未加密的 ${TARFILE} 供人工处理"
        return 1
    fi

    # 产物必须存在且非空，才认为是真的成功
    if [[ ! -s "${encfile}" ]]; then
        STEP_ENC="失败"
        fail "加密产物不存在或为空：${encfile}（明文归档已保留）"
        return 1
    fi

    # 到这里才允许删明文
    rm -f -- "${TARFILE}"
    OUT_FILE="${encfile}"
    STEP_ENC="成功（$(calculate_size "${encfile}")）"
    log "加密完成：${encfile}"
}

#=============================================================================
# 5. 上传
#=============================================================================

do_upload() {
    if [[ "${RCLONE_ENABLED}" != "true" ]]; then
        STEP_UPLOAD="未启用"
        log "未启用上传（RCLONE_ENABLED=false）"
        return 0
    fi

    # 原版在这里是静默跳过：rclone 没装就什么都不发生也不报错
    if ! command -v rclone >/dev/null 2>&1; then
        STEP_UPLOAD="失败"
        fail "RCLONE_ENABLED=true 但系统未安装 rclone"
        return 1
    fi

    if [[ -z "${RCLONE_REMOTE}" || -z "${RCLONE_FOLDER}" ]]; then
        STEP_UPLOAD="失败"
        fail "需要同时配置 RCLONE_REMOTE 与 RCLONE_FOLDER"
        return 1
    fi

    if [[ ! -s "${OUT_FILE}" ]]; then
        STEP_UPLOAD="失败"
        fail "待上传文件不存在或为空：${OUT_FILE}"
        return 1
    fi

    local dest="${RCLONE_REMOTE}:${RCLONE_FOLDER}"
    log "开始上传：${OUT_FILE} -> ${dest}"

    if ! rclone copy "${OUT_FILE}" "${dest}" \
        --transfers "${RCLONE_TRANSFERS}" \
        --tpslimit "${RCLONE_TPSLIMIT}" \
        --drive-chunk-size 64M \
        --drive-use-trash=false \
        --fast-list \
        --bwlimit "${RCLONE_BWLIMIT}" \
        --retries 3 \
        --low-level-retries 10 \
        --stats-one-line \
        --log-file "${LOGFILE}" \
        --log-level INFO
    then
        STEP_UPLOAD="失败"
        fail "上传到 ${dest} 失败"
        return 1
    fi

    # 校验：远端必须能看到同名文件，且字节数一致
    # 不校验就等于没备份 —— rclone 报成功但文件没落地的情况是存在的
    local local_size remote_size listing
    local_size="$(stat -c %s "${OUT_FILE}" 2>/dev/null || stat -f %z "${OUT_FILE}")"
    listing="$(rclone lsl "${dest}/$(basename "${OUT_FILE}")" 2>/dev/null || true)"

    if [[ -z "${listing}" ]]; then
        STEP_UPLOAD="校验失败"
        fail "上传后未在远端找到文件：${dest}/$(basename "${OUT_FILE}")"
        return 1
    fi

    remote_size="$(printf '%s' "${listing}" | awk 'NR==1 {print $1}')"
    if [[ "${remote_size}" != "${local_size}" ]]; then
        STEP_UPLOAD="校验失败"
        fail "远端文件大小 ${remote_size} 字节与本地 ${local_size} 字节不一致"
        return 1
    fi

    STEP_UPLOAD="成功 -> ${dest}"
    log "上传完成并校验通过：${dest}/$(basename "${OUT_FILE}")"
}

#=============================================================================
# 6. 清理
#=============================================================================

clean_local() {
    local f age removed=0

    while IFS= read -r -d '' f; do
        age="$(file_age_days "${f}")"
        if (( age > KEEP_LOCAL_DAYS )); then
            log "删除本地过期备份：$(basename "${f}")（${age} 天）"
            rm -f -- "${f}"
            removed=$(( removed + 1 ))
        fi
    done < <(find "${LOCALDIR}" -maxdepth 1 -type f \
        \( -name '*.tgz' -o -name '*.tgz.enc' \) -print0 2>/dev/null)

    log "本地清理完成，删除 ${removed} 个文件（保留 ${KEEP_LOCAL_DAYS} 天）"
}

clean_remote() {
    if [[ "${RCLONE_ENABLED}" != "true" ]]; then
        return 0
    fi

    # 远端清理只在备份目录明确设置时执行，避免误删根目录
    if [[ -z "${RCLONE_REMOTE}" || -z "${RCLONE_FOLDER}" ]]; then
        log "远端目录未配置，跳过远端清理"
        return 0
    fi

    if ! command -v rclone >/dev/null 2>&1; then
        log "rclone 未安装，跳过远端清理"
        return 0
    fi

    # 与本地保留天数解耦：本地省空间，云端保命
    log "清理远端 ${KEEP_REMOTE_DAYS} 天前的备份"
    if rclone delete "${RCLONE_REMOTE}:${RCLONE_FOLDER}" \
        --min-age "${KEEP_REMOTE_DAYS}d" \
        --drive-use-trash=false \
        --log-file "${LOGFILE}" \
        --log-level INFO
    then
        log "远端清理完成"
    else
        log "警告：远端清理失败，但不影响本次备份结果"
    fi
}

cleanup_backups() {
    CURRENT_STEP="清理"
    clean_local
    clean_remote
}

#=============================================================================
# 7. 通知
#=============================================================================

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "${s}"
}

render_template() {
    local tpl="$1"
    tpl="${tpl//'{{HOSTNAME}}'/${SHORT_HOST}}"
    tpl="${tpl//'{{STATUS}}'/${STATUS}}"
    tpl="${tpl//'{{STATUS_CN}}'/${STATUS_CN}}"
    tpl="${tpl//'{{DATE}}'/$(date '+%Y-%m-%d %H:%M:%S')}"
    tpl="${tpl//'{{DB_STATUS}}'/${STEP_DB}}"
    tpl="${tpl//'{{TAR_SIZE}}'/${TAR_SIZE}}"
    tpl="${tpl//'{{ENC_STATUS}}'/${STEP_ENC}}"
    tpl="${tpl//'{{UPLOAD_STATUS}}'/${STEP_UPLOAD}}"
    tpl="${tpl//'{{REMOTE}}'/${RCLONE_REMOTE}${RCLONE_FOLDER:+/${RCLONE_FOLDER}}}"
    tpl="${tpl//'{{DURATION}}'/${DURATION}}"
    tpl="${tpl//'{{FILE}}'/${OUT_FILE##*/}}"
    tpl="${tpl//'{{ERROR}}'/${ERROR_DETAIL}}"
    tpl="${tpl//'{{NOTE}}'/${NOTIFY_NOTE:-}}"
    printf '%s' "${tpl}"
}

notify_smtp() {
    local subject="$1" body="$2" mailfile url
    mailfile="$(mktemp)"

    {
        printf 'From: %s\r\n' "${SMTP_FROM:-${SMTP_USER}}"
        printf 'To: %s\r\n' "${SMTP_TO}"
        printf 'Subject: %s\r\n' "${subject}"
        printf 'Date: %s\r\n' "$(date -R)"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf '\r\n'
        printf '%s\r\n' "${body}"
    } > "${mailfile}"

    if [[ "${SMTP_TLS:-ssl}" == "ssl" ]]; then
        url="smtps://${SMTP_HOST}:${SMTP_PORT:-465}"
        curl -sS --url "${url}" \
            --mail-from "${SMTP_FROM:-${SMTP_USER}}" \
            --mail-rcpt "${SMTP_TO}" \
            --user "${SMTP_USER}:${SMTP_PASS}" \
            --upload-file "${mailfile}"
    else
        url="smtp://${SMTP_HOST}:${SMTP_PORT:-587}"
        curl -sS --url "${url}" --ssl-reqd \
            --mail-from "${SMTP_FROM:-${SMTP_USER}}" \
            --mail-rcpt "${SMTP_TO}" \
            --user "${SMTP_USER}:${SMTP_PASS}" \
            --upload-file "${mailfile}"
    fi
    local rc=$?
    rm -f -- "${mailfile}"
    return "${rc}"
}

notify_agentmail() {
    local subject="$1" body="$2" payload
    payload="$(printf '{"to":[{"email":"%s"}],"subject":"%s","text":"%s"}' \
        "${AGENTMAIL_TO}" \
        "$(json_escape "${subject}")" \
        "$(json_escape "${body}")")"

    curl -sS -X POST \
        "${AGENTMAIL_BASE:-https://api.agentmail.to}/v0/inboxes/${AGENTMAIL_INBOX}/messages/send" \
        -H "Authorization: Bearer ${AGENTMAIL_KEY}" \
        -H "Content-Type: application/json" \
        -d "${payload}"
}

notify_ntfy() {
    local subject="$1" body="$2"
    curl -sS -d "${body}" \
        -H "Title: ${subject}" \
        -H "Tags: floppy_disk" \
        "${NTFY_URL}"
}

notify_custom() {
    local subject="$1" body="$2"
    # 通过环境变量把内容交给自定义命令
    NOTIFY_SUBJECT_RENDERED="${subject}" \
    NOTIFY_BODY_RENDERED="${body}" \
    bash -c "${NOTIFY_CUSTOM_CMD}"
}

notify_webhook() {
    local subject="$1" body="$2" payload

    # 结构化字段 + 渲染好的文本一起发。
    # 服务端会完整保留原始 payload，同时尽力提取 host/status 等字段用于展示，
    # 所以以后脚本这边加字段，不需要同步改服务端。
    payload="$(printf '{"host":"%s","status":"%s","subject":"%s","body":"%s","duration":"%s","size":"%s","file":"%s","steps":{"db":"%s","tar":"%s","enc":"%s","upload":"%s"},"error":"%s"}' \
        "$(json_escape "${SHORT_HOST}")" \
        "$(json_escape "${STATUS}")" \
        "$(json_escape "${subject}")" \
        "$(json_escape "${body}")" \
        "$(json_escape "${DURATION}")" \
        "$(json_escape "${TAR_SIZE}")" \
        "$(json_escape "${OUT_FILE##*/}")" \
        "$(json_escape "${STEP_DB}")" \
        "$(json_escape "${STEP_TAR}")" \
        "$(json_escape "${STEP_ENC}")" \
        "$(json_escape "${STEP_UPLOAD}")" \
        "$(json_escape "${ERROR_DETAIL}")")"

    if [[ -z "${NOTIFY_WEBHOOK_URL}" || -z "${NOTIFY_WEBHOOK_TOKEN}" ]]; then
        fail "webhook 模式缺少 NOTIFY_WEBHOOK_URL 或 NOTIFY_WEBHOOK_TOKEN"
        return 1
    fi

    # -f 是必须的：不加的话服务端返回 401/500，curl 依然退出 0，
    # 脚本会误以为"通知发送成功"。加了 -f，HTTP >= 400 时退出码 22。
    #
    # --noproxy：跳过系统代理。踩过的坑——机器上只要存在 HTTP_PROXY 环境变量，
    # curl 会把发往 127.0.0.1 的上报也丢给代理，代理返回 502，
    # 表现成"通知失败"但实际是请求压根没到服务端。
    local noproxy_args=()
    if [[ -n "${NOTIFY_NO_PROXY}" ]]; then
        noproxy_args=(--noproxy "${NOTIFY_NO_PROXY}")
    fi

    curl -sS -f --max-time 20 ${noproxy_args[@]+"${noproxy_args[@]}"} -X POST \
        "${NOTIFY_WEBHOOK_URL%/}/api/report?token=${NOTIFY_WEBHOOK_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "${payload}"
}

notify_notion() {
    local subject="$1" body="$2" payload response children
    # rc 必须先初始化：命令替换失败时，用 "|| rc=$?" 才能既保住退出码
    # 又不让 set -e 直接终止脚本（详见下面 curl 处的说明）
    local rc=0

    if [[ -z "${NOTION_TOKEN}" || -z "${NOTION_TARGET_ID}" ]]; then
        fail "Notion 模式缺少 NOTION_TOKEN 或 NOTION_TARGET_ID"
        return 1
    fi

    # 提前校验 token 格式。Notion 的 401 报错很含糊，
    # 在本地先拦一次能直接告诉你"是 token 抄错了"还是"是权限没给"。
    if [[ "${NOTION_TOKEN}" != ntn_* && "${NOTION_TOKEN}" != secret_* ]]; then
        fail "NOTION_TOKEN 格式不对，应以 ntn_ 或 secret_ 开头，当前开头为 ${NOTION_TOKEN:0:8}..."
        return 1
    fi

    # 正文以代码块写入页面，保留换行和缩进
    children="$(printf '[{"object":"block","type":"code","code":{"rich_text":[{"type":"text","text":{"content":"%s"}}],"language":"plain text"}}]' \
        "$(json_escape "${body}")")"

    if [[ "${NOTION_TARGET}" == "page" ]]; then
        # 追加流水到页面：不需要列名，配置最少，但只有一条条记录，没法筛选排序
        #
        # 注意这里的 "|| rc=$?" 不能省。本脚本开了 set -e，
        # 如果写成 response="$(curl ...)" 然后另起一行 rc=$?，
        # curl 一失败就会在赋值那一步直接终止整个脚本，
        # 后面那句 fail 和 rc 判断根本执行不到 ——
        # 结果是「通知失败」这件事没有日志、也没有告警，只剩一个静默的非零退出码。
        rc=0
        response="$(curl -sS --max-time 20 -X PATCH \
            "${NOTION_API_BASE}/v1/blocks/${NOTION_TARGET_ID}/children" \
            -H "Authorization: Bearer ${NOTION_TOKEN}" \
            -H "Notion-Version: ${NOTION_VERSION}" \
            -H 'Content-Type: application/json' \
            -d "{\"children\":${children}}")" || rc=$?
    else
        payload="$(printf '{"parent":{"database_id":"%s"},"properties":{"%s":{"title":[{"text":{"content":"%s"}}]},"%s":{"select":{"name":"%s"}},"%s":{"date":{"start":"%s"}}},"children":%s}' \
            "${NOTION_TARGET_ID}" \
            "$(json_escape "${NOTION_TITLE_PROP}")" \
            "$(json_escape "${subject}")" \
            "$(json_escape "${NOTION_STATUS_PROP}")" \
            "$(json_escape "${STATUS_CN}")" \
            "$(json_escape "${NOTION_DATE_PROP}")" \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            "${children}")"
        rc=0
        response="$(curl -sS --max-time 20 -X POST \
            "${NOTION_API_BASE}/v1/pages" \
            -H "Authorization: Bearer ${NOTION_TOKEN}" \
            -H "Notion-Version: ${NOTION_VERSION}" \
            -H 'Content-Type: application/json' \
            -d "${payload}")" || rc=$?
    fi

    if [[ "${rc}" -ne 0 ]]; then
        fail "Notion 请求失败（curl 退出码 ${rc}），网络不通或 DNS 解析失败"
        return 1
    fi

    # 这里故意不用 curl -f。Notion 的错误信息在响应体里，
    # validation_error 会直接指出「哪个列名不存在」——这是最有用的排错线索，
    # 用 -f 丢掉了 body，就只剩一句没头没尾的 HTTP 400。
    if printf '%s' "${response}" | grep -q '"object"[[:space:]]*:[[:space:]]*"error"'; then
        fail "Notion 拒绝写入：$(printf '%s' "${response}" | tr -d '\n' | head -c 400)"
        return 1
    fi

    return 0
}

send_notification() {
    local subject body subject_tpl body_tpl

    # 坑：绝对不能写成 ${NOTIFY_SUBJECT:-[备份] {{STATUS}} {{HOSTNAME}}}。
    # bash 解析 ${VAR:-word} 时，遇到 word 里第一个 } 就判定展开结束，
    # 剩下的 "} {{HOSTNAME}}" 会被当普通字面量拼回结果。必须分两步赋默认值。
    subject_tpl="${NOTIFY_SUBJECT:-}"
    if [[ -z "${subject_tpl}" ]]; then
        subject_tpl='[备份] {{STATUS_CN}} - {{HOSTNAME}}'
    fi

    body_tpl="${NOTIFY_BODY:-}"
    if [[ -z "${body_tpl}" ]]; then
        body_tpl='主机: {{HOSTNAME}}
状态: {{STATUS_CN}}
时间: {{DATE}}
耗时: {{DURATION}} 秒
文件: {{FILE}}
大小: {{TAR_SIZE}}
数据库: {{DB_STATUS}}
加密: {{ENC_STATUS}}
上传: {{UPLOAD_STATUS}}
失败原因: {{ERROR}}'
    fi

    subject="$(render_template "${subject_tpl}")"
    body="$(render_template "${body_tpl}")"

    log "发送通知（${NOTIFY_TYPE}）：${subject}"

    case "${NOTIFY_TYPE}" in
        smtp)      notify_smtp "${subject}" "${body}" ;;
        agentmail) notify_agentmail "${subject}" "${body}" ;;
        ntfy)      notify_ntfy "${subject}" "${body}" ;;
        webhook)   notify_webhook "${subject}" "${body}" ;;
        notion)    notify_notion "${subject}" "${body}" ;;
        custom)    notify_custom "${subject}" "${body}" ;;
        *)
            log "警告：未知的 NOTIFY_TYPE：${NOTIFY_TYPE}"
            return 1
            ;;
    esac
}

#=============================================================================
# 主流程
#=============================================================================

main() {
    CURRENT_STEP="启动"
    log "==================== 备份开始 ===================="
    log "主机：${SHORT_HOST}，脚本：${SCRIPT_NAME}，配置：${CONFIG_FILE}"

    run_step "磁盘空间预检" check_disk_space || return 1
    run_step "数据库导出"   db_backup        || return 1
    run_step "打包"         do_tar           || return 1
    run_step "加密"         do_encrypt       || return 1
    run_step "上传"         do_upload        || return 1
    run_step "清理"         cleanup_backups  || return 1

    CURRENT_STEP="完成"
    return 0
}

main
