#!/usr/bin/env bash
#=============================================================================
# backup-v2.sh 的 Notion 上报格式测试
#
# 为什么单独测这一块：Notion 的「状态」列有三种属性类型，JSON 结构互不相同，
# 发错结构时脚本本身不会崩，只在日志里留一行 Notion 的英文报错——
# 很容易被当成"通知偶发失败"放过去。实测踩过两次：
#   1. 列是 status 类型，脚本发的是 select 结构 -> "状态 is expected to be status."
#   2. status 的选项不能即写即建，值不在列里 -> "Invalid status option"
# 这个测试把三种结构都钉死，改动 payload 拼装时能立刻发现回归。
#
# 不依赖网络、不依赖 rclone、不依赖 Notion：本地起一个替身接口收下请求体，
# 直接断言发出去的 JSON 结构。
#=============================================================================

set -uo pipefail

WORK="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${WORK}/backup-v2.sh"
SB="${WORK}/sandbox-notion"
PORT=18987
BODIES="${SB}/bodies"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

cleanup() {
    [[ -n "${SRV_PID:-}" ]] && kill "${SRV_PID}" 2>/dev/null
    return 0
}
trap cleanup EXIT

PY=""
for c in /usr/bin/python3 python3; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
[[ -n "$PY" ]] || { echo "找不到 python3"; exit 1; }
[[ -r "$SCRIPT" ]] || { echo "找不到 ${SCRIPT}"; exit 1; }

printf '\n\033[1m═══ 准备替身接口 ═══\033[0m\n'
rm -rf "$SB"
mkdir -p "${SB}/src" "${SB}/out" "${SB}/bodydir"
printf 'notion payload probe\n' > "${SB}/src/notes.txt"

# 替身接口：把每个请求的 body 落盘成一个文件，再回一个成功响应。
# 想模拟报错时，把 ${SB}/reply/index.json 换成错误体即可。
cat > "${SB}/notion_stub.py" <<'PYEOF'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

BODYDIR = sys.argv[2]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n).decode('utf-8', 'replace')
        seq = len(os.listdir(BODYDIR))
        with open(os.path.join(BODYDIR, '%03d.json' % seq), 'w') as fh:
            fh.write(raw)
        reply_path = os.path.join(os.path.dirname(BODYDIR), 'reply.json')
        if os.path.exists(reply_path):
            body = open(reply_path).read()
            code = int(open(os.path.join(os.path.dirname(BODYDIR), 'reply_code')).read().strip())
        else:
            body = json.dumps({"object": "page", "id": "stub-page-id"})
            code = 200
        data = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')

    def log_message(self, *a):
        pass

HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PYEOF

"$PY" "${SB}/notion_stub.py" "$PORT" "$BODIES" &
SRV_PID=$!
sleep 1
if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "替身接口起不来，端口 ${PORT} 可能被占"; exit 1
fi
echo "  替身接口已在 127.0.0.1:${PORT} 监听"

#--- 造一份只开 notion 上报的配置 -------------------------------------------
write_env() {
    cat > "${SB}/backup.env" <<EOF
LOCALDIR="${SB}/out"
TEMPDIR="${SB}/out/temp"
LOGFILE="${SB}/out/backup.log"
LOCKFILE="${SB}/out/backup.lock"
KEEP_LOCAL_DAYS=7
KEEP_REMOTE_DAYS=90
DB_TYPE="none"
BACKUP_PATHS=("${SB}/src")
ENCRYPT=false
RCLONE_ENABLED=false
NOTIFY_ENABLED=true
NOTIFY_TYPE="notion"
NOTIFY_SUBJECT="[备份] {{STATUS_CN}} - {{HOSTNAME}}"
NOTIFY_BODY="状态: {{STATUS_CN}}"
NOTION_TOKEN="ntn_stub_token"
NOTION_TARGET="database"
NOTION_TARGET_ID="00000000000000000000000000000000"
NOTION_VERSION="2022-06-28"
NOTION_TITLE_PROP="名称"
NOTION_STATUS_PROP="状态"
NOTION_DATE_PROP="日期"
NOTION_STATUS_TYPE="$1"
NOTION_API_BASE="http://127.0.0.1:${PORT}"
EOF
}

# 跑一次备份，只关心上报那一步，所以输出全丢进文件
# 用 bash 显式调用，不依赖仓库里 backup-v2.sh 的可执行位
run_backup() {
    BACKUP_CONFIG="${SB}/backup.env" \
    BACKUP_ALLOW_NONROOT=true \
    bash "${SCRIPT}" > "${SB}/run.log" 2>&1
    return $?
}

printf '\n\033[1m═══ 三种状态列类型各发一次 ═══\033[0m\n'
for t in status select rich_text; do
    rm -rf "$BODIES"; mkdir -p "$BODIES"
    write_env "$t"
    if ! run_backup; then
        bad "${t}: 脚本非零退出"
        sed -n '$p' "${SB}/run.log"
        continue
    fi
    bf="$(find "$BODIES" -name '*.json' | head -1)"
    if [[ -z "$bf" ]]; then
        bad "${t}: 替身接口没收到请求"
        continue
    fi
    if "$PY" - "$bf" "$t" <<'PYEOF'
import json, sys
path, t = sys.argv[1], sys.argv[2]
d = json.load(open(path))
props = d["properties"]
st = props["状态"]
expect = {"status": "status", "select": "select", "rich_text": "rich_text"}[t]
assert expect in st, "状态 用的是 %r，期望 %r" % (list(st.keys()), expect)
# 三种结构各自的取值路径也要对。注意只取当前这一种，
# 写成字典字面量会把三种都求值，直接 KeyError。
if t == "status":
    val = st["status"]["name"]
elif t == "select":
    val = st["select"]["name"]
else:
    val = st["rich_text"][0]["text"]["content"]
assert val in ("成功", "失败"), "状态值异常: %r" % val
assert props["名称"]["title"][0]["text"]["content"].startswith("[备份]"), "标题没渲染"
assert "date" in props["日期"], "日期列结构不对"
PYEOF
    then ok "${t} 结构正确"
    else bad "${t} 结构不对（见上）"; fi
done

printf '\n\033[1m═══ 错误提示是否命中人话 ═══\033[0m\n'
# 模拟 Notion 的类型不符报错
rm -rf "$BODIES"; mkdir -p "$BODIES"
printf '{"object":"error","code":"validation_error","message":"状态 is expected to be status."}' > "${SB}/reply.json"
echo 400 > "${SB}/reply_code"
write_env "select"
run_backup
if grep -q 'expected to be' "${SB}/run.log" && grep -q 'NOTION_STATUS_TYPE' "${SB}/run.log"; then
    ok "类型不符时给出了改造配置的提示"
else
    bad "类型不符时没给出提示"; tail -3 "${SB}/run.log"
fi
# 模拟选项不存在
printf '{"object":"error","code":"validation_error","message":"Invalid status option. Status option \\"成功\\" does not exist"}' > "${SB}/reply.json"
rm -rf "$BODIES"; mkdir -p "$BODIES"
run_backup
if grep -q '不能即写即建' "${SB}/run.log"; then
    ok "选项缺失时提示了 status 不能即写即建"
else
    bad "选项缺失时没给出提示"; tail -3 "${SB}/run.log"
fi
# 上报失败不应影响备份本身的结论
if grep -q '备份结束：SUCCESS' "${SB}/run.log"; then
    ok "上报失败不影响备份结论（仍记 SUCCESS）"
else
    bad "上报失败把备份结论带崩了"; tail -3 "${SB}/run.log"
fi

printf '\n\033[1m═══ 结果 ═══\033[0m\n'
printf '  通过 %d，失败 %d\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
