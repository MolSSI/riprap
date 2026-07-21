ARG RIPRAP_AGENT_CANDIDATE_IMAGE
FROM ${RIPRAP_AGENT_CANDIDATE_IMAGE}
ARG CLAUDE_VERSION
ARG CODEX_VERSION
ARG OPENCODE_VERSION
ARG TOOLING_IMAGE_ID
# The project image is based on this image and inherits these labels, so an
# exported image reports its agent releases and the project it belongs to
# without reference to the machine that built it.
ARG RIPRAP_PROJECT_ID
LABEL io.riprap.claude-version="${CLAUDE_VERSION}" \
      io.riprap.codex-version="${CODEX_VERSION}" \
      io.riprap.opencode-version="${OPENCODE_VERSION}" \
      io.riprap.tooling-image-id="${TOOLING_IMAGE_ID}" \
      io.riprap.project-id="${RIPRAP_PROJECT_ID}"
