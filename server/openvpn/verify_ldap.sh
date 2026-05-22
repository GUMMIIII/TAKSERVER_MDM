#!/bin/sh
# OpenVPN auth-user-pass-verify script
# Called by OpenVPN via-env: $username and $password are set as environment variables.
# Exits 0 on success, 1 on failure.
LLDAP_URL="http://lldap:17170"

RESULT=$(wget -qO- \
    --post-data="{\"username\":\"${username}\",\"password\":\"${password}\"}" \
    --header="Content-Type: application/json" \
    "${LLDAP_URL}/auth/simple/login" 2>/dev/null) || true

echo "${RESULT}" | grep -q '"token"' && exit 0
exit 1
