# WiFi Crack Termux

适用于 Android（Termux + Root）的 WiFi 密码字典暴破工具

## 功能特性

- 扫描附近的 WiFi 网络
- 使用字典文件暴破密码
- 自动识别加密类型（WPA2/WPA3/WEP）
- 通过 `cmd wifi` 快速验证连接
- 显示破解进度、速度与预计剩余时间

## 环境要求

- 已获取 root 权限的 Android 手机
- 已安装 Termux
- 可用 `cmd wifi` 命令（需要 root 权限）

## 使用方法

```bash
# 交互模式
wifi-crack

# 快速模式 - 直接指定目标
wifi-crack -t <SSID> [BSSID] [加密类型] [字典路径]
```

### 交互模式

1. 运行 `wifi-crack`
2. 选择选项 `1` 开始扫描
3. 从列表中选择目标网络
4. 等待密码被破解出来

### 快速模式

```bash
wifi-crack -t MINI 50:88:11:7b:b5:3c wpa2 ~/幻影WiFi字典.txt
```

## 字典文件

将字典文件放到 `~/幻影WiFi字典.txt`，或在命令行中指定自定义路径。

支持任意文本文件，每行一个密码。

## 安装步骤

```bash
# 克隆仓库
git clone https://github.com/xkxxs/wifi-crack-termux.git
cd wifi-crack-termux

# 添加可执行权限
chmod +x wifi-crack.sh

# 复制到用户主目录
cp wifi-crack.sh ~/wifi-crack.sh

# 创建快捷命令（可选，之后可在任意目录直接运行 wifi-crack）
sudo tee /data/data/com.termux/files/usr/bin/wifi-crack > /dev/null << 'EOF'
#!/bin/bash
exec sudo /data/data/com.termux/files/home/wifi-crack.sh "$@"
EOF
sudo chmod +x /data/data/com.termux/files/usr/bin/wifi-crack
```

## 注意事项

- 每次密码尝试约耗时 5 秒
- 使用质量较好的字典可以更快出结果
- 破解成功后脚本会自动断开该 WiFi
- 结果保存在 `~/wifi-results/`