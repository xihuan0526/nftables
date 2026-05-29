# nftables 端口转发管理脚本

一个纯 Shell 的 Linux 端口转发管理工具，底层使用 `nftables`。

运行脚本后会出现菜单，可以直接选择功能：

```text
1) 添加端口转发
2) 显示当前端口转发
3) 删除端口转发
4) 清空全部规则
5) 退出
```

## 功能

- 交互式菜单操作
- 自动检测 nftables；如果没有安装，会尝试自动执行 `apt update -y` 和 `apt install nftables -y`
- 添加 TCP / UDP 端口转发
- 显示当前端口转发信息
- 删除指定端口转发
- 清空本脚本创建的全部规则
- 同时保留命令行参数模式，方便脚本化使用

## 一键下载

不用 clone 整个仓库，直接下载脚本即可：

```bash
wget https://raw.githubusercontent.com/xihuan0526/nftables/refs/heads/main/nftables-forwarder.sh
chmod +x nftables-forwarder.sh
sudo ./nftables-forwarder.sh
```

如果系统没有安装 nftables，脚本会在需要使用 nftables 时自动尝试安装：

```bash
apt update -y
apt install nftables -y
```

> 自动安装依赖需要 root 权限，所以推荐用 `sudo ./nftables-forwarder.sh` 运行。

## 交互式使用

直接运行：

```bash
sudo ./nftables-forwarder.sh
```

然后根据菜单选择：

```text
1) 添加端口转发
2) 显示当前端口转发
3) 删除端口转发
4) 清空全部规则
5) 退出
```

## 命令行使用

### 添加端口转发

格式：

```bash
sudo ./nftables-forwarder.sh add <协议> <监听端口> <目标IP> <目标端口> [网卡]
```

示例：

```bash
sudo ./nftables-forwarder.sh add tcp 8080 10.0.0.2 80 eth0
```

意思是：

```text
本机 eth0 的 8080/tcp -> 10.0.0.2:80
```

UDP 示例：

```bash
sudo ./nftables-forwarder.sh add udp 5353 10.0.0.3 53 eth0
```

不限制网卡：

```bash
sudo ./nftables-forwarder.sh add tcp 8080 10.0.0.2 80
```

### 显示当前端口转发

```bash
sudo ./nftables-forwarder.sh list
```

或：

```bash
sudo ./nftables-forwarder.sh show
```

### 删除端口转发

按协议 + 监听端口删除：

```bash
sudo ./nftables-forwarder.sh delete tcp 8080
```

如果同一个监听端口有多条规则，可以指定目标 IP 和目标端口：

```bash
sudo ./nftables-forwarder.sh delete tcp 8080 10.0.0.2 80
```

简写：

```bash
sudo ./nftables-forwarder.sh rm tcp 8080
```

### 清空全部规则

```bash
sudo ./nftables-forwarder.sh flush
```

这会删除：

- `inet portfw` 表
- 本地记录文件 `/var/lib/nftables-forwarder/rules.tsv`

## 本脚本创建了什么

默认管理这个 nftables table：

```text
inet portfw
```

内部包含：

- `prerouting`：DNAT 转发规则
- `forward`：放行转发流量

本地记录文件：

```text
/var/lib/nftables-forwarder/rules.tsv
```

## 注意事项

- 需要 Linux。
- Debian / Ubuntu 系统未安装 nftables 时，脚本会尝试用 apt 自动安装。
- 添加/删除/清空规则通常需要 root 权限。
- 本工具管理的 table 是 `inet portfw`。
- 不要把其它手写 nftables 规则放进 `inet portfw`，因为 `flush` 会删除整个表。
- 如果转发到内网机器，目标机器的回程路由/网关也要正确，否则连接可能回不来。
- 脚本会在添加规则时执行 `sysctl -w net.ipv4.ip_forward=1`。

## 测试

```bash
bash -n nftables-forwarder.sh
./tests/test_shell_menu.sh
```

## License

MIT
