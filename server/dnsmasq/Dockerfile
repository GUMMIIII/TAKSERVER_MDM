FROM alpine:3.19
RUN apk add --no-cache dnsmasq iproute2 iptables iptables-legacy
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
