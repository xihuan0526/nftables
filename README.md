# nftables-forwarder

一个小型 Linux CLI 工具，用 `nftables` 生成/应用端口转发规则。

它适合把公网机器上的端口转发到内网机器，例如：

```text
公网服务器:8080  ->  10.0.0.2:80
公网服务器:5353/udp  ->  10.0.0.3:53/udp
```

## 功能

- 生成 `nftables` NAT 端口转发脚本
- 支持 TCP / UDP
- 支持指定入站网卡，例如 `eth0`
- 支持直接执行 `nft -f -` 应用规则
- 支持删除工具创建的 nftables table
- 默认 table 名：`portfw`

## 安装

```bash
git clone https://github.com/xihuan0526/nftables.git
cd nftables
python3 -m pip install -e .
```

系统需要安装 nftables：

```bash
sudo apt install nftables
```

## 使用

### 只生成规则，不应用

```bash
nftables-forwarder 8080:10.0.0.2:80
```

输出示例：

```nft
#!/usr/sbin/nft -f
delete table inet portfw

table inet portfw {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    tcp dport 8080 dnat ip to 10.0.0.2:80
  }

  chain forward {
    type filter hook forward priority filter; policy accept;
    ip daddr 10.0.0.2 tcp dport 80 accept
  }
}
```

### 指定网卡

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

### 应用规则

需要 root 权限：

```bash
sudo nftables-forwarder --apply --sysctl -i eth0 8080:10.0.0.2:80
```

说明：

- `--apply`：直接调用 `nft -f -` 应用规则
- `--sysctl`：先执行 `sysctl -w net.ipv4.ip_forward=1`

### 保存为文件

```bash
nftables-forwarder -i eth0 8080:10.0.0.2:80 -o portfw.nft
sudo nft -f portfw.nft
```

### 删除规则

```bash
sudo nftables-forwarder --delete --apply
```

等价于：

```nft
delete table inet portfw
```

## 映射格式

```text
listen_port:target_ip:target_port[/protocol]
```

例子：

```text
8080:10.0.0.2:80
5353:10.0.0.3:53/udp
```

默认协议是 `tcp`。

## 注意

- 需要 Linux + nftables。
- 应用规则通常需要 root 权限。
- 如果转发到内网机器，目标机器的回程路由/网关也要正确，否则连接可能回不来。
- 本工具会重建指定 table（默认 `inet portfw`），不要把其它手写规则放进同名 table。

## 开发测试

```bash
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

## License

MIT
