#!/usr/bin/env bash

TARGETS=(
"8.8.8.8          Google_IPv4"
"1.1.1.1          Cloudflare_IPv4"
"2001:4860:4860::8888  Google_IPv6"
"2606:4700:4700::1111  Cloudflare_IPv6"
)

TIMEOUT=3
BAR_WIDTH=20
EXEC_MODE="native"
ADB_TARGET=""

# ──────────────────────────────────────────
# Backend detection
# ──────────────────────────────────────────
_AVAIL_NATIVE=true
_AVAIL_ADB=false
_AVAIL_LADB=false
_AVAIL_RISH=false

if command -v adb >/dev/null 2>&1; then
    _state=$(adb -s emulator-5554 get-state 2>/dev/null)
    if [[ "$_state" == "device" ]]; then
        _AVAIL_LADB=true
        _AVAIL_ADB=false
        ADB_TARGET="emulator-5554"
    elif adb devices 2>/dev/null | grep -q "device$"; then
        _AVAIL_ADB=true
        ADB_TARGET=$(adb devices 2>/dev/null | grep "device$" | head -1 | awk '{print $1}')
    fi
fi

if command -v rish >/dev/null 2>&1; then
    if rish -c "exit" >/dev/null 2>&1; then _AVAIL_RISH=true; fi
fi

# Auto-select backend
if $_AVAIL_LADB; then EXEC_MODE="ladb"
elif $_AVAIL_ADB; then EXEC_MODE="adb"
elif $_AVAIL_RISH; then EXEC_MODE="rish"
else EXEC_MODE="native"
fi

# ──────────────────────────────────────────
# Execution wrappers
# ──────────────────────────────────────────
run_cmd() {
    case "$EXEC_MODE" in
        ladb|adb) adb -s "$ADB_TARGET" shell "$1" 2>&1 ;;
        rish)     rish -c "$1" 2>&1 ;;
        native)   eval "$1" 2>&1 ;;
    esac
}

run_ping()      { run_cmd "ping $1"; }
run_ping6()     { run_cmd "ping6 $1"; }
run_tracepath() { eval "tracepath $1" 2>&1; }

get_iface_mtu() {
    local iface="$1"
    local mtu=$(run_cmd "cat /sys/class/net/$iface/mtu" | tr -dc '0-9')
    [[ -n "$mtu" && "$mtu" -gt 0 ]] && { echo "$mtu"; return; }
    echo "1500"
}

MTU_WLAN=$(get_iface_mtu wlan0)

draw_progress() {
    local done=$1 total=$2 spin=$3
    local percent=$(( done * 100 / total ))
    local filled=$(( done * BAR_WIDTH / total ))
    local empty=$(( BAR_WIDTH - filled ))
    local bar=""
    for (( i=0; i<filled; i++ )); do
        if [[ $filled -gt 0 && $(( spin % filled )) -eq $i ]]; then bar+=">"; else bar+="#"; fi
    done
    for (( i=0; i<empty; i++ )); do bar+="-"; done
    printf '\033[36m[%s]\033[0m \033[1m%3d%%\033[0m (%d/%d)' "$bar" "$percent" "$done" "$total"
}

extract_mtu_number() { echo "$1" | grep -iEo 'mtu[ =:]+[0-9]+' | grep -oE '[0-9]+' | head -1; }

translate_mode() {
    case "$1" in
        error_read)    echo "error_read   [confidence:high]" ;;
        direct)        echo "direct       [confidence:high]" ;;
        binary_search) echo "binary_search[confidence:mid]"  ;;
        tracepath)     echo "tracepath    [confidence:mid]"  ;;
        *)             echo "$1" ;;
    esac
}

# ──────────────────────────────────────────
# Mode 2: Backend selection submenu
# ──────────────────────────────────────────
select_backend() {
    echo ""
    echo "  Select execution backend:"
    echo ""

    local idx=1
    declare -gA _BACKEND_MAP

    local _tag_native=""
    [[ "$EXEC_MODE" == "native" ]] && _tag_native=" \033[32m<- auto-detected\033[0m"
    printf "    %d) %-30s%b\n" $idx "native (Termux direct)" "$_tag_native"
    _BACKEND_MAP[$idx]="native"; idx=$((idx+1))

    if $_AVAIL_ADB; then
        local _tag_adb=""
        [[ "$EXEC_MODE" == "adb" ]] && _tag_adb=" \033[32m<- auto-detected\033[0m"
        printf "    %d) %-30s%b\n" $idx "adb ($ADB_TARGET)" "$_tag_adb"
        _BACKEND_MAP[$idx]="adb"; idx=$((idx+1))
    else
        printf "    \033[90m-) %-30s [not found]\033[0m\n" "adb"
    fi

    if $_AVAIL_LADB; then
        local _tag_ladb=""
        [[ "$EXEC_MODE" == "ladb" ]] && _tag_ladb=" \033[32m<- auto-detected\033[0m"
        printf "    %d) %-30s%b\n" $idx "ladb (emulator-5554)" "$_tag_ladb"
        _BACKEND_MAP[$idx]="ladb"; idx=$((idx+1))
    else
        printf "    \033[90m-) %-30s [not found]\033[0m\n" "ladb (emulator-5554)"
    fi

    if $_AVAIL_RISH; then
        local _tag_rish=""
        [[ "$EXEC_MODE" == "rish" ]] && _tag_rish=" \033[32m<- auto-detected\033[0m"
        printf "    %d) %-30s%b\n" $idx "rish" "$_tag_rish"
        _BACKEND_MAP[$idx]="rish"; idx=$((idx+1))
    else
        printf "    \033[90m-) %-30s [not found]\033[0m\n" "rish"
    fi

    echo ""
    local max_idx=$(( idx - 1 ))
    while true; do
        read -rp "  Select [1-${max_idx}]: " _be_sel
        if [[ -z "$_be_sel" ]]; then
            echo "  -> Backend: $EXEC_MODE (kept auto-detected)"
            break
        fi
        if [[ -n "${_BACKEND_MAP[$_be_sel]}" ]]; then
            EXEC_MODE="${_BACKEND_MAP[$_be_sel]}"
            echo "  -> Backend: $EXEC_MODE"
            break
        fi
        echo "  * Enter a valid number"
    done
    echo ""
}

# ──────────────────────────────────────────
# Measurement core
# ──────────────────────────────────────────
measure_target() {
    local target="$1" proto="$2" outfile="$3" mode="$4"
    local result_mtu=0 final_mode="" header low high ping_runner frag_opt
    high=$MTU_WLAN
    if [[ "$proto" == "IPv4" ]]; then
        header=28; low=576; ping_runner="run_ping"; frag_opt="-M do"
    else
        header=48; low=1280; ping_runner="run_ping6"; frag_opt=""
    fi

    # Mode 3 → tracepath (native only)
    if [[ "$mode" == "3" ]]; then
        local out=$(run_tracepath "$target")
        result_mtu=$(echo "$out" | grep -i "pmtu" | tail -1 | grep -oE '[0-9]+' | tail -1)
        [[ -n "$result_mtu" && "$result_mtu" -gt 0 ]] \
            && echo "OK:$result_mtu:tracepath" > "$outfile" \
            || echo "BLOCKED:tracepath failed" > "$outfile"
        return
    fi

    # Mode 1 or 2 → ping
    if ! $ping_runner "-c1 -W$TIMEOUT $frag_opt -s $((low - header)) $target" \
            | grep -qE "1 received|1 packets received"; then
        echo "UNREACHABLE" > "$outfile"; return
    fi

    local err=$($ping_runner "-c1 -W$TIMEOUT $frag_opt -s $((high - header)) $target")
    local extracted=$(extract_mtu_number "$err")

    if [[ -n "$extracted" && "$extracted" -gt 0 ]]; then
        result_mtu=$extracted
        final_mode="error_read"
    else
        if echo "$err" | grep -qE "1 received|1 packets received"; then
            result_mtu=$high
            final_mode="direct"
        else
            local optimal=0 tmp_low=$low tmp_high=$high
            while [[ "$tmp_low" -le "$tmp_high" ]]; do
                local mid=$(( (tmp_low + tmp_high) / 2 ))
                if $ping_runner "-c1 -W$TIMEOUT $frag_opt -s $((mid - header)) $target" \
                        | grep -qE "1 received|1 packets received"; then
                    optimal=$mid; tmp_low=$((mid + 1))
                else
                    tmp_high=$((mid - 1))
                fi
            done
            result_mtu=$optimal
            final_mode="binary_search"
        fi
    fi

    [[ "$result_mtu" -gt 0 ]] \
        && echo "OK:$result_mtu:$final_mode" > "$outfile" \
        || echo "BLOCKED" > "$outfile"
}

# ──────────────────────────────────────────
# Main
# ──────────────────────────────────────────
printf '\033[1m\033[36m==========================================\n   MTU Checker\n'
printf "   Backend    : $EXEC_MODE (auto)\n   wlan0 MTU  : $MTU_WLAN bytes\n==========================================\033[0m\n\n"

echo "Select measurement mode:"
echo "  1/Enter) Default [error_read / binary_search / direct]"
echo "  2)       Default [specify backend]"
echo "  3)       tracepath [ICMP:native]"
echo ""
read -rp "Select [1/2/3]: " MODE_SELECT
[[ -z "$MODE_SELECT" ]] && MODE_SELECT=1

# Mode 2 → show backend submenu, then run as ping
if [[ "$MODE_SELECT" == "2" ]]; then
    select_backend
    MODE_SELECT=1
fi

printf "  Backend: \033[1m$EXEC_MODE\033[0m\n\n"

# Re-fetch wlan0 MTU after backend is finalized
MTU_WLAN=$(get_iface_mtu wlan0)

declare -A pids temp labels
for item in "${TARGETS[@]}"; do
    target=$(echo "$item" | awk '{print $1}' | tr -d '\r')
    labels["$target"]=$(echo "$item" | awk '{$1=""; print $0}' | sed 's/^ //' | tr -d '\r')
    temp["$target"]=$(mktemp)
    proto=$([[ "$target" =~ : ]] && echo "IPv6" || echo "IPv4")
    measure_target "$target" "$proto" "${temp[$target]}" "$MODE_SELECT" &
    pids["$target"]=$!
done

TOTAL=${#TARGETS[@]}
DISPLAY_LINES=$(( TOTAL * 3 + 2 ))
for (( i=0; i<DISPLAY_LINES; i++ )); do echo ""; done

spin=0
while true; do
    all_done=true; done_count=0; output=""; spin=$((spin+1))

    for target in "${!pids[@]}"; do
        if kill -0 "${pids[$target]}" 2>/dev/null; then
            all_done=false
        else
            done_count=$((done_count+1))
        fi
    done

    output+="$(draw_progress $done_count $TOTAL $spin)\033[K\n\n"

    for item in "${TARGETS[@]}"; do
        target=$(echo "$item" | awk '{print $1}' | tr -d '\r')
        output+="=== ${labels[$target]} ($target) ===\033[K\n"
        if kill -0 "${pids[$target]}" 2>/dev/null; then
            dots=""
            for ((d=0; d<(spin % 4); d++)); do dots+="."; done
            output+="Measuring${dots}\033[K\n\n"
        else
            res=$(cat "${temp[$target]}" | tr -d '\r')
            if [[ "$res" == OK* ]]; then
                val=$(echo "$res" | cut -d: -f2)
                mode=$(echo "$res" | cut -d: -f3)
                output+="Path MTU = $val bytes [$(translate_mode "$mode")]\033[K\n\n"
            else
                output+="\033[31mFailed\033[0m\033[K\n\n"
            fi
        fi
    done

    printf "\033[${DISPLAY_LINES}A%b" "$output"
    $all_done && break
    sleep 0.4
done

rm -f "${temp[@]}"
echo "Done"
