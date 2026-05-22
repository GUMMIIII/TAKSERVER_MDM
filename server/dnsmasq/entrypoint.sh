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

# ── nginx (port 443 / 80) ────────────────────────────────────────────────────
NGINX_IP=$(nslookup nginx 127.0.0.11 2>/dev/null | grep '^Address:' | grep -v '127\.0\.0\.11' | awk '{print $2}')
if [ -n "$NGINX_IP" ]; then
    add_dnat tcp 443 "$NGINX_IP" 443
    add_dnat tcp 80  "$NGINX_IP" 80
    echo "dnsmasq: DNAT nginx → $NGINX_IP:443/80"
else
    echo "dnsmasq: WARNING: could not resolve nginx — DNAT not set"
fi

# ── TAKServer (8089 TLS client / 8443 WebTAK / 8444 cert-enroll / 8446) ─────
TAK_IP=$(nslookup takserver 127.0.0.11 2>/dev/null | grep '^Address:' | grep -v '127\.0\.0\.11' | awk '{print $2}')
if [ -n "$TAK_IP" ]; then
    add_dnat tcp 8089 "$TAK_IP" 8089
    add_dnat tcp 8443 "$TAK_IP" 8443
    add_dnat tcp 8444 "$TAK_IP" 8444
    add_dnat tcp 8446 "$TAK_IP" 8446
    echo "dnsmasq: DNAT takserver → $TAK_IP:8089/8443/8444/8446"
else
    echo "dnsmasq: TAKServer not running — skipping TAK DNAT"
fi

exec dnsmasq --keep-in-foreground -C /etc/dnsmasq.conf
