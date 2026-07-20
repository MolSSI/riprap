ARG RIPRAP_TOOLING_IMAGE
FROM ${RIPRAP_TOOLING_IMAGE}

ARG CLAUDE_VERSION
ARG CODEX_VERSION
ARG OPENCODE_VERSION

RUN set -eu; \
    test -n "$CLAUDE_VERSION"; \
    curl -fsSL https://claude.ai/install.sh | bash -s -- "$CLAUDE_VERSION"; \
    rm -rf /root/.claude.json /root/.claude

RUN set -eu; \
    test -n "$CODEX_VERSION"; \
    CODEX_HOME=/opt/codex; \
    export CODEX_HOME; \
    curl -fsSL https://chatgpt.com/codex/install.sh | sh -s -- --release "$CODEX_VERSION"

RUN set -eu; \
    test -n "$OPENCODE_VERSION"; \
    if [ "$OPENCODE_VERSION" = latest ]; then version_args=; else version_args="--version $OPENCODE_VERSION"; fi; \
    curl -fsSL https://opencode.ai/install | bash -s -- $version_args --no-modify-path; \
    mkdir -p /opt/opencode/bin; \
    mv /root/.opencode/bin/opencode /opt/opencode/bin/opencode; \
    rm -rf /root/.opencode

COPY opencode /usr/local/bin/opencode
RUN chmod 0755 /usr/local/bin/opencode

ENV CODEX_HOME=/root/.codex
ENV DISABLE_AUTOUPDATER=1
