#!/bin/sh
# Offline management helper; never starts services or exports secrets.
set -eu
umask 022
ONE=${ZEROTIER_PATH:-/var/lib/zerotier-one}
CFG=${CONFIG_PATH:-/app/config}
DIST=${DIST_PATH:-/app/dist}
MK=${MKWORLD_BIN:-/usr/local/bin/mkworld}
mkdir -p "$ONE" "$CFG" "$DIST"
role=$(cat "$CFG/role" 2>/dev/null || echo primary)
case ${1:-} in
root-init)
    [ "$role" = root ] || [ -z "$(ls -A "$ONE")" ] || { echo 'Existing primary data; refusing root initialization' >&2; exit 1; }
    echo root > "$CFG/role"
    port=${4:-9994}
    case "$port" in ''|*[!0-9]*) exit 1;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
    if [ ! -e "$ONE/identity.secret" ] && [ ! -e "$ONE/identity.public" ]; then
        zerotier-idtool generate "$ONE/identity.secret" "$ONE/identity.public"
    fi
    [ "$(zerotier-idtool getpublic "$ONE/identity.secret")" = "$(cat "$ONE/identity.public")" ]
    # Endpoints are explicit; there is no network access in this helper.
    jq -n --arg identity "$(cat "$ONE/identity.public")" --arg ip4 "${2:-}" --arg ip6 "${3:-}" --arg p "$port" \
        '{roots:[{identity:$identity,stableEndpoints:([$ip4,$ip6]|map(select(length>0)|.+"/"+$p))}]}' > "$CFG/root.json.tmp"
    "$MK" validate "$CFG/root.json.tmp"
    if [ -f "$CFG/root.json" ] && ! cmp -s "$CFG/root.json.tmp" "$CFG/root.json"; then
        echo 'Root already initialized with different endpoints; refusing to change live configuration' >&2
        exit 1
    fi
    mv "$CFG/root.json.tmp" "$CFG/root.json"
    echo root > "$CFG/role"
    echo "$port" > "$CFG/zerotier-one.port"
    ;;
root-export)
    if [ "$role" = root ]; then cat "$CFG/root.json";
    else "$MK" inspect "$DIST/planet" | jq --arg id "$(cat "$ONE/identity.public")" '{roots:[.roots[]|select(.identity==$id)]}'; fi
    ;;
build)
    [ "$role" = primary ] || { echo 'Only primary can sign' >&2; exit 1; }
    cat > "$CFG/roots.next.json"
    "$MK" build "$CFG/roots.next.json" "$DIST/planet" "$ONE" "$DIST/planet.next"
    "$MK" member "$DIST/planet.next" "$ONE/identity.public"
    ;;
check)
    "$MK" member "$CFG/planet.in" "$ONE/identity.public"
    if [ -f "$DIST/planet" ]; then "$MK" verify "$DIST/planet" "$CFG/planet.in"; fi
    # Legacy deployments may still have the official planet in the daemon directory.
    if [ -f "$ONE/planet" ] && "$MK" member "$ONE/planet" "$ONE/identity.public" 2>/dev/null; then
        "$MK" verify "$ONE/planet" "$CFG/planet.in"
    fi
    ;;
snapshot|restore)
    case "${2:-}" in apply.*) ;; *) exit 1;; esac
    case "$2" in */*) exit 1;; esac
    saved="$CFG/$2"
    [ -d "$saved" ]
    for name in one dist; do
        target="$ONE/planet"
        [ "$name" != dist ] || target="$DIST/planet"
        if [ "$1" = snapshot ]; then
            [ ! -f "$target" ] || cp "$target" "$saved/$name"
        elif [ -f "$saved/$name" ]; then
            cp "$saved/$name" "$target.restore"
            mv "$target.restore" "$target"
        else
            rm -f "$target"
        fi
    done
    if [ "$1" = snapshot ]; then touch "$saved/snapshot"; fi
    ;;
apply)
    "$0" check
    cp "$CFG/planet.in" "$ONE/planet.new"
    cp "$CFG/planet.in" "$DIST/planet.new"
    mv "$ONE/planet.new" "$ONE/planet"
    mv "$DIST/planet.new" "$DIST/planet"
    ;;
version)
    "$MK" inspect "$DIST/planet" | jq -r --arg id "$(cut -d: -f1 "$ONE/identity.public")" '[.id,.timestamp,$id]|@tsv'
    ;;
info)
    echo "role=$role" >&2
    "$MK" inspect "$DIST/planet"
    if [ -f "$ONE/planet" ] && ! cmp -s "$ONE/planet" "$DIST/planet"; then
        echo 'WARNING: runtime and published planet differ; inspect before applying' >&2
        "$MK" inspect "$ONE/planet" >&2
    fi
    ;;
*) echo 'planetctl: root-init IPv4 IPv6 PORT | root-export | build | check | apply | info' >&2; exit 1;;
esac
