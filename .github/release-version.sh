#!/bin/bash
# .github/release-version.sh <git ref>   (from the repo root) -> "version=…" and "prerelease=true|false" on stdout.
# The version is engine/pyproject.toml's, read the same way as macos/build.sh. It must be x.y.z or x.y.z-alpha|beta|rc[.n]
# (uv accepts those: 0.0.2-beta locks as 0.0.2b0); a "-" makes a GitHub prerelease. A ref refs/tags/release/vX must
# name exactly that version; any other tag is refused; a branch (manual rehearsal) just uses the version.
set -euo pipefail
ref=$1
v=$(sed -n 's/^version = "\(.*\)"/\1/p' engine/pyproject.toml | head -1)
fail() { echo "::error::$*" >&2; exit 1; }
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.?[0-9]*)?$ ]] ||
  fail "engine/pyproject.toml version '$v' is not x.y.z or x.y.z-alpha|beta|rc[.n]"
case $ref in
  refs/tags/release/v*)
    [ "${ref#refs/tags/release/v}" = "$v" ] || fail "tag ${ref#refs/tags/} does not match engine/pyproject.toml version $v:" \
      "set version = \"${ref#refs/tags/release/v}\" there, run 'uv lock' in engine/, commit, and tag that commit (docs/release.md)" ;;
  refs/tags/*) fail "only release/v* tags are released, not ${ref#refs/tags/}" ;;
esac
echo "version=$v"
if [[ $v == *-* ]]; then echo prerelease=true; else echo prerelease=false; fi
