#!/bin/sh
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"

depth=5
while [ "$depth" -le 160 ]; do
    git fetch --quiet --depth "$depth" origin "$(git rev-parse HEAD)" '+refs/tags/an-*:refs/tags/an-*'
    if tag=$(git describe --tags --abbrev=0 --match 'an-*' 2>/dev/null); then
        echo "note: $tag reachable at depth $depth"
        exit 0
    fi
    depth=$((depth * 4))
done

echo "warning: no an-* tag within 160 commits; the build will stamp no-tag"
