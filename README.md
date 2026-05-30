# nftables-forwarder

一个基于 `nftables` 的 Linux 端口转发管理脚本。

特点：

- 纯 Shell 实现，不依赖 Python、Node.js 等运行环境
- 直接运行脚本即可进入中文菜单
- 支持添加、查看、按编号删除端口转发规则
- 默认同时添加 TCP 和 UDP，也可以单独添加 TCP 或 UDP
- 查看规则时只显示脚本记录的端口转发清单，不展示底层 nftables 规则
- 自动添加 `masquerade`，目标是内网 IP 或外网 IP 时都更容易正常回包
- 自动检测 `nftables`，未安装时会尝试自动安装
- 适合 Debian / Ubuntu 服务器快速配置端口转发

## 快速使用

直接下载单个脚本即可，不需要 clone 整个仓库：

```bash
wget https://raw.githubusercontent.com/xihuan0526/nftables/refs/heads/main/nftables-forwarder.sh
chmod +x nftables-forwarder.sh
sudo ./nftables-forwarder.sh
```

运行后会看到菜单：

```text
========================================
 nftables 端口转发管理工具
========================================
1) 添加端口转发
2) 显示当前端口转发
3) 删除端口转发
4) 清空全部规则
5) 退出
========================================
请选择功能 [1-5]:
```

## 自动安装 nftables

脚本会先检测系统里有没有 `nft` 命令。

如果已经安装 `nftables`，脚本会直接使用，不会重复安装。

如果没有安装，并且系统支持 `apt` 或 `apt-get`，脚本会自动执行：

```bash
apt update -y
apt install nftables -y
```

所以建议使用 root 权限运行：

```bash
sudo ./nftables-forwarder.sh
```

如果你的系统不是 Debian / Ubuntu，例如 CentOS、AlmaLinux、Rocky Linux、Arch Linux，需要先自己安装 `nftables`。

## 菜单功能说明

### 1. 添加端口转发

用于创建新的端口转发规则。

默认会同时添加 TCP 和 UDP。

示例：

```text
本机 8080/tcp+udp -> 10.0.0.2:80
```

意思是访问本机 `8080` 端口时，TCP 和 UDP 流量都会转发到 `10.0.0.2:80`。

脚本会同时添加 `masquerade` 回包规则。这样目标可以是内网 IP，也可以是只允许本机公网 IP 访问的外网 IP。目标服务器看到的来源 IP 会是本机/转发机 IP。

### 2. 显示当前端口转发

只显示本脚本记录的端口转发清单，并带有编号，方便删除时选择。

### 3. 删除端口转发

优先按编号删除规则。

例如列表里显示：

```text
编号 协议   监听端口     目标
2    udp    8080         10.0.0.2:80
```

删除编号 `2`：

```bash
sudo ./nftables-forwarder.sh delete 2
```

也保留按协议和监听端口删除的方式：

```bash
sudo ./nftables-forwarder.sh delete tcp 8080
```

### 4. 清空全部规则

删除本脚本创建的整个 `inet portfw` 表，并清空本地记录文件。

注意：不要把其它手写规则放进 `inet portfw`，否则清空时会一起删除。

## 命令行用法

除了菜单模式，也可以直接用命令行参数。

### 添加规则

```bash
sudo ./nftables-forwarder.sh add <协议> <监听端口> <目标IP> <目标端口> [网卡]
```

协议可以是：

- `both`：同时添加 TCP 和 UDP，默认推荐
- `tcp`：只添加 TCP
- `udp`：只添加 UDP

示例：

```bash
sudo ./nftables-forwarder.sh add both 8080 10.0.0.2 80 eth0
```

不指定网卡也可以：

```bash
sudo ./nftables-forwarder.sh add both 8080 10.0.0.2 80
```

UDP 示例：

```bash
sudo ./nftables-forwarder.sh add udp 5353 10.0.0.3 53 eth0
```

### 查看规则

```bash
sudo ./nftables-forwarder.sh list
```

也可以使用：

```bash
sudo ./nftables-forwarder.sh show
```

### 删除规则

推荐先查看编号：

```bash
sudo ./nftables-forwarder.sh list
```

然后按编号删除：

```bash
sudo ./nftables-forwarder.sh delete 2
```

也可以按协议和监听端口删除：

```bash
sudo ./nftables-forwarder.sh delete tcp 8080
```

如果同一个监听端口有多条规则，可以指定目标 IP 和目标端口：

```bash
sudo ./nftables-forwarder.sh delete tcp 8080 10.0.0.2 80
```

也可以使用简写：

```bash
sudo ./nftables-forwarder.sh rm tcp 8080
```

### 清空规则

```bash
sudo ./nftables-forwarder.sh flush
```

或：

```bash
sudo ./nftables-forwarder.sh clear
```

## 脚本会改动什么

脚本会创建并管理这个 nftables 表：
```text
inet portfw
```

里面包含三个 chain：

- `prerouting`：用于 DNAT 端口转发
- `forward`：用于放行转发流量
- `postrouting`：用于 `masquerade`，保证目标机器能把回包返回给本机/转发机

脚本还会保存一份本地记录，方便显示和删除规则：

```text
/var/lib/nftables-forwarder/rules.tsv
```

添加规则时，脚本会启用 IPv4 转发：

```bash
sysctl -w net.ipv4.ip_forward=1
```

## 注意事项

- 本脚本需要 Linux 系统。
- 添加、删除、清空规则通常需要 root 权限。
- Debian / Ubuntu 可以自动安装 `nftables`。
- 其它发行版需要手动安装 `nftables`。
- 本脚本只管理 `inet portfw` 表。
- 不要把其它 nftables 规则写进 `inet portfw`。
- 如果目标是外网 IP，并且对方防火墙只允许本机公网 IP 访问，`masquerade` 是必须的。
- 因为开启了 `masquerade`，目标服务器看到的来源 IP 会是本机/转发机 IP，不是原始客户端 IP。
- 脚本修改的是当前运行中的 nftables 规则；如果系统重启后规则丢失，需要重新运行脚本添加。

## 测试

```bash
bash -n nftables-forwarder.sh
./tests/test_shell_menu.sh
```

## License

MIT
