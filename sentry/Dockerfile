ARG SENTRY_IMAGE
FROM ${SENTRY_IMAGE}

# Install init system and debugging tools: tini for lightweight init and strace for debugging
RUN apt-get update && apt-get install -y --no-install-recommends \
    tini \
    strace \
    xz-utils \
    procps \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install s6-overlay for lightweight process supervision
ARG S6_OVERLAY_VERSION=3.2.0.2
RUN ARCH=$(uname -m) && \
    case ${ARCH} in \
        x86_64) S6_ARCH="x86_64" ;; \
        aarch64|arm64) S6_ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    wget -O /tmp/s6-overlay-noarch.tar.xz https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz && \
    wget -O /tmp/s6-overlay-${S6_ARCH}.tar.xz https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-${S6_ARCH}.tar.xz && \
    rm /tmp/s6-overlay-*.tar.xz

COPY . /usr/src/sentry

# Set working directory according to s6-overlay best practices
WORKDIR /usr/src/sentry

RUN if [ -s /usr/src/sentry/enhance-image.sh ]; then \
    /usr/src/sentry/enhance-image.sh; \
fi

RUN if [ -s /usr/src/sentry/requirements.txt ]; then \
    echo "sentry/requirements.txt is deprecated, use sentry/enhance-image.sh - see https://develop.sentry.dev/self-hosted/#enhance-sentry-image"; \
    pip install -r /usr/src/sentry/requirements.txt; \
fi

ADD entrypoint-optimized.sh /entrypoint-optimized.sh

ENTRYPOINT [ "/entrypoint-optimized.sh" ]
