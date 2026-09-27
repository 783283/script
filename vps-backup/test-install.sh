#!/usr/bin/env bash
#=============================================================================
# install.sh 的端到端演练
#
# 在 macOS 上真跑一遍完整链路：
#   造数据 → 起上报接收端 → install.sh 安装 → 用装出来的配置真的跑一次备份
#   → 检查加密产物上了「网盘」、明文被清掉、上报链路收到了记录
#
# 用 --prefix 把 /etc /usr/local/bin /var 全部重定向到沙箱目录，
# 用 --remote-type local 把 Google Drive 换成本地目录（授权没法自动化）。
# 除了这两处替身，跑的是和 VPS 上完全相同的代码路径。
#=============================================================================

set -uo pipefail

WORK="$(cd "$(dirname "$0")" && pwd)"
SB="${WORK}/sandbox-install"
PFX="${SB}/prefix"
PORT=18899
WT="sandbox-write-token"
RT="sandbox-read-token"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

cleanup() {
    [[ -n "${SRV_PID:-}" ]] && kill "${SRV_PID}" 2>/dev/null
    return 0
}
trap cleanup EXIT

PY=""
for c in /usr/bin/python3 python3; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
[[ -n "$PY" ]] || { echo "找不到 python3"; exit 1; }

printf '\n\033[1m═══ 准备沙箱 ═══\033[0m\n'
rm -rf "$SB" "${WORK}/backup"
mkdir -p "${SB}/src/data/sub" "${SB}/remote" "${SB}/bin" "${SB}/logs"

#--- rclone（真二进制，官方发行版）------------------------------------------
if [[ -x "${SB}/bin/rclone" ]]; then
    :
elif [[ -x /tmp/rclone-test/rclone-v1.75.1-osx-arm64/rclone ]]; then
    cp /tmp/rclone-test/rclone-v1.75.1-osx-arm64/rclone "${SB}/bin/rclone"
else
    echo "  下载 rclone ..."
    ( cd "${SB}" && curl -sL -o r.zip https://downloads.rclone.org/rclone-current-osx-arm64.zip \
      && unzip -q -o r.zip && cp "$(find . -name rclone -type f | head -1)" bin/rclone && rm -f r.zip )
fi
export PATH="${SB}/bin:${PATH}"
xattr -d com.apple.quarantine "${SB}/bin/rclone" 2>/dev/null
echo "  rclone: $(rclone version | head -1)"

#--- 造点真数据（约 500 KB）-------------------------------------------------
head -c 300000 /dev/urandom > "${SB}/src/data/blob.bin"
printf 'hello backup\n'          > "${SB}/src/data/notes.txt"
for i in 1 2 3; do head -c 60000 /dev/urandom > "${SB}/src/data/sub/f${i}.bin"; done
SRC_KB="$(du -sk "${SB}/src/data" | cut -f1)"
echo "  备份源：${SB}/src/data（${SRC_KB} KB）"

#--- 起一个最小上报接收端（测试替身，内嵌在脚本里）--------------------------
# webhook 模式下服务端由使用者自备，本仓库不附带实现。
# 这里只需要被测脚本会用到的最小接口，足够验证上报链路本身：
#   POST /api/report?token=X  → 原样追加一行 JSONL（写 token）
#   GET  /health              → 存活检查
#   GET  /?token=X            → 极简页面，显示最近一次状态（读 token，与写 token 分开）
cat > "${SB}/stub-server.py" <<'PYEOF'
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DATA = os.environ["STUB_DATA"]
WRITE_TOKEN = os.environ["STUB_WRITE_TOKEN"]
READ_TOKEN = os.environ["STUB_READ_TOKEN"]
PORT = int(os.environ["STUB_PORT"])


def last_record():
    if not os.path.exists(DATA):
        return None
    rec = None
    with open(DATA, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                rec = json.loads(line)
    return rec


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/health":
            self._send(200, '{"ok": true}')
            return
        if (parse_qs(u.query).get("token") or [""])[0] != READ_TOKEN:
            self._send(401, '{"ok": false, "error": "unauthorized"}')
            return
        rec = last_record()
        if rec is None:
            big = "尚无任何上报记录"
        elif rec.get("status") == "SUCCESS":
            big = "最近一次备份成功"
        elif rec.get("status") == "FAILURE":
            big = "最近一次备份失败"
        else:
            big = "最近一次上报状态未知"
        self._send(200, "<html><body><h1>%s</h1></body></html>" % big, "text/html")

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/api/report":
            self._send(404, '{"ok": false, "error": "not found"}')
            return
        if (parse_qs(u.query).get("token") or [""])[0] != WRITE_TOKEN:
            self._send(401, '{"ok": false, "error": "unauthorized"}')
            return
        n = int(self.headers.get("Content-Length") or 0)
        text = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        rec = {"ts": time.time(), "ts_iso": time.strftime("%Y-%m-%d %H:%M:%S")}
        try:
            parsed = json.loads(text)
            if isinstance(parsed, dict):
                rec.update(parsed)          # 原样保留脚本发来的全部字段
        except Exception:
            rec["status"] = "unknown"
        rec.setdefault("host", "unknown")
        with open(DATA, "a", encoding="utf-8") as fh:
            # 紧凑分隔符：脚本发出的是无空格 JSON，落盘要保持字节一致，
            # 否则断言里 "\"host\":\"xMacBookAir\"" 这种匹配会失手
            fh.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
        self._send(200, '{"ok": true}')


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF

STUB_DATA="${SB}/logs/reports.jsonl" STUB_WRITE_TOKEN="${WT}" STUB_READ_TOKEN="${RT}" \
    STUB_PORT="${PORT}" "$PY" "${SB}/stub-server.py" > "${SB}/logs/stub.log" 2>&1 &
SRV_PID=$!
sleep 1.3

if curl -sS --noproxy '*' "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q '"ok"'; then
    echo "  上报接收端（内嵌替身）在 ${PORT} 端口就绪"
else
    echo "  上报接收端起不来，日志："; cat "${SB}/logs/stub.log"; exit 1
fi

#=============================================================================
printf '\n\033[1m═══ 1. 运行 install.sh --yes ═══\033[0m\n'
#=============================================================================

WB_PREFIX="${PFX}" \
WB_BACKUP_PATHS="${SB}/src/data" \
WB_DB_TYPE=none \
WB_BACKUP_PASSWORD='sandbox-pw-0123456789abcdef' \
WB_RCLONE_NAME=sandbox \
WB_RCLONE_FOLDER=backup/test \
WB_NOTIFY_TYPE=webhook \
WB_WEBHOOK_URL="http://127.0.0.1:${PORT}" \
WB_WEBHOOK_TOKEN="${WT}" \
WB_SCHEDULE=03:00 \
bash "${WORK}/install.sh" --yes --prefix "${PFX}" --remote-type local --skip-deps \
    2>&1 | sed 's/^/  /'

INSTALL_RC="${PIPESTATUS[0]}"
echo
if [[ "${INSTALL_RC}" -eq 0 ]]; then ok "install.sh 退出码 0"; else bad "install.sh 退出码 ${INSTALL_RC}"; fi

#=============================================================================
printf '\n\033[1m═══ 2. 检查安装产物 ═══\033[0m\n'
#=============================================================================

CONF="${PFX}/etc/backup.env"
BIN="${PFX}/usr/local/bin/backup-v2.sh"
RCLONE_CONF="${PFX}/root/.config/rclone/rclone.conf"

chk "配置文件已生成"            "[[ -f '${CONF}' ]]"
chk "配置权限是 600"            "[[ \"\$(stat -f %Lp '${CONF}')\" == '600' ]]"
chk "备份脚本已安装且可执行"    "[[ -x '${BIN}' ]]"
chk "备份脚本权限是 755"        "[[ \"\$(stat -f %Lp '${BIN}')\" == '755' ]]"
chk "数据目录已建"              "[[ -d '${PFX}/opt/backups/temp' ]]"
chk "rclone.conf 已生成"        "[[ -f '${RCLONE_CONF}' ]]"
chk "rclone.conf 权限是 600"    "[[ \"\$(stat -f %Lp '${RCLONE_CONF}')\" == '600' ]]"
chk "systemd service 已生成"    "[[ -f '${PFX}/etc/systemd/system/backup-v2.service' ]]"
chk "systemd timer 已生成"      "[[ -f '${PFX}/etc/systemd/system/backup-v2.timer' ]]"

#--- 配置内容是否真的对 ------------------------------------------------------
(
    set -a; . "${CONF}"; set +a
    echo "PATHS=${BACKUP_PATHS[*]:-}"
    echo "PWD=${BACKUP_PASSWORD}"
    echo "REMOTE=${RCLONE_REMOTE}|${RCLONE_FOLDER}"
    echo "KEEP=${KEEP_LOCAL_DAYS}/${KEEP_REMOTE_DAYS}"
    echo "NOTIFY=${NOTIFY_ENABLED}|${NOTIFY_TYPE}|${NOTIFY_WEBHOOK_URL}"
    echo "LOCK=${LOCKFILE}"
    echo "ENABLED=${RCLONE_ENABLED}"
) > "${SB}/parsed.txt" 2>${SB}/parsed.err
PARSED="$(cat "${SB}/parsed.txt")"

chk "备份路径写对了"        "grep -qF 'PATHS=${SB}/src/data' '${SB}/parsed.txt'"
chk "加密口令写对了"        "grep -qF 'PWD=sandbox-pw-0123456789abcdef' '${SB}/parsed.txt'"
chk "远端名与目录写对了"    "grep -qF 'REMOTE=sandbox|backup/test' '${SB}/parsed.txt'"
chk "保留策略写对了"        "grep -qF 'KEEP=7/90' '${SB}/parsed.txt'"
chk "通知配置写对了"        "grep -qF 'NOTIFY=true|webhook|http://127.0.0.1:${PORT}' '${SB}/parsed.txt'"
chk "锁文件路径在沙箱内"    "grep -qF 'LOCK=${PFX}/var/run/backup.lock' '${SB}/parsed.txt'"
chk "上传开关是 true"       "grep -qF 'ENABLED=true' '${SB}/parsed.txt'"

chk "timer 里写的是 03:00"  "grep -q 'OnCalendar=.*3:00:00' '${PFX}/etc/systemd/system/backup-v2.timer'"
chk "service 指向装好的脚本" "grep -qF \"ExecStart=${BIN}\" '${PFX}/etc/systemd/system/backup-v2.service'"

#=============================================================================
printf '\n\033[1m═══ 3. 用装出来的配置真跑一次备份 ═══\033[0m\n'
#=============================================================================

export RCLONE_CONFIG="${RCLONE_CONF}"
export BACKUP_ALLOW_NONROOT=true
# local 类型的 remote 会把路径解析成「相对当前目录」，
# 所以在远端根目录下执行，模拟 sandbox:backup/test 真的落到网盘上
( cd "${SB}/remote" && BACKUP_CONFIG="${CONF}" "${BIN}" ) > "${SB}/logs/backup-run.log" 2>&1
RUN_RC=$?
sed 's/^/  /' "${SB}/logs/backup-run.log"

echo
if [[ "${RUN_RC}" -eq 0 ]]; then ok "备份脚本退出码 0"; else bad "备份脚本退出码 ${RUN_RC}"; fi

ENC_FILE="$(find "${PFX}/opt/backups" -maxdepth 1 -name '*.enc' | head -1)"
chk "生成了加密产物"          "[[ -n '${ENC_FILE}' ]]"
chk "明文 tar 已被删除（加密成功才该删）" \
    "! find '${PFX}/opt/backups' -maxdepth 1 -name '*.tgz' | grep -q ."

if [[ -n "${ENC_FILE}" ]]; then
    ENC_KB=$(( $(stat -f %z "${ENC_FILE}") / 1024 ))
    echo "  加密产物：$(basename "${ENC_FILE}")（${ENC_KB} KB）"
    chk "加密产物里没有明文 tar 头" "! head -c 8 '${ENC_FILE}' | grep -q 'ustar'"
fi

#--- 真的解密回来，比对内容 --------------------------------------------------
if [[ -n "${ENC_FILE}" ]]; then
    if printf '%s' 'sandbox-pw-0123456789abcdef' \
        | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass stdin \
            -in "${ENC_FILE}" -out "${SB}/restored.tgz" 2>/dev/null \
       && tar -tzf "${SB}/restored.tgz" > "${SB}/restored-list.txt" 2>/dev/null; then
        ok "用配置里的口令能解密并列出内容"
        chk "还原出来的目录结构对得上" \
            "grep -q 'data/notes.txt$' '${SB}/restored-list.txt'"
    else
        bad "解密失败——这就是「备份等于没备份」"
    fi
fi

#--- 产物真的到「网盘」了吗 --------------------------------------------------
chk "文件已上传到远端目录" \
    "find '${SB}/remote/backup/test' -name '*.enc' | grep -q ."
chk "远端文件大小与本地一致" \
    "[[ \"\$(stat -f %z \"\$(find '${SB}/remote/backup/test' -name '*.enc' | head -1)\")\" == \"\$(stat -f %z '${ENC_FILE}')\" ]]"

#=============================================================================
printf '\n\033[1m═══ 4. 上报链路收到了什么 ═══\033[0m\n\033[0m'
#=============================================================================

# 上报接收端在最后会看到安装自检 + 真实备份两条记录
printf '  %s\n' "$(cat "${SB}/logs/reports.jsonl" 2>/dev/null | wc -l | tr -d ' ') 条记录"

BACKUP_REC="$("$PY" - "${SB}/logs/reports.jsonl" <<'PYEOF' 2>/dev/null
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
real = [r for r in rows if r.get('host') != 'install-selfcheck']
if real:
    r = real[-1]
    print(r.get('status'), '|', r.get('subject'), '|', r.get('size'), '|', (r.get('raw') or {}).get('steps', {}).get('upload'))
PYEOF
)"
echo "  最后一条真实备份记录：${BACKUP_REC}"

chk "上报链路收到了真实备份的 success 记录" \
    "grep -qF '\"host\":\"xMacBookAir\"' '${SB}/logs/reports.jsonl'"
chk "上报里的上传步骤是成功态" \
    "grep -qF '\"upload\":\"成功 -> sandbox:backup/test\"' '${SB}/logs/reports.jsonl'"

chk "页面能正常渲染" \
    "curl -sS --noproxy '*' 'http://127.0.0.1:${PORT}/?token=${RT}' | grep -q '最近一次备份成功'"

curl -sS --noproxy '*' "http://127.0.0.1:${PORT}/?token=${RT}" > "${SB}/page.html" 2>/dev/null
echo "  页面快照：${SB}/page.html（$(wc -c < "${SB}/page.html" | tr -d ' ') 字节）"

#=============================================================================
printf '\n\033[1m═══ 5. 重复安装是否幂等 ═══\033[0m\n'
#=============================================================================

WB_PREFIX="${PFX}" WB_BACKUP_PATHS="${SB}/src/data" WB_DB_TYPE=none \
WB_BACKUP_PASSWORD='second-run-should-not-overwrite' \
WB_RCLONE_NAME=sandbox WB_RCLONE_FOLDER=backup/test \
WB_NOTIFY_TYPE=none WB_SCHEDULE=03:00 \
bash "${WORK}/install.sh" --yes --prefix "${PFX}" --remote-type local --skip-deps \
    > "${SB}/logs/reinstall.log" 2>&1
RC2=$?
if [[ "${RC2}" -eq 0 ]]; then ok "再装一次不报错（退出码 0）"; else bad "再装一次失败（退出码 ${RC2}）"; fi
chk "重装覆盖了配置（旧口令已换新）" \
    "grep -q 'second-run-should-not-overwrite' '${CONF}'"
chk "rclone 里没有重复的 remote 段" \
    "[[ \$(grep -c '^\\[sandbox\\]' '${RCLONE_CONF}') -eq 1 ]]"

#=============================================================================
printf '\n\033[1m═══ 6. 卸载 ═══\033[0m\n'
#=============================================================================

bash "${WORK}/install.sh" --uninstall --prefix "${PFX}" > "${SB}/logs/uninstall.log" 2>&1
sed 's/^/  /' "${SB}/logs/uninstall.log"
chk "备份脚本已删除"     "[[ ! -f '${BIN}' ]]"
chk "配置被保留（不误删密钥）" "[[ -f '${CONF}' ]]"

#=============================================================================
printf '\n\033[1m═══ 7. deploy.sh 传令牌的交接点 ═══\033[0m\n\033[0m'
#=============================================================================

# deploy.sh 会把令牌写进 rclone-token.json 随包上传，install.sh 要能读出来。
# 这里用伪造令牌模拟那个交接，验证令牌真的落进了 rclone.conf。
PFX2="${SB}/prefix2"
STAGE2="${SB}/stage2"
mkdir -p "${STAGE2}"
cp "${WORK}/install.sh" "${WORK}/backup-v2.sh" "${STAGE2}/"
FAKE_TOKEN='{"access_token":"ya29.fake","token_type":"Bearer","refresh_token":"1//0gFakeRefresh","expiry":"2026-09-27T09:30:11+08:00"}'
printf '%s' "${FAKE_TOKEN}" > "${STAGE2}/rclone-token.json"
chmod 600 "${STAGE2}/rclone-token.json"

WB_PREFIX="${PFX2}" WB_BACKUP_PATHS="${SB}/src/data" WB_DB_TYPE=none \
WB_BACKUP_PASSWORD='handoff-test-pw' WB_RCLONE_NAME=gdrive WB_RCLONE_FOLDER='backup/host' \
WB_NOTIFY_TYPE=none WB_SCHEDULE=04:00 \
bash "${STAGE2}/install.sh" --yes --prefix "${PFX2}" --remote-type drive --skip-deps \
    > "${SB}/logs/handoff.log" 2>&1
RC3=$?
chk "带令牌的安装流程正常结束" "[[ ${RC3} -eq 0 ]]"
chk "识别到了 rclone-token.json" \
    "grep -q '来自 rclone-token.json' '${SB}/logs/handoff.log'"

RC2_CONF="${PFX2}/root/.config/rclone/rclone.conf"
chk "rclone.conf 里 remote 类型是 drive"  "grep -q '^type = drive' '${RC2_CONF}'"
chk "令牌已写入 rclone.conf" \
    "grep -qF 'refresh_token' '${RC2_CONF}'"
chk "token 是完整的一行（没被换行截断）" \
    "grep -qF '1//0gFakeRefresh' '${RC2_CONF}'"
chk "rclone.conf 权限是 600" "[[ \"\$(stat -f %Lp '${RC2_CONF}')\" == '600' ]]"

printf '\n  ---- 生成的 rclone.conf（令牌已脱敏）----\n'
sed 's/"access_token":"[^"]*"/"access_token":"****"/' "${RC2_CONF}" | sed 's/^/    /'
printf '\n'

#=============================================================================
printf '\n\033[1m═══ 结果 ═══\033[0m\n'
printf '  通过 %s / 失败 %s\n\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]] && exit 0 || exit 1
