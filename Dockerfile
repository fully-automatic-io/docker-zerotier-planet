ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION} AS builder

ENV TZ=Asia/Shanghai
# ZeroTierOne release tag to build (only stable releases, e.g. 1.16.2)
ARG TAG=1.16.2
ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG ZTNCUI_REPO=https://github.com/key-networks/ztncui.git

WORKDIR /app
COPY ./patch/entrypoint.sh /app/entrypoint.sh
COPY ./patch/planetctl.sh /app/planetctl.sh
COPY ./patch/http_server.js /app/http_server.js
COPY ./patch/mkworld_custom.cpp /app/patch/mkworld_custom.cpp
COPY ./patch/build_mkworld.sh /app/patch/build_mkworld.sh

# init tool
RUN set -x \
    && apk add --no-cache git nodejs npm make g++ linux-headers curl pkgconfig openssl-dev jq build-base cargo rust \
    && echo "env prepare success!"

# make zerotier-one
# Since 1.16 the network controller (needed by ztncui) lives in nonfree/ and is
# only built with ZT_NONFREE=1 (source-available, non-commercial license).
RUN set -x \
    && git clone --depth 1 --branch "${TAG}" https://github.com/zerotier/ZeroTierOne.git \
    && cd ZeroTierOne \
    && echo "building tag: ${TAG}" \
    && make -j"$(nproc)" ZT_NONFREE=1 one \
    && make install \
    && echo "make success!" \
    && sh /app/patch/build_mkworld.sh /app/ZeroTierOne /app/patch/mkworld_custom.cpp /usr/local/bin/mkworld \
    && mkdir -p /app/LICENSES \
    && cp LICENSE.txt LICENSE-MPL.txt /app/LICENSES/ \
    && cp nonfree/LICENSE.md /app/LICENSES/LICENSE-NONFREE.md \
    && echo "mkworld build success!"

# make ztncui
# argon2@0.19 does not build on current Node, bump to a maintained version
# (same hash/verify API, existing password hashes stay valid).
RUN set -x \
    && cd /app \
    && git clone --depth 1 --progress "${ZTNCUI_REPO}" ztncui \
    && cd /app/ztncui \
    && ZTNCUI_COMMIT="$(git rev-parse --short HEAD)" \
    && rm -rf .git \
    && cd src \
    && npm config set registry "${NPM_REGISTRY}" \
    && npm pkg set dependencies.argon2=^0.44.0 \
    && npm install --omit=dev --no-audit --no-fund \
    && echo "ztncui=${ZTNCUI_COMMIT} zerotier=${TAG} node=$(node -v)" > /app/ztncui/.version \
    && cat /app/ztncui/.version

FROM alpine:${ALPINE_VERSION}

ARG TAG=1.16.2

WORKDIR /app

ENV IP_ADDR4=''
ENV IP_ADDR6=''

ENV ZT_PORT=9994
ENV API_PORT=3443
ENV FILE_SERVER_PORT=3000

ENV FILE_KEY=''
ENV TZ=Asia/Shanghai
ENV ZT_VERSION=${TAG}

RUN set -x \
    && apk add --no-cache nodejs npm libstdc++ libgcc libssl3 libcrypto3 curl jq openssl tzdata \
    && mkdir -p /app/config /var/lib/zerotier-one

COPY --from=builder /app/ztncui /bak/ztncui
COPY --from=builder /usr/sbin/zerotier-one /usr/sbin/zerotier-one
COPY --from=builder /usr/local/bin/mkworld /usr/local/bin/mkworld
COPY --from=builder /app/LICENSES /app/LICENSES
COPY --from=builder /app/entrypoint.sh /app/entrypoint.sh
COPY --from=builder /app/planetctl.sh /app/planetctl.sh
COPY --from=builder /app/http_server.js /app/http_server.js

RUN ln -sf zerotier-one /usr/sbin/zerotier-cli \
    && ln -sf zerotier-one /usr/sbin/zerotier-idtool \
    && zerotier-one -v

VOLUME [ "/app/dist","/app/ztncui","/var/lib/zerotier-one","/app/config"]

CMD ["/bin/sh","/app/entrypoint.sh"]
