# script

自用脚本集。每个子目录是一套独立可用的东西。

## 目录

| 目录 | 内容 |
|---|---|
| [`vps-backup/`](vps-backup/) | VPS 备份套件：应用层导出 → 打包 → 加密 → 上传 Google Drive → 结果上报。含一键安装器和两套自测 |

## vps-backup 快速开始

在**你自己的电脑上**执行（网盘授权需要浏览器，VPS 上没有）：

```bash
bash vps-backup/deploy.sh root@你的服务器
```

SSH 端口不是 22 时写成 `root@你的服务器:2222`。

装完即无人值守：按设定时间每天自动跑一次，本地保留 7 天、云端保留 90 天，临时文件在中断时自动清理。

### 文档

| 文件 | 讲什么 |
|---|---|
| [`vps-backup/install-README.md`](vps-backup/install-README.md) | 一键安装怎么用、装完东西在哪、报错怎么查 |
| [`vps-backup/README.md`](vps-backup/README.md) | 脚本全集：全部配置项、六种通知方式、运行行为、恢复流程、退出码 |
| [`vps-backup/notify-notion-setup.md`](vps-backup/notify-notion-setup.md) | 把备份结果写进 Notion 的界面操作步骤与排错表 |

### 自测

两个测试都不依赖网络以外的服务，改动敢不敢提交，跑一遍就有答案：

```bash
bash vps-backup/test-install.sh         # 端到端演练，41 项断言
bash vps-backup/test-notion-payload.sh  # Notion 上报的 JSON 结构，6 项断言
```

## 注意

- 备份内容先加密再上传（AES-256-CBC，PBKDF2 迭代 100000）。**加密口令只存在于目标机的 `/etc/backup.env`**，务必自行另存一份——机器丢失后没有它，网盘上的归档无法恢复。
- 仓库内配置模板全部为占位值，不含任何真实凭证、地址或密钥。
