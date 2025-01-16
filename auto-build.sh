#!/usr/bin/env bash
set -euxo pipefail

GIT_REPO_URL="https://github.com/veeresh08/jveeresh.git"
PROJ_NAME=jveeresh
REGION="us-central1"

get_github_code() {
    TEMP_DIR=$(mktemp -d)
    echo "Using temporary directory: $TEMP_DIR"

    if [[ ${GIT_REF} =~ ^release- || 
          ${GIT_REF} =~ ^v[0-9]+\.[0-9]+\.[0-9]+.*$ ||
          ${GIT_REF} = 'main' ]]; then
        git clone --quiet --depth 1 --branch "${GIT_REF}" --single-branch "${GIT_REPO_URL}" "${TEMP_DIR}"
        cd "${TEMP_DIR}"
    else
        echo -e "${GIT_REF} is not a valid tag or branch name on GitHub repo.\n\t${GIT_REPO_URL}"
        exit 1
    fi

    if [[ ! -z ${PATCH_FILE} ]] ; then
        BUCKET="gps-coordinator-artifacts-test"
        FOLDER="prerel-patch"
        gsutil cp "gs://${BUCKET}/${FOLDER}/${PATCH_FILE}" .
        VERSION=$(basename "${PATCH_FILE}" .patch)
        if git apply -v "${PATCH_FILE}" 2>/dev/null; then
            echo "${VERSION}" > version.txt
        else
            echo "Patch file ${PATCH_FILE} is invalid or empty. Skipping patch application."
            echo "${VERSION}" > version.txt
        fi
    else
        echo "No patch file provided."
        echo "v1.14.0-rc01" > version.txt
    fi
    build
}

build() {
    SRV_ACNT="projects/${PROJ_NAME}/serviceAccounts/run-function-sa@${PROJ_NAME}.iam.gserviceaccount.com"
    IMG_REPO="${REGION}-docker.pkg.dev/${PROJ_NAME}"
    REL=$(cat version.txt)

    SUBS="_BUILD_IMAGE_REPO_PATH=${IMG_REPO}/gps-bazel-image,\
_BUILD_IMAGE_NAME=bazel-build-container,\
_BUILD_IMAGE_TAG=${REL}"

    gcloud builds submit --region="${REGION}" \
        --service-account="${SRV_ACNT}" \
        --suppress-logs \
        --config=build-scripts/gcp/build-container/cloudbuild.yaml \
        --substitutions="${SUBS}" >/dev/null

    SUBS="_BUILD_IMAGE_REPO_PATH=${IMG_REPO}/gps-bazel-image,\
_BUILD_IMAGE_NAME=bazel-build-container,\
_BUILD_IMAGE_TAG=${REL},\
_OUTPUT_IMAGE_REPO_PATH=${IMG_REPO}/gps-keygen,\
_OUTPUT_KEYGEN_IMAGE_NAME=keygen_mp_gcp_prod,\
_OUTPUT_IMAGE_TAG=${REL},\
_TAR_PUBLISH_BUCKET=gps-coordinator-artifacts-test,\
_TAR_PUBLISH_BUCKET_PATH=coordinator-archive"

    gcloud builds submit \
        --region="${REGION}" \
        --service-account="${SRV_ACNT}" \
        --suppress-logs --async \
        --config=build-scripts/gcp/cloudbuild.yaml \
        --substitutions="${SUBS}" >/dev/null
}

PATCH_FILE=""
GIT_REF=$(tr -d ' ' <<< "$1")
if [[ $# -eq 2 ]] ; then
    PATCH_FILE=$2
fi
get_github_code
