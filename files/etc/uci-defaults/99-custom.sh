#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE

# 设置默认防火墙规则，方便单网口虚拟机首次访问 WebUI 
uci set firewall.@zone[1].input='ACCEPT'

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 检查配置文件pppoe-settings是否存在
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >>$LOGFILE
else
    . "$SETTINGS_FILE"
fi

# 1. 获取所有物理接口列表
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

count=$(echo "$ifnames" | wc -w)
echo "Detected physical interfaces: $ifnames" >>$LOGFILE
echo "Interface count: $count" >>$LOGFILE

# 2. 单网口设备作为旁路由配置
if [ "$count" -eq 1 ]; then
    # 单网口设备，作为旁路由LAN口
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr='192.168.10.66'
    uci set network.lan.netmask='255.255.255.0'
    uci set network.lan.gateway='192.168.10.100'
    uci set network.lan.dns='192.168.10.100'  # 使用主路由作为DNS
    
    # 关闭LAN口DHCP服务
    uci set dhcp.lan.ignore='1'
    
    # 删除WAN/WAN6接口
    uci delete network.wan 2>/dev/null
    uci delete network.wan6 2>/dev/null
    
    # 设置唯一网口为LAN
    uci set network.lan.device="$ifnames"
    
    uci commit network
    uci commit dhcp
    echo "Configured single-port as LAN with static IP" >>$LOGFILE

# 3. 多网口设备保持原逻辑（但需修复问题）
elif [ "$count" -gt 1 ]; then
    # 多网口设备配置
    board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
    echo "Board detected: $board_name" >>$LOGFILE

    wan_ifname=""
    lan_ifnames=""
    case "$board_name" in
        "radxa,e20c"|"friendlyarm,nanopi-r5c")
            wan_ifname="eth1"
            lan_ifnames="eth0"
            ;;
        *)
            wan_ifname=$(echo "$ifnames" | awk '{print $1}')
            lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
            ;;
    esac

    # 配置WAN
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'
    
    # 配置WAN6
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'

    # 配置LAN
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[[0-9]+\]\.name=br-lan$/ {print $2; exit}')
    if [ -n "$section" ]; then
        uci -q delete "network.$section.ports"
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports=$port"
        done
    fi

    uci set network.lan.proto='static'
    uci set network.lan.netmask='255.255.255.0'
    
    # 使用自定义IP或默认值
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        uci set network.lan.ipaddr=$(cat "$IP_VALUE_FILE")
    else
        uci set network.lan.ipaddr='192.168.100.1'
    fi

    # PPPoE配置
    if [ "$enable_pppoe" = "yes" ]; then
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
    fi

    uci commit network
    echo "Configured multi-port device" >>$LOGFILE
fi

# 若安装了dockerd 则设置docker的防火墙规则
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..." >>$LOGFILE
    FW_FILE="/etc/config/firewall"
    
    # 删除旧配置
    uci delete firewall.docker 2>/dev/null
    for idx in $(seq 0 10); do
        uci get firewall.@forwarding[$idx] >/dev/null 2>&1 || break
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            uci delete firewall.@forwarding[$idx]
        fi
    done
    
    # 添加新配置
    uci commit firewall
    cat <<EOF >>"$FW_FILE"

config zone
    option name 'docker'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'
    list network 'docker0'

config forwarding
    option src 'docker'
    option dest 'lan'

config forwarding
    option src 'lan'
    option dest 'docker'
EOF
    uci commit firewall
fi

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface 2>/dev/null

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 设置编译作者信息
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='Packaged by wukongdaily'/" /etc/openwrt_release

# 若luci-app-advancedplus已安装 则去除zsh的调用
if opkg list-installed | grep -q 'luci-app-advancedplus'; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus 2>/dev/null
fi

echo "Configuration completed at $(date)" >>$LOGFILE
exit 0
