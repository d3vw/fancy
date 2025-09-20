#!/usr/bin/env bash
set -euo pipefail

declare -a ALLOW_LIST=()
declare -a ADD_LIST=()
declare -a REMOVE_LIST=()

usage() {
    cat <<USAGE

Usage: $0 [-a <ip_or_cidr>[,<ip_or_cidr>...]]... [-r <ip_or_cidr>[,<ip_or_cidr>...]]... [-p <port>]

Options:
  -a    Comma-separated list of client IP addresses or networks (CIDR) to add to the allow-list.
        Repeat the option to add more entries. At least one allow-list entry must remain.
  -r    Comma-separated list of client IP addresses or networks (CIDR) to remove from the allow-list.
        Repeat the option to remove more entries.
  -p    Port that Dante should listen on (default: 1080).
  -h    Display this help message.
USAGE
}

require_root() {
    if [[ $(id -u) -ne 0 ]]; then
        echo "[ERROR] This script must be run as root." >&2
        exit 1
    fi
}

validate_port() {
    local port=$1
    if ! [[ $port =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        echo "[ERROR] Invalid port: $port. Must be an integer between 1 and 65535." >&2
        exit 1
    fi
}

split_and_append_ips() {
    local input=$1
    local array_name=$2
    local entry ip octet
    local -a entries octets
    local old_ifs=$IFS
    local -n target=$array_name

    IFS=',' read -ra entries <<< "$input"
    IFS=$old_ifs

    for entry in "${entries[@]}"; do
        entry=$(echo "$entry" | xargs)
        if [[ -z $entry ]]; then
            continue
        fi
        if ! [[ $entry =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3})(/(3[0-2]|[12]?[0-9]))?$ ]]; then
            echo "[ERROR] Invalid IPv4 or CIDR block: $entry" >&2
            exit 1
        fi
        # basic octet check
        ip=${entry%%/*}

        old_ifs=$IFS
        IFS='.' read -r -a octets <<< "$ip"
        IFS=$old_ifs

        for octet in "${octets[@]}"; do
            if ((octet < 0 || octet > 255)); then
                echo "[ERROR] Invalid IPv4 address octet in: $entry" >&2
                exit 1
            fi
        done
        if [[ $entry != */* ]]; then
            entry+="/32"
        fi
        target+=("$entry")
    done
}

array_contains() {
    local array_name=$1
    local needle=$2
    local value
    local -n haystack=$array_name

    for value in "${haystack[@]}"; do
        if [[ $value == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

remove_from_array() {
    local array_name=$1
    local needle=$2
    local value
    local -a result=()
    local -n haystack=$array_name

    for value in "${haystack[@]}"; do
        if [[ $value != "$needle" ]]; then
            result+=("$value")
        fi
    done

    haystack=("${result[@]}")
}

read_existing_allow_list() {
    local config_path=$1
    ALLOW_LIST=()

    if [[ ! -f $config_path ]]; then
        return
    fi

    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*from:[[:space:]]*([^[:space:]]+) ]]; then
            ALLOW_LIST+=("${BASH_REMATCH[1]}")
        fi
    done < <(awk '/client pass {/,/}/' "$config_path")
}

get_default_interface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -z $iface ]]; then
        echo "[ERROR] Could not determine the default network interface." >&2
        exit 1
    fi
    echo "$iface"
}

backup_config() {
    local config_path=$1
    if [[ -f $config_path ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d%H%M%S)
        cp "$config_path" "${config_path}.bak-${timestamp}"
    fi
}

write_config() {
    local config_path=$1
    local port=$2
    local iface=$3
    shift 3
    local allow_list=("$@")

    {
        echo "logoutput: syslog"
        echo "internal: 0.0.0.0 port = $port"
        echo "external: $iface"
        echo "clientmethod: none"
        echo "socksmethod: none"
        echo "user.privileged: root"
        echo "user.notprivileged: nobody"
        echo "user.libwrap: nobody"
        for cidr in "${allow_list[@]}"; do
            echo "client pass {"
            echo "    from: $cidr"
            echo "    to: 0.0.0.0/0"
            echo "    log: connect disconnect error"
            echo "}"
        done
        echo "client block {"
        echo "    from: 0.0.0.0/0"
        echo "    to: 0.0.0.0/0"
        echo "    log: connect error"
        echo "}"
        for cidr in "${allow_list[@]}"; do
            echo "pass {"
            echo "    from: $cidr"
            echo "    to: 0.0.0.0/0"
            echo "    protocol: tcp udp"
            echo "    log: connect disconnect error"
            echo "}"
        done
        echo "block {"
        echo "    from: 0.0.0.0/0"
        echo "    to: 0.0.0.0/0"
        echo "    log: connect error"
        echo "}"
    } > "$config_path"
}

restart_service() {
    systemctl daemon-reload
    systemctl enable danted
    systemctl restart danted
}

main() {
    require_root

    local port=1080
    ALLOW_LIST=()
    ADD_LIST=()
    REMOVE_LIST=()

    while getopts ":a:r:p:h" opt; do
        case $opt in
            a)
                split_and_append_ips "$OPTARG" ADD_LIST
                ;;
            r)
                split_and_append_ips "$OPTARG" REMOVE_LIST
                ;;
            p)
                validate_port "$OPTARG"
                port=$OPTARG
                ;;
            h)
                usage
                exit 0
                ;;
            :)
                echo "[ERROR] Option -$OPTARG requires an argument." >&2
                usage
                exit 1
                ;;
            \?)
                echo "[ERROR] Invalid option: -$OPTARG" >&2
                usage
                exit 1
                ;;
        esac
    done


    shift $((OPTIND - 1))

    local config_path="/etc/danted.conf"

    read_existing_allow_list "$config_path"

    if [[ ${#ALLOW_LIST[@]} -eq 0 && ${#ADD_LIST[@]} -eq 0 ]]; then
        echo "[ERROR] No existing allow-list entries found. Use -a to specify at least one client IP/CIDR." >&2
        usage
        exit 1
    fi

    local entry

    for entry in "${ADD_LIST[@]}"; do
        if ! array_contains ALLOW_LIST "$entry"; then
            ALLOW_LIST+=("$entry")
        fi
    done

    for entry in "${REMOVE_LIST[@]}"; do
        if array_contains ALLOW_LIST "$entry"; then
            remove_from_array ALLOW_LIST "$entry"
        else
            echo "[WARN] Client $entry not present in allow-list; skipping removal." >&2
        fi
    done

    if [[ ${#ALLOW_LIST[@]} -eq 0 ]]; then
        echo "[ERROR] At least one allowed client IP/CIDR must remain after applying changes." >&2
        exit 1
    fi

    echo "[INFO] Installing Dante server package..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y dante-server

    local iface
    iface=$(get_default_interface)

    echo "[INFO] Backing up existing configuration (if any)..."
    backup_config "$config_path"

    echo "[INFO] Writing new configuration..."
    write_config "$config_path" "$port" "$iface" "${ALLOW_LIST[@]}"

    echo "[INFO] Restarting Dante service..."
    restart_service

    echo "[SUCCESS] Dante server is configured to listen on port $port"
    if [[ ${#ADD_LIST[@]} -gt 0 ]]; then
        echo "          Added clients: ${ADD_LIST[*]}"
    fi
    if [[ ${#REMOVE_LIST[@]} -gt 0 ]]; then
        echo "          Removed clients: ${REMOVE_LIST[*]}"
    fi
    echo "          Allowed clients: ${ALLOW_LIST[*]}"
    echo "          Default interface: $iface"
}

main "$@"
