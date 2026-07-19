FROM localhost/riprap-tooling:latest

ARG CLAUDE_VERSION
ARG CODEX_VERSION

RUN set -eu; \
    test -n "$CLAUDE_VERSION"; \
    curl -fsSL https://claude.ai/install.sh | bash -s -- "$CLAUDE_VERSION"; \
    rm -rf /root/.claude.json /root/.claude

RUN set -eu; \
    test -n "$CODEX_VERSION"; \
    CODEX_HOME=/opt/codex; \
    export CODEX_HOME; \
    curl -fsSL https://chatgpt.com/codex/install.sh | sh -s -- --release "$CODEX_VERSION"

ENV CODEX_HOME=/root/.codex
ENV DISABLE_AUTOUPDATER=1
