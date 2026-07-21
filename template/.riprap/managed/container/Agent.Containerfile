ARG RIPRAP_TOOLING_IMAGE
FROM ${RIPRAP_TOOLING_IMAGE}

ARG CLAUDE_VERSION
ARG CODEX_VERSION
ARG OPENCODE_VERSION

# The installers place files beneath HOME, which the tooling image sets to an
# image-owned path outside /root. Each agent's own configuration home under that
# path is a credential mount point at run time, so the image leaves nothing there.
RUN set -eu; \
    test -n "$CLAUDE_VERSION"; \
    curl -fsSL https://claude.ai/install.sh | bash -s -- "$CLAUDE_VERSION"; \
    rm -rf "$HOME/.claude.json" "$HOME/.claude"

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
    mv "$HOME/.opencode/bin/opencode" /opt/opencode/bin/opencode; \
    rm -rf "$HOME/.opencode"

COPY opencode /usr/local/bin/opencode
RUN chmod 0755 /usr/local/bin/opencode

ENV CODEX_HOME=/opt/riprap/home/.codex
ENV DISABLE_AUTOUPDATER=1

# Reach the agent programs as any unprivileged user, on the same terms as the toolchain the tooling
# image installed. Every directory beneath the home directory is made sticky world-writable so any
# runtime user can create the scratch and configuration directories the agents write at startup --
# an agent installed as root leaves directories there that the runtime user must write into.
RUN chmod -R a+rX /opt/riprap /opt/codex /opt/opencode && find /opt/riprap/home -type d -exec chmod 1777 {} +
