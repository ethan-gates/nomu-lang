#!/bin/bash
# Bazel workspace status (`--workspace_status_command`): the compiler's identity, baked into the binary
# (`BuildInfo.compilerIdentity`) and used in its cache keys (task 206). `STABLE_` keys rebuild their users
# when they change.
#
# The identity is the git commit, plus a hash of uncommitted changes under the paths that build `nomu`
# (tracked edits and untracked files), so a compiler built from a dirty tree never shares cache entries with
# the committed one. Outside a git checkout it is `unstamped`.
paths=(src MODULE.bazel MODULE.bazel.lock .bazelrc BUILD.bazel)
commit=$(git rev-parse HEAD 2>/dev/null) || { echo "STABLE_NOMU_GIT_COMMIT unstamped"; echo "STABLE_NOMU_COMPILER_IDENTITY unstamped"; exit 0; }
changes=$( { git diff HEAD --binary -- "${paths[@]}"
             git ls-files --others --exclude-standard -z -- "${paths[@]}" | xargs -0 shasum 2>/dev/null; } | shasum | cut -c1-16 )
empty=$(printf '' | shasum | cut -c1-16)
echo "STABLE_NOMU_GIT_COMMIT $commit"
if [ "$changes" = "$empty" ]; then
  echo "STABLE_NOMU_COMPILER_IDENTITY $commit"
else
  echo "STABLE_NOMU_COMPILER_IDENTITY $commit-$changes"
fi
