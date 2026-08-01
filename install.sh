#!/bin/sh
# Ultimate VLAN Wizard
# - Validation
# - Dual-WAN aware
# - Multi-radio Wi-Fi
# - Profiles
# - LAN4 forced trunk
# - Rollback safety
# - Subnet conflict detection
# - Warning if no untagged/access ports are assigned anywhere
#
# Notes:
# - Supports swconfig and DSA-style configs
# - Assumes per-VLAN subnet 192.168.<VLAN>.0/24
# - LAN4 is always the tagged trunk port
# - Does NOT enforce a management VLAN

set -e

info() { echo "[*] $*"; }
warn() { echo "[!] $*"; }
ok()   { echo "[+] $*"; }

trim_spaces() {
    echo "$1" | awk '{$1=$1; print}'
}

contains_word() {
    needle="$1"
    shift
    for item in $*; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# --- MODE DETECT ---
if uci show network 2>/dev/null | grep -q "switch_vlan"; then
    MODE="swconfig"
else
    MODE="dsa"
fi

info "Mode: $MODE"

# --- MODEL DETECT ---
MODEL_NAME="$(ubus call system board 2>/dev/null | grep -o '"model": *"[^"]*"' | sed 's/"model": *"//;s/"$//' || true)"
BOARD_NAME="$(cat /etc/board.json 2>/dev/null | grep -o '"id": *"[^"]*"' | sed 's/"id": *"//;s/"$//' || true)"

if [ "$MODE" = "swconfig" ]; then
    DEFAULT_TRUNK_PORT="4"
    DEFAULT_LAN_PORTS="1 2 3 4"
else
    DEFAULT_TRUNK_PORT="4"
    DEFAULT_LAN_PORTS=""
fi

case "$BOARD_NAME" in
    glinet,gl-be14000)
        MODEL_FAMILY="GL-BE14000"
        DEFAULT_TRUNK_PORT="6"
        ;;
    glinet,gl-mt6000)
        MODEL_FAMILY="GL-MT6000"
        ;;
    qcom,ipq5332-ap-mi01.2)
        MODEL_FAMILY="GL-BE6500"
        ;;
    qcom,ipq5332-ap-mi04.1-c2)
        MODEL_FAMILY="BE3600"
        ;;
    glinet,gl-be10000)
        MODEL_FAMILY="GL-BE10000"
        ;;
    *)
        MODEL_FAMILY="unknown"
        ;;
esac

info "Model: ${MODEL_FAMILY:-unknown}"
info "Board: ${BOARD_NAME:-unknown}"

# --- PHYSICAL PORT MAP (per model / wiki) ---
# Used by validation and trunk detection to enforce real hardware limits.
case "$MODEL_FAMILY" in
    GL-BE14000)
        MAX_PHYSICAL_PORT=6
        KNOWN_LAN_PORTS="lan1 lan2 lan3 lan4 lan5 lan6"
        ;;
    GL-MT6000)
        MAX_PHYSICAL_PORT=5
        KNOWN_LAN_PORTS="1 2 3 4 5"
        ;;
    GL-BE6500)
        MAX_PHYSICAL_PORT=4
        KNOWN_LAN_PORTS="lan1 lan2 lan3 lan4"
        ;;
    BE3600)
        MAX_PHYSICAL_PORT=4
        KNOWN_LAN_PORTS="lan1 lan2 lan3 lan4"
        ;;
    GL-BE10000)
        MAX_PHYSICAL_PORT=4
        KNOWN_LAN_PORTS="lan1 lan2 lan3 lan4"
        ;;
    *)
        MAX_PHYSICAL_PORT=""
        KNOWN_LAN_PORTS=""
        ;;
esac

if [ -n "$MAX_PHYSICAL_PORT" ]; then
    info "Physical LAN ports: $MAX_PHYSICAL_PORT ($KNOWN_LAN_PORTS)"
fi

# --- OS VERSION DETECT ---
OPENWRT_VERSION=""
OPENWRT_RELEASE=""
if [ -f /etc/openwrt_release ]; then
    OPENWRT_VERSION="$(grep -o 'DISTRIB_VERSION="[^"]*"' /etc/openwrt_release | cut -d'"' -f2 || true)"
    OPENWRT_RELEASE="$(grep -o 'DISTRIB_RELEASE="[^"]*"' /etc/openwrt_release | cut -d'"' -f2 || true)"
fi
info "OpenWrt: ${OPENWRT_VERSION:-unknown} (${OPENWRT_RELEASE:-unknown})"

# Set a flag for 21.02-era behavior
OPENWRT_LEGACY="0"
case "$OPENWRT_VERSION" in
    21.02*|19.07*|22.03*)
        OPENWRT_LEGACY="1"
        ;;
esac

# --- WAN DETECT (DUAL-WAN SAFE) ---
WAN_IFACES=""
for net in wan wan6 wwan wan2; do
    DEV="$(uci -q get network.$net.device || true)"
    IFNAME="$(uci -q get network.$net.ifname || true)"

    [ -n "$DEV" ] && WAN_IFACES="$WAN_IFACES $DEV"
    [ -n "$IFNAME" ] && WAN_IFACES="$WAN_IFACES $IFNAME"
done
WAN_IFACES="$(trim_spaces "$WAN_IFACES")"

if [ -n "$WAN_IFACES" ]; then
    info "Detected WAN interfaces: $WAN_IFACES"
else
    warn "No WAN interfaces auto-detected"
fi

# --- PORT DETECT ---
# Prefer the wiki-derived physical port map when available;
# fall back to /sys/class/net for unknown models.
if [ -n "$KNOWN_LAN_PORTS" ]; then
    if [ "$MODE" = "swconfig" ]; then
        # KNOWN_LAN_PORTS for swconfig is numeric ("1 2 3 4 5")
        LAN_PORTS="$KNOWN_LAN_PORTS"
    else
        LAN_PORTS="$KNOWN_LAN_PORTS"
    fi
else
    if [ "$MODE" = "dsa" ]; then
        LAN_PORTS="$(ls /sys/class/net 2>/dev/null | grep -E '^lan[0-9]+$' | sort || true)"
    else
        LAN_PORTS="1 2 3 4"
    fi
fi

info "Available LAN ports: ${LAN_PORTS:-${DEFAULT_LAN_PORTS}}"

# Default trunk: highest-numbered physical port (common convention),
# but never exceed the known physical port count.
if [ "$MODE" = "dsa" ]; then
    TRUNK_PORT="$(echo "$LAN_PORTS" | tr ' ' '\n' | grep -E '^lan[0-9]+$' | sed 's/lan//' | sort -n | tail -n 1 || true)"
else
    TRUNK_PORT="$(echo "$LAN_PORTS" | tr ' ' '\n' | sort -n | tail -n 1 || true)"
fi

if [ -n "$MAX_PHYSICAL_PORT" ]; then
    case "$TRUNK_PORT" in
        ''|*[!0-9]*)
            TRUNK_PORT="$DEFAULT_TRUNK_PORT"
            ;;
        *)
            if [ "$TRUNK_PORT" -gt "$MAX_PHYSICAL_PORT" ] 2>/dev/null; then
                TRUNK_PORT="$MAX_PHYSICAL_PORT"
            fi
            ;;
    esac
fi

if [ -z "${TRUNK_PORT:-}" ]; then
    TRUNK_PORT="$DEFAULT_TRUNK_PORT"
fi

if [ "$MODEL_FAMILY" = "GL-BE14000" ]; then
    info "BE14000 detected: using lan6 as default trunk"
elif [ "$MODE" = "swconfig" ]; then
    info "swconfig detected: using port $TRUNK_PORT as default trunk"
elif [ -n "$MAX_PHYSICAL_PORT" ]; then
    info "Default trunk: port $TRUNK_PORT"
fi

echo
printf "Load profile? (name or blank): "
read PROFILE

PROFILE_FILE="/root/vlan_profiles/$PROFILE.conf"

VLANS=""
CONFIGS=""
WIFI_PASS=""

if [ -n "$PROFILE" ] && [ -f "$PROFILE_FILE" ]; then
    info "Loading profile $PROFILE"
    # shellcheck disable=SC1090
    . "$PROFILE_FILE"
else
    printf "Enter VLAN IDs (space separated): "
    read VLANS

    if [ -z "$VLANS" ]; then
        warn "No VLANs entered"
        exit 1
    fi

    printf "Wi-Fi password: "
    read WIFI_PASS

    CONFIGS=""

    for v in $VLANS; do
        echo "==== VLAN $v ===="

        printf "SSID (blank = none): "
        read SSID

        if [ -n "$SSID" ]; then
            printf "Isolation? (y/N): "
            read ISO
            case "$ISO" in
                y|Y|yes|YES) ISO="y" ;;
                *) ISO="n" ;;
            esac
        else
            ISO="n"
        fi

        printf "Untagged ports (exclude WAN + %s): " "$TRUNK_PORT"
        read UNTAG
        UNTAG="$(trim_spaces "$UNTAG")"

        CONFIGS="$CONFIGS|$v;$SSID;$ISO;$UNTAG"
    done
fi

# If profile loaded but VLANS missing, rebuild from CONFIGS
if [ -z "$VLANS" ] && [ -n "$CONFIGS" ]; then
    for entry in $(echo "$CONFIGS" | tr '|' ' '); do
        [ -z "$entry" ] && continue
        v="$(echo "$entry" | cut -d';' -f1)"
        VLANS="$VLANS $v"
    done
    VLANS="$(trim_spaces "$VLANS")"
fi

# =========================
# VALIDATION
# =========================
info "Running validation..."

ERRORS=0
WARNINGS=0
UNTAGGED_USED=""
SEEN_VLANS=""
SUBNETS=""
TOTAL_UNTAGGED_PORTS=0

for entry in $(echo "$CONFIGS" | tr '|' ' '); do
    [ -z "$entry" ] && continue

    v="$(echo "$entry" | cut -d';' -f1)"
    SSID="$(echo "$entry" | cut -d';' -f2)"
    ISO="$(echo "$entry" | cut -d';' -f3)"
    UNTAG="$(echo "$entry" | cut -d';' -f4)"
    UNTAG="$(trim_spaces "$UNTAG")"

    # Validate VLAN numeric
    case "$v" in
        ''|*[!0-9]*)
            warn "Invalid VLAN ID: $v"
            ERRORS=$((ERRORS+1))
            continue
            ;;
    esac

    # VLAN range
    if [ "$v" -lt 1 ] || [ "$v" -gt 4094 ]; then
        warn "VLAN $v out of range (1-4094)"
        ERRORS=$((ERRORS+1))
    fi

    # Duplicate VLAN IDs
    if contains_word "$v" $SEEN_VLANS; then
        warn "Duplicate VLAN ID detected: $v"
        ERRORS=$((ERRORS+1))
    else
        SEEN_VLANS="$SEEN_VLANS $v"
    fi

    # Isolation value sanity
    case "$ISO" in
        y|n) ;;
        *)
            warn "Invalid isolation value on VLAN $v: $ISO"
            ERRORS=$((ERRORS+1))
            ;;
    esac

    # Subnet conflict detection
    # Current scheme maps VLAN X -> 192.168.X.0/24
    SUBNET="192.168.$v.0/24"
    if contains_word "$SUBNET" $SUBNETS; then
        warn "Subnet conflict detected for VLAN $v ($SUBNET)"
        ERRORS=$((ERRORS+1))
    else
        SUBNETS="$SUBNETS $SUBNET"
    fi

    # Validate untagged ports
    if [ -n "$UNTAG" ]; then
        for p in $UNTAG; do
            case "$p" in
                ''|*[!0-9]*)
                    warn "VLAN $v has invalid port value: $p"
                    ERRORS=$((ERRORS+1))
                    continue
                    ;;
            esac

            if [ "$p" = "$TRUNK_PORT" ]; then
                warn "VLAN $v uses port $p as untagged, but port $TRUNK_PORT is reserved as trunk"
                ERRORS=$((ERRORS+1))
                continue
            fi

            if [ "$MODE" = "swconfig" ]; then
                if ! contains_word "$p" $LAN_PORTS; then
                    warn "VLAN $v references unknown LAN port: $p"
                    ERRORS=$((ERRORS+1))
                fi
            else
                if ! contains_word "lan$p" $LAN_PORTS; then
                    warn "VLAN $v references unknown LAN port: $p"
                    ERRORS=$((ERRORS+1))
                fi
            fi

            # Physical port limit (from wiki model data)
            if [ -n "$MAX_PHYSICAL_PORT" ]; then
                case "$p" in
                    ''|*[!0-9]*) ;;
                    *)
                        if [ "$p" -gt "$MAX_PHYSICAL_PORT" ] 2>/dev/null; then
                            warn "VLAN $v references port $p which exceeds physical port count ($MAX_PHYSICAL_PORT)"
                            ERRORS=$((ERRORS+1))
                        fi
                        ;;
                esac
            fi

            # WAN safety
            if [ "$MODE" = "dsa" ]; then
                if contains_word "lan$p" $WAN_IFACES; then
                    warn "Port $p is mapped as WAN and cannot be used as LAN"
                    ERRORS=$((ERRORS+1))
                fi
            else
                # Best effort only for swconfig
                if echo " $WAN_IFACES " | grep -q " $p "; then
                    warn "Port $p may be a WAN-related interface; check mapping"
                    ERRORS=$((ERRORS+1))
                fi
            fi

            # Untagged port conflict detection
            for used in $UNTAGGED_USED; do
                used_port="${used#*:}"
                used_vlan="${used%%:*}"
                if [ "$p" = "$used_port" ]; then
                    warn "Port $p is untagged in multiple VLANs ($used_vlan and $v)"
                    ERRORS=$((ERRORS+1))
                fi
            done

            UNTAGGED_USED="$UNTAGGED_USED $v:$p"
            TOTAL_UNTAGGED_PORTS=$((TOTAL_UNTAGGED_PORTS+1))
        done
    else
        warn "VLAN $v has no untagged ports (trunk-only VLAN)"
        WARNINGS=$((WARNINGS+1))
    fi

    # SSID sanity
    if [ -n "$SSID" ]; then
        case "$SSID" in
            *';'*|'|'*)
                warn "SSID for VLAN $v contains unsupported delimiter characters (; or |)"
                ERRORS=$((ERRORS+1))
                ;;
        esac
    fi
done

# Global warning if there are no untagged/access ports anywhere
if [ "$TOTAL_UNTAGGED_PORTS" -eq 0 ]; then
    warn "No untagged/access ports were assigned on any VLAN"
    WARNINGS=$((WARNINGS+1))
fi

if [ -z "$TRUNK_PORT" ]; then
    warn "No trunk port defined"
    ERRORS=$((ERRORS+1))
fi

if [ "$ERRORS" -gt 0 ]; then
    echo
    warn "Validation failed with $ERRORS error(s)"
    exit 1
fi

ok "Validation passed"
if [ "$WARNINGS" -gt 0 ]; then
    warn "Validation completed with $WARNINGS warning(s)"
fi

# --- PREVIEW ---
echo
echo "====== PREVIEW ======"
for entry in $(echo "$CONFIGS" | tr '|' ' '); do
    [ -z "$entry" ] && continue

    v="$(echo "$entry" | cut -d';' -f1)"
    SSID="$(echo "$entry" | cut -d';' -f2)"
    ISO="$(echo "$entry" | cut -d';' -f3)"
    UNTAG="$(echo "$entry" | cut -d';' -f4)"

    echo "VLAN $v"
    echo "  Subnet: 192.168.$v.0/24"
    echo "  Gateway: 192.168.$v.1"
    echo "  Trunk: ${TRUNK_PORT} (tagged)"
    echo "  Untagged: ${UNTAG:-none}"
    echo "  SSID: ${SSID:-none}"
    echo "  Isolation: $ISO"
    echo
done

printf "Apply config? [y/N]: "
read CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) exit 0 ;;
esac

# --- SAVE PROFILE ---
mkdir -p /root/vlan_profiles
printf "Save profile? (name or blank): "
read SAVE
if [ -n "$SAVE" ]; then
    {
        echo "VLANS=\"$VLANS\""
        echo "CONFIGS=\"$CONFIGS\""
        echo "WIFI_PASS=\"$WIFI_PASS\""
    } > "/root/vlan_profiles/$SAVE.conf"
    ok "Saved profile: $SAVE"
fi

# --- BACKUP ---
BACKUP="/root/vlan_backup_$(date +%s)"
mkdir -p "$BACKUP"
uci export network > "$BACKUP/network"
uci export wireless > "$BACKUP/wireless"
uci export firewall > "$BACKUP/firewall"
uci export dhcp > "$BACKUP/dhcp"

ok "Backup saved to: $BACKUP"

# --- ROLLBACK ---
ROLLBACK="/tmp/vlan_rollback"
touch "$ROLLBACK"

(
    sleep 60
    if [ -f "$ROLLBACK" ]; then
        warn "Rollback timer expired, restoring previous config..."
        uci import network < "$BACKUP/network"
        uci import wireless < "$BACKUP/wireless"
        uci import firewall < "$BACKUP/firewall"
        uci import dhcp < "$BACKUP/dhcp"
        uci commit network
        uci commit wireless
        uci commit firewall
        uci commit dhcp
        /etc/init.d/network restart || true
        /etc/init.d/firewall restart || true
        /etc/init.d/dnsmasq restart || true
        wifi reload || true
    fi
) &

# --- CLEAN OLD GENERATED WIFI IFACES ---
# Remove previously generated vlan<vid>_<radio> sections to avoid duplicates
for sec in $(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
    case "$sec" in
        vlan[0-9]*_wifi*)
            uci -q delete "wireless.$sec"
            ;;
    esac
done

# --- CLEAN OLD GENERATED FIREWALL/DHCP ZONES FOR CURRENT VLANS ---
for v in $VLANS; do
    uci -q delete "firewall.vlan$v" || true
    uci -q delete "dhcp.VLAN_$v" || true
    uci -q delete "network.VLAN_$v" || true
done

# --- APPLY NETWORK ---
if [ "$MODE" = "swconfig" ]; then
    while uci -q delete network.@switch_vlan[0]; do :; done

    for entry in $(echo "$CONFIGS" | tr '|' ' '); do
        [ -z "$entry" ] && continue

        v="$(echo "$entry" | cut -d';' -f1)"
        UNTAG="$(echo "$entry" | cut -d';' -f4)"

        PORTS="6t ${TRUNK_PORT}t"
        for p in $UNTAG; do
            [ "$p" = "$TRUNK_PORT" ] && continue
            PORTS="$PORTS $p"
        done

        uci add network switch_vlan >/dev/null
        uci set network.@switch_vlan[-1].device='switch1'
        uci set network.@switch_vlan[-1].vlan="$v"
        uci set network.@switch_vlan[-1].ports="$PORTS"

        uci set network.VLAN_$v='interface'
        uci set network.VLAN_$v.type='bridge'
        uci set network.VLAN_$v.ifname="eth1.$v"
        uci set network.VLAN_$v.proto='static'
        uci set network.VLAN_$v.ipaddr="192.168.$v.1"
        uci set network.VLAN_$v.netmask='255.255.255.0'
    done
else
    # DSA mode
    # NOTE: This assumes br-lan exists and LAN ports are named lan1..lanN
    # It does not delete all existing bridge-vlan sections globally to avoid damaging unrelated config.
    # It appends the requested VLANs.

    for entry in $(echo "$CONFIGS" | tr '|' ' '); do
        [ -z "$entry" ] && continue

        v="$(echo "$entry" | cut -d';' -f1)"
        UNTAG="$(echo "$entry" | cut -d';' -f4)"

        # --- BE6500 23.05 / IPQ53xx: also configure switch1 explicitly ---
        # The BE6500 exposes a non-standard switch1 (ports 4 5 6 7 3t)
        # where port 3 is tagged toward eth1. DSA bridge-vlan alone may
        # not fully program this switch on 23.05, so we write both
        # switch_vlan and bridge-vlan configs for this model.
        if [ "$MODEL_FAMILY" = "GL-BE6500" ]; then
            info "BE6500 detected: writing switch1 hardware VLAN $v"

            # Map DSA port numbers to BE6500 switch1 ports:
            #   lan1 -> 4, lan2 -> 5, lan3 -> 6, lan4 -> 7
            # CPU/tagged uplink is port 3
            SWITCH_PORTS="3t"

            for p in $UNTAG; do
                [ "$p" = "$TRUNK_PORT" ] && continue
                case "$p" in
                    1) SWITCH_PORTS="$SWITCH_PORTS 4u" ;;
                    2) SWITCH_PORTS="$SWITCH_PORTS 5u" ;;
                    3) SWITCH_PORTS="$SWITCH_PORTS 6u" ;;
                    4) SWITCH_PORTS="$SWITCH_PORTS 7u" ;;
                    *) SWITCH_PORTS="$SWITCH_PORTS ${p}u" ;;
                esac
            done

            if [ -n "$TRUNK_PORT" ]; then
                case "$TRUNK_PORT" in
                    1) SWITCH_PORTS="$SWITCH_PORTS 4t" ;;
                    2) SWITCH_PORTS="$SWITCH_PORTS 5t" ;;
                    3) SWITCH_PORTS="$SWITCH_PORTS 6t" ;;
                    4) SWITCH_PORTS="$SWITCH_PORTS 7t" ;;
                    *) SWITCH_PORTS="$SWITCH_PORTS ${TRUNK_PORT}t" ;;
                esac
            fi

            uci add network switch_vlan >/dev/null
            uci set network.@switch_vlan[-1].device='switch1'
            uci set network.@switch_vlan[-1].vlan="$v"
            uci set network.@switch_vlan[-1].ports="$SWITCH_PORTS"
        fi
        # --- end BE6500 switch_vlan ---

        uci add network bridge-vlan >/dev/null
        uci set network.@bridge-vlan[-1].device='br-lan'
        uci set network.@bridge-vlan[-1].vlan="$v"
        uci add_list network.@bridge-vlan[-1].ports="lan${TRUNK_PORT}:t"

        FIRST=1
        for p in $UNTAG; do
            [ "$p" = "$TRUNK_PORT" ] && continue
            if [ "$FIRST" = "1" ]; then
                uci add_list network.@bridge-vlan[-1].ports="lan${p}:u*"
                FIRST=0
            else
                uci add_list network.@bridge-vlan[-1].ports="lan${p}:u"
            fi
        done

        uci set network.VLAN_$v='interface'
        uci set network.VLAN_$v.device="br-lan.$v"
        uci set network.VLAN_$v.proto='static'
        uci set network.VLAN_$v.ipaddr="192.168.$v.1"
        uci set network.VLAN_$v.netmask='255.255.255.0'
    done
fi

uci commit network

# --- WIFI (ALL RADIOS) ---
RADIOS="$(uci show wireless 2>/dev/null | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1 | sort -u)"
info "Detected Wi-Fi radios: ${RADIOS:-none}"

for entry in $(echo "$CONFIGS" | tr '|' ' '); do
    [ -z "$entry" ] && continue

    v="$(echo "$entry" | cut -d';' -f1)"
    SSID="$(echo "$entry" | cut -d';' -f2)"
    ISO="$(echo "$entry" | cut -d';' -f3)"

    [ -z "$SSID" ] && continue

    for r in $RADIOS; do
        IFACE="vlan${v}_${r}"

        uci set wireless.$IFACE='wifi-iface'
        uci set wireless.$IFACE.device="$r"
        uci set wireless.$IFACE.network="VLAN_$v"
        uci set wireless.$IFACE.mode='ap'
        uci set wireless.$IFACE.ssid="$SSID"
        uci set wireless.$IFACE.encryption='psk2'
        uci set wireless.$IFACE.key="$WIFI_PASS"

        if [ "$ISO" = "y" ]; then
            uci set wireless.$IFACE.isolate='1'
        else
            uci -q delete wireless.$IFACE.isolate || true
        fi
    done
done

uci commit wireless

# --- FIREWALL + DHCP ---
for v in $VLANS; do
    uci set firewall.vlan$v='zone'
    uci set firewall.vlan$v.name="VLAN_$v"
    uci set firewall.vlan$v.network="VLAN_$v"
    uci set firewall.vlan$v.input='ACCEPT'
    uci set firewall.vlan$v.forward='REJECT'
    uci set firewall.vlan$v.output='ACCEPT'

    uci add firewall forwarding >/dev/null
    uci set firewall.@forwarding[-1].src="VLAN_$v"
    uci set firewall.@forwarding[-1].dest='wan'

    uci set dhcp.VLAN_$v='dhcp'
    uci set dhcp.VLAN_$v.interface="VLAN_$v"
    uci set dhcp.VLAN_$v.start='100'
    uci set dhcp.VLAN_$v.limit='150'
    uci set dhcp.VLAN_$v.leasetime='12h'
    uci add_list dhcp.VLAN_$v.dhcp_option="6,192.168.$v.1"
done

uci commit firewall
uci commit dhcp

# --- RESTART ---
/etc/init.d/network restart
/etc/init.d/firewall restart || true
/etc/init.d/dnsmasq restart || true
wifi reload || true

echo
printf "Confirm network is working (y to keep): "
read OKAY

case "$OKAY" in
    y|Y|yes|YES)
        rm -f "$ROLLBACK"
        ok "Rollback cancelled, config kept"
        ;;
    *)
        warn "Rollback will trigger automatically in about 60 seconds"
        ;;
esac

ok "Done."
