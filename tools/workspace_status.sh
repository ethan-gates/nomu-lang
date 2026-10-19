#!/bin/bash
# Bazel workspace status (`--workspace_status_command`): the git commit the build comes from, as the
# compiler's identity in the per-host cache key (task 190, D4). `STABLE_` keys rebuild their users when they
# change. Outside a git checkout the commit is `unstamped`.
echo "STABLE_NOMU_GIT_COMMIT $(git rev-parse HEAD 2>/dev/null || echo unstamped)"
