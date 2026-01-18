
#!/bin/bash

set -Eeuo pipefail
if [ "$(echo "${DEBUG:-}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then set -x; fi

# Load secrets if available
if [ ! -z ${SECRETS_B64:-} ]; then
        export $(echo $SECRETS_B64 | base64 -d | grep -v '^#' | xargs -d '\n')

        REGISTRY_ENDPOINT=${APP_REGISTRY_ENDPOINT}
        REGISTRY_USERNAME=${APP_REGISTRY_USERNAME}
        REGISTRY_PASSWORD=${APP_REGISTRY_PASSWORD}
fi

# Determine CI system
# Github Action
if [[ "${GITHUB_REF:-}" != "" ]]; then
        # CI specifc vars
        GIT_CISYSTEM=actions
        GIT_COMMIT=$GITHUB_SHA
        GIT_BRANCH_REF=$GITHUB_REF

        GIT_REF=$(echo $GIT_BRANCH_REF | sed -r 's/^refs\/[^\/]+\///g')
        if [[ "$GIT_BRANCH_REF" == "refs/heads"* ]]; then
                GIT_BRANCH=$GIT_REF
        elif [[ "$GIT_BRANCH_REF" == "refs/tags/"* ]]; then
                GIT_TAG=$GIT_REF
        elif [[ "$GIT_BRANCH_REF" == "refs/pull/"* ]]; then
                GIT_PR=$(echo $GIT_REF | sed -re 's/([0-9]+).*/\1/')
                GIT_COMMIT=$GITHUB_PR_SHA
        else
                echo "Unknown github ref"
                exit 1
        fi

# Drone.IO
elif [[ "${DRONE_COMMIT_REF:-}" != "" ]]; then
        # CI specifc vars
        GIT_CISYSTEM=drone
        GIT_COMMIT=${DRONE_COMMIT_SHA:-HEAD}
        GIT_BRANCH_REF=$DRONE_COMMIT_REF

        GIT_REF=$(echo $GIT_BRANCH_REF | sed -r 's/^refs\/[^\/]+\///g')
        if [[ "$GIT_BRANCH_REF" == "refs/heads"* ]]; then
                GIT_BRANCH=$DRONE_BRANCH
        elif [[ "$GIT_BRANCH_REF" == "refs/tags/"* ]]; then
                GIT_TAG=$DRONE_TAG
        elif [[ "$GIT_BRANCH_REF" == "refs/pull/"* ]]; then
                GIT_PR=$DRONE_PULL_REQUEST
        elif [[ "$DRONE_BRANCH" == "local" ]]; then
                GIT_BRANCH=$DRONE_BRANCH
        else
                echo "Unknown drone ref"
                exit 1
        fi

# CircleCI
elif [[ "${CIRCLECI:-}" == "true" ]]; then
        # CI specifc vars
        GIT_CISYSTEM=circle
        GIT_COMMIT=$CIRCLE_SHA1

        if [[ "${CIRCLE_BRANCH:-}" != "" ]]; then
                GIT_BRANCH_REF="refs/heads/$CIRCLE_BRANCH"
                GIT_BRANCH=$CIRCLE_BRANCH
        elif [[ "${CIRCLE_TAG:-}" != "" ]]; then
                GIT_BRANCH_REF="refs/tags/$CIRCLE_TAG"
                GIT_TAG=$CIRCLE_TAG
        elif [[ "${CIRCLE_PR_NUMBER:-}" != "" ]]; then
                GIT_BRANCH_REF="refs/pull/$CIRCLE_PR_NUMBER/merge"
                GIT_PR=$CIRCLE_PR_NUMBER
        else
                echo "Unsupported in circleci"
                exit 1
        fi
        GIT_REF=$(echo $GIT_BRANCH_REF | sed -r 's/^refs\/[^\/]+\///g')

else
        echo "Unknown CI system"
        exit 1
fi

# Common functions
function add_tag()
{
        docker tag ${IMAGE_PREFIX:-}${INPUT_IMAGE}${SUFFIX}:${UNIQ_TAG} ${IMAGE_PREFIX:-}${INPUT_IMAGE}${SUFFIX}:$TAG
        docker push -q ${IMAGE_PREFIX:-}${INPUT_IMAGE}${SUFFIX}:$TAG
}
function build_image()
{
        INPUT_IMAGE=$1
        BUILD_FOLDER=${BUILD_FOLDER:-./}
        SUFFIX=${2:-}

        if [ -f ${BUILD_FOLDER}/Dockerfile ]; then

                docker build --rm=true --pull=true -t ${IMAGE_PREFIX:-}${INPUT_IMAGE}${SUFFIX}:${UNIQ_TAG} ${BUILD_FOLDER}
                unset BUILD_FOLDER

                TAG=${GIT_COMMIT} add_tag
                TAG=$(echo $GIT_COMMIT | cut -c1-7) add_tag
                TAG=${GIT_CISYSTEM} add_tag
                TAG=${GIT_CISYSTEM}-$(date +%y%m%d_%H%M%S) add_tag

                if [[ "${GIT_TAG:-}" != "" ]]; then
                        TAG=$(echo ${GIT_TAG} | grep -o '[0-9]\+\.\?[0-9]*\.\?[0-9]*' | head -1) && add_tag
                        TAG=${GIT_CISYSTEM}-${TAG} add_tag
                        TAG=$(echo ${TAG} | cut -f1-2 -d.) && add_tag
                        TAG=$(echo ${TAG} | cut -f1 -d.) && add_tag

                elif [[ "${GIT_PR:-}" != "" ]]; then
                        TAG=pr-${GIT_PR} && add_tag
                        TAG=${GIT_CISYSTEM}-${TAG} add_tag

                else
                        TAG=$(echo ${GIT_BRANCH} | sed 's/[^[:alnum:]]/_/g') && add_tag
                        TAG=${GIT_CISYSTEM}-${TAG} add_tag
                fi

                docker rmi ${IMAGE_PREFIX:-}${INPUT_IMAGE}${SUFFIX}:${UNIQ_TAG}
        fi
}

# Common vars
UNIQ_TAG=$(echo $GIT_REF | sed 's/[^[:alnum:]]/_/g')-${GIT_COMMIT}
CACHE_LABEL=`date +"%Y-%m-%U"`W
IMAGE_PREFIX=${REGISTRY_ENDPOINT}/

# Login to push
docker login ${REGISTRY_ENDPOINT} --username ${REGISTRY_USERNAME} --password ${REGISTRY_PASSWORD} 2>/dev/null


# Build images in this repo
BUILD_FOLDER=./ build_image $REGISTRY_REPO
