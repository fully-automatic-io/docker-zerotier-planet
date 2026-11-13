#!/bin/bash
# Sourced by deploy.sh; all management binaries run from the selected image.
planet_tool() {
    docker run --rm -i --network none --entrypoint /bin/sh \
        -v "${ZEROTIER_PATH}/one:/var/lib/zerotier-one" \
        -v "${CONFIG_PATH}:/app/config" -v "${DIST_PATH}:/app/dist" \
        "$DOCKER_IMAGE" /app/planetctl.sh "$@"
}
root_start() {
    local port
    port=$(cat "${CONFIG_PATH}/zerotier-one.port")
    docker run -d --name "$CONTAINER_NAME" \
        -p "$port:$port/udp" \
        -v "${ZEROTIER_PATH}/one:/var/lib/zerotier-one" \
        -v "${CONFIG_PATH}:/app/config" -v "${DIST_PATH}:/app/dist" \
        --restart unless-stopped "$DOCKER_IMAGE"
}
planet_health() {
    local expected actual attempt
    expected=$(planet_tool version) || return 1
    for ((attempt=0; attempt<30; attempt++)); do
        actual=$(docker exec "$CONTAINER_NAME" sh -c 'curl -fsS --max-time 2 -H "X-ZT1-Auth: $(cat /var/lib/zerotier-one/authtoken.secret)" "http://127.0.0.1:$(cat /app/config/zerotier-one.port)/status" | jq -r "[.planetWorldId,.planetWorldTimestamp,.address]|@tsv"' 2>/dev/null) || actual=''
        if [ "$actual" = "$expected" ]; then return 0; fi
        sleep 1
    done
    echo 'Running planet did not match expected ID/timestamp' >&2
    return 1
}
planet_apply() (
    set -e
    local input=$1 transaction existed=0 committed=0
    [ -f "$input" ] || exit 1
    mkdir -p "$CONFIG_PATH"
    # A directory lock also prevents concurrent apply/build through this script.
    mkdir "$CONFIG_PATH/planet.lock" || { echo 'Another planet operation is active' >&2; exit 1; }
    transaction=$(mktemp -d "$CONFIG_PATH/apply.XXXXXX") || { rmdir "$CONFIG_PATH/planet.lock"; exit 1; }
    cleanup() {
        if [ "$committed" = 0 ]; then
            if [ -f "$transaction/snapshot" ]; then
                planet_tool restore "$(basename "$transaction")" || {
                    echo "Restore failed; keep service stopped and restore the full backup. Snapshot: $transaction" >&2
                    return 1
                }
            fi
            if [ "$existed" = 1 ]; then docker start "$CONTAINER_NAME" >/dev/null || true; fi
        fi
        rm -f "$CONFIG_PATH/planet.in"
        rmdir "$CONFIG_PATH/planet.lock"
    }
    trap cleanup EXIT
    cp "$input" "$CONFIG_PATH/planet.in" || exit 1
    planet_tool check || exit 1
    if cmp -s "$CONFIG_PATH/planet.in" "$DIST_PATH/planet" && cmp -s "$CONFIG_PATH/planet.in" "$ZEROTIER_PATH/one/planet"; then
        if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then planet_health || exit 1; committed=1; exit 0; fi
    fi
    if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then existed=1; fi
    backup_data || exit 1
    planet_tool snapshot "$(basename "$transaction")" || exit 1
    planet_tool apply || exit 1
    if [ "$existed" = 1 ]; then docker start "$CONTAINER_NAME" >/dev/null || exit 1;
    elif [ "$(cat "$CONFIG_PATH/role" 2>/dev/null)" = root ]; then root_start || exit 1;
    else install_from_config || exit 1; fi
    if ! planet_health; then docker stop "$CONTAINER_NAME" >/dev/null || true; exit 1; fi
    committed=1
    echo 'Planet applied; retain the old root for clients still using the previous version.'
)
planet_dispatch() {
    case "$1" in
    root-init) mkdir -p "$CONFIG_PATH" "$DIST_PATH" "${ZEROTIER_PATH}/one"; planet_tool "$@";;
    root-export) planet_tool root-export;;
    planet-build)
        [ -f "${2:-}" ] || { echo 'Usage: ./deploy.sh planet-build ROOTS.json' >&2; return 1; }
        mkdir "$CONFIG_PATH/planet.lock" || return 1
        planet_tool build < "$2"
        local status=$?
        rmdir "$CONFIG_PATH/planet.lock"
        [ "$status" = 0 ] || return "$status"
        echo "Candidate: $DIST_PATH/planet.next (apply on new roots first)";;
    planet-apply) planet_apply "${2:?Usage: planet-apply PLANET}";;
    planet-info) planet_tool info;;
    *) echo 'Unknown multi-planet command' >&2; return 1;;
    esac
}
