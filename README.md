# nftables-forwarder

一个 Linux 端口转发管理工具，核心使用 `nftables`。

现在提供两种用法：

1. **Shell 脚本版**：`nftables-forwarder.sh`，适合服务器直接运行。
2. **Python CLI 版**：`nftables-forwarder`，适合生成 nft 脚本或做二次开发。

## Shell 脚本版（推荐）

脚本功能：

- 添加端口转发
- 显示当前端口转发信息
- 删除指定端口转发
- 清空本工具创建的所有端口转发

### 准备

系统需要安装 nftables：

```bash
sudo apt update
sudo apt install nftables
```

下载仓库：

```bash
git clone https://github.com/xihuan0526/nftables.git
cd nftables
chmod +x nftables-forwarder.sh
```

### 添加端口转发

格式：

```bash
sudo ./nftables-forwarder.sh add <协议> <监听端口> <目标IP> <目标端口> [网卡]
```

例子：

```bash
sudo ./nftables-forwarder.sh add tcp 8080 10.0.0.2 80 eth0
```

意思是：

```text
本机 eth0 的 8080/tcp  ->  10.0.0.2:80
```

UDP 示例：

```bash
sudo ./nftables-forwarder.sh add udp 5353 10.0.0.3 53 eth0
```

如果不想限制网卡，可以省略最后的网卡参数：

```bash
sudo ./nftables-forwarder.sh add tcp 8080 10.0.0.2 80
```

### 显示当前端口转发信息

```bash
sudo ./nftables-forwarder.sh list
```

也可以：

```bash
sudo ./nftables-forwarder.sh show
```

它会显示：

- 本脚本记录的端口转发
- 当前 `nftables` 中 `inet portfw` 表的规则

### 删除端口转发

按协议 + 监听端口删除：

```bash
sudo ./nftables-forwarder.sh delete tcp 8080
```

如果同一个监听端口有多条规则，可以指定目标 IP 和目标端口：

```bash
sudo ./nftables-forwarder.sh delete tcp 8080 10.0.0.2 80
```

也可以用简写：

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

### 帮助

```bash
./nftables-forwarder.sh --help
```

## 注意事项

- 需要 Linux + nftables。
- 添加/删除/清空规则通常需要 root 权限。
- 本工具管理的 table 是：`inet portfw`。
- 不要把其它手写 nftables 规则放进 `inet portfw`，因为 `flush` 会删除整个表。
- 如果转发到内网机器，目标机器的回程路由/网关也要正确，否则连接可能回不来。

## Python CLI 版

### 安装

```bash
python3 -m pip install -e .
```

### 生成规则，不应用

```bash
nftables-forwarder -i eth0 8080:10.0.0.2:80
```

### UDP 转发

```bash
nftables-forwarder 5353:10.0.0.3:53/udp
```

### 多条规则

```bash
nftables-forwarder \
  8080:10.0.0.2:80 \
  8443:10.0.0.2:443 \
  5353:10.0.0.3:53/udp
```

### 直接应用

```bash
sudo nftables-forwarder --apply --sysctl -i eth0 8080:10.0.0.2:80
```

### 删除 Python CLI 创建的 table

```bash
sudo nftables-forwarder --delete --apply
```

## 开发测试

```bash
PYTHONPATH=src python3 -m unittest discover -s tests -v
bash -n nftables-forwarder.sh
```

## License

MIT
