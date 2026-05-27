#!/bin/sh
# Wait for tun0 in the shared OpenVPN network namespace
until ip addr show tun0 >/dev/null 2>&1; do
    echo "dnsmasq: waiting for tun0..."
    sleep 1
done
echo "dnsmasq: tun0 is up"

# Helper: add DNAT + MASQUERADE (idempotent, legacy backend = same as OpenVPN)
# $1 = proto (tcp/udp), $2 = port, $3 = dest IP, $4 = dest port
add_dnat() {
    PROTO=$1 PORT=$2 DEST_IP=$3 DEST_PORT=$4
    IPT="iptables-legacy -t nat"
    $IPT -D PREROUTING -i tun0 -p "$PROTO" --dport "$PORT" -j DNAT --to "$DEST_IP:$DEST_PORT" 2>/dev/null || true
    $IPT -A PREROUTING -i tun0 -p "$PROTO" --dport "$PORT" -j DNAT --to "$DEST_IP:$DEST_PORT"
}

# MASQUERADE on eth1 so Docker bridge can route responses back (idempotent)
iptables-legacy -t nat -D POSTROUTING -s 10.8.0.0/24 -o eth1 -j MASQUERADE 2>/dev/null || true
iptables-legacy -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth1 -j MASQUERADE

# Resolve a Docker container name via Docker's embedded DNS (127.0.0.11).
# Uses getent(1) which is reliable on Alpine/musl; retries until the container
# is registered in DNS (up to $2 * 2 s).
# Prints the IP to stdout and returns 0 on success, 1 on timeout.
resolve_with_retry() {
    local name="$1" max="${2:-30}" attempt=0 ip=""
    while [ "$attempt" -lt "$max" ]; do
        ip=$(getent hosts "$name" 2>/dev/null | awk '{print $1; exit}')
        [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

# ── nginx (port 443 / 80) ────────────────────────────────────────────────────
if NGINX_IP=$(resolve_with_retry nginx 30); then
    add_dnat tcp 443   "$NGINX_IP" 443
    add_dnat tcp 80    "$NGINX_IP" 80
    add_dnat tcp 64738 "$NGINX_IP" 64738
    add_dnat udp 64738 "$NGINX_IP" 64738
    echo "dnsmasq: DNAT nginx → $NGINX_IP:443/80/64738"
else
    echo "dnsmasq: WARNING: could not resolve nginx — DNAT not set"
fi

# ── TAKServer (8089 TLS client / 8443 WebTAK / 8444 cert-enroll / 8446) ─────
if TAK_IP=$(resolve_with_retry takserver 5); then
    add_dnat tcp 8089 "$TAK_IP" 8089
    add_dnat tcp 8443 "$TAK_IP" 8443
    add_dnat tcp 8444 "$TAK_IP" 8444
    add_dnat tcp 8446 "$TAK_IP" 8446
    echo "dnsmasq: DNAT takserver → $TAK_IP:8089/8443/8444/8446"
else
    echo "dnsmasq: TAKServer not running — skipping TAK DNAT"
fi

exec dnsmasq --keep-in-foreground -C /etc/dnsmasq.conf
