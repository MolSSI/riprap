FROM localhost/guardrails-tooling:latest

COPY agent-build.candidate.env /etc/guardrails/agent-build.env

RUN set -eu; \
    version="$(sed -n 's/^CLAUDE_VERSION=//p' /etc/guardrails/agent-build.env | tr -d '\r' | head -n 1)"; \
    curl -fsSL https://claude.ai/install.sh | bash -s -- "$version"; \
    rm -rf /root/.claude.json /root/.claude

RUN set -eu; \
    version="$(sed -n 's/^CODEX_VERSION=//p' /etc/guardrails/agent-build.env | tr -d '\r' | head -n 1)"; \
    CODEX_HOME=/opt/codex; \
    export CODEX_HOME; \
    curl -fsSL https://chatgpt.com/codex/install.sh | sh -s -- --release "$version"

ENV CODEX_HOME=/root/.codex
ENV DISABLE_AUTOUPDATER=1
