"""Move preserved project content into the ownership layout before Copier updates."""

from __future__ import annotations

import os
from pathlib import Path


def assert_safe_parents(path: Path) -> None:
    """Reject parent-directory links so migration cannot escape the project."""
    current = Path()
    for part in path.parent.parts:
        current /= part
        if current.is_symlink():
            raise SystemExit(f"Riprap: refusing to migrate through symbolic-link directory {current}")


def files_match(source: Path, destination: Path) -> bool:
    """Return whether two ordinary files have identical content."""
    return (
        source.is_file()
        and destination.is_file()
        and not source.is_symlink()
        and not destination.is_symlink()
        and source.read_bytes() == destination.read_bytes()
    )


def move_preserved_file(source: Path, destination: Path) -> None:
    """Move source without discarding an established, different destination."""
    if not os.path.lexists(source):
        return
    assert_safe_parents(source)
    assert_safe_parents(destination)
    if os.path.lexists(destination):
        if files_match(source, destination):
            source.unlink()
            return
        raise SystemExit(
            f"Riprap: both {source} and {destination} exist; reconcile them before updating"
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    source.replace(destination)


def main() -> None:
    root = Path(".riprap")
    migrations = [
        (
            root / "skills" / skill / "local.md",
            root / "user" / "skills" / skill / "local.md",
        )
        for skill in ("rr-architecture", "rr-implement", "rr-plan", "rr-quiz")
    ]
    migrations.extend(
        [
            (root / "podman" / "run-options", root / "user" / "podman" / "run-options"),
            (root / "agent-pin.env", root / "user" / "agent-pin.env"),
            (root / "project-id", root / "state" / "project-id"),
            (
                root / "podman" / "agent-build.env",
                root / "state" / "podman" / "agent-build.env",
            ),
            (
                root / "podman" / "agent-build.candidate.env",
                root / "state" / "podman" / "agent-build.candidate.env",
            ),
        ]
    )

    # Validate the whole migration before moving anything, so a conflict cannot leave a
    # partially migrated ownership tree.
    for source, destination in migrations:
        if not os.path.lexists(source):
            continue
        assert_safe_parents(source)
        assert_safe_parents(destination)
        if os.path.lexists(destination) and not files_match(source, destination):
            raise SystemExit(
                f"Riprap: both {source} and {destination} exist; reconcile them before updating"
            )

    for source, destination in migrations:
        move_preserved_file(source, destination)


if __name__ == "__main__":
    main()
