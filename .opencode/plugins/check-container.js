// Riprap-managed required-location adapter. Do not edit; use copier update.

const message =
  'Riprap: OpenCode must run inside the project development container. ' +
  'Launch it with "bash rr.sh" (or "rr.bat" on Windows).'

function rejectOutsideContainer(worktree) {
  if (process.platform === 'win32') throw new Error(message)
  if (!worktree) throw new Error(message)

  const result = Bun.spawnSync([
    'bash',
    `${worktree}/.riprap/managed/hooks/check-container.sh`,
  ])
  if (result.exitCode !== 0) throw new Error(message)
}

export const RiprapContainerCheck = async ({ worktree }) => ({
  'chat.message': async () => rejectOutsideContainer(worktree),
})
