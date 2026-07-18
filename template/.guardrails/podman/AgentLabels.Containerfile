FROM localhost/guardrails-agent:candidate
ARG CLAUDE_VERSION
ARG CODEX_VERSION
ARG TOOLING_IMAGE_ID
LABEL io.guardrails.claude-version="${CLAUDE_VERSION}" \
      io.guardrails.codex-version="${CODEX_VERSION}" \
      io.guardrails.tooling-image-id="${TOOLING_IMAGE_ID}"
