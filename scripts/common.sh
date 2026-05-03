#!/usr/bin/env bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

fail() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $1"
    exit 1
}

check_file_exists() {
    local file_path="$1"
    local description="$2"

    if [ ! -f "$file_path" ]; then
        fail "$description not found: $file_path"
    fi
}

load_openrc() {
    local openrc_file="$1"

    check_file_exists "$openrc_file" "OpenRC file"
    source "$openrc_file"

    log "OpenStack credentials loaded."
}

check_openstack_cli() {
    if ! command -v openstack >/dev/null 2>&1; then
        fail "OpenStack CLI not found. Install python3-openstackclient first."
    fi

    log "OpenStack CLI found."
}

check_openstack_connection() {
    log "Checking OpenStack connection."

    if ! openstack server list >/dev/null 2>&1; then
        fail "Could not connect to OpenStack. Check the OpenRC file and credentials."
    fi

    log "OpenStack connection OK."
}

create_keypair() {
    local tag="$1"
    local ssh_key="$2"
    local key_name="${tag}_key"

    if openstack keypair show "$key_name" >/dev/null 2>&1; then
        log "Detected $key_name keypair."
    else
        log "Adding $key_name associated with $ssh_key."
        openstack keypair create --public-key "${ssh_key}.pub" "$key_name"
    fi
}

create_network() {
    local tag="$1"
    local network_name="${tag}_network"
    local subnet_name="${tag}_subnet"
    local router_name="${tag}_router"

    if openstack network show "$network_name" >/dev/null 2>&1; then
        log "Detected $network_name."
    else
        log "Did not detect $network_name, adding it."
        openstack network create --tag "$tag" "$network_name" >/dev/null
        log "Added $network_name."
    fi

    if openstack subnet show "$subnet_name" >/dev/null 2>&1; then
        log "Detected $subnet_name."
    else
        log "Did not detect $subnet_name, adding it."
        openstack subnet create \
            --network "$network_name" \
            --subnet-range 192.168.100.0/24 \
            --dns-nameserver 8.8.8.8 \
            "$subnet_name" >/dev/null
        log "Added $subnet_name."
    fi

    if openstack router show "$router_name" >/dev/null 2>&1; then
        log "Detected $router_name."
    else
        log "Did not detect $router_name, adding it."
        openstack router create --tag "$tag" "$router_name" >/dev/null
        log "Added $router_name."

        local external_network
        external_network=$(openstack network list --external -f value -c Name | head -1)

        if [ -n "$external_network" ]; then
            openstack router set --external-gateway "$external_network" "$router_name"
        fi
    fi

    if openstack port list --router "$router_name" -f value -c "Fixed IP Addresses" | grep -q "192.168.100.1"; then
        log "Router interface already exists."
    else
        log "Adding subnet to router."
        openstack router add subnet "$router_name" "$subnet_name"
        log "Router interface added."
    fi
}

create_security_group() {
    local tag="$1"
    local sg_name="${tag}_security_group"

    if openstack security group show "$sg_name" >/dev/null 2>&1; then
        log "Detected $sg_name."
    else
        log "Adding security group $sg_name."
        openstack security group create --tag "$tag" "$sg_name" >/dev/null
    fi

    openstack security group rule create --proto icmp "$sg_name" >/dev/null 2>&1 || true
    openstack security group rule create --proto tcp --dst-port 22 "$sg_name" >/dev/null 2>&1 || true
    openstack security group rule create --proto tcp --dst-port 5000 "$sg_name" >/dev/null 2>&1 || true
    openstack security group rule create --proto udp --dst-port 6000 "$sg_name" >/dev/null 2>&1 || true
    openstack security group rule create --proto udp --dst-port 161 "$sg_name" >/dev/null 2>&1 || true

    log "Security group rules ready."
}

get_image() {
    local image_name

    image_name=$(openstack image list --status active -f value -c Name | grep -i "ubuntu 20.04" | head -1)

    if [ -z "$image_name" ]; then
        image_name=$(openstack image list --status active -f value -c Name | grep -i "ubuntu" | head -1)
    fi

    if [ -z "$image_name" ]; then
        fail "No Ubuntu image found."
    fi

    echo "$image_name"
}

get_flavor() {
    if openstack flavor show tiny >/dev/null 2>&1; then
        echo "tiny"
    else
        openstack flavor list -f value -c Name | head -1
    fi
}

launch_server() {
    local server_name="$1"
    local tag="$2"
    local image_name="$3"
    local flavor_name="$4"

    local network_name="${tag}_network"
    local key_name="${tag}_key"
    local sg_name="${tag}_security_group"

    if openstack server show "$server_name" >/dev/null 2>&1; then
        log "Detected $server_name."
    else
        log "Launching $server_name."
        openstack server create \
            --image "$image_name" \
            --flavor "$flavor_name" \
            --network "$network_name" \
            --security-group "$sg_name" \
            --key-name "$key_name" \
            --tag "$tag" \
            "$server_name" >/dev/null
    fi
}

wait_for_servers() {
    local servers=("$@")

    log "Waiting for servers to become ACTIVE."

    for server_name in "${servers[@]}"; do
        local status=""
        local tries=0

        while [ "$status" != "ACTIVE" ] && [ "$tries" -lt 60 ]; do
            sleep 5
            status=$(openstack server show "$server_name" -f value -c status 2>/dev/null || echo "")
            tries=$((tries + 1))
        done

        if [ "$status" != "ACTIVE" ]; then
            fail "$server_name did not become ACTIVE. Current status: $status"
        fi

        log "$server_name is ACTIVE."
    done
}

get_server_ip() {
    local server_name="$1"

    openstack server show "$server_name" -f json | \
        python3 -c "
import sys, json
d = json.load(sys.stdin)
addrs = list(d['addresses'].values())[0]
a = addrs[0]
print(a if isinstance(a, str) else a['addr'])
"
}

get_free_floating_ip() {
    local free_ip

    free_ip=$(openstack floating ip list --status DOWN -f value -c "Floating IP Address" 2>/dev/null | head -1)

    if [ -n "$free_ip" ]; then
        log "Reusing floating IP $free_ip." >&2
        echo "$free_ip"
        return
    fi

    local external_network
    external_network=$(openstack network list --external -f value -c Name | head -1)

    if [ -z "$external_network" ]; then
        fail "No external network found for floating IP allocation."
    fi

    log "Allocating new floating IP from $external_network." >&2
    openstack floating ip create "$external_network" -f value -c floating_ip_address
}

get_floating_ip() {
    local server_name="$1"

    openstack server show "$server_name" -f json | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for addrs in data['addresses'].values():
    # this openstack returns plain strings not dicts
    # private IP is first, floating IP is second
    if len(addrs) >= 2:
        a = addrs[1]
        print(a if isinstance(a, str) else a['addr'])
        sys.exit()
"
}

assign_floating_ip() {
    local server_name="$1"
    local floating_ip="$2"

    local existing_ip
    existing_ip=$(get_floating_ip "$server_name" 2>/dev/null || true)

    if [ -n "$existing_ip" ]; then
        log "$server_name already has floating IP $existing_ip."
    else
        log "Assigning floating IP $floating_ip to $server_name."
        openstack server add floating ip "$server_name" "$floating_ip"
    fi
}

wait_for_ssh() {
    local ip_address="$1"
    local key_file="$2"
    local tries=0

    log "Waiting for SSH on $ip_address."

    until ssh -i "$key_file" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        "ubuntu@$ip_address" "echo ok" >/dev/null 2>&1; do

        tries=$((tries + 1))

        if [ "$tries" -ge 48 ]; then
            fail "SSH on $ip_address did not become ready."
        fi

        sleep 10
    done

    log "SSH ready on $ip_address."
}

build_ssh_config() {
    local tag="$1"
    local key_file="$2"
    local bastion_ip="$3"
    local output_file="${tag}_SSHconfig"

    log "Writing SSH config to $output_file."

    cat > "$output_file" <<EOF
Host bastion ${tag}_bastion
    HostName $bastion_ip
    User ubuntu
    IdentityFile $key_file
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host ${tag}_proxy
    HostName $(get_server_ip "${tag}_proxy")
    User ubuntu
    IdentityFile $key_file
    ProxyJump bastion
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

    local node_count
    node_count=$(cat servers.conf | tr -d '[:space:]')

    for i in $(seq 1 "$node_count"); do
        cat >> "$output_file" <<EOF

Host ${tag}_node${i}
    HostName $(get_server_ip "${tag}_node${i}")
    User ubuntu
    IdentityFile $key_file
    ProxyJump bastion
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    done
}

build_inventory() {
    local tag="$1"
    local bastion_pub="$2"
    local node_count
    node_count=$(cat servers.conf | tr -d '[:space:]')

    log "Writing Ansible inventory."

    {
        echo "[proxy]"
        echo "${tag}_proxy"
        echo ""
        echo "[bastion]"
        echo "${tag}_bastion ansible_host=${bastion_pub}"
        echo ""
        echo "[nodes]"
        for i in $(seq 1 "$node_count"); do
            echo "${tag}_node${i}"
        done
        echo ""
        echo "[all:vars]"
        echo "ansible_user=ubuntu"
        echo "ansible_ssh_private_key_file=$SSH_KEY"
        echo "ansible_ssh_common_args='-F ${tag}_SSHconfig -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"
    } > hosts
}

update_node_list() {
    local tag="$1"
    local bastion_ip="$2"
    local key_file="$3"
    local node_count

    node_count=$(cat servers.conf | tr -d '[:space:]')

    local node_ips=""
    for i in $(seq 1 "$node_count"); do
        node_ips+="$(get_server_ip "${tag}_node${i}")"$'\n'
    done

    echo "$node_ips" | ssh -i "$key_file" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "ubuntu@$bastion_ip" "cat > /home/ubuntu/nodes.yaml"

    log "Updated node list on bastion."
}
validate_deployment() {
    local proxy_ip="$1"

    log "Validating service through proxy."

    for i in 1 2 3; do
        local response
        response=$(curl -s --max-time 5 "http://${proxy_ip}:5000/" 2>/dev/null || echo "no response")
        log "Request ${i}: $response"
    done

    log "Validation completed."
}
count_live_nodes() {
    local tag="$1"
    local bastion_ip="$2"
    local key_file="$3"
    local live_count=0

    local node_list
    node_list=$(openstack server list --name "${tag}_node" -f value -c Name 2>/dev/null)

    while IFS= read -r node_name; do
        [ -z "$node_name" ] && continue

        local node_ip
        node_ip=$(get_server_ip "$node_name" </dev/null 2>/dev/null || true)
        [ -z "$node_ip" ] && continue

        local result
        result=$(ssh -i "$key_file" \
            -n \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            "ubuntu@$bastion_ip" \
            "ping -c1 -W2 $node_ip >/dev/null 2>&1 && echo ok" 2>/dev/null || true)

        if [ "$result" = "ok" ]; then
            live_count=$((live_count + 1))
        fi
    done < <(echo "$node_list")

    echo "$live_count"
}
