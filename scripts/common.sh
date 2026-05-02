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
