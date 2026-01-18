#!/bin/bash

set -Eeuo pipefail
if [ "$(echo "${DEBUG:-}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then set -x; fi

# Load onerror function
[ -f _ops/utils/onerror.sh ] && source _ops/utils/onerror.sh || source tools/utils/onerror.sh

echo "Usage: bash _ops/utils/bump.sh <PREFIX> <SUFFIX> or use ENV vars for optional prefix/suffix"

# Get prefix as input var or from ENV
PREFIX=${1:-${PREFIX:-}}
[ -n "$PREFIX" ] && [[ "${PREFIX}" != "-" ]] && PREFIX="${PREFIX}/"

# Get suffix as input var or from ENV
SUFFIX=${2:-${SUFFIX:-}}
[ -n "$SUFFIX" ] && SUFFIX="-${SUFFIX}"

# Count commits
git fetch --unshallow || true
COMMITS=$(( $(date +%y%m%d)*100 + $(git rev-list --count HEAD) ))
INCREMENT=1

# For Flutter apps
if [ -f pubspec.yaml ]; then
    # Find and increment the version number.
    perl -i -pe "s/^(version:\s+\d+\.\d+\.)(\d+)(\+)(\d+)/\$1.(\$2+$INCREMENT).\$3.($COMMITS+1)/e" pubspec.yaml

    # Commit and tag this change.
    version=$(grep 'version: ' pubspec.yaml | sed 's/version: //' | sed -e 's/\+.*$//')
    tag="${PREFIX:-}${version}${SUFFIX:-}+$((COMMITS+1))"
    git config user.name || git config user.name 'gitops-bot'
    git config user.email || git config user.email '52609384+gitops-bot@users.noreply.github.com'
    git commit -m "${MSG_PREFIX:-}Bump version to $tag" pubspec.yaml
    git tag "$tag"

# For generic repos
else
	version=$(echo `git rev-list --tags --max-count=100` | tr " " "\n" | tail -n1 | xargs git tag --contains | grep -o '[0-9]\+\.[0-9]*\.\?[0-9]*' | sort -rV | head -n1 || :)
	if [[ "$version" == "" ]]; then
		version=0.0.0
	fi
	if [ `echo $version | grep '[0-9]\+\.[0-9]\+\.' -c` == 0 ]; then
		version=${version}.0
	fi

	version=$(echo $version | awk -F. -v OFS=. '{$NF += '''"$INCREMENT"''' ; print}')
	tag=${PREFIX:-}$version${SUFFIX:-}+$((COMMITS+0))
	git tag $tag -m "${MSG_PREFIX:-}Bump version to $tag"
fi

MASTER_BRANCH=$(git remote show origin | grep HEAD | awk '{print $3;}' || echo "master")
if [[ -n "${GITHUB_REF:-}" ]]; then
    # auto push for GitHub actions
    git push --atomic origin "$MASTER_BRANCH" "$tag"
else
    echo "To push, use: git push --atomic origin $MASTER_BRANCH $tag"
fi
