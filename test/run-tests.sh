#!/usr/bin/env bash
# Exercises the action's script against local bare repos. The SSH remote is
# swapped for a filesystem path, so refspec construction, the guards, and the
# ref-level outcomes are all covered without needing a knot to talk to.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

SCRIPT="$TMPROOT/script.sh"
TEST_SCRIPT="$TMPROOT/script_test.sh"
WORKDIR="$TMPROOT/work"
PASS=0; FAIL=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

python3 "$REPO_ROOT/test/extract-script.py" > "$SCRIPT"
bash -n "$SCRIPT" || { echo "action script is not valid bash"; exit 1; }

sed 's|^REMOTE="git@\${TM_KNOT}:\${TM_REPO}"$|REMOTE="$TEST_REMOTE"|' "$SCRIPT" > "$TEST_SCRIPT"
grep -q 'REMOTE="\$TEST_REMOTE"' "$TEST_SCRIPT" \
  || { echo "harness: REMOTE substitution failed. Did action.yml change?"; exit 1; }

run_action() {
  ( set +e
    export GITHUB_OUTPUT="$TMPROOT/gh_output"
    export GITHUB_STEP_SUMMARY="$TMPROOT/gh_summary"
    : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
    bash "$TEST_SCRIPT" 2>&1
    echo "EXIT:$?"
  )
}

check() { # name, expected-substring, actual
  # -- so a pattern beginning with "--" is not read as grep options.
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "  ok    $1"; PASS=$((PASS+1))
  else
    echo "  FAIL  $1"
    echo "        wanted: $2"
    echo "        got:    $(printf '%s' "$3" | tr '\n' '|' | cut -c1-260)"
    FAIL=$((FAIL+1))
  fi
}

assert_ref() { # name, git-dir, ref, present|absent
  if git --git-dir="$2" show-ref --verify --quiet "$3"; then found=present; else found=absent; fi
  if [ "$found" = "$4" ]; then
    echo "  ok    $1"; PASS=$((PASS+1))
  else
    echo "  FAIL  $1 (expected $4, was $found)"; FAIL=$((FAIL+1))
  fi
}

commit() { git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1"; }

fresh_repo() {
  rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"; cd "$WORKDIR"
  git init -q --bare knot.git -b main
  git init -q --bare gh.git -b main
  git clone -q gh.git repo 2>/dev/null
  cd repo
  commit one
  git push -q origin main
  git tag v1.0.0 && git push -q origin v1.0.0
}

defaults() {
  export TM_KEY="dummy" TM_REPO="did:plc:test/demo" TM_KNOT="knot.example"
  export TM_PORT="22" TM_KNOWN_HOSTS="knot.example ssh-ed25519 AAAAfake"
  export TM_BRANCHES="" TM_TAGS="true" TM_PRUNE="false"
  export TM_FORCE="false" TM_FORCE_TAGS="false" TM_DRY_RUN="false"
  export TM_ON_DIVERGENCE="warn" TM_ALLOW_LFS="false" TM_MIRROR="false"
  export TM_SKIP_CI="false" TM_ADDRESS_FAMILY="auto"
  export TEST_REMOTE="$WORKDIR/knot.git"
}

staging_count() { git for-each-ref refs/tangled-mirror-staging/ | wc -l | tr -d ' '; }

echo "guards"
fresh_repo; defaults; mkdir -p "$WORKDIR/plain"; cd "$WORKDIR/plain"
check "errors outside a git repo" "Run actions/checkout before this action" "$(run_action)"

fresh_repo; defaults; cd "$WORKDIR"
git clone -q --depth 1 "file://$WORKDIR/gh.git" shallow 2>/dev/null; cd shallow
check "errors on a shallow clone" "Set 'fetch-depth: 0'" "$(run_action)"

fresh_repo; defaults; TM_KEY=""
check "errors on empty ssh-key" "secrets are not exposed to pull_request runs from forks" "$(run_action)"

fresh_repo; defaults; TM_PRUNE="true"; TM_BRANCHES="main"
check "rejects prune without a wildcard" "requires 'branches: \"*\"'" "$(run_action)"

fresh_repo; defaults; TM_BRANCHES="nope"
check "errors on a missing branch" "Branch 'nope' does not exist locally" "$(run_action)"

fresh_repo; defaults; git checkout -q --detach HEAD
check "errors on detached HEAD" "HEAD is detached" "$(run_action)"

echo
echo "push behaviour"
fresh_repo; defaults
check "default push succeeds" "EXIT:0" "$(run_action)"
assert_ref "current branch landed" "$WORKDIR/knot.git" refs/heads/main present
assert_ref "tags landed" "$WORKDIR/knot.git" refs/tags/v1.0.0 present
if git --git-dir="$WORKDIR/knot.git" for-each-ref --format='%(refname)' | grep -q '^refs/remotes'; then
  echo "  FAIL  remote-tracking refs leaked onto the knot"; FAIL=$((FAIL+1))
else
  echo "  ok    no remote-tracking refs leaked onto the knot"; PASS=$((PASS+1))
fi

fresh_repo; defaults; git branch dev; TM_BRANCHES="main dev"
run_action >/dev/null
assert_ref "explicit branch list pushes each" "$WORKDIR/knot.git" refs/heads/dev present

fresh_repo; defaults; TM_DRY_RUN="true"
run_action >/dev/null
assert_ref "dry-run pushes nothing" "$WORKDIR/knot.git" refs/heads/main absent

echo
echo "refs the action was not told about"
fresh_repo; defaults
run_action >/dev/null
git --git-dir="$WORKDIR/knot.git" update-ref refs/heads/contributor-patch "$(git rev-parse main)"
commit two
run_action >/dev/null
assert_ref "contributor branch survives a mirror run" "$WORKDIR/knot.git" refs/heads/contributor-patch present

echo
echo "branches: '*'"
fresh_repo; defaults
git checkout -qb feature-x >/dev/null 2>&1; commit x; git push -q origin feature-x
git checkout -q main; git fetch -q origin
TM_BRANCHES="*"
run_action >/dev/null
assert_ref "mirrors branches that exist only on origin" "$WORKDIR/knot.git" refs/heads/feature-x present
assert_ref "no refs/heads/HEAD artifact" "$WORKDIR/knot.git" refs/heads/HEAD absent
[ "$(staging_count)" = "0" ] \
  && { echo "  ok    staging refs cleaned up"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  staging refs left behind"; FAIL=$((FAIL+1)); }

fresh_repo; defaults; TM_BRANCHES="*"; TM_PRUNE="true"
run_action >/dev/null
git --git-dir="$WORKDIR/knot.git" update-ref refs/heads/stale "$(git rev-parse main)"
commit two
run_action >/dev/null
assert_ref "prune removes refs absent locally" "$WORKDIR/knot.git" refs/heads/stale absent

fresh_repo; defaults; TM_BRANCHES="*"; TEST_REMOTE="$WORKDIR/does-not-exist.git"
run_action >/dev/null 2>&1
[ "$(staging_count)" = "0" ] \
  && { echo "  ok    staging cleaned up after a failed push"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  staging left behind after a failed push"; FAIL=$((FAIL+1)); }

echo
echo "input validation and LFS"
fresh_repo; defaults; TM_ON_DIVERGENCE="maybe"
check "rejects an unknown on-divergence value" "must be warn, fail or ignore" "$(run_action)"

fresh_repo; defaults
printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes
git add .gitattributes && commit lfs
check "refuses a Git LFS repository" "silently incomplete" "$(run_action)"

fresh_repo; defaults; TM_ALLOW_LFS="true"
printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes
git add .gitattributes && commit lfs
check "allow-lfs overrides the refusal" "EXIT:0" "$(run_action)"

echo
echo "prune fallback guard"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"; cd "$WORKDIR"
git init -q --bare knot.git -b main
git init -q standalone -b main; cd standalone
commit one
defaults; TM_BRANCHES="*"; TM_PRUNE="true"
check "refuses to prune without remote-tracking refs" "would delete every branch on the knot" "$(run_action)"

echo
echo "divergence reporting"
fresh_repo; defaults
run_action >/dev/null
git --git-dir="$WORKDIR/knot.git" update-ref refs/heads/theirs "$(git rev-parse main)"
commit two
OUT="$(run_action)"
check "warns about refs only on the knot" "only on the knot: refs/heads/theirs" "$OUT"
check "warning does not block the push" "EXIT:0" "$OUT"

fresh_repo; defaults; TM_ON_DIVERGENCE="fail"
run_action >/dev/null
git --git-dir="$WORKDIR/knot.git" update-ref refs/heads/theirs "$(git rev-parse main)"
commit two
check "on-divergence: fail stops the run" "Knot has diverged" "$(run_action)"

fresh_repo; defaults; TM_ON_DIVERGENCE="ignore"
run_action >/dev/null
git --git-dir="$WORKDIR/knot.git" update-ref refs/heads/theirs "$(git rev-parse main)"
commit two
OUT="$(run_action)"
if printf '%s' "$OUT" | grep -q 'only on the knot'; then
  echo "  FAIL  on-divergence: ignore still reported"; FAIL=$((FAIL+1))
else
  echo "  ok    on-divergence: ignore stays quiet"; PASS=$((PASS+1))
fi

fresh_repo; defaults
run_action >/dev/null
commit two
OUT="$(run_action)"
if printf '%s' "$OUT" | grep -q 'differs:'; then
  echo "  FAIL  reported divergence when merely ahead"; FAIL=$((FAIL+1))
else
  echo "  ok    being ahead of the knot is not reported"; PASS=$((PASS+1))
fi

echo
echo "rolling tags"
fresh_repo; defaults
run_action >/dev/null
commit two
git tag -f v1.0.0 >/dev/null 2>&1
OUT="$(run_action)"
check "a moved tag is refused with a usable message" "Set 'force-tags: true'" "$OUT"
check "the refusal names the tag" "v1.0.0" "$OUT"
if printf '%s' "$OUT" | grep -q 'atomic push failed'; then
  echo "  FAIL  cryptic atomic error reached the user"; FAIL=$((FAIL+1))
else
  echo "  ok    no cryptic atomic error"; PASS=$((PASS+1))
fi
assert_ref "knot tag untouched by the refused run" "$WORKDIR/knot.git" refs/tags/v1.0.0 present

fresh_repo; defaults; TM_ON_DIVERGENCE="ignore"
run_action >/dev/null
commit two
git tag -f v1.0.0 >/dev/null 2>&1
check "tag guard still applies when reporting is off" "Set 'force-tags: true'" "$(run_action)"

fresh_repo; defaults
run_action >/dev/null
commit two
git tag -f v1.0.0 >/dev/null 2>&1
TM_FORCE_TAGS="true"
run_action >/dev/null
if [ "$(git --git-dir="$WORKDIR/knot.git" rev-parse refs/tags/v1.0.0)" = "$(git rev-parse refs/tags/v1.0.0)" ]; then
  echo "  ok    force-tags moves a rolling tag"; PASS=$((PASS+1))
else
  echo "  FAIL  force-tags did not move the tag"; FAIL=$((FAIL+1))
fi

echo
echo "mirror preset (true replica)"
# Build a knot that disagrees with GitHub in every way that matters, then check
# a single mirror:true run reconciles all of it.
fresh_repo; defaults
git checkout -qb feature-keep >/dev/null 2>&1; commit keep; git push -q origin feature-keep
git checkout -q main; git fetch -q origin
TM_MIRROR="true"
run_action >/dev/null

# 1. a branch only the knot has
git --git-dir="$WORKDIR/knot.git" update-ref refs/heads/knot-only "$(git rev-parse main)"
# 2. a branch the knot has diverged on
git --git-dir="$WORKDIR/knot.git" update-ref refs/heads/feature-keep "$(git rev-parse main)"
# 3. a tag pointing somewhere else
git --git-dir="$WORKDIR/knot.git" update-ref refs/tags/v1.0.0 "$(git rev-parse main)"
commit newer
git tag -f v1.0.0 >/dev/null 2>&1
git push -q --force origin main v1.0.0 2>/dev/null || git push -q --force origin main
git fetch -q origin

OUT="$(run_action)"
check "mirror run succeeds against a divergent knot" "EXIT:0" "$OUT"
check "mirror warns that it is destructive" "will be made to match this repository exactly" "$OUT"
assert_ref "branch only on the knot is removed" "$WORKDIR/knot.git" refs/heads/knot-only absent

KNOT_KEEP="$(git --git-dir="$WORKDIR/knot.git" rev-parse refs/heads/feature-keep 2>/dev/null || echo missing)"
if [ "$KNOT_KEEP" = "$(git rev-parse refs/remotes/origin/feature-keep)" ]; then
  echo "  ok    diverged branch is forced back into line"; PASS=$((PASS+1))
else
  echo "  FAIL  diverged branch not reconciled (knot=$KNOT_KEEP)"; FAIL=$((FAIL+1))
fi

if [ "$(git --git-dir="$WORKDIR/knot.git" rev-parse refs/tags/v1.0.0)" = "$(git rev-parse refs/tags/v1.0.0)" ]; then
  echo "  ok    moved tag is reconciled"; PASS=$((PASS+1))
else
  echo "  FAIL  moved tag not reconciled"; FAIL=$((FAIL+1))
fi

# The real assertion: knot branches+tags are now exactly GitHub's.
KNOT_SET="$(git --git-dir="$WORKDIR/knot.git" for-each-ref --format='%(refname)' refs/heads/ refs/tags/ | sort | tr '\n' ' ')"
WANT_SET="$( { git for-each-ref --format='refs/heads/%(refname:lstrip=3)' refs/remotes/origin/ | grep -v '/HEAD$'
              git for-each-ref --format='%(refname)' refs/tags/; } | sort | tr '\n' ' ')"
if [ "$KNOT_SET" = "$WANT_SET" ]; then
  echo "  ok    knot ref set matches GitHub exactly"; PASS=$((PASS+1))
else
  echo "  FAIL  ref sets differ"; FAIL=$((FAIL+1))
  echo "        knot: $KNOT_SET"
  echo "        want: $WANT_SET"
fi

fresh_repo; defaults; TM_MIRROR="true"; TM_BRANCHES="main"; TM_PRUNE="false"
check "mirror overrides conflicting individual flags" "EXIT:0" "$(run_action)"

echo
echo "tangled protocol options"
fresh_repo; defaults; TM_ADDRESS_FAMILY="bogus"
check "rejects an unknown address-family" "must be auto, inet or inet6" "$(run_action)"

fresh_repo; defaults; TM_ADDRESS_FAMILY="inet"
check "address-family inet still pushes" "EXIT:0" "$(run_action)"

# Git's local file transport does not implement push options, unlike a real
# knot, which advertises the push-options capability. So the success path can't
# be reproduced here. What this does verify is that a receiving end lacking the
# capability produces our explanation rather than a raw git error.
fresh_repo; defaults; TM_SKIP_CI="true"
OUT="$(run_action)"
check "unsupported push options give a usable message" "Set 'skip-ci: false'" "$OUT"

fresh_repo; defaults; TM_SKIP_CI="true"
sed 's|^ARGS+=("\$REMOTE" "\${REFSPECS\[@\]}")$|printf "ARGSDUMP:%s\\n" "${ARGS[*]}"\n&|' \
  "$TEST_SCRIPT" > "$TMPROOT/script_args.sh"
ARGS_OUT="$( export GITHUB_OUTPUT="$TMPROOT/gh_output" GITHUB_STEP_SUMMARY="$TMPROOT/gh_summary"
             : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
             bash "$TMPROOT/script_args.sh" 2>&1 )"
check "skip-ci becomes a real push option" "--push-option=skip-ci" "$ARGS_OUT"

dump_args() { # leaves the built ARGS in $ARGS_OUT
  sed 's|^ARGS+=("\$REMOTE" "\${REFSPECS\[@\]}")$|printf "ARGSDUMP:%s\\n" "${ARGS[*]}"\n&|' \
    "$TEST_SCRIPT" > "$TMPROOT/script_args.sh"
  ARGS_OUT="$( export GITHUB_OUTPUT="$TMPROOT/gh_output" GITHUB_STEP_SUMMARY="$TMPROOT/gh_summary"
               : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
               bash "$TMPROOT/script_args.sh" 2>&1 )"
}

fresh_repo; defaults; dump_args
if printf '%s' "$ARGS_OUT" | grep -q 'push-option'; then
  echo "  FAIL  push option sent when skip-ci is off"; FAIL=$((FAIL+1))
else
  echo "  ok    no push option when skip-ci is off"; PASS=$((PASS+1))
fi

# Verified against a live knot: a real push accepts the option, but a dry run
# sends no pack and the knot answers "malformed pack stream". Since the manual
# workflow defaults dry_run on, these two must not combine.
fresh_repo; defaults; TM_SKIP_CI="true"; TM_DRY_RUN="true"; dump_args
if printf '%s' "$ARGS_OUT" | grep -q 'push-option'; then
  echo "  FAIL  push option sent during a dry run"; FAIL=$((FAIL+1))
else
  echo "  ok    no push option during a dry run"; PASS=$((PASS+1))
fi
fresh_repo; defaults; TM_SKIP_CI="true"; TM_DRY_RUN="true"
OUT="$(run_action)"
check "dry run + skip-ci explains itself" "'skip-ci' is ignored during a dry run" "$OUT"
check "dry run + skip-ci does not fail" "EXIT:0" "$OUT"

echo
echo "repo path handling"
fresh_repo; defaults; TM_REPO="@seth.bsky.social/my-repo"; TM_KNOT="knot.example.com"
OUT="$(run_action)"
check "leading @ is stripped" "Dropped the leading '@'" "$OUT"
check "push target has no @" "Pushing to knot.example.com:seth.bsky.social/my-repo" "$OUT"

fresh_repo; defaults; TM_REPO="seth.bsky.social/my-repo"; TM_KNOT="knot.example.com"
OUT="$(run_action)"
if printf '%s' "$OUT" | grep -q "Dropped the leading"; then
  echo "  FAIL  stripped an @ that was not there"; FAIL=$((FAIL+1))
else
  echo "  ok    plain repo path left alone"; PASS=$((PASS+1))
fi

fresh_repo; defaults; TM_REPO="did:plc:abc123/my-repo"; TM_KNOT="knot.example.com"
check "DID paths pass through untouched" "Pushing to knot.example.com:did:plc:abc123/my-repo" "$(run_action)"

echo
echo "custom knots"
# The action must never assume tangled.org. Everything host-shaped has to come
# from the knot input, including the URL in the rejected-key error.
fresh_repo; defaults
TM_KNOT="knot.example.com"; TM_REPO="alice.test/thing"
OUT="$(run_action)"
check "push reports the custom knot" "Pushing to knot.example.com:alice.test/thing" "$OUT"
if printf '%s' "$OUT" | grep -q 'tangled\.org'; then
  echo "  FAIL  tangled.org leaked into a custom-knot run"; FAIL=$((FAIL+1))
else
  echo "  ok    no tangled.org fallback on a custom knot"; PASS=$((PASS+1))
fi

# A key pinned without -p is written plainly, but OpenSSH looks up [host]:port
# on a non-default port and will not match that. The action should cover both.
KEYMAT="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII2UShEm/FFPmYZUizaPnIqOJuynoCQpcLhl5PPHd02n"
probe_known_hosts() { # $1 = port, writes the built file to $WORKDIR/kh.built
  fresh_repo; defaults
  TM_KNOT="knot.example.com"; TM_PORT="$1"
  TM_KNOWN_HOSTS="knot.example.com $KEYMAT"
  # Capture the file the action builds by copying it before the trap fires.
  sed 's|^REMOTE="\$TEST_REMOTE"$|cp "$KH_FILE" '"$WORKDIR"'/kh.built\nREMOTE="$TEST_REMOTE"|' \
    "$TEST_SCRIPT" > "$TMPROOT/script_kh.sh"
  ( export GITHUB_OUTPUT="$TMPROOT/gh_output" GITHUB_STEP_SUMMARY="$TMPROOT/gh_summary"
    : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
    bash "$TMPROOT/script_kh.sh" >/dev/null 2>&1 )
}

probe_known_hosts 2222
if [ -f "$WORKDIR/kh.built" ] \
   && ssh-keygen -F '[knot.example.com]:2222' -f "$WORKDIR/kh.built" >/dev/null 2>&1; then
  echo "  ok    port 2222: OpenSSH can match the built known_hosts"; PASS=$((PASS+1))
else
  echo "  FAIL  port 2222: OpenSSH cannot match the built known_hosts"; FAIL=$((FAIL+1))
fi

probe_known_hosts 22
if [ -f "$WORKDIR/kh.built" ] \
   && ssh-keygen -F 'knot.example.com' -f "$WORKDIR/kh.built" >/dev/null 2>&1; then
  echo "  ok    port 22: plain entry left untouched"; PASS=$((PASS+1))
else
  echo "  FAIL  port 22: plain lookup broken"; FAIL=$((FAIL+1))
fi
if [ -s "$WORKDIR/kh.built" ] && ! grep -q '^\[' "$WORKDIR/kh.built"; then
  echo "  ok    port 22: no needless bracketed line added"; PASS=$((PASS+1))
else
  echo "  FAIL  port 22: bracketed line added unnecessarily, or file was empty"; FAIL=$((FAIL+1))
fi

echo
echo "-----------------------------"
echo " passed: $PASS   failed: $FAIL"
echo "-----------------------------"
[ "$FAIL" -eq 0 ]
