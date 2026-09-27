# backup-v2 使用说明书

一套跑在 Linux 服务器上的备份脚本。把指定的目录打包、加密，传到 Google Drive，并把结果通知给你。

---

## 一、它是什么

**一句话**：定时把服务器上不可再生的数据（配置、数据库、上传文件）打包加密，推到网盘，并告诉你成没成。

它不做什么，同样重要：

- **不是同步工具。** 只往网盘单向追加，本地误删不会波及云端历史版本。
- **不是整机镜像。** 只备你指定的路径，不备份操作系统和依赖。
- **不做去重。** 每轮都是一份完整的独立包，所以保留天数要自己权衡磁盘。

### 为什么不用 `rclone sync`

`sync` 会让云端跟本地保持一致。本地一旦误删或磁盘损坏，下一轮备份会把云端那份一起删掉。备份链路必须是**单向追加 + 显式清理**，这就是本脚本的做法。

### 六个步骤，任一失败即停

```
磁盘空间预检 → 数据库导出 → 打包 → 加密 → 上传(含大小校验) → 清理过期
```

失败会停在出错那一步，并把失败步骤和退出码写进日志和通知里。

---

## 二、文件清单

| 文件 | 干什么 |
|---|---|
| `backup-v2.sh` | **主脚本**。干活的就是它，装到 `/usr/local/bin/` |
| `install.sh` | 安装向导。在服务器上跑，负责装依赖、写配置、配定时、自检 |
| `deploy.sh` | 在你自己的电脑上跑，一键完成「授权 + 上传 + 安装」 |
| `backup.env.example` | 配置模板，手工改配置时对照用 |
| `test-install.sh` | 端到端演练，可在 macOS 上完整验证整条链路 |
| `notify-notion-setup.md` | Notion 通知的界面操作步骤与排错表 |
| `install-README.md` | 一键安装的说明与排错表 |

### 装完之后，文件都去哪了

| 位置 | 内容 |
|---|---|
| `/usr/local/bin/backup-v2.sh` | 主脚本（755） |
| `/etc/backup.env` | 配置（**600**，里面有密码） |
| `/opt/backups/` | 本地备份产物 + 日志 |
| `/etc/systemd/system/backup-v2.{service,timer}` | 定时任务 |
| `/root/.config/rclone/rclone.conf` | 网盘授权（**600**） |

---

## 三、怎么装

### 方式 A：在自己电脑上一条命令（推荐）

```bash
bash deploy.sh root@你的服务器          # 目标机地址
bash deploy.sh root@1.2.3.4             # 装到指定机器
```

**为什么要在自己电脑上跑**：Google Drive 授权必须点一次浏览器登录，服务器上没有浏览器。`deploy.sh` 把这一步提到你本机做完，令牌随包上传，全程你只点一次「允许」。

> ⚠️ **已知限制**：`deploy.sh` 目前**不支持非 22 端口**。目标机 SSH 端口不是 22 的话，得手动部署，见方式 C。

### 方式 B：在服务器上跑向导

把 `install.sh` 和 `backup-v2.sh` 传到同一个目录：

```bash
bash install.sh
```

授权环节会提示你去有浏览器的电脑上跑 `rclone authorize drive`，把输出的 JSON 粘回来。多一点手工，其余一样。

### 方式 C：全非交互（脚本化 / 特殊端口）

`install.sh --yes` 模式下所有参数从环境变量读，适合自动化：

```bash
WB_BACKUP_PATHS='/opt/app/data /etc/nginx' \
WB_DB_TYPE=none \
WB_BACKUP_PASSWORD='你的加密口令' \
WB_RCLONE_NAME=gdrive \
WB_RCLONE_FOLDER='backup/主机名' \
WB_NOTIFY_TYPE=none \
WB_SCHEDULE='03:00' \
bash install.sh --yes --run-now
```

网盘授权可以直接放一个令牌文件在脚本同目录，命名为 `rclone-token.json`，安装时自动读取。

---

## 四、命令参考

### `install.sh`

| 参数 | 作用 |
|---|---|
| 无参数 | 交互式向导 |
| `--yes` / `-y` | 非交互，全部取默认值或环境变量 |
| `--check` | 只做环境预检，不改动任何文件 |
| `--run-now` | 装完立刻跑一次真实备份 |
| `--uninstall` | 卸载，**保留**配置、历史备份、网盘授权 |
| `--skip-deps` | 跳过依赖安装 |
| `--prefix <目录>` | 沙箱模式，把 `/etc` `/usr/local/bin` `/var` 重定向到指定目录。用于测试 |
| `--remote-type <类型>` | 目标存储类型，默认 `drive`。测试时可用 `local` |
| `--help` / `-h` | 用法 |

`--yes` 模式可用的环境变量：`WB_BACKUP_PATHS`、`WB_DB_TYPE`、`WB_MYSQL_PASSWORD`、`WB_BACKUP_PASSWORD`、`WB_RCLONE_NAME`、`WB_RCLONE_FOLDER`、`WB_NOTIFY_TYPE`、`WB_NOTION_TOKEN`、`WB_NOTION_TARGET_ID`、`WB_WEBHOOK_URL`、`WB_WEBHOOK_TOKEN`、`WB_SCHEDULE`。

### `deploy.sh`

| 参数 | 作用 |
|---|---|
| `[user@host]` | 目标机，必填；非 22 端口写成 `user@host:2222` |
| `--run-now` | 装完立刻跑一次 |
| `--skip-auth` | 跳过本机授权，改为在服务器上手工粘贴令牌 |
| `--help` / `-h` | 用法 |

想用自己的 Google OAuth 客户端：`WB_CLIENT_ID=xxx WB_CLIENT_SECRET=yyy bash deploy.sh`

### `backup-v2.sh`

**没有参数**。直接执行即可，它会读 `/etc/backup.env`。

```bash
/usr/local/bin/backup-v2.sh
```

换配置文件用环境变量：`BACKUP_CONFIG=/path/to/other.env /usr/local/bin/backup-v2.sh`

**退出码**

| 码 | 含义 |
|---|---|
| 0 | 成功；或另一轮正在跑，本次主动跳过 |
| 1 | 某一步失败（不是 root、配置读不到、或预检/导出/打包/加密/上传/清理失败） |

**必须有 root 权限**，否则直接退出。原因是密码、密钥、备份产物的属主和权限都依赖 root。

---

## 五、配置项完整参考

配置文件默认在 `/etc/backup.env`，权限必须是 `600`。

### 路径

| 项 | 默认 | 说明 |
|---|---|---|
| `LOCALDIR` | `/opt/backups` | 本地备份产物目录 |
| `TEMPDIR` | `$LOCALDIR/temp` | 临时文件目录，中断会被 trap 清空 |
| `LOGFILE` | `$LOCALDIR/backup.log` | 日志文件 |
| `LOCKFILE` | `/var/run/backup.lock` | 防重入锁 |

### 保留策略

| 项 | 默认 | 说明 |
|---|---|---|
| `KEEP_LOCAL_DAYS` | `7` | 本地留几天。省磁盘，够应急回滚 |
| `KEEP_REMOTE_DAYS` | `90` | 云端留几天。**这才是保命那份**，本地和云端互相独立 |

### 备份内容

| 项 | 说明 |
|---|---|
| `BACKUP_PATHS` | **数组**，要备份的目录或文件，写绝对路径。解包时按原路径还原 |

```bash
BACKUP_PATHS=(
    '/opt/app/data'
    '/etc/nginx'
)
```

### 数据库

| 项 | 默认 | 说明 |
|---|---|---|
| `DB_TYPE` | `none` | `none` / `mysql`（宿主机直装）/ `docker-mysql`（跑在容器里） |
| `MYSQL_ROOT_USER` | `root` | 数据库账号 |
| `MYSQL_ROOT_PASSWORD` | 空 | 数据库密码。走 `MYSQL_PWD` 环境变量传给 dump 命令，不出现在进程列表 |
| `MYSQL_DATABASE_NAMES` | 空数组 | 留空 = 导出全部库；否则只导出列出的库 |
| `MYSQL_DOCKER_CONTAINER` | 空 | `docker-mysql` 时必填，容器名 |

> 目前**只支持 MySQL / MariaDB**。PostgreSQL 需要手工在备份前加一步 `pg_dump`，或在 `BACKUP_PATHS` 外部处理。

### 加密

| 项 | 默认 | 说明 |
|---|---|---|
| `ENCRYPT` | `true` | 建议保持开启。网盘会扫描内容，也不该假设网盘可信 |
| `BACKUP_PASSWORD` | 空 | **加密口令**。丢了就无法恢复，见下文 |

算法是 `AES-256-CBC` + `PBKDF2`（100000 轮迭代）+ `-md sha256`。

### 上传

| 项 | 默认 | 说明 |
|---|---|---|
| `RCLONE_ENABLED` | `false` | 是否上传 |
| `RCLONE_REMOTE` | 空 | rclone remote 名，如 `gdrive` |
| `RCLONE_FOLDER` | 空 | remote 下的目录，建议按主机名分开 |
| `RCLONE_BWLIMIT` | `off` | 限速。`"08:00,8M 23:00,off"` 表示 8–23 点限 8MB/s，其余不限 |
| `RCLONE_TPSLIMIT` | `8` | 每秒 API 调用上限。Google Drive 默认只给约 10 次/秒，留余量 |
| `RCLONE_TRANSFERS` | `4` | 并发传输数 |

### 通知

| 项 | 默认 | 说明 |
|---|---|---|
| `NOTIFY_ENABLED` | `false` | 总开关 |
| `NOTIFY_TYPE` | `smtp` | 见下一节 |
| `NOTIFY_SUBJECT` | — | 标题模板 |
| `NOTIFY_BODY` | — | 正文模板 |
| `NOTIFY_NOTE` | 空 | 会填进 `{{NOTE}}` 的附加备注 |
| `NOTIFY_NO_PROXY` | `*` | 上报时绕过代理。默认 `*` 表示不走任何代理 |
| `NOTIFY_TIMEOUT` | `20` | 通知请求超时秒数 |

**成功和失败都会发通知，这是故意的。** 成功那条当成心跳看：

> 收到成功 = 跑完了 · 收到失败 = 出事了 · **什么都没收到 = 出事了**（最坏的一种：脚本压根没启动或卡死）

---

## 六、通知方式

`NOTIFY_TYPE` 六选一，各自需要的配置项如下。

### `smtp` — 用标准 SMTP 发邮件

VPS 上零安装，curl 自带支持。

| 项 | 说明 |
|---|---|
| `SMTP_HOST` | 如 `smtp.qq.com` |
| `SMTP_PORT` | `465`（ssl）或 `587`（starttls） |
| `SMTP_TLS` | `ssl` 或 `starttls` |
| `SMTP_USER` | 发信邮箱 |
| `SMTP_PASS` | **授权码**，不是邮箱登录密码 |
| `SMTP_FROM` | 留空则用 `SMTP_USER` |
| `SMTP_TO` | 收件方 |

### `ntfy` — 推送到 ntfy

只需 `NTFY_URL`，如 `https://ntfy.sh/一串很长的随机topic`。零注册，但默认 topic 是公开可读的，靠 topic 名的随机性保护。

### `webhook` — POST 到自建服务

| 项 | 说明 |
|---|---|
| `NOTIFY_WEBHOOK_URL` | 服务地址，如 `http://127.0.0.1:8899` |
| `NOTIFY_WEBHOOK_TOKEN` | 写入 token，对应服务端的 `WRITE_TOKEN` |

服务端由使用者自备，本仓库不附带实现。最小只需要两个接口：`POST /api/report?token=X` 接收到 JSON 后原样落盘，`GET /health` 返回存活。脚本不解析响应体，**HTTP 非 2xx 即判为发送失败**。

### `notion` — 写成 Notion 数据库的一行

| 项 | 说明 |
|---|---|
| `NOTION_TOKEN` | integration secret，形如 `ntn_xxx` |
| `NOTION_TARGET` | `database`（推荐，有表格视图）/ `page`（追加流水，配置最少） |
| `NOTION_TARGET_ID` | 目标 ID，从链接里复制那 32 位字符串 |
| `NOTION_VERSION` | 固定 `2022-06-28`，别动 |
| `NOTION_TITLE_PROP` / `NOTION_STATUS_PROP` / `NOTION_DATE_PROP` | **必须与 Notion 里的列名完全一致**，含大小写和空格。默认 `名称` / `状态` / `时间` |

详细步骤见 `notify-notion-setup.md`。**最容易卡住的一步**：新建的 integration 是空的，必须在 Notion 页面里点 `···` → 连接 → 选中它，否则永远报 `object_not_found`。

### `agentmail` — 调 AgentMail REST API

| 项 | 说明 |
|---|---|
| `AGENTMAIL_KEY` | API key |
| `AGENTMAIL_TO` / `AGENTMAIL_INBOX` | 收件邮箱 / 发信 inbox |
| `AGENTMAIL_BASE` | API 基地址，一般不用改 |

### `custom` — 自己写一条命令

配置 `NOTIFY_CUSTOM_CMD`，脚本会把内容通过环境变量传给它：

- `NOTIFY_SUBJECT_RENDERED` — 渲染好的标题
- `NOTIFY_BODY_RENDERED` — 渲染好的正文

### 模板可用变量

`NOTIFY_SUBJECT` 和 `NOTIFY_BODY` 支持这 13 个占位符：

| 变量 | 含义 |
|---|---|
| `{{HOSTNAME}}` | 主机名 |
| `{{STATUS}}` | `SUCCESS` / `FAILURE` |
| `{{STATUS_CN}}` | `成功` / `失败` |
| `{{DATE}}` | 执行时间 |
| `{{DURATION}}` | 耗时秒数 |
| `{{FILE}}` | 备份文件名 |
| `{{TAR_SIZE}}` | 打包后大小 |
| `{{DB_STATUS}}` | 数据库导出结果 |
| `{{ENC_STATUS}}` | 加密结果 |
| `{{UPLOAD_STATUS}}` | 上传结果，含目标路径 |
| `{{REMOTE}}` | 远端路径 |
| `{{ERROR}}` | 失败原因（成功时为空） |
| `{{NOTE}}` | `NOTIFY_NOTE` 的值 |

> **建议模板里保留 `{{UPLOAD_STATUS}}` 和 `{{TAR_SIZE}}`。** 没有这两个字段的通知是没法证伪的——脚本说成功不等于文件真的上去了。

---

## 七、运行行为

### 定时

安装时用 **systemd timer**（不是 cron），因为 timer 有日志、天然防重入、`Persistent=true` 保证关机期间错过的任务开机后补跑。默认每天 03:00 触发，带 5 分钟随机延迟。

单元文件里有一条兜底：`TimeoutStartSec=6h`，防止某次卡死一直占着锁。

### 防重入

脚本用 `flock` 独占一个锁文件。上一轮没跑完时，新一轮**直接退出并返回 0**，不会叠跑撑爆磁盘。

### 日志

追加写入 `LOGFILE`，每行带时间戳。关键行：

```
备份开始 / 开始：打包 / 打包完成：xxx.tgz（4.0K）
开始：加密 / 加密完成：xxx.tgz.enc
上传完成并校验通过：gdrive:backup/sg/xxx.tgz.enc
备份结束：SUCCESS，耗时 44 秒
```

判断成功的标准是最后一行出现 `SUCCESS`。

### 中断保护

脚本注册了 `EXIT` trap，无论正常结束、报错退出还是被 `Ctrl-C` 中断，都会执行清理：删掉临时目录里的**明文 sql dump 和明文 tar**，不留敏感文件在磁盘上。

### 上传后校验

上传完成不等于成功。脚本会在上传后比对远端文件大小与本地是否一致，不一致就报失败。

---

## 八、恢复数据

**没验证过的备份等于没有备份。** 建议每季度真跑一次。

```bash
# 1. 看网盘上有什么
rclone lsl gdrive:backup/<主机名>

# 2. 下载
mkdir -p /tmp/restore && cd /tmp/restore
rclone copy gdrive:backup/<主机名>/<文件名>.tgz.enc .

# 3. 解密
openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -md sha256 \
  -pass 'pass:你的加密口令' \
  -in <文件名>.tgz.enc -out backup.tgz

# 4. 先看内容，别急着写盘
tar tzf backup.tgz

# 5. 确认后还原
tar xzf backup.tgz -C /        # 回原始位置
tar xzf backup.tgz -C /tmp/x   # 或先解到临时目录检查
```

包内是**绝对路径**，所以解到 `/` 就是还原回原位。

---

## 九、出问题

| 现象 | 原因 | 怎么办 |
|---|---|---|
| 日志说加密完成但没有 `.enc` 文件 | 磁盘满（打一份明文再写一份密文，需要 2 倍空间） | `df -h` 看空间，脚本有预检但阈值之外的情况仍可能发生 |
| 上传失败 | 令牌失效 / Drive API 未启用 / 网络受限 | `rclone lsd gdrive:` 手工复查 |
| 远端清理很慢 | 驱动要遍历目录树，正常现象 | 大目录树时可能几十秒到几分钟 |
| 通知没收到 | 网络、token、代理 | 脚本会明确报错；注意 `NOTIFY_NO_PROXY` 的坑 |
| Notion 报 `object_not_found` | **90% 是数据库没「连接」给 integration** | 在 Notion 页面点 `···` → 连接 → 选它 |
| 改了保留天数但旧文件没删 | 清理按文件 mtime 算，且只在备份成功后执行 | 下次备份成功时会清 |
| `另一个备份进程正在运行` | 上一轮还没跑完 | 正常保护，等它跑完 |

---

## 十、必须知道的三件事

**1. 加密口令只在服务器上有一份，这是个单点。**

它存在 `/etc/backup.env` 里。机器丢了，网盘上的 `.enc` 就是一堆废字节——没有重置、没有后门。**装完立刻存进密码管理器。**

**2. 备份是单向追加，不是双向同步。**

好处是误删有救；代价是改小 `BACKUP_PATHS` 移除某个目录后，网盘上它之前的历史备份**不会自动删**，要手动清。

**3. rclone 内置的共享 client_id 将在 2026 年内失效。**

Google 正在停用 rclone 的公共 OAuth 客户端。现在能用，但需要尽早自建一个客户端替换，否则某天备份会突然开始失败。

---

## 附：设计取舍

写这套脚本时有意做对的几件事，也是它和常见「backup.sh 一把梭」的区别：

| 决定 | 原因 |
|---|---|
| 保留策略本地/云端解耦 | 本地 7 天省磁盘、云端 90 天保命，是两个不同的需求 |
| 清理按 mtime 而非解析文件名 | 原版按 `hostname_日期` 解析，主机名含下划线就永久不清理，磁盘会悄悄堆满 |
| `mysqldump --single-transaction` | 不加会锁表，备份期间业务被阻塞 |
| 密码走 `MYSQL_PWD` 环境变量 | 直接写命令行会出现在 `ps` 里，任何用户都能看到 |
| 上传后校验大小 | rclone 说成功不等于文件完整 |
| 失败也发通知 | 静默失败的备份是最常见的失效模式 |
| trap 清理明文 | 中断后明文数据库 dump 留在磁盘上是常见事故 |
| `flock` 防重入 | 备份超过 24 小时就会叠跑，磁盘被撑爆 |
