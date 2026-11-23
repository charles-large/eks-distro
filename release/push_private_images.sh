#!/usr/bin/env bash
# Copyright Amazon.com Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euxo pipefail

RELEASE_MANIFEST="${1?First required argument is the release manifest, for example kubernetes-1-35/kubernetes-1-35-eks-1.yaml}"
IMAGE_REPO="${2?Second required argument is the public image repository the release was pushed to}"
PRIVATE_IMAGE_REPO="${3?Third required argument is the private image repository to copy to}"

BASE_DIRECTORY=$(git rev-parse --show-toplevel)
source "${BASE_DIRECTORY}/build/lib/common.sh"

IMAGES=$(yq '.status.components[].assets[] | select(.type == "Image") | .image.uri' "${RELEASE_MANIFEST}" \
    | { grep "^${IMAGE_REPO}/" || true; } | sort -u)
if [ -z "${IMAGES}" ]; then
    echo "No images under ${IMAGE_REPO} in ${RELEASE_MANIFEST}"
    exit 1
fi

for SOURCE_IMAGE in ${IMAGES}; do
    DEST_IMAGE="${PRIVATE_IMAGE_REPO}/${SOURCE_IMAGE#"${IMAGE_REPO}/"}"
    DEST_REPO="${DEST_IMAGE%:*}"
    TAG="${DEST_IMAGE##*:}"

    retry docker buildx imagetools create --tag "${DEST_IMAGE}" "${SOURCE_IMAGE}"

    SOURCE_DIGEST=$(retry oras manifest fetch --descriptor "${SOURCE_IMAGE}" | jq -r '.digest')
    DEST_DIGEST=$(retry oras manifest fetch --descriptor "${DEST_IMAGE}" | jq -r '.digest')
    if [ "${SOURCE_DIGEST}" != "${DEST_DIGEST}" ]; then
        echo "${DEST_IMAGE} has digest ${DEST_DIGEST}, expected ${SOURCE_DIGEST} from ${SOURCE_IMAGE}"
        exit 1
    fi

    # Each platform image needs its own tag because Inspector skips manifest lists.
    PLATFORMS=$(retry oras manifest fetch "${DEST_IMAGE}" \
        | jq -r '.manifests[]? | select(.platform.os == "linux") | "\(.digest) \(.platform.architecture) \(.mediaType)"')
    while read -r DIGEST ARCH MEDIA_TYPE; do
        [ -n "${DIGEST}" ] || continue
        case "${MEDIA_TYPE}" in
            application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json) ;;
            *)
                echo "${DEST_REPO}@${DIGEST} for ${ARCH} has media type ${MEDIA_TYPE}, expected an image manifest"
                exit 1
                ;;
        esac
        retry oras tag "${DEST_REPO}@${DIGEST}" "${TAG}-linux_${ARCH}"
    done <<< "${PLATFORMS}"
done
