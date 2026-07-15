#!/bin/bash

# Modified rebase.sh for non-interactive workspace environment
# Changes from original:
# 1. SSH URLs -> HTTPS URLs for git remote add
# 2. openshift remote -> https://github.com/JSampsonIV/kubernetes
# 3. gh prerequisite check is non-fatal (warning instead of exit)
# 4. podman -it flags removed (no interactive flags in original but Z flag kept)
# 5. read -n 1 replaced with automated conflict resolution per rules
# 6. git remote add uses || true since remotes may already exist
# 7. Push to redhat-chai-bot/kubernetes (origin remote)

# validate input args
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

# prerequisites (check git, podman, ... is present)
if ! command -v git &>/dev/null; then
  echo "git not installed, exiting"
  exit 1
fi

# MODIFICATION: gh check is non-fatal (warning instead of exit)
if ! command -v gh &>/dev/null; then
  echo "WARNING: gh not installed, PR creation will be skipped"
fi

if ! command -v podman &>/dev/null; then
  echo "podman not installed, exiting"
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

# MODIFICATION: Use HTTPS URLs and || true for existing remotes
# fetch remote https://github.com/kubernetes/kubernetes
git remote add upstream https://github.com/kubernetes/kubernetes.git 2>/dev/null || true
git fetch upstream --tags -f
# fetch remote https://github.com/JSampsonIV/kubernetes (openshift fork)
git remote add openshift https://github.com/JSampsonIV/kubernetes.git 2>/dev/null || true
git fetch openshift

git checkout --track "openshift/$openshift_release" 2>/dev/null || git checkout "$openshift_release"
git pull openshift "$openshift_release"

if [ -z "$(git tag -l "$k8s_tag")" ]; then
    echo "No such tag exists in upstream for: $k8s_tag"
	exit 1
fi
git merge "$k8s_tag"
# shellcheck disable=SC2181
if [ $? -eq 0 ]; then
  echo "No conflicts detected. Automatic merge looks to have succeeded"
else
  echo "=== CONFLICTS DETECTED - Starting automated resolution ==="

  # Get list of conflicting files
  conflicting_files=$(git diff --name-only --diff-filter=U)
  echo "Conflicting files:"
  echo "$conflicting_files"
  echo ""

  # Determine rebase level (patch vs minor)
  current_minor=$(echo "$k8s_tag" | sed -E 's/v(1\.[0-9]+)\.[0-9]+/\1/')
  # For patch-level rebases, remaining files accept upstream

  for file in $conflicting_files; do
    echo "--- Resolving: $file ---"

    if [[ "$file" == "go.mod" && ! "$file" == staging/* ]]; then
      # Root go.mod — marker parsing (keep openshift + accept upstream bumps)
      echo "  Rule: Root go.mod — marker parsing (keep openshift + accept upstream bumps)"

      # Strategy: Accept theirs as base, then restore OpenShift-specific entries
      # First, save the conflict markers version for analysis
      cp "$file" "${file}.conflicted"

      # Accept upstream (theirs) as base
      git checkout --theirs "$file"

      # Now we need to add back OpenShift-specific entries from ours
      # Extract OpenShift-specific requires and replaces from the ours version
      git show :2:"$file" > "${file}.ours" 2>/dev/null || true

      if [ -f "${file}.ours" ]; then
        # Get OpenShift-specific require entries (github.com/openshift/*, etc.)
        openshift_requires=$(grep -E '^\s+(github\.com/openshift|github\.com/openshift-eng)' "${file}.ours" 2>/dev/null || true)

        # Get OpenShift-specific replace directives
        openshift_replaces=$(grep -E '^\s+(github\.com/openshift|github\.com/openshift-eng)' "${file}.ours" 2>/dev/null | head -0 || true)

        # Check if there are OpenShift replace blocks we need to preserve
        # We'll use a Python script for more precise merging if needed
        python3 - "$file" "${file}.ours" <<'PYEOF'
import sys
import re

theirs_path = sys.argv[1]
ours_path = sys.argv[2]

with open(theirs_path, 'r') as f:
    theirs_content = f.read()
with open(ours_path, 'r') as f:
    ours_content = f.read()

# Find OpenShift-specific dependencies in ours
# These are deps that exist in ours but not in theirs
ours_lines = ours_content.split('\n')
theirs_lines = theirs_content.split('\n')

# Build sets of module paths from theirs
theirs_modules = set()
for line in theirs_lines:
    m = re.match(r'\s+(\S+)\s+', line)
    if m:
        theirs_modules.add(m.group(1))

# Find OpenShift-specific require entries
openshift_requires = []
in_require = False
for line in ours_lines:
    if line.strip() == 'require (' or line.strip().startswith('require ('):
        in_require = True
        continue
    if in_require and line.strip() == ')':
        in_require = False
        continue
    if in_require:
        m = re.match(r'\s+(\S+)\s+(\S+)', line)
        if m:
            mod = m.group(1)
            if ('openshift' in mod.lower() or 'openshift-eng' in mod.lower()) and mod not in theirs_modules:
                openshift_requires.append(line)

# Find OpenShift-specific replace directives
openshift_replaces = []
in_replace = False
for line in ours_lines:
    if line.strip() == 'replace (' or line.strip().startswith('replace ('):
        in_replace = True
        continue
    if in_replace and line.strip() == ')':
        in_replace = False
        continue
    if in_replace:
        if 'openshift' in line.lower() or 'openshift-eng' in line.lower():
            openshift_replaces.append(line)

# If we found OpenShift-specific entries, add them to theirs
if openshift_requires or openshift_replaces:
    result = theirs_content

    # Add OpenShift requires before the closing paren of the last require block
    if openshift_requires:
        # Find the last require block
        require_pattern = r'(require \([^)]*)\)'
        matches = list(re.finditer(require_pattern, result, re.DOTALL))
        if matches:
            last_match = matches[-1]
            insert_pos = last_match.end() - 1  # before the closing )
            insert_text = '\n' + '\n'.join(openshift_requires) + '\n'
            result = result[:insert_pos] + insert_text + result[insert_pos:]

    # Add OpenShift replaces before the closing paren of the replace block
    if openshift_replaces:
        replace_pattern = r'(replace \([^)]*)\)'
        matches = list(re.finditer(replace_pattern, result, re.DOTALL))
        if matches:
            last_match = matches[-1]
            insert_pos = last_match.end() - 1
            insert_text = '\n' + '\n'.join(openshift_replaces) + '\n'
            result = result[:insert_pos] + insert_text + result[insert_pos:]

    with open(theirs_path, 'w') as f:
        f.write(result)

    print(f"  Added {len(openshift_requires)} OpenShift require entries")
    print(f"  Added {len(openshift_replaces)} OpenShift replace entries")
else:
    print("  No OpenShift-specific entries to preserve")
PYEOF
      fi

      rm -f "${file}.conflicted" "${file}.ours"
      git add "$file"

    elif [[ "$file" == "go.sum" && ! "$file" == staging/* ]]; then
      # Root go.sum — accept upstream (regenerated by go mod tidy)
      echo "  Rule: Root go.sum — accept upstream (regenerated by go mod tidy)"
      git checkout --theirs "$file"
      git add "$file"

    elif [[ "$file" == staging/* ]] || [[ "$file" == vendor/* ]] || [[ "$file" == *_generated.go ]] || [[ "$file" == *_generated.pb.go ]] || [[ "$file" == CHANGELOG* ]]; then
      # Dependency-adjacent — accept upstream (regenerated by vendor/make update)
      echo "  Rule: Dependency-adjacent — accept upstream (regenerated by vendor/make update)"
      git checkout --theirs "$file"
      git add "$file"

    elif [[ "$file" == hack/verify-* ]] || [[ "$file" == hack/update-* ]] || [[ "$file" == .go-version ]] || [[ "$file" == build/* ]] || [[ "$file" == test/images/* ]]; then
      # Build/CI infrastructure — accept upstream
      echo "  Rule: Build/CI infrastructure — accept upstream (track upstream tooling)"
      git checkout --theirs "$file"
      git add "$file"

    elif [[ "$file" == openshift-hack/* ]] || [[ "$file" == openshift/* ]]; then
      # OpenShift-specific paths — keep ours
      echo "  Rule: openshift-hack/ — keep ours (openshift-specific)"
      git checkout --ours "$file"
      git add "$file"

    else
      # Remaining files — patch-level rebase → accept upstream
      echo "  Rule: Remaining files — accept upstream (patch-level rebase)"
      git checkout --theirs "$file"
      git add "$file"
    fi
  done

  echo "=== All conflicts resolved ==="
  git commit --no-edit -m "UPSTREAM: <drop>: automated conflict resolution for $k8s_tag rebase"
fi

# openshift-hack/images/hyperkube/Dockerfile.rhel still has FROM pointing to old tag
# we need to remove the prefix "v" from the $k8s_tag to stay compatible
# MODIFICATION: use sed directly instead of podman run alpine
sed -i -E "s/(io.openshift.build.versions=\"kubernetes=)(1.[1-9]+.[0-9]+)/\1${k8s_tag:1}/" \
  openshift-hack/images/hyperkube/Dockerfile.rhel

go_mod_go_ver=$(grep -E 'go 1\.[1-9][0-9]?' go.mod | sed -E 's/go (1\.[1-9][0-9]?)/\1/' | cut -d '.' -f 1,2)
tag=$(grep "^  tag:" .ci-operator.yaml | head -n1 | sed -E 's/.*: (.*)/\1/')

echo "> go mod tidy && hack/update-vendor.sh"
# MODIFICATION: Removed -it flags, using podman without interactive terminal
podman run --rm -v "$(pwd):/go/k8s.io/kubernetes:Z" \
  --workdir=/go/k8s.io/kubernetes \
  "registry.ci.openshift.org/openshift/release:$tag" \
  /bin/bash -c "go mod tidy && hack/update-vendor.sh"

# shellcheck disable=SC2181
if [ $? -ne 0 ]; then
  echo "updating the vendor folder failed, is any dependency missing?"
  exit 1
fi

echo "> make clean to remove stale _output directory"
podman run --rm -v "$(pwd):/go/k8s.io/kubernetes:Z" \
  --workdir=/go/k8s.io/kubernetes \
  "registry.ci.openshift.org/openshift/release:$tag" \
  make clean

podman run --rm -v "$(pwd):/go/k8s.io/kubernetes:Z" \
  --workdir=/go/k8s.io/kubernetes \
  "registry.ci.openshift.org/openshift/release:$tag" \
  make update OS_RUN_WITHOUT_DOCKER=yes

git add -A
git commit -m "UPSTREAM: <drop>: hack/update-vendor.sh, make update and update image"

remote_branch="rebase-$k8s_tag"
git push origin "$openshift_release:$remote_branch"

XY=$(echo "$k8s_tag" | sed -E "s/v(1\.[0-9]+)\.[0-9]+/\1/")
ver=$(echo "$k8s_tag" | sed "s/\.//g")
link="https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-$XY.md#$ver"
if [ -n "${jira_id}" ]; then
  if command -v gh &>/dev/null; then
    gh pr create \
      --title "$jira_id: Rebase $k8s_tag in $openshift_release" \
      --body "CHANGELOG $link" \
      --base "$openshift_release" \
      --head "$remote_branch"
  fi
fi
