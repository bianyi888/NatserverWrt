#!/bin/bash
# diy-part2: 在 feeds install 之后、copy .config 之前执行
# 工作流调用位置: openwrt/ 目录下
# 主要做: 主机名、IP、版本标识等轻量定制, 不动内核

# 1. 默认 LAN IP 改成 192.168.5.1
sed -i 's/192\.168\.1\.1/192.168.5.1/g' package/base-files/files/bin/config_generate
if ! grep -q '192\.168\.5\.1' package/base-files/files/bin/config_generate; then
  echo "ERROR: LAN 默认 IP 192.168.5.1 未生效" >&2; exit 1
fi

# 2. 确保 golang 版本足够新 (dae 需要 go 1.21+), feeds 自带一般够, 这里只打印确认
./scripts/feeds list | grep -E "^(dae|daed|luci-app-daede|vmlinux-btf|v2ray-geo)" || echo "WARN: dae 相关 feed 未列出, 请检查 diy-part1 是否生效"

# 5. RE-SS-01 内核分区扩到 12M (照抄 istoreos 方案: HLOS12M GPT + U-Boot /big.html)
#    只改 Device/jdcloud_re-ss-01 块, 不动 re-cs-02/re-cs-07/nn6000 的 6144k
sed -i '/^define Device\/jdcloud_re-ss-01$/,/^endef$/s/KERNEL_SIZE := 6144k/KERNEL_SIZE := 12288k/' target/linux/qualcommax/image/ipq60xx.mk
if ! sed -n '/^define Device\/jdcloud_re-ss-01$/,/^endef$/p' target/linux/qualcommax/image/ipq60xx.mk | grep -q 'KERNEL_SIZE := 12288k'; then
  echo "ERROR: RE-SS-01 KERNEL_SIZE 12288k 补丁未生效 (上游块结构变了?)" >&2
  exit 1
fi
if [ "$(grep -c 'KERNEL_SIZE := 12288k' target/linux/qualcommax/image/ipq60xx.mk)" != "1" ]; then
  echo "ERROR: 12288k 出现次数不是 1, 可能误改了其他设备" >&2
  exit 1
fi
echo "OK: RE-SS-01 KERNEL_SIZE := 12288k"

# 6. 默认主题设为 Aurora (首次开机时切换)
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-set-aurora-theme <<'THEME_EOF'
#!/bin/sh
# 首次开机把默认主题切到 aurora
if [ "$(uci -q get luci.main.mediaurlbase)" = "/luci-static/bootstrap" ]; then
  uci set luci.main.mediaurlbase='/luci-static/aurora'
  uci commit luci
fi
exit 0
THEME_EOF
chmod +x files/etc/uci-defaults/99-set-aurora-theme
echo "OK: 默认主题 -> Aurora (uci-defaults)"

# 7. 关 DNS 重定向 (防 nft 劫持绕过 daed 致 DNS 泄漏)
cat > files/etc/uci-defaults/99-dns-redirect-off <<'DNS_EOF'
#!/bin/sh
# 首次开机关闭 DNS 重定向
uci set dhcp.@dnsmasq[0].noresolv='0'
# 删掉 firewall 里的 DNS 劫持 redirect 规则
uci delete firewall.dns_redirect 2>/dev/null
uci commit dhcp
uci commit firewall
/etc/init.d/dnsmasq restart 2>/dev/null
/etc/init.d/firewall restart 2>/dev/null
exit 0
DNS_EOF
chmod +x files/etc/uci-defaults/99-dns-redirect-off
echo "OK: DNS 重定向已关 (uci-defaults)"

# 8. PS5 DNS 劫持 (manuals.playstation.net -> 140.245.119.225，屏蔽更新域名)
cat > files/etc/uci-defaults/99-ps5-dns <<'PS5_EOF'
#!/bin/sh
# 首次开机写入 dnsmasq 的 PS5 劫持/屏蔽规则
uci add_list dhcp.@dnsmasq[0].address='/manuals.playstation.net/140.245.119.225'
uci add_list dhcp.@dnsmasq[0].address='/manuals.playstation.net/::'
uci add_list dhcp.@dnsmasq[0].address='/playstation.net/0.0.0.0'
uci add_list dhcp.@dnsmasq[0].address='/playstation.com/0.0.0.0'
uci add_list dhcp.@dnsmasq[0].address='/psndl.net/0.0.0.0'
uci add_list dhcp.@dnsmasq[0].address='/playstation.org/0.0.0.0'
uci add_list dhcp.@dnsmasq[0].address='/psn.net/0.0.0.0'
uci add_list dhcp.@dnsmasq[0].address='/sonyentertainmentnetwork.com/0.0.0.0'
uci commit dhcp
/etc/init.d/dnsmasq restart 2>/dev/null
exit 0
PS5_EOF
chmod +x files/etc/uci-defaults/99-ps5-dns
echo "OK: PS5 DNS 劫持已写入 (uci-defaults)"

# 9. WAN 默认 PPPoE (账号密码留空，用户自己填)
cat > files/etc/uci-defaults/99-wan-pppoe <<'PPPOE_EOF'
#!/bin/sh
# 首次开机把 WAN 切到 PPPoE，账号密码留空
uci set network.wan.proto='pppoe'
uci set network.wan.username=''
uci set network.wan.password=''
uci commit network
/etc/init.d/network restart 2>/dev/null
exit 0
PPPOE_EOF
chmod +x files/etc/uci-defaults/99-wan-pppoe
echo "OK: WAN -> PPPoE (uci-defaults)"

# 10. 防火墙放行 PT 51413 (TCP+UDP，WAN -> LAN)
cat > files/etc/uci-defaults/99-custom-firewall <<'FW_EOF'
#!/bin/sh
# 首次开机放行 PT 下载机的 51413 端口
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-PT-51413'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest='lan'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='51413'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall restart 2>/dev/null
exit 0
FW_EOF
chmod +x files/etc/uci-defaults/99-custom-firewall
echo "OK: 防火墙放行 51413 (uci-defaults)"

echo "diy-part2 done"
