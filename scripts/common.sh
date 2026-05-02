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
    if openstack flavor show small >/dev/null 2>&1; then
        echo "small"
    else
        openstack flavor list -f value -c Name | head -1
    fi
}
