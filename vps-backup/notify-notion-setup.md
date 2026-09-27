# Notion 通知接入说明

把备份结果写成 Notion 数据库里的一行。脚本跑完就写，你在 Notion 或手机 App 里看。

---

## 结论：需要三样东西，不是两样

| # | 东西 | 从哪来 |
|---|---|---|
| 1 | **token** | notion.so/my-integrations 新建一个 integration，复制 Secret。形如 `ntn_xxx` |
| 2 | **数据库 ID** | 打开数据库页面，从链接里取 32 位字符串 |
| 3 | **把数据库"连接"给这个 integration** | 在 Notion 页面里点 `···` → 连接 → 选你的 integration |

**第 3 步是最容易漏的，也是 90% 的人卡住的地方。**

新建一个 integration，它会拿到一个合法 token，但**看不到任何东西**——Notion 的权限模型是在页面里逐个授权的，不是在建 integration 的时候配的。漏了这步，脚本会一直报 `object_not_found`，看起来像"ID 填错了"，其实 ID 是对的。

---

## 步骤 1：建 integration

1. 打开 <https://www.notion.so/my-integrations>，点 **新建 integration**
2. 名字随便起，比如 `backup-reporter`；类型选 **内部**（Internal），关联你的工作区
3. 进 **Capabilities** 标签，**只勾 `Insert content`**

   > 为什么只勾这一个：备份脚本只往里写，从来不读。勾了 `Read content` 反而给了 VPS
   > 多一份读取权限——万一机器被入侵，攻击者能读走所有共享给这个 integration 的内容。
   > 只给 Insert 的话，最坏情况是被人灌几条垃圾数据。
   >
   > **AI 读取走的是另一条路**（Notion 连接器，见文末），不受这里影响。

4. 进 **Secrets** 标签，复制 token（形如 `ntn_xxxxxxxx`）

---

## 步骤 2：建一个数据库

在 Notion 里新建一个数据库（表格视图），**建这三列**：

| 列名 | 类型 | 说明 |
|---|---|---|
| `名称` | 标题 | 这条记录叫什么。**标题列是每个数据库自带的，名字默认是「名称」** |
| `状态` | 选择 | 取值为「成功」或「失败」 |
| `时间` | 日期 | 备份完成时间 |

列名必须**和上面完全一致**。因为 Notion 是按列名寻址的：

- 列名对不上 → 直接报 400，Notion 会告诉你哪个列不存在
- 建成后又改了列名 → 脚本**静默失效**，日志里看不出来

英文界面的 Notion，标题列默认叫 `Name`。那就把配置里的 `NOTION_TITLE_PROP` 改成 `Name`，状态列和日期列同理。

> 不想建列？改用 `NOTION_TARGET="page"` 模式：脚本把每次结果追加成一个代码块，
> 不需要任何列名，只要一个页面 ID。代价是没有表格视图、不能筛选和排序。

---

## 步骤 3：把数据库连接给 integration（最容易漏）

1. 在 Notion 里打开**那个数据库页面**
2. 点右上角 `···` → 找到 **连接 / Connections** → 选步骤 1 建的那个 integration
3. 确认它出现在已连接的列表里

三个容易踩的点：

- **必须连源数据库，不能连"视图"**。Linked view / 过滤视图只是引用，连了没用。
- **权限是向下继承的**。连一个父页面，它下面的内容才都能访问；单独连一个子页面，
  既看不到父页面也看不到兄弟页面。
- **把页面挪到别的位置会悄悄失去权限**。页面树一变，继承关系就断了——代码没改、
  token 没变，任务突然开始写不进去。遇到莫名其妙的失败，先回来检查这一步。

---

## 步骤 4：拿数据库 ID

在数据库页面点 `···` → **复制链接**，会得到类似：

```
https://www.notion.so/1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d?v=9f8e7d6c5b4a39281706f5e4d3c2b1a0
                          └────────── 这段就是数据库 ID ──────────┘
```

取 `?v=` **之前**的那段 32 位字符串。中间带的横杠可以留也可以去，两种 Notion 都认。

（`?v=` 后面那串是视图 ID，不要用。）

---

## 步骤 5：填配置并试跑

编辑 `/etc/backup.env`：

```ini
NOTIFY_ENABLED=true
NOTIFY_TYPE="notion"

NOTION_TOKEN="ntn_..."
NOTION_TARGET="database"
NOTION_TARGET_ID="1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"

NOTION_TITLE_PROP="名称"
NOTION_STATUS_PROP="状态"
NOTION_DATE_PROP="时间"
NOTION_STATUS_TYPE="status"
```

然后跑一次：

```bash
/usr/local/bin/backup-v2.sh
```

有两种结果：

- **成功**：Notion 数据库里多出一行，点开还能看到完整的步骤明细（正文以代码块写入）
- **失败**：去看日志里 `Notion 拒绝写入：` 后面那段 JSON，里面会直接告诉你原因

---

## 失败时怎么读错误信息

脚本**故意不吞** Notion 返回的原文，因为它的诊断信息非常有用。对照表：

| 日志里出现 | 真实原因 | 怎么办 |
|---|---|---|
| `body.properties.状态X should be defined, instead was undefined` | 数据库里没有这个列名 | 检查列名，改配置里的 `NOTION_*_PROP` |
| `Could not find database with ID: ...  Make sure the relevant pages and databases are shared with your integration` | 两种可能：**integration 没连上这个数据库**（更常见），或 **ID 本身就是错的** | 先回步骤 3 确认已连接；已连接还报这个，说明 ID 抄错了。注意报错里的 ID 就是脚本发出去的那个，直接比对即可 |
| `API token is invalid` | token 抄错了，或没复制完整 | 重新复制 Secret |
| `NOTION_TOKEN 格式不对，应以 ntn_ 或 secret_ 开头` | 填成了别的东西（比如 URL 或数据库 ID） | 检查配置 |
| `状态 is expected to be status.` | 「状态」列的真实属性类型和 `NOTION_STATUS_TYPE` 填的不一致 | 按报错里 `expected to be` 后面那个类型改配置（`status` / `select` / `rich_text`） |
| `Invalid status option. Status option "成功" does not exist` | 该列是 `status` 类型，而 `status` 的选项**不能即写即建** | 先在 Notion 里手工给这一列加上「成功」「失败」两个选项；或把 `NOTION_STATUS_TYPE` 改成 `select`（`select` 会自动建选项） |
| `Notion 请求失败（curl 退出码 N）` | 网络或 DNS 不通 | 检查 VPS 出网；若在国内机器上，可能需要走代理 |

这几种情况的报错原文都实测过，不是凭印象写的。

### 两个实测踩过的坑

**`status` 与 `select` 不是一回事。** 中文界面新建的「状态」列默认是 Notion 原生的 `status` 类型，
它写入时的 JSON 结构是 `{"status":{"name":"..."}}`；单选的 `select` 列则是 `{"select":{"name":"..."}}`。
两者发错结构，报错就是上面那条 `expected to be`。写 `status` 时选项必须已存在，写 `select` 时不存在会自动创建——
想要"发什么值都能记上"，`select` 反而更省心。

**改 Notion 数据库的选项列表要用 PATCH `/v1/databases`，而它是整表替换，不是追加。**
曾经想"补两个选项"，只发了 `{"options":[成功,失败]}`，结果原来那三个选项被一并抹掉了。
要用这个接口，必须把**全部**选项按最终想要的顺序一次性发全。

---

## AI 怎么读这一半

上面那三步是**给备份脚本用的**（只写权限）。AI 读取走的是另一条路：

**装 Notion 连接器**，它会用你自己的身份读你的工作区，权限范围也由你在授权时决定。
装好之后我就能查这个数据库、汇总最近几天的备份情况，不用你把数据搬来搬去。

两套凭证分开的好处是：VPS 上那份万一泄露，攻击者最多能往你的数据库里灌垃圾，
读不到任何内容，也删不掉历史记录。

---

## 代价（该说清楚）

选 Notion 换掉了"部署一个常驻服务"这件事，但也不是没有成本：

| 事项 | 说明 |
|---|---|
| 列名脆弱 | Notion 按列名寻址，改列名会让脚本静默失效。已做成配置项，改配置即可 |
| 权限会被移动静默破坏 | 页面挪位置会断掉继承，任务突然失败且原因不明显 |
| VPS 上多了一份外部凭证 | 用"只给 Insert content"把影响面压到最小 |
| 失联判断弱一点 | 查不到新记录时，可能是备份没跑，也可能是 Notion 这边权限出了问题，需要我读的时候分辨 |
| 速率限制 | 平均 3 请求/秒。对每天一次的上报完全无影响 |
