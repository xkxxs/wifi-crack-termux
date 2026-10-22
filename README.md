# WiFi 字典测试工具（Termux + Root）

在 Android 上用 `cmd wifi` 逐个尝试字典里的密码，验证某个 WiFi 的口令是否属于弱口令。

> **它不破解 WPA/WPA2/WPA3 加密。** 没有任何密码学攻击，只是"拿着字典一遍遍调用系统连接接口"，
> 每次尝试都要等一次完整的连接握手（约 5 秒）。10 万条字典理论上要 139 小时，
> 而且强密码靠字典是猜不出来的，只对默认密码、纯数字、常见弱口令有意义。
>
> **仅限测试你自己拥有或已获得授权的网络。** 对他人网络逐个试密码，在《网络安全法》第 27 条
> 和《刑法》第 285 条范围内。

## 一行命令安装

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/xkxxs/wifi-crack-termux/master/install.sh)
```

上面这条走 **gh-proxy** 镜像（和安装器内部的优先顺序一致）。如果它也拉不动，依次换用 jsDelivr 和原始地址：

```bash
# jsDelivr CDN
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/xkxxs/wifi-crack-termux@master/install.sh)

# 原始地址（需要能访问 raw.githubusercontent.com）
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/wifi-crack-termux/master/install.sh)
```

装完直接输入 `wifi-crack` 即可。**不需要 sudo**，安装器只写 `$PREFIX`（Termux 自己的目录）和 `$HOME`。

### 安装器做了什么

| 步骤 | 说明 |
| --- | --- |
| 环境检查 | 确认在 Termux 里、`$PREFIX/bin` 可写 |
| 获取脚本 | 从仓库目录运行时用本地文件，管道安装时按 gh-proxy → CDN → raw 顺序下载，并做 `bash -n` 语法校验 |
| 安装程序 | 原子替换到 `$PREFIX/share/wifi-crack/wifi-crack.sh`（先写临时文件再 `mv`，中断不会留下半个脚本） |
| 生成命令 | `$PREFIX/bin/wifi-crack`，内容是 `exec <程序路径> "$@"`，不依赖环境变量 |
| 安装字典 | 若 `~/.wifi-crack/dict/幻影WiFi字典.txt` 不存在则一并安装；`--no-dict` 可跳过 |
| 环境提示 | 检查 `cmd` 是否可用、`su`/`sudo` 是否存在，只提示不阻断 |
| 卸载 | `--uninstall` 删除程序与命令，保留 `~/.wifi-crack/` 里的字典和结果 |

重复运行安装器是安全的：程序内容一致会跳过覆盖，你改过的 `$PREFIX/bin/wifi-crack` 会先备份成 `.bak`。

## 手动安装

```bash
git clone https://github.com/xkxxs/wifi-crack-termux.git
cd wifi-crack-termux
bash install.sh            # 或 bash install.sh --no-dict
```

不想用安装器的话，最小可用方式（不要往 `~` 根目录丢文件，数据会自动收进 `~/.wifi-crack/`）：

```bash
mkdir -p "$PREFIX/share/wifi-crack"
cp wifi-crack.sh "$PREFIX/share/wifi-crack/"
"$PREFIX/share/wifi-crack/wifi-crack.sh"          # 直接跑，脚本会自己 su 提权
```

## 卸载

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/xkxxs/wifi-crack-termux/master/install.sh) --uninstall
```

## 原理

```bash
cmd wifi connect-network <SSID> <open|owe|wpa2|wpa3> <密码> [-b <BSSID>]
```

- 成功后轮询 `cmd wifi status`，看是否连上了目标 SSID；
- `connect-network` 会把网络写进系统"已保存网络"，所以每次失败后要 `forget-network` 清掉；
- 脚本启动前先快照目标 SSID 已有的网络 ID，清理时做差集，**只删自己新建的，不动你已保存的 WiFi**。

## 环境要求

- 已 root 的 Android 11+（需要 `cmd wifi`，Magisk / KernelSU 均可）
- Termux + bash
- 不需要 `iw`，也不需要 proot（v2 里的 `iw` 依赖是多余的，v3 已移除）

## 用法

```bash
wifi-crack                 # 交互菜单
wifi-crack -s              # 只扫描并列出附近网络
wifi-crack -t <SSID> [BSSID] [加密] [字典路径]
wifi-crack -q <SSID> <密码> [加密]     # 只试一个密码
wifi-crack -l              # 查看历史结果
wifi-crack -h              # 帮助
```

选项：

| 选项 | 说明 |
|---|---|
| `-v, --verbose` | 进度里显示明文密码（默认打码，防止录屏/共享屏幕泄露） |
| `--forget-on-success` | 成功后删除该网络配置（默认保留，手机继续连着） |

快速模式示例：

```bash
wifi-crack -t MINI 50:88:11:7b:b5:3c wpa2 ~/.wifi-crack/dict/幻影WiFi字典.txt
```

## 数据目录

安装后所有数据都在 `~/.wifi-crack/` 下，不再往 home 根目录散落文件：

```
~/.wifi-crack/
├── dict/
│   └── 幻影WiFi字典.txt     # 默认字典，也可以放自己的其他字典
├── results/                # 命中的结果，每个 <SSID>_<时间>.txt，权限 600
└── tmp/                    # 运行中的临时文件，退出/中断自动清理
```

从 v3.0 及更早版本升级时，脚本和安装器都会自动把旧的 `~/幻影WiFi字典.txt`、
`~/wifi-results/`、`~/wifi-dicts/` 迁移进来，不需要手动搬。

## 结果

- 保存在 `~/.wifi-crack/results/<SSID>_<时间>.txt`，权限 600（仅自己可读）。
- 成功时默认保留网络配置，手机会保持连接；不想要就加 `--forget-on-success`。

## v3 修了什么

| 问题 | 处理 |
|---|---|
| WEP 网络永远连不上（`cmd wifi` 只支持 open/owe/wpa2/wpa3），错误被 `\|\| true` 吞掉，白跑整个字典 | 扫描时标记 `wep`，选中直接拒绝；`-t` 传入 wep 也报错 |
| `-t` 模式的字典默认路径和文档不一致 | 统一为 `~/.wifi-crack/dict/幻影WiFi字典.txt` |
| 字典、结果、临时目录散落在 home 根目录 | 统一收进 `~/.wifi-crack/`，并自动迁移旧布局 |
| 安装文档没说要复制字典，开箱即报错 | 安装器自动装字典，文档已补 |
| 依赖 `iw` 但从未使用；root 下 `pkg install` 会出问题 | 移除 `iw`，改为检测 `cmd wifi` 是否真的可用 |
| `sudo` 后 PATH 没有 `/system/bin`，`cmd` 被误判缺失 | PATH 追加系统目录（追加而非前置，避免 toybox 覆盖 Termux 的 GNU 工具） |
| SSID 含空格被 `awk $5` 截断，中文名/带空格名连错目标 | 重写解析：跳过前 4 列，再按"标志块"剥离末尾 `[WPA2-PSK-CCMP][ESS]`，保留 SSID 里的空格和方括号 |
| 同一 SSID 多 BSSID 去重时随机保留，可能选到弱信号 | 按 RSSI 保留最强的一条，并按信号降序显示 |
| 空字典除零崩溃 | `check_dict` 直接拒绝空字典 |
| 字典最后一行没有换行符被漏掉 | `while read \|\| [[ -n $password ]]` |
| 清理时 `grep "$ssid"` 用的子串/正则匹配，会拿到错误网络 ID，**误删你已保存的 WiFi** | 改为按 SSID 精确比较 + 启动前快照基线 ID，只删本次新增的；快照失败直接中止 |
| `disconnect_wifi` 会把你当前网络 `forget-network` 掉（等于删掉自家 WiFi 密码） | 整段删除；发现目标就是当前连接的网络时直接提示无需测试 |
| Ctrl-C 中断留下半成品配置和临时目录 | `trap INT/TERM/EXIT` 统一清理 |
| 进度行回显明文密码 | 默认打码，只显示长度 |
| `connect-network` 失败原因被忽略，看起来像"密码都不对" | 区分"命令被拒"（加密类型/权限问题）和"密码错误"，连续 3 次命令被拒直接报错退出 |
| 快速模式不校验参数，空 SSID/空密码也会去连 | 参数校验 + 加密类型白名单 |

## 常见问题

**跑到一半报 "connect-network 连续失败 3 次"**
系统拒绝了连接请求。常见原因：该 BSSID 被 Android 暂时拉黑（反复认证失败后会有退避）、
加密类型不匹配、或 root 权限没生效。等一两分钟、换个 BSSID（同一 SSID 的另一频段）再试。

**扫描结果很旧 / 数量很少**
Android 对 WiFi 扫描有前台/后台限流，`start-scan` 不一定立刻生效。脚本会等最多 12 秒，
过期数据会给出提示。

**手机连不上别的网络**
Android 会优先保持当前已连接的网络。需要时在系统 WiFi 设置里关掉自己网络的"自动连接"，
或先手动断开。

**密码对了但显示没匹配**
某些机型 `connect-network` 后需要更长时间完成 DHCP。把脚本顶部 `CONNECT_POLLS` 调大（如 20 = 10 秒）。

**`wifi-crack: command not found`**
`$PREFIX/bin` 不在当前 PATH，或安装时用错了 `PREFIX`。重开 Termux 再试，
也可以直接 `$PREFIX/bin/wifi-crack`。

## 许可

仅供学习与自有网络安全自查使用。
