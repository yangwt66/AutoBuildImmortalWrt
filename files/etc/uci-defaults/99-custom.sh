#!/bin/sh
LOGFILE="/tmp/uci-defaults-log.txt"
exec >$LOGFILE 2>&1
echo "=== Secure configuration script starts at $(date) ==="

# ---------------------------
# 安全基础配置
# ---------------------------

# 强制保持 WAN 区域默认安全策略 (INPUT: REJECT)
uci set firewall.@zone[1].input='REJECT' && 
    echo "[Firewall] WAN zone policy set to REJECT"

# ---------------------------
# 服务访问控制
# ---------------------------

# TTYD 安全配置 (仅允许 LAN 访问)
uci set ttyd.@ttyd[0].interface='br-lan' &&
    echo "[TTYD] Restricted to LAN interface"

# SSH 安全配置 (仅允许 LAN 访问)
uci set dropbear.@dropbear[0].Interface='lan' &&
    echo "[SSH] Restricted to LAN interface"

# ---------------------------
# 防火墙增强规则
# ---------------------------

# 删除可能存在的临时放行规则
uci -q delete firewall.allow_webui

# 添加明确的 LAN 访问规则
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-LAN-WebUI'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='80 443'
uci set firewall.@rule[-1].target='ACCEPT' &&
    echo "[Firewall] Added LAN WebUI access rule"

# 禁止 WAN 访问管理服务
uci add firewall rule
uci set firewall.@rule[-1].name='Block-WAN-Admin'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='22 80 443'
uci set firewall.@rule[-1].target='REJECT' &&
    echo "[Firewall] Blocked WAN admin access"

# ---------------------------
# 安全网络配置
# ---------------------------

# 静态 DNS 映射 (安全方式)
uci add_list dhcp.@dnsmasq[0].address="/time.android.com/203.107.6.88" &&
    echo "[DNS] Added secure static mapping"

# 禁用不必要的 DHCP 选项
uci set dhcp.lan.dhcpv6='disabled' &&
    echo "[DHCP] Disabled IPv6 DHCP"

# ---------------------------
# 网络接口配置
# ---------------------------

# 物理网卡检测 (安全增强版)
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && [ "$(cat $iface/type 2>/dev/null)" = "1" ]; then
        ifnames="$ifnames $iface_name"
        echo "[Network] Valid physical interface: $iface_name"
    fi
done
ifnames=$(echo $ifnames | xargs)

# 多网卡配置
if [ $(echo $ifnames | wc -w) -gt 1 ]; then
    wan_ifname=$(echo $ifnames | awk '{print $1}')
    lan_ifnames=$(echo $ifnames | cut -d' ' -f2-)

    # 强制 LAN 口静态 IP
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr='192.168.10.66'
    uci set network.lan.netmask='255.255.255.0' &&
        echo "[Network] Set secure LAN IP"

    # 桥接端口绑定验证
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    [ -n "$section" ] && {
        uci -q delete "network.$section.ports"
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "[Bridge] Secured bridge ports: $lan_ifnames"
    }
fi

# ---------------------------
# PPPoE 安全配置
# ---------------------------

SETTINGS_FILE="/etc/config/pppoe-settings"
if [ -f "$SETTINGS_FILE" ]; then
    . "$SETTINGS_FILE"
    [ "$enable_pppoe" = "yes" ] && {
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan6.proto='none' &&
            echo "[PPPoE] Configured with credential protection"
    }
fi

# ---------------------------
# 最终安全措施
# ---------------------------

# 提交所有配置
uci commit

# 强制刷新服务配置
service firewall restart
service network restart
service dnsmasq restart

echo "=== Secure configuration completed at $(date) ==="
exit 0
