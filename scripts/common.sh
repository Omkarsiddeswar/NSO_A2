#!/usr/bin/env bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

fail() {
    echo "ERROR: $1"
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
        fail "OpenStack CLI is not installed. Install it first using: sudo apt install python3-openstackclient"
    fi

    log "OpenStack CLI found."
}

check_openstack_connection() {
    log "Checking OpenStack connection."

    if ! openstack server list >/dev/null 2>&1; then
        fail "Could not connect to OpenStack. Check your OpenRC file and credentials."
    fi

    log "OpenStack connection OK."
}
create_keypair_if_missing() {
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

create_network_if_missing() {
    local tag="$1"
    local network_name="${tag}_network"
    local subnet_name="${tag}_subnet"
    local router_name="${tag}_router"

    if openstack network show "$network_name" >/dev/null 2>&1; then
        log "Detected $network_name."
    else
        log "Did not detect $network_name, adding it."
        openstack network create "$network_name"
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
            "$subnet_name"
        log "Added $subnet_name."
    fi

    if openstack router show "$router_name" >/dev/null 2>&1; then
        log "Detected $router_name."
    else
        log "Did not detect $router_name, adding it."
        openstack router create "$router_name"
        log "Added $router_name."
    fi

    if ! openstack router show "$router_name" -f value -c interfaces_info | grep -q "$subnet_name"; then
        log "Adding subnet to router."
        openstack router add subnet "$router_name" "$subnet_name" || true
        log "Router interface added."
    fi
}
