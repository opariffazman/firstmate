#!/usr/bin/env bash
# E2E: a no-mistakes-shaped task branch (pushed from a separate worktree, no upstream)
# is squash-merged and its remote branch deleted. Compare base vs change fleet-sync.
# Usage: e2e-landed-prune.sh <change-root> <base-root>
set -u
CHANGE=$1 BASE_ROOT=$2
export GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.invalid GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.invalid
T=$(mktemp -d /tmp/fm-e2e-prune.XXXXXX)
trap 'rm -rf "$T"' EXIT
FB="$T/fakebin"; mkdir -p "$FB"
# No forge reachable: every gh/gh-axi call errors, so only local proof can apply.
printf '#!/usr/bin/env bash\necho "%s $*" >> %s/gh-calls.log\nexit 1\n' gh-axi "$T" > "$FB/gh-axi"
printf '#!/usr/bin/env bash\necho "%s $*" >> %s/gh-calls.log\nexit 1\n' gh "$T" > "$FB/gh"
chmod +x "$FB/gh" "$FB/gh-axi"

setup() {  # <home>
  local h=$1
  mkdir -p "$h/projects"
  git init -q "$h/work"; git -C "$h/work" symbolic-ref HEAD refs/heads/main
  echo v0 > "$h/work/file.txt"; git -C "$h/work" add .; git -C "$h/work" commit -qm C0
  git clone -q --bare "$h/work" "$h/origin.git"
  git -C "$h/work" remote add origin "file://$h/origin.git"; git -C "$h/work" fetch -q origin
  git -C "$h/work" branch -q -u origin/main main
  git clone -q "file://$h/origin.git" "$h/projects/proj"
  local c="$h/projects/proj"
  # landed task: pushed from a gate worktree without -u, then squash-merged + remote deleted
  git -C "$c" worktree add -q --no-track -b fm/landed "$h/wt1" origin/main
  echo feature > "$h/wt1/a.txt"; git -C "$h/wt1" add .; git -C "$h/wt1" commit -qm "task landed"
  git -C "$h/wt1" push -q origin fm/landed; git -C "$c" worktree remove "$h/wt1"
  echo feature > "$h/work/a.txt"; git -C "$h/work" add .; git -C "$h/work" commit -qm "squash fm/landed (#1)"
  git -C "$h/work" push -q origin main; git -C "$h/work" push -q origin --delete fm/landed
  # parked task: unpushed local commit, worktree already recycled
  git -C "$c" worktree add -q --no-track -b fm/parked "$h/wt2" origin/main
  echo wip > "$h/wt2/b.txt"; git -C "$h/wt2" add .; git -C "$h/wt2" commit -qm "parked wip"
  git -C "$c" worktree remove "$h/wt2"
}

show() {  # <clone>
  git -C "$1" for-each-ref --format='  %(refname:short)  upstream=[%(upstream:short)] track=[%(upstream:track)]' refs/heads
}

run() {  # <label> <root> <home> [env...] -- args
  local label=$1 root=$2 home=$3; shift 3
  echo "\$ $label"
  env PATH="$FB:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$@" 2>&1 | sed 's/^/  /'
  echo "  branches after:"; show "$home/projects/proj"
  echo
}

echo "=== 1. BASE commit (bug): FM_FLEET_PRUNE default, landed no-upstream branch never pruned ==="
H="$T/h1"; setup "$H"; echo "branches before:"; show "$H/projects/proj"; echo
run "fm-fleet-sync.sh (base)" "$BASE_ROOT" "$H" FM_FLEET_PRUNE_MERGED=1 "$BASE_ROOT/bin/fm-fleet-sync.sh" "$H/projects/proj"

echo "=== 2. CHANGE, opt-in OFF (default): behaviour unchanged, landed branch kept ==="
H="$T/h2"; setup "$H"
run "fm-fleet-sync.sh (change, no opt-in)" "$CHANGE" "$H" "$CHANGE/bin/fm-fleet-sync.sh" "$H/projects/proj"

echo "=== 3. CHANGE, FM_FLEET_PRUNE_MERGED=1: landed pruned, parked unpushed work survives ==="
H="$T/h3"; setup "$H"
run "FM_FLEET_PRUNE_MERGED=1 fm-fleet-sync.sh (change)" "$CHANGE" "$H" FM_FLEET_PRUNE_MERGED=1 "$CHANGE/bin/fm-fleet-sync.sh" "$H/projects/proj"
echo "  parked commit still reachable: $(git -C "$H/projects/proj" log -1 --format=%s fm/parked 2>&1)"
echo

echo "=== 4. CHANGE, FM_FLEET_PRUNE_MERGED=1 FM_FLEET_PRUNE=0: every prune disabled ==="
H="$T/h4"; setup "$H"
run "FM_FLEET_PRUNE=0 FM_FLEET_PRUNE_MERGED=1 fm-fleet-sync.sh (change)" "$CHANGE" "$H" FM_FLEET_PRUNE=0 FM_FLEET_PRUNE_MERGED=1 "$CHANGE/bin/fm-fleet-sync.sh" "$H/projects/proj"

echo "=== 5. CHANGE, --no-pr-lookup (bootstrap form): content proof still prunes, zero gh calls ==="
H="$T/h5"; setup "$H"; rm -f "$T/gh-calls.log"
run "FM_FLEET_PRUNE_MERGED=1 fm-fleet-sync.sh --no-pr-lookup (change)" "$CHANGE" "$H" FM_FLEET_PRUNE_MERGED=1 "$CHANGE/bin/fm-fleet-sync.sh" --no-pr-lookup "$H/projects/proj"
echo "  gh/gh-axi pr calls made: $(grep -c ' pr ' "$T/gh-calls.log" 2>/dev/null || echo 0)"
