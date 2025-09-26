#!/bin/bash

# ==============================================================================
# GitLab Projects Migration Script (v2.1 - with Config Validation)
#
# This script migrates all projects from one GitLab instance (A) to another (B).
# It replicates the source group/subgroup structure under a target parent group
# in the destination instance.
#
# USAGE:
#   ./git_migrate.sh         (Runs the actual migration)
#   ./git_migrate.sh --dry-run (Previews what would be migrated)
#   ./git_migrate.sh --use-git (Uses git push instead of git push --mirror)
#
# PREREQUISITES:
# 1. git, curl, jq, dirname
# ==============================================================================

# --- CONFIGURATION ---
# PLEASE FILL IN THESE VARIABLES
GITLAB_A_URL=""
GITLAB_A_TOKEN=""
GITLAB_B_URL=""
GITLAB_B_TOKEN=""
GITLAB_B_TARGET_ROOT_GROUP_ID=""

GIT_RESOLVE_IP=""
GIT_RESOLVE_DOMAIN=""

# --- VALIDATE CONFIGURATION ---
if [ -z "${GITLAB_A_URL:-}" ] || [ -z "${GITLAB_A_TOKEN:-}" ] || [ -z "${GITLAB_B_URL:-}" ] || [ -z "${GITLAB_B_TOKEN:-}" ] || [ -z "${GITLAB_B_TARGET_ROOT_GROUP_ID:-}" ]; then
  echo "❌ ERROR: Configuration variables are not set."
  echo "Please edit the script and fill in the following variables in the '--- CONFIGURATION ---' section:"
  echo "  - GITLAB_A_URL"
  echo "  - GITLAB_A_TOKEN"
  echo "  - GITLAB_B_URL"
  echo "  - GITLAB_B_TOKEN"
  echo "  - GITLAB_B_TARGET_ROOT_GROUP_ID"
  exit 1
fi

# --- ARGUMENT PARSING ---
DRY_RUN=false
USE_GIT_PUSH=true
IGNORE_CERT=false
CURL_CERT_FLAG=""
CURL_RESOLVE_FLAG="" # Leave empty unless --ignore-cert is used

for arg in "$@"; do
  if [ "$arg" = "--dry-run" ]; then
    DRY_RUN=true
  fi
  if [ "$arg" = "--use-git" ]; then
    USE_GIT_PUSH=true
  fi

  case $arg in
  --dry-run)
    DRY_RUN=true
    ;;
  --use-git)
    USE_GIT_PUSH=true
    ;;
  --ignore-cert)
    export GIT_SSL_NO_VERIFY=true
    CURL_CERT_FLAG="-k"
    CURL_RESOLVE_FLAG="--resolve $GIT_RESOLVE_DOMAIN:443:$GIT_RESOLVE_IP"
    IGNORE_CERT=true
    ;;
  esac
done

# --- SCRIPT SETTINGS ---
MIGRATION_WORKSPACE="$(pwd)/workspace"
SUCCESS_LOG="$(pwd)/migration_success.log"
ERROR_LOG="$(pwd)/migration_error.log"
LOG_FILE="$(pwd)/.migration_debug.log"

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipelines return the exit status of the last command to exit with a non-zero status.
set -o pipefail

# --- GLOBAL CACHE ---
# Associative array to cache namespace paths to their GitLab IDs
declare -A NAMESPACE_ID_CACHE

# --- FUNCTION DEFINITIONS ---

log_error() {
  local project_path="$1"
  local error_message="$2"
  echo "$(date): [${project_path}] - ${error_message}" >>"${ERROR_LOG}"
  echo "❌ ERROR: Migration failed for ${project_path}. See ${ERROR_LOG} for details."
}

log_and_print() {
  local message="$*"
  echo "$message" >>"${LOG_FILE}"
  echo "$message"
}

# Ensures a namespace (e.g., "group/subgroup") exists under a parent group in GitLab B.
# Creates groups/subgroups recursively if they don't exist.
# Returns the final subgroup's ID.
ensure_destination_namespace_id() {
  local source_namespace_path="$1"
  local parent_group_id="$2"

  if [ "$source_namespace_path" = "." ]; then
    echo "$parent_group_id"
    return
  fi

  if [ -n "${NAMESPACE_ID_CACHE[${source_namespace_path}]:-}" ]; then
    echo "${NAMESPACE_ID_CACHE[${source_namespace_path}]}"
    return
  fi

  echo "  - Ensuring destination namespace '${source_namespace_path}' exists..." >&2

  local current_parent_id="$parent_group_id"
  IFS='/' read -r -a path_parts <<<"$source_namespace_path"

  for part in "${path_parts[@]}"; do
    local search_result
    search_result=$(curl $CURL_CERT_FLAG $CURL_RESOLVE_FLAG --silent --show-error --header "PRIVATE-TOKEN: ${GITLAB_B_TOKEN}" \
      "${GITLAB_B_URL}/api/v4/groups/${current_parent_id}/subgroups?search=${part}")

    local existing_group_id
    existing_group_id=$(echo "$search_result" | jq -r ".[] | select(.path == \"${part}\") | .id")

    if [ -n "$existing_group_id" ]; then
      current_parent_id="$existing_group_id"
    else
      echo "    - Creating subgroup '${part}' under parent ID ${current_parent_id}..." >&2
      local create_result
      create_result=$(curl $CURL_CERT_FLAG $CURL_RESOLVE_FLAG --silent --show-error --request POST \
        --header "PRIVATE-TOKEN: ${GITLAB_B_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "{\"name\": \"${part}\", \"path\": \"${part}\", \"parent_id\": ${current_parent_id}}" \
        "${GITLAB_B_URL}/api/v4/groups")

      local new_group_id
      new_group_id=$(echo "$create_result" | jq -r '.id')

      if [ -z "$new_group_id" ] || [ "$new_group_id" = "null" ]; then
        local error_msg
        error_msg=$(echo "$create_result" | jq -r '.message')
        log_error "$source_namespace_path" "Failed to create subgroup '${part}'. API response: ${error_msg}"
        return 1
      fi
      current_parent_id="$new_group_id"
    fi
  done

  NAMESPACE_ID_CACHE["$source_namespace_path"]="$current_parent_id"
  echo "$current_parent_id"
}

# --- SCRIPT START ---

echo "GitLab Migration Script Started (v2.1 - with Config Validation)"
echo "-----------------------------------------------------------------"

if [ "$DRY_RUN" = "true" ]; then
  echo "===================================="
  echo "  DRY RUN MODE ENABLED"
  echo "  No actual changes will be made."
  echo "===================================="
  echo
fi

mkdir -p "${MIGRATION_WORKSPACE}"
touch "${SUCCESS_LOG}" "${ERROR_LOG}"

NAMESPACE_ID_CACHE["."]=${GITLAB_B_TARGET_ROOT_GROUP_ID}

echo "Fetching all projects from GitLab A (${GITLAB_A_URL})..."
page=1
while :; do
  response=$(curl $CURL_CERT_FLAG $CURL_RESOLVE_FLAG --silent --show-error --header "PRIVATE-TOKEN: ${GITLAB_A_TOKEN}" "${GITLAB_A_URL}/api/v4/projects?archived=false&per_page=100&page=${page}")

  if [ -z "$response" ] || [ "$response" == "[]" ]; then
    break
  fi

  echo "$response" | jq -c '.[]' | while read -r project; do
    project_path_with_namespace=$(echo "$project" | jq -r '.path_with_namespace')
    project_name=$(echo "$project" | jq -r '.path')
    project_clone_url=$(echo "$project" | jq -r '.http_url_to_repo')
    is_empty_repo=$(echo "$project" | jq -r '.empty_repo')

    if [ "$is_empty_repo" = "true" ]; then
      log_and_print "⏭️ SKIPPING: ${project_path_with_namespace} is an empty project (no commits)."
      continue
    fi

    if grep -qFx "${project_path_with_namespace}" "${SUCCESS_LOG}"; then
      log_and_print "✅ SKIPPING: ${project_path_with_namespace} is already marked as successfully migrated."
      continue
    fi

    source_namespace=$(dirname "${project_path_with_namespace}")

    if [ "$DRY_RUN" = "true" ]; then
      if [ "$source_namespace" = "." ]; then
        echo "➡️  [DRY RUN] Would migrate project '${project_name}' directly into root group ID ${GITLAB_B_TARGET_ROOT_GROUP_ID}."
      else
        echo "➡️  [DRY RUN] Would migrate project '${project_path_with_namespace}' by replicating namespace under root group ID ${GITLAB_B_TARGET_ROOT_GROUP_ID}."
      fi
      continue
    fi

    log_and_print "▶️ PROCESSING: ${project_path_with_namespace}"

    target_namespace_id=$(ensure_destination_namespace_id "$source_namespace" "$GITLAB_B_TARGET_ROOT_GROUP_ID")
    if [ $? -ne 0 ]; then
      continue
    fi
    log_and_print "  - Target Namespace ID in GitLab B is: ${target_namespace_id}"

    authed_clone_url=$(echo "${project_clone_url}" | sed "s|://|://oauth2:${GITLAB_A_TOKEN}@|")
    repo_path="${MIGRATION_WORKSPACE}/${project_name}.git"
    rm -rf "${repo_path}"

    log_and_print "  - Cloning '${project_path_with_namespace}' from GitLab A..."
    if ! git clone --mirror --quiet "${authed_clone_url}" "${repo_path}"; then
      log_error "${project_path_with_namespace}" "Failed to clone repository."
      continue
    fi

    cd "${repo_path}"

    echo "  - Current branches/tags in the repo:"
    git for-each-ref --format="%(refname:short)" refs/heads refs/tags | sed 's/^/    - /'

    echo "  - Current refs in the repo:"
    git for-each-ref --format="%(refname)" | sed 's/^/    - /'

    log_and_print "  - Cleaning up refs/merge-requests/* to avoid push errors..."
    rm -rf refs/merge-requests/
    sed -i '/refs\/merge-requests\//d' packed-refs

    log_and_print "  - Cleaning up refs/environments/* to avoid push errors..."
    rm -rf refs/environments/
    sed -i '/refs\/environments\//d' packed-refs

    log_and_print "  - Cleaning up refs/pipelines/* to avoid push errors..."
    rm -rf refs/pipelines/
    sed -i '/refs\/pipelines\//d' packed-refs

    # git reflog expire --expire=now --all
    # git gc --prune=now

    # 先檢查專案是否存在
    exist_response=$(curl $CURL_CERT_FLAG $CURL_RESOLVE_FLAG --silent --show-error --header "PRIVATE-TOKEN: ${GITLAB_B_TOKEN}" "${GITLAB_B_URL}/api/v4/groups/${target_namespace_id}/projects?search=${project_name}")
    exist_project_id=$(echo "$exist_response" | jq -r ".[] | select(.path == \"${project_name}\") | .id")

    if [ -n "$exist_project_id" ]; then
      log_and_print "  - Project '${project_name}' already exists in GitLab B. Using existing project for push."
      exist_project_info=$(curl $CURL_CERT_FLAG $CURL_RESOLVE_FLAG --silent --show-error --header "PRIVATE-TOKEN: ${GITLAB_B_TOKEN}" "${GITLAB_B_URL}/api/v4/projects/${exist_project_id}")
      new_repo_url=$(echo "$exist_project_info" | jq -r '.http_url_to_repo')
      git_repo_url=$(echo "$exist_project_info" | jq -r '.ssh_url_to_repo')
    else
      log_and_print "  - Creating project '${project_name}' in GitLab B under group ID ${target_namespace_id}..."
      create_response=$(curl $CURL_CERT_FLAG $CURL_RESOLVE_FLAG --silent --show-error --request POST \
        --header "PRIVATE-TOKEN: ${GITLAB_B_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "{\"name\": \"${project_name}\", \"path\": \"${project_name}\", \"namespace_id\": ${target_namespace_id}}" \
        "${GITLAB_B_URL}/api/v4/projects")

      if echo "$create_response" | jq -e '.message' >/dev/null; then
        log_and_print "  - WARNING: Project '${project_name}' already exists in GitLab B."
        log_and_print "    Skipping creation and proceeding to push."
        log_and_print "  - Current response from B: $create_response"
        error_msg=$(echo "$create_response" | jq -r '.message | tostring')
        log_error "${project_path_with_namespace}" "Failed to create project in GitLab B. API response: ${error_msg}"
        cd ../..
        continue
      fi

      new_repo_url=$(echo "$create_response" | jq -r '.http_url_to_repo')
      git_repo_url=$(echo "$create_response" | jq -r '.ssh_url_to_repo')
    fi

    log_and_print "  - Setting detached tags."
    git config --local lfs.${new_repo_url}/info/lfs.locksverify true

    if [ "$IGNORE_CERT" = "true" ]; then
      git config --local http.${new_repo_url}.sslVerify false
      git config --local http.${git_repo_url}.sslVerify false
      git config --local http.${GIT_RESOLVE_DOMAIN}.extraHeader "Host: ${GIT_RESOLVE_DOMAIN}"
    fi

    if [ "$USE_GIT_PUSH" = "true" ]; then
      remote_url="$git_repo_url"
    else
      remote_url=$(echo "${new_repo_url}" | sed "s|://|://oauth2:${GITLAB_B_TOKEN}@|")
    fi

    # Check if there are any LFS objects to push
    lfs_objects_count=$(git lfs ls-files | wc -l)
    log_and_print "  - Found ${lfs_objects_count} Git LFS objects to push."

    if [ "$lfs_objects_count" -eq 0 ]; then
      log_and_print "  - No Git LFS objects found to push."

    else
      log_and_print "  - Fetching Git LFS objects..."
      git lfs install --local
      if ! git lfs fetch --all; then
        log_and_print "  - WARNING: 'git lfs fetch' failed. This is okay if the project does not use LFS."
      fi
      log_and_print "  - Pushing Git LFS objects..."
      if ! git lfs push --all "${remote_url}"; then
        log_error "${project_path_with_namespace}" "Failed to push Git LFS objects. Please check if the project uses LFS."
      fi
    fi

    log_and_print "  - Pushing to new repository at GitLab B..."
    git remote set-url origin "$remote_url"
    git push origin --mirror
    # git push --quiet origin --all
    # git push --quiet origin --tags

    cd ../..

    rm -rf "${repo_path}"
    log_and_print "${project_path_with_namespace}" >>"${SUCCESS_LOG}"
    log_and_print "Repo url: $new_repo_url"
    log_and_print "✔️ SUCCESS: Migrated ${project_path_with_namespace} successfully."

  done

  # Check for a next page header. If it doesn't exist, we're done.
  # The `if` statement combined with `set -o pipefail` correctly handles the case
  # where `grep` finds no match, preventing the script from exiting due to `set -e`.
  if curl $CURL_CERT_FLAG $CURL_RESOLVE_FLAG --silent --head --header "PRIVATE-TOKEN: ${GITLAB_A_TOKEN}" "${GITLAB_A_URL}/api/v4/projects?archived=false&per_page=100&page=${page}" | grep -q -i "x-next-page"; then
    page=$((page + 1))
    log_and_print "Fetching next page (${page})..."
  else
    break
  fi
done

log_and_print "---------------------------------"
log_and_print "Migration script finished."
log_and_print "Check '${SUCCESS_LOG}' for successfully migrated projects."
log_and_print "Check '${ERROR_LOG}' for any projects that failed."
