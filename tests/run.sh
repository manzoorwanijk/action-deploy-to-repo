#!/usr/bin/env bash
#
# End to end tests for entrypoint.sh against local bare repositories.
# Run with: tests/run.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRYPOINT="$ROOT/entrypoint.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-to-repo-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# A pristine HOME keeps a developer's global git config out of the results.
mkdir -p "$TMP/home"

FAILURES=0
CASE_DIR=""

pass() { printf '  ✅ %s\n' "$1"; }
fail() {
	printf '  ❌ %s\n' "$1"
	FAILURES=$((FAILURES + 1))
}
assert_eq() {
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
assert_ok() {
	if [ "$2" = "0" ]; then pass "$1"; else fail "$1 (exited $2)"; fi
}
assert_fails() {
	if [ "$2" != "0" ]; then pass "$1"; else fail "$1 (expected a non-zero exit)"; fi
}

# HEAD is pinned because the runner's init.defaultBranch is not necessarily main.
new_bare_repo() {
	git init --quiet --bare "$1"
	git -C "$1" symbolic-ref HEAD refs/heads/main
}

# Creates a bare repo at <case>/server/acme/site.git with one commit on main.
new_case() {
	CASE_DIR="$TMP/$1"
	printf '\n▶ %s\n' "$1"
	mkdir -p "$CASE_DIR/server/acme" "$CASE_DIR/workspace" "$CASE_DIR/tmp"
	new_bare_repo "$CASE_DIR/server/acme/site.git"

	git init --quiet "$CASE_DIR/seed"
	git -C "$CASE_DIR/seed" checkout --quiet -B main
	git -C "$CASE_DIR/seed" config user.email t@example.com
	git -C "$CASE_DIR/seed" config user.name Tester
	echo "hello" >"$CASE_DIR/seed/README.md"
	git -C "$CASE_DIR/seed" add -A
	git -C "$CASE_DIR/seed" commit --quiet -m "init"
	git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main
}

run_action() {
	local status=0
	: >"$CASE_DIR/output.txt"
	(
		cd "$CASE_DIR/workspace"
		env -i PATH="$PATH" HOME="${env_home:-$TMP/home}" \
			GITHUB_WORKSPACE="$CASE_DIR/workspace" \
			GITHUB_SERVER_URL="file://$CASE_DIR/server" \
			GITHUB_OUTPUT="$CASE_DIR/output.txt" \
			GITHUB_REPOSITORY="acme/source" \
			GITHUB_SHA="0000000000000000000000000000000000000000" \
			RUNNER_TEMP="$CASE_DIR/tmp" \
			INPUT_ACCESS_TOKEN="dummy-token" \
			"$@" sh "$ENTRYPOINT"
	) >"$CASE_DIR/log.txt" 2>&1 || status=$?
	return "$status"
}

output_value() {
	grep "^$1=" "$CASE_DIR/output.txt" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Reads a path out of the pushed branch of the bare repo.
remote_show() {
	git -C "$CASE_DIR/server/acme/site.git" show "$1:$2" 2>/dev/null
}

remote_has() {
	git -C "$CASE_DIR/server/acme/site.git" cat-file -e "$1:$2" 2>/dev/null
}

remote_sha() {
	git -C "$CASE_DIR/server/acme/site.git" rev-parse --verify --quiet "refs/heads/$1" || true
}

# --------------------------------------------------------------------------
new_case "happy path copies files and dotfiles"
mkdir -p "$CASE_DIR/workspace/build/nested"
echo "app" >"$CASE_DIR/workspace/build/app.js"
echo "keep" >"$CASE_DIR/workspace/build/.npmrc"
echo "deep" >"$CASE_DIR/workspace/build/nested/deep.txt"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "app.js is pushed" "$(remote_show main assets/app.js)" "app"
assert_eq "dotfiles are pushed" "$(remote_show main assets/.npmrc)" "keep"
assert_eq "nested files are pushed" "$(remote_show main assets/nested/deep.txt)" "deep"
assert_eq "existing files are kept" "$(remote_show main README.md)" "hello"
assert_eq "pushed output" "$(output_value pushed)" "true"
assert_eq "commit_sha output" "$(output_value commit_sha)" "$(remote_sha main)"
assert_eq "commit message" "$(git -C "$CASE_DIR/server/acme/site.git" log -1 --pretty=%s main)" \
	"Deployed from acme/source@0000000000000000000000000000000000000000"
assert_eq "committer identity" "$(git -C "$CASE_DIR/server/acme/site.git" log -1 --pretty=%an main)" \
	"github-actions[bot]"
assert_eq "workspace has no leftover clone" \
	"$(find "$CASE_DIR/workspace" -mindepth 1 -maxdepth 1 ! -name build)" ""

# --------------------------------------------------------------------------
new_case "target branch is created when missing"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets \
	INPUT_TARGET_BRANCH=release || status=$?
assert_ok "action succeeds" "$status"
assert_eq "file lands on the new branch" "$(remote_show release assets/app.js)" "app"
assert_eq "the new branch keeps the default branch content" "$(remote_show release README.md)" "hello"
assert_eq "main is untouched" "$(remote_sha main)" "$(git -C "$CASE_DIR/seed" rev-parse main)"

# --------------------------------------------------------------------------
new_case "a run without changes pushes nothing"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets
first_sha="$(remote_sha main)"
status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_ok "second run succeeds" "$status"
assert_eq "nothing new is pushed" "$(remote_sha main)" "$first_sha"
assert_eq "pushed output" "$(output_value pushed)" "false"
assert_eq "commit_sha output is the branch tip" "$(output_value commit_sha)" "$first_sha"

# --------------------------------------------------------------------------
new_case "a target_repo without an owner fails without touching the workspace"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"
before_sha="$(remote_sha main)"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=site INPUT_TARGET_DIR=assets \
	INPUT_CLEANUP_COMMAND="rm -rf ./*" || status=$?
assert_fails "action fails" "$status"
assert_eq "the workspace is untouched" "$(cat "$CASE_DIR/workspace/build/app.js")" "app"
assert_eq "nothing is pushed" "$(remote_sha main)" "$before_sha"

# --------------------------------------------------------------------------
new_case "an unreachable target_repo fails without touching the workspace"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/nope INPUT_TARGET_DIR=assets \
	INPUT_CLEANUP_COMMAND="rm -rf ./*" || status=$?
assert_fails "action fails" "$status"
assert_eq "the workspace is untouched" "$(cat "$CASE_DIR/workspace/build/app.js")" "app"

# --------------------------------------------------------------------------
new_case "the legacy target_owner input still works"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_OWNER=acme INPUT_TARGET_REPO=site \
	INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "file is pushed" "$(remote_show main assets/app.js)" "app"

# --------------------------------------------------------------------------
new_case "cleanup_command runs in the clone and the source .git is not copied"
mkdir -p "$CASE_DIR/workspace/build/.git"
echo "app" >"$CASE_DIR/workspace/build/app.js"
echo "source-git-sentinel" >"$CASE_DIR/workspace/build/.git/config"
echo "sentinel" >"$CASE_DIR/workspace/sentinel.txt"

# The precommit command inspects the clone before the trap removes it. Asserting
# on the pushed tree would pass either way, since git refuses to track a .git path.
status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=. \
	INPUT_CLEANUP_COMMAND="rm -f README.md" \
	INPUT_PRECOMMIT_COMMAND="! grep -q source-git-sentinel .git/config && echo generated > generated.txt" || status=$?
assert_ok "the clone .git survives the copy" "$status"
assert_eq "the workspace is untouched" "$(cat "$CASE_DIR/workspace/sentinel.txt")" "sentinel"
assert_eq "precommit output is committed" "$(remote_show main generated.txt)" "generated"
if remote_has main README.md; then fail "cleanup_command removed README.md"; else pass "cleanup_command removed README.md"; fi

# --------------------------------------------------------------------------
new_case "a failing cleanup_command fails the action"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"
before_sha="$(remote_sha main)"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets \
	INPUT_CLEANUP_COMMAND="exit 3" || status=$?
assert_fails "action fails" "$status"
assert_eq "nothing is pushed" "$(remote_sha main)" "$before_sha"

# --------------------------------------------------------------------------
new_case "a missing src_dir fails"
status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_fails "action fails" "$status"

# --------------------------------------------------------------------------
new_case "an escaping target_dir fails"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=../escape || status=$?
assert_fails "action fails" "$status"

# --------------------------------------------------------------------------
new_case "a single file source is copied"
mkdir -p "$CASE_DIR/workspace"
echo "one" >"$CASE_DIR/workspace/file.txt"

status=0
run_action INPUT_SRC_DIR=file.txt INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "the file is pushed" "$(remote_show main assets/file.txt)" "one"

# --------------------------------------------------------------------------
new_case "a history rewrite needs force"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"
git -C "$CASE_DIR/seed" commit --quiet --allow-empty -m "second"
git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main
before_sha="$(remote_sha main)"

# Dropping a commit makes the local branch diverge from the target branch.
status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets \
	INPUT_PRECOMMIT_COMMAND="git reset --soft HEAD~1" || status=$?
assert_fails "a non fast forward push fails without force" "$status"
assert_eq "the target branch is untouched" "$(remote_sha main)" "$before_sha"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets INPUT_FORCE=true \
	INPUT_PRECOMMIT_COMMAND="git reset --soft HEAD~1" || status=$?
assert_ok "a forced push succeeds" "$status"
assert_eq "the file is pushed" "$(remote_show main assets/app.js)" "app"
assert_eq "the dropped commit is gone" "$(git -C "$CASE_DIR/server/acme/site.git" rev-list --count main)" "2"

# --------------------------------------------------------------------------
new_case "force does not discard a concurrent push"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

# Push to the target branch after the action has cloned it.
status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets INPUT_FORCE=true \
	INPUT_PRECOMMIT_COMMAND="git -C '$CASE_DIR/seed' commit --quiet --allow-empty -m meanwhile && git -C '$CASE_DIR/seed' push --quiet '$CASE_DIR/server/acme/site.git' main" || status=$?
assert_fails "the lease rejects the forced push" "$status"
assert_eq "the concurrent commit survives" "$(git -C "$CASE_DIR/server/acme/site.git" log -1 --pretty=%s main)" "meanwhile"

# --------------------------------------------------------------------------
new_case "an empty target repository gets the branch created"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"
new_bare_repo "$CASE_DIR/server/acme/empty.git"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/empty INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "the file is pushed" \
	"$(git -C "$CASE_DIR/server/acme/empty.git" show main:assets/app.js)" "app"

# --------------------------------------------------------------------------
new_case "the clone is removed from the runner temp directory"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets
assert_eq "no clone is left behind on success" "$(find "$CASE_DIR/tmp" -mindepth 1)" ""

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets \
	INPUT_CLEANUP_COMMAND="exit 1" || status=$?
assert_fails "action fails" "$status"
assert_eq "no clone is left behind on failure" "$(find "$CASE_DIR/tmp" -mindepth 1)" ""

# --------------------------------------------------------------------------
new_case "a failure anywhere in a user command fails the action"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"
before_sha="$(remote_sha main)"

# The failing command is not the last one, so a subshell with `set -e` suppressed
# would report success.
status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets \
	INPUT_CLEANUP_COMMAND="false; echo continued" || status=$?
assert_fails "cleanup_command fails" "$status"
assert_eq "nothing is pushed" "$(remote_sha main)" "$before_sha"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets \
	INPUT_PRECOMMIT_COMMAND="false; echo continued" || status=$?
assert_fails "precommit_command fails" "$status"
assert_eq "nothing is pushed" "$(remote_sha main)" "$before_sha"

# --------------------------------------------------------------------------
new_case "the token is not visible to user commands"
# The bracket keeps the pattern from matching the command string in the environment.
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets \
	INPUT_PRECOMMIT_COMMAND="! env | grep -q 'dummy[-]token'" || status=$?
assert_ok "no environment variable carries the token" "$status"

# --------------------------------------------------------------------------
new_case "a symlinked target_dir cannot escape the clone"
mkdir -p "$CASE_DIR/workspace/build" "$CASE_DIR/outside"
echo "app" >"$CASE_DIR/workspace/build/app.js"
echo "untouched" >"$CASE_DIR/outside/app.js"

# A target repository that points its deploy directory outside the clone.
ln -s "$CASE_DIR/outside" "$CASE_DIR/seed/assets"
git -C "$CASE_DIR/seed" add -A
git -C "$CASE_DIR/seed" commit --quiet -m "symlink"
git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_fails "action fails" "$status"
assert_eq "the file outside the clone is untouched" "$(cat "$CASE_DIR/outside/app.js")" "untouched"

# --------------------------------------------------------------------------
new_case "target_owner is ignored when target_repo names an owner"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_OWNER=ignored INPUT_TARGET_REPO=acme/site \
	INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "the file is pushed" "$(remote_show main assets/app.js)" "app"

# --------------------------------------------------------------------------
new_case "an empty source directory pushes nothing"
mkdir -p "$CASE_DIR/workspace/build"
before_sha="$(remote_sha main)"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "nothing is pushed" "$(remote_sha main)" "$before_sha"
assert_eq "pushed output" "$(output_value pushed)" "false"

# --------------------------------------------------------------------------
new_case "paths with spaces and glob characters work"
mkdir -p "$CASE_DIR/workspace/my build[1]"
echo "app" >"$CASE_DIR/workspace/my build[1]/my app.js"

status=0
run_action INPUT_SRC_DIR="my build[1]" INPUT_TARGET_REPO=acme/site \
	INPUT_TARGET_DIR="my assets[1]" || status=$?
assert_ok "action succeeds" "$status"
assert_eq "the file is pushed" "$(remote_show main "my assets[1]/my app.js")" "app"

# --------------------------------------------------------------------------
new_case "a failed clone leaves no temporary directory"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/nope INPUT_TARGET_DIR=assets || status=$?
assert_fails "action fails" "$status"
assert_eq "no clone is left behind" "$(find "$CASE_DIR/tmp" -mindepth 1)" ""

# --------------------------------------------------------------------------
new_case "a nested symlink in the target cannot redirect the copy"
mkdir -p "$CASE_DIR/workspace/build/tree" "$CASE_DIR/outside"
echo "app" >"$CASE_DIR/workspace/build/tree/victim"
echo "untouched" >"$CASE_DIR/outside/victim"

# The copy merges into an existing directory, so the symlink is one level below
# target_dir and a check on target_dir alone would not see it.
mkdir -p "$CASE_DIR/seed/assets/tree"
ln -s "$CASE_DIR/outside/victim" "$CASE_DIR/seed/assets/tree/victim"
git -C "$CASE_DIR/seed" add -A
git -C "$CASE_DIR/seed" commit --quiet -m "nested symlink"
git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "the file outside the clone is untouched" "$(cat "$CASE_DIR/outside/victim")" "untouched"
assert_eq "the symlink is replaced by the copied file" "$(remote_show main assets/tree/victim)" "app"

# --------------------------------------------------------------------------
new_case "a glob in target_dir is not expanded against the clone"
mkdir -p "$CASE_DIR/workspace/build" "$CASE_DIR/outside"
echo "app" >"$CASE_DIR/workspace/build/app.js"

# `li*` would expand to the real `linker` directory if the path were globbed.
mkdir -p "$CASE_DIR/seed/safe" "$CASE_DIR/seed/linker"
echo "placeholder" >"$CASE_DIR/seed/linker/.keep"
ln -s "$CASE_DIR/outside" "$CASE_DIR/seed/safe/linker"
git -C "$CASE_DIR/seed" add -A
git -C "$CASE_DIR/seed" commit --quiet -m "glob bait"
git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR='safe/li*/new' || status=$?
assert_ok "action succeeds" "$status"
assert_eq "nothing is created outside the clone" "$(find "$CASE_DIR/outside" -mindepth 1)" ""
assert_eq "the literal path is used" "$(remote_show main 'safe/li*/new/app.js')" "app"

# --------------------------------------------------------------------------
new_case "a push hook cannot inherit the credentials"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets \
	INPUT_PRECOMMIT_COMMAND="printf '#!/bin/sh\nenv >$TMP/hook-env.txt\n' >.git/hooks/pre-push && chmod +x .git/hooks/pre-push && mkdir -p ../hooks && cp .git/hooks/pre-push ../hooks/pre-push && git config core.hooksPath ../hooks" || status=$?
assert_ok "action succeeds" "$status"
# $TMP has no spaces, so the hook's own redirect cannot fail for the wrong reason.
if [ -e "$TMP/hook-env.txt" ]; then
	fail "the hook did not run (it saw $(grep -c GIT_CONFIG "$TMP/hook-env.txt") credential variables)"
else
	pass "the hook did not run"
fi

# --------------------------------------------------------------------------
new_case "an exported token variable is not reused"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

# The caller exports the names the script assigns to; they must not stay exported.
status=0
run_action ACCESS_TOKEN=placeholder AUTH_HEADER=placeholder \
	INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets \
	INPUT_PRECOMMIT_COMMAND="! env | grep -q 'dummy[-]token'" || status=$?
assert_ok "the token does not reach the command" "$status"

# --------------------------------------------------------------------------
new_case "target_owner is ignored even when it is not a valid name"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_OWNER="bad/owner" INPUT_TARGET_REPO=acme/site \
	INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "the file is pushed" "$(remote_show main assets/app.js)" "app"

# --------------------------------------------------------------------------
new_case "a traversing repository name is rejected"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO="acme/../site" INPUT_TARGET_DIR=assets || status=$?
assert_fails "a dot dot component fails" "$status"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_OWNER=".." INPUT_TARGET_REPO=site INPUT_TARGET_DIR=assets || status=$?
assert_fails "a dot dot owner fails" "$status"

# --------------------------------------------------------------------------
new_case "a src_dir outside the workspace is rejected"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR="../outside" INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_fails "a relative escape fails" "$status"

status=0
run_action INPUT_SRC_DIR="/etc" INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_fails "an absolute path fails" "$status"

# --------------------------------------------------------------------------
new_case "target_dir cannot write into the git metadata"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/config"
before_sha="$(remote_sha main)"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=.git || status=$?
assert_fails "action fails" "$status"
assert_eq "nothing is pushed" "$(remote_sha main)" "$before_sha"

# --------------------------------------------------------------------------
new_case "an ignored target_dir fails instead of deploying nothing"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"
echo "assets/" >"$CASE_DIR/seed/.gitignore"
git -C "$CASE_DIR/seed" add -A
git -C "$CASE_DIR/seed" commit --quiet -m "ignore assets"
git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main
before_sha="$(remote_sha main)"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_fails "action fails" "$status"
assert_eq "nothing is pushed" "$(remote_sha main)" "$before_sha"

# --------------------------------------------------------------------------
new_case "a submodule at target_dir fails instead of swallowing the copy"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"
new_bare_repo "$CASE_DIR/server/acme/sub.git"
git init --quiet "$CASE_DIR/sub"
git -C "$CASE_DIR/sub" checkout --quiet -B main
git -C "$CASE_DIR/sub" config user.email t@example.com
git -C "$CASE_DIR/sub" config user.name Tester
echo "sub" >"$CASE_DIR/sub/file.txt"
git -C "$CASE_DIR/sub" add -A
git -C "$CASE_DIR/sub" commit --quiet -m "sub"
git -C "$CASE_DIR/sub" push --quiet "$CASE_DIR/server/acme/sub.git" main
git -C "$CASE_DIR/seed" -c protocol.file.allow=always submodule --quiet add "$CASE_DIR/server/acme/sub.git" assets
git -C "$CASE_DIR/seed" commit --quiet -m "add submodule"
git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main
before_sha="$(remote_sha main)"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_fails "action fails" "$status"
assert_eq "nothing is pushed" "$(remote_sha main)" "$before_sha"

# --------------------------------------------------------------------------
new_case "a symlinked src_dir cannot leave the workspace"
mkdir -p "$CASE_DIR/secrets"
echo "TOPSECRET" >"$CASE_DIR/secrets/id_rsa"
ln -s "$CASE_DIR/secrets" "$CASE_DIR/workspace/build"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_fails "action fails" "$status"
if remote_has main assets/id_rsa; then fail "the secret is not deployed"; else pass "the secret is not deployed"; fi

# --------------------------------------------------------------------------
new_case "a newline in a source name cannot reach outside target_dir"
mkdir -p "$CASE_DIR/workspace/build/$(printf 'foo\n..')"
echo "app" >"$CASE_DIR/workspace/build/$(printf 'foo\n..')/bar"
mkdir -p "$CASE_DIR/outside"
echo "untouched" >"$CASE_DIR/outside/bar"

# A guard that read find's output as lines would probe "$DEST_PATH/../bar".
ln -s "$CASE_DIR/outside/bar" "$CASE_DIR/seed/bar"
git -C "$CASE_DIR/seed" add -A
git -C "$CASE_DIR/seed" commit --quiet -m "sibling symlink"
git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "the sibling symlink survives" "$(remote_show main bar)" "$CASE_DIR/outside/bar"
assert_eq "the file outside is untouched" "$(cat "$CASE_DIR/outside/bar")" "untouched"

# --------------------------------------------------------------------------
new_case "a missing branch is created even when nothing changed"
mkdir -p "$CASE_DIR/workspace/build"
echo "hello" >"$CASE_DIR/workspace/build/README.md"

# The copy reproduces the default branch exactly, so there is nothing to commit.
status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=. \
	INPUT_TARGET_BRANCH=release || status=$?
assert_ok "action succeeds" "$status"
assert_eq "the branch is created" "$(remote_show release README.md)" "hello"
assert_eq "pushed output" "$(output_value pushed)" "true"

# --------------------------------------------------------------------------
new_case "hostile git trace settings do not print the token"
mkdir -p "$CASE_DIR/workspace/build" "$CASE_DIR/home"
echo "app" >"$CASE_DIR/workspace/build/app.js"
cat >"$CASE_DIR/home/.gitconfig" <<'GITCONFIG'
[trace2]
	configparams = http.*
	normalTarget = 2
GITCONFIG

status=0
env_home="$CASE_DIR/home" run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site \
	INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
if grep -q 'dummy[-]token\|eC1hY2Nlc3MtdG9rZW4' "$CASE_DIR/log.txt"; then
	fail "the log does not carry the credential"
else
	pass "the log does not carry the credential"
fi

# --------------------------------------------------------------------------
new_case "a renamed default remote does not confuse the branch check"
mkdir -p "$CASE_DIR/workspace/build" "$CASE_DIR/home"
echo "app" >"$CASE_DIR/workspace/build/app.js"
printf '[clone]\n\tdefaultRemoteName = upstream\n' >"$CASE_DIR/home/.gitconfig"

status=0
env_home="$CASE_DIR/home" run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site \
	INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "the file is pushed to the existing branch" "$(remote_show main assets/app.js)" "app"
assert_eq "the existing content is kept" "$(remote_show main README.md)" "hello"

# --------------------------------------------------------------------------
new_case "a trailing slash on src_dir keeps the symlink guard working"
mkdir -p "$CASE_DIR/workspace/build/tree" "$CASE_DIR/outside"
echo "app" >"$CASE_DIR/workspace/build/tree/victim"
echo "untouched" >"$CASE_DIR/outside/victim"

mkdir -p "$CASE_DIR/seed/assets/tree"
ln -s "$CASE_DIR/outside/victim" "$CASE_DIR/seed/assets/tree/victim"
git -C "$CASE_DIR/seed" add -A
git -C "$CASE_DIR/seed" commit --quiet -m "nested symlink"
git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main

status=0
run_action INPUT_SRC_DIR="build/" INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_ok "action succeeds" "$status"
assert_eq "the file outside the clone is untouched" "$(cat "$CASE_DIR/outside/victim")" "untouched"
assert_eq "the symlink is replaced by the copied file" "$(remote_show main assets/tree/victim)" "app"

# --------------------------------------------------------------------------
new_case "a nested ignore pattern fails instead of deploying nothing"
mkdir -p "$CASE_DIR/workspace/build/sub"
echo "app" >"$CASE_DIR/workspace/build/sub/app.js"
echo "assets/sub/*" >"$CASE_DIR/seed/.gitignore"
git -C "$CASE_DIR/seed" add -A
git -C "$CASE_DIR/seed" commit --quiet -m "ignore nested"
git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main
before_sha="$(remote_sha main)"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets || status=$?
assert_fails "action fails" "$status"
assert_eq "nothing is pushed" "$(remote_sha main)" "$before_sha"

# --------------------------------------------------------------------------
new_case "a submodule hidden behind a glob name is still found"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"
new_bare_repo "$CASE_DIR/server/acme/sub.git"
git init --quiet "$CASE_DIR/sub"
git -C "$CASE_DIR/sub" checkout --quiet -B main
git -C "$CASE_DIR/sub" config user.email t@example.com
git -C "$CASE_DIR/sub" config user.name Tester
echo "sub" >"$CASE_DIR/sub/file.txt"
git -C "$CASE_DIR/sub" add -A
git -C "$CASE_DIR/sub" commit --quiet -m "sub"
git -C "$CASE_DIR/sub" push --quiet "$CASE_DIR/server/acme/sub.git" main

# "z0" sorts first, so reading only the first pathspec match would miss "z?".
echo "keep" >"$CASE_DIR/seed/z0"
git -C "$CASE_DIR/seed" -c protocol.file.allow=always submodule --quiet add "$CASE_DIR/server/acme/sub.git" 'z?'
git -C "$CASE_DIR/seed" add -A
git -C "$CASE_DIR/seed" commit --quiet -m "add submodule"
git -C "$CASE_DIR/seed" push --quiet "$CASE_DIR/server/acme/site.git" main
before_sha="$(remote_sha main)"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR='z?' || status=$?
assert_fails "action fails" "$status"
assert_eq "nothing is pushed" "$(remote_sha main)" "$before_sha"

# --------------------------------------------------------------------------
new_case "cleanup_command cannot repoint src_dir out of the workspace"
mkdir -p "$CASE_DIR/workspace/build" "$CASE_DIR/secrets"
echo "app" >"$CASE_DIR/workspace/build/app.js"
echo "TOPSECRET" >"$CASE_DIR/secrets/id_rsa"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets \
	INPUT_CLEANUP_COMMAND="rm -rf '$CASE_DIR/workspace/build' && ln -s '$CASE_DIR/secrets' '$CASE_DIR/workspace/build'" || status=$?
assert_fails "action fails" "$status"
if remote_has main assets/id_rsa; then fail "the secret is not deployed"; else pass "the secret is not deployed"; fi

# --------------------------------------------------------------------------
new_case "an uppercase .git target_dir is rejected"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/config"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=.GIT || status=$?
assert_fails "action fails" "$status"

# --------------------------------------------------------------------------
new_case "an invalid force value fails"
mkdir -p "$CASE_DIR/workspace/build"
echo "app" >"$CASE_DIR/workspace/build/app.js"

status=0
run_action INPUT_SRC_DIR=build INPUT_TARGET_REPO=acme/site INPUT_TARGET_DIR=assets INPUT_FORCE=yes || status=$?
assert_fails "action fails" "$status"

printf '\n'
if [ "$FAILURES" -gt 0 ]; then
	printf '%s test(s) failed\n' "$FAILURES"
	exit 1
fi
printf 'All tests passed\n'
