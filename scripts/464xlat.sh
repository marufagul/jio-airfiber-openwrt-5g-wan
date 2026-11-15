#!/bin/sh
# ==============================================================================
# OpenWrt netifd 464xlat Protocol Handler (Offline Bootstrap Reference)
# Copies to /lib/netifd/proto/464xlat.sh if missing on minimal/offline builds
# ==============================================================================

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_464xlat_init_config() {
	proto_config_add_string "tunlink"
	proto_config_add_string "ip6prefix"
	proto_config_add_int "mtu"
	no_device=1
	available=1
}

proto_464xlat_setup() {
	local config="$1"
	local iface="$2"

	local tunlink ip6prefix mtu
	json_get_vars tunlink ip6prefix mtu

	[ -z "$tunlink" ] && {
		proto_notify_error "$config" "MISSING_TUNLINK"
		proto_block_restart "$config"
		return 1
	}

	[ -z "$ip6prefix" ] && ip6prefix="64:ff9b::/96"
	[ -z "$mtu" ] && mtu=1460

	logger -t 464xlat "Bringing up 464xlat interface 464-$config over $tunlink with prefix $ip6prefix"
	proto_init_update "464-$config" 1
	proto_add_ipv4_route "0.0.0.0" 0 "" "" 10
	proto_send_update "$config"
}

proto_464xlat_teardown() {
	local config="$1"
	logger -t 464xlat "Tearing down 464xlat interface 464-$config"
	proto_init_update "*" 0
	proto_send_update "$config"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol 464xlat
}
