#!/bin/sh

set -e
umask 022

# 配置路径和端口
ZEROTIER_PATH="/var/lib/zerotier-one"
APP_PATH="/app"
CONFIG_PATH="${APP_PATH}/config"
DIST_PATH="${APP_PATH}/dist"
BACKUP_PATH="/bak"
ZTNCUI_PATH="${APP_PATH}/ztncui"
ZTNCUI_SRC_PATH="${ZTNCUI_PATH}/src"
MKWORLD_BIN="/usr/local/bin/mkworld"

# 启动 ZeroTier 和 ztncui
start() {
    echo "Start ztncui and zerotier"
    zerotier-one -v
    zerotier-one -p"$(cat ${CONFIG_PATH}/zerotier-one.port)" -d "${ZEROTIER_PATH}" || exit 1
    nohup node ${APP_PATH}/http_server.js > ${APP_PATH}/server.log 2>&1 &
    cd $ZTNCUI_SRC_PATH && exec npm start
}

# 检查文件服务器端口配置文件
check_file_server() {
    mkdir -p ${CONFIG_PATH}
    if [ ! -f "${CONFIG_PATH}/file_server.port" ]; then
        echo "file_server.port does not exist, generating it"
        echo "${FILE_SERVER_PORT}" > ${CONFIG_PATH}/file_server.port
    else
        echo "file_server.port exists, reading it"
        FILE_SERVER_PORT=$(cat ${CONFIG_PATH}/file_server.port)
    fi
    export FILE_SERVER_PORT
    echo "${FILE_SERVER_PORT}"
}

# 初始化 ZeroTier 数据（仅在数据目录为空时执行，已有 planet 绝不重新生成）
init_zerotier_data() {
    echo "Initializing ZeroTier data"
    echo "${ZT_PORT}" > ${CONFIG_PATH}/zerotier-one.port

    cd $ZEROTIER_PATH
    openssl rand -hex 16 > authtoken.secret
    chmod 600 authtoken.secret
    zerotier-idtool generate identity.secret identity.public
    zerotier-idtool initmoon identity.public > moon.json

    IP_ADDR4=${IP_ADDR4:-$(curl -s --max-time 10 https://ipv4.icanhazip.com/)}
    IP_ADDR6=${IP_ADDR6:-$(curl -s --max-time 10 https://ipv6.icanhazip.com/)}

    echo "IP_ADDR4=$IP_ADDR4"
    echo "IP_ADDR6=$IP_ADDR6"
    ZT_PORT=$(cat ${CONFIG_PATH}/zerotier-one.port)
    echo "ZT_PORT=$ZT_PORT"

    if [ -n "$IP_ADDR4" ] && [ -n "$IP_ADDR6" ]; then
        stableEndpoints="[\"$IP_ADDR4/${ZT_PORT}\",\"$IP_ADDR6/${ZT_PORT}\"]"
    elif [ -n "$IP_ADDR4" ]; then
        stableEndpoints="[\"$IP_ADDR4/${ZT_PORT}\"]"
    elif [ -n "$IP_ADDR6" ]; then
        stableEndpoints="[\"$IP_ADDR6/${ZT_PORT}\"]"
    else
        echo "IP_ADDR4 and IP_ADDR6 are both empty!"
        exit 1
    fi

    echo "$IP_ADDR4" > ${CONFIG_PATH}/ip_addr4
    echo "$IP_ADDR6" > ${CONFIG_PATH}/ip_addr6
    echo "stableEndpoints=$stableEndpoints"

    jq --argjson newEndpoints "$stableEndpoints" '.roots[0].stableEndpoints = $newEndpoints' moon.json > temp.json && mv temp.json moon.json
    # moon 在 ZeroTier 1.16 中已被标记为弃用，这里仍然生成以兼容旧用法
    zerotier-idtool genmoon moon.json && mkdir -p moons.d && cp ./*.moon ./moons.d

    if ! ${MKWORLD_BIN}; then
        echo "mkmoonworld failed!"
        exit 1
    fi

    mkdir -p ${DIST_PATH}
    mv world.bin ${DIST_PATH}/planet
    cp ${DIST_PATH}/planet ${ZEROTIER_PATH}/planet
    cp *.moon ${DIST_PATH}/
    echo "mkmoonworld success!"
}

# 检查并初始化 ZeroTier
check_zerotier() {
    mkdir -p $ZEROTIER_PATH
    if [ "$(ls -A $ZEROTIER_PATH)" ]; then
        echo "$ZEROTIER_PATH is not empty, starting directly (existing planet is kept)"
        [ -s "$ZEROTIER_PATH/identity.secret" ] && [ -s "$ZEROTIER_PATH/identity.public" ] || {
            echo "Incomplete identity; restore backup instead of reinitializing" >&2; exit 1;
        }
        if [ ! -f "${CONFIG_PATH}/zerotier-one.port" ]; then
            echo "${ZT_PORT}" > ${CONFIG_PATH}/zerotier-one.port
        fi
    else
        init_zerotier_data
    fi
}

# 写入/校正 ztncui 的 .env（端口与 token 与当前 zerotier 保持一致）
write_ztncui_env() {
    ZT_PORT_CUR=$(cat ${CONFIG_PATH}/zerotier-one.port)
    TOKEN=$(cat ${ZEROTIER_PATH}/authtoken.secret)
    ENV_FILE="${ZTNCUI_SRC_PATH}/.env"
    {
        echo "HTTP_PORT=${API_PORT}"
        echo "NODE_ENV=production"
        echo "HTTP_ALL_INTERFACES=true"
        echo "ZT_ADDR=localhost:${ZT_PORT_CUR}"
        echo "ZT_TOKEN=${TOKEN}"
        # 保留用户自行添加的其他配置（例如 HTTPS_PORT）
        if [ -f "${ENV_FILE}" ]; then
            grep -v -E '^(HTTP_PORT|NODE_ENV|HTTP_ALL_INTERFACES|ZT_ADDR|ZT_TOKEN)=' "${ENV_FILE}" || true
        fi
    } > "${ENV_FILE}.new"
    mv "${ENV_FILE}.new" "${ENV_FILE}"
}

# 初始化 ztncui 数据
init_ztncui_data() {
    echo "Initializing ztncui data"
    cp -a ${BACKUP_PATH}/ztncui/. $ZTNCUI_PATH/
    cp -v ${ZTNCUI_SRC_PATH}/etc/default.passwd ${ZTNCUI_SRC_PATH}/etc/passwd
    echo "ztncui initialization successful!"
}

# 升级 ztncui：镜像中的 ztncui（代码/node_modules）与数据卷不一致时，
# 替换代码和依赖（旧版本 node_modules 中的 argon2 是为旧 Node 编译的，无法在新版本运行），
# 同时保留用户数据：etc/passwd、etc/storage（成员名称）、etc/tls 以及 .env
upgrade_ztncui() {
    NEW_VERSION=$(cat ${BACKUP_PATH}/ztncui/.version 2>/dev/null || true)
    OLD_VERSION=$(cat ${ZTNCUI_PATH}/.version 2>/dev/null || true)
    if [ "${NEW_VERSION}" = "${OLD_VERSION}" ]; then
        echo "ztncui is up to date: ${OLD_VERSION}"
        return
    fi
    echo "Upgrading ztncui: '${OLD_VERSION:-unknown}' -> '${NEW_VERSION}'"

    KEEP_DIR=$(mktemp -d)
    for item in etc/passwd etc/storage etc/tls .env; do
        if [ -e "${ZTNCUI_SRC_PATH}/${item}" ]; then
            mkdir -p "${KEEP_DIR}/$(dirname ${item})"
            cp -a "${ZTNCUI_SRC_PATH}/${item}" "${KEEP_DIR}/${item}"
        fi
    done

    find ${ZTNCUI_PATH} -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a ${BACKUP_PATH}/ztncui/. $ZTNCUI_PATH/
    cp -a "${KEEP_DIR}/." ${ZTNCUI_SRC_PATH}/
    rm -rf "${KEEP_DIR}"

    if [ ! -f "${ZTNCUI_SRC_PATH}/etc/passwd" ]; then
        cp -v ${ZTNCUI_SRC_PATH}/etc/default.passwd ${ZTNCUI_SRC_PATH}/etc/passwd
    fi
    echo "ztncui upgrade successful!"
}

# 检查并初始化 ztncui
check_ztncui() {
    mkdir -p $ZTNCUI_PATH
    echo "${API_PORT}" > ${CONFIG_PATH}/ztncui.port
    if [ "$(ls -A $ZTNCUI_PATH)" ]; then
        echo "$ZTNCUI_PATH is not empty, checking for upgrade"
        upgrade_ztncui
    else
        init_ztncui_data
    fi
    write_ztncui_env
}

mkdir -p "$CONFIG_PATH"
if [ ! -f "$CONFIG_PATH/role" ]; then echo "${ZT_ROLE:-primary}" > "$CONFIG_PATH/role"; fi
ROLE=$(cat "$CONFIG_PATH/role")
case "$ROLE" in
root)
    [ -s "$ZEROTIER_PATH/identity.secret" ] && [ -s "$ZEROTIER_PATH/planet" ] || {
        echo "Initialize root and apply a signed planet before starting" >&2; exit 1;
    }
    "$MKWORLD_BIN" member "$ZEROTIER_PATH/planet" "$ZEROTIER_PATH/identity.public"
    exec zerotier-one -p"$(cat "$CONFIG_PATH/zerotier-one.port")" "$ZEROTIER_PATH"
    ;;
primary)
    check_file_server
    check_zerotier
    # Migrate legacy roots that ran with the built-in official planet.
    if [ -f "$DIST_PATH/planet" ]; then
        "$MKWORLD_BIN" member "$DIST_PATH/planet" "$ZEROTIER_PATH/identity.public"
        if [ ! -f "$ZEROTIER_PATH/planet" ]; then
            cp "$DIST_PATH/planet" "$ZEROTIER_PATH/planet"
        elif ! "$MKWORLD_BIN" member "$ZEROTIER_PATH/planet" "$ZEROTIER_PATH/identity.public" 2>/dev/null; then
            cp "$ZEROTIER_PATH/planet" "$CONFIG_PATH/planet.before-migration"
            cp "$DIST_PATH/planet" "$ZEROTIER_PATH/planet"
        elif ! cmp -s "$DIST_PATH/planet" "$ZEROTIER_PATH/planet"; then
            echo "WARNING: published and runtime planet differ; keeping runtime planet" >&2
        fi
    fi
    check_ztncui
    start
    ;;
*) echo "Invalid persisted role: $ROLE" >&2; exit 1;;
esac
