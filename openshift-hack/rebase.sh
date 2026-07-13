#!/bin/bash

# READ FIRST BEFORE USING THIS SCRIPT
#
# This script requires git and bash to work properly (dependencies are checked for you).
#
# This script generates a git remote structure described in:
# https://github.com/openshift/kubernetes/blob/master/REBASE.openshift.md#preparing-the-local-repo-clone
# Please check if you have configured the correct remotes, otherwise the script will fail.
#
# The usage is described in /Rebase.openshift.md.

# validate input args --k8s-tag=v1.21.2 --openshift-release=release-4.8 --jira-id=OCPBUGS-91759
k8s_tag=""
openshift_release=""
jira_id=""

usage() {
  echo "Available arguments:"
  echo "  --k8s-tag            (required) Example: --k8s-tag=v1.21.2"
  echo "  --openshift-release  (required) Example: --openshift-release=release-4.8"
  echo "  --jira-id        (optional) Include Jira ticket in PR title: Example: --jira-id=OCPBUGS-1234"
}

for i in "$@"; do
  case $i in
  --k8s-tag=*)
    k8s_tag="${i#*=}"
    shift
    ;;
  --openshift-release=*)
    openshift_release="${i#*=}"
    shift
    ;;
  --jira-id=*)
    jira_id="${i#*=}"
    shift
    ;;
  *)
    usage
    exit 1
    ;;
  esac
done

if [ -z "${k8s_tag}" ]; then
  echo "Required argument missing: --k8s-tag"
  echo ""
  usage
  exit 1
fi

if [ -z "${openshift_release}" ]; then
  echo "Required argument missing: --openshift-release"
  echo ""
  usage
  exit 1
fi

echo "Processed arguments are:"
echo "--k8s_tag=${k8s_tag}"
echo "--openshift_release=${openshift_release}"
echo "--jira_id=${jira_id}"

# prerequisites (check git is present)
if ! command -v git &>/dev/null; then
  echo "git not installed, exiting"
  exit 1
fi

# make sure we're in "kubernetes" dir
if [[ $(basename "$PWD") != "kubernetes" ]]; then
  echo "Not in kubernetes dir, exiting"
  exit 1
fi

origin=$(git remote get-url origin)
if [[ "$origin" =~ .*kubernetes/kubernetes.* || "$origin" =~ .*openshift/kubernetes.* ]]; then
  echo "cannot rebase against k/k or o/k! found: ${origin}, exiting"
  exit 1
fi

# fetch remote https://github.com/kubernetes/kubernetes
# ADAPTATION 1: SSH -> HTTPS URLs
git remote add upstream https://github.com/kubernetes/kubernetes.git 2>/dev/null || true
git fetch upstream --tags -f
# fetch remote https://github.com/openshift/kubernetes
git remote add openshift https://github.com/openshift/kubernetes.git 2>/dev/null || true
git fetch openshift

git checkout --track "openshift/$openshift_release"
git pull openshift "$openshift_release"

if [ -z "$(git tag -l "$k8s_tag")" ]; then
    echo "No such tag exists in upstream for: $k8s_tag"
	exit 1
fi
git merge "$k8s_tag"
# shellcheck disable=SC2181
if [ $? -eq 0 ]; then
  echo "No conflicts detected. Automatic merge looks to have succeeded"
# ADAPTATION 2: Replace interactive prompt with merge abort + exit
else
  echo "ERROR: Merge conflicts detected. Cannot resolve automatically."
  git merge --abort
  exit 1
fi

# ADAPTATION 4: Replace podman commands with native execution
# openshift-hack/images/hyperkube/Dockerfile.rhel still has FROM pointing to old tag
# we need to remove the prefix "v" from the $k8s_tag to stay compatible
sed -i -E "s/(io.openshift.build.versions=\"kubernetes=)(1.[1-9]+.[1-9]+)/\1${k8s_tag:1}/" \
  openshift-hack/images/hyperkube/Dockerfile.rhel

echo "> go mod tidy && hack/update-vendor.sh"
go mod tidy && hack/update-vendor.sh
if [ $? -ne 0 ]; then
  echo "updating the vendor folder failed"
  exit 1
fi

echo "> make clean"
make clean

echo "> make update"
make update OS_RUN_WITHOUT_DOCKER=yes

git add -A
git commit -m "UPSTREAM: <drop>: hack/update-vendor.sh, make update and update image"

# ADAPTATION 3: Unique branch naming (include openshift_release)
remote_branch="rebase-${openshift_release}-${k8s_tag}"
git push origin "$openshift_release:$remote_branch"

XY=$(echo "$k8s_tag" | sed -E "s/v(1\.[0-9]+)\.[0-9]+/\1/")
ver=$(echo "$k8s_tag" | sed "s/\.//g")
link="https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-$XY.md#$ver"

# ADAPTATION 5: gh pr create section removed - PR creation handled by coordinator
