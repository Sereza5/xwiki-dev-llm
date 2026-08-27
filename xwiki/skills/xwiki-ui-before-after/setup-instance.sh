#!/usr/bin/env bash
# Build a module at a given git ref and hot-swap it into a local XWiki test instance,
# so a before/after UI screenshot comparison can be captured against real running code.
#
# Usage:
#   setup-instance.sh [--verify jarHint:pathInJar:pattern ...] \
#     <instance-dir> <module-dir> <git-ref-or-HEAD> [extra-module-dir ...]
#
# --verify          Optional, repeatable. After swapping jars, independently confirm the swap
#                   landed by grepping inside the deployed jar - don't just trust the script's
#                   own echoed progress (that's easy to lose track of, e.g. if you piped/buffered
#                   the output). "jarHint" is a substring matching the deployed jar's filename
#                   under webapps/xwiki/WEB-INF/lib (e.g. "tree-webjar"), "pathInJar" is the path
#                   to a resource/class inside that jar (e.g.
#                   META-INF/resources/webjars/xwiki-platform-tree-webjar/*/finder.js - globs
#                   are expanded against the jar's own file list), and "pattern" is a grep -q
#                   pattern that must match its content. Fails the whole script (exit 1) if any
#                   verify spec doesn't match, so a silently-failed swap can't slip through.
#                   Example: --verify 'tree-webjar:META-INF/resources/webjars/xwiki-platform-tree-webjar/*/finder.js:xwiki-icon'
# <instance-dir>   path to a XWiki jetty+hsqldb distribution root (contains start_xwiki.sh).
#                   If it doesn't exist yet, copy one from an existing test distribution of the
#                   SAME xwiki version first (see SKILL.md step 0).
# <module-dir>      path to the maven module whose fix you're comparing (e.g.
#                   xwiki-platform-core/xwiki-platform-oldcore). Built with -DskipTests so its
#                   test-jar (if any downstream module needs it) is still produced.
# <git-ref-or-HEAD> "HEAD" to build the current working tree as-is, or a commit-ish (e.g. the
#                   commit before your fix) to build via a throwaway git worktree, left in
#                   <repo>/.git/xwiki-ui-before-after-worktree and cleaned up automatically.
# extra-module-dir  Additional modules to build and swap, in the order given. Needed whenever a
#                   -legacy module weaves the module you changed: the woven jar is what ships in
#                   WEB-INF/lib, so the original alone changes nothing on screen. The xwiki-build
#                   skill owns that rule and how to spot such a module; the common case is a fix
#                   in xwiki-platform-oldcore, which needs
#                   xwiki-platform-core/xwiki-platform-legacy/xwiki-platform-legacy-oldcore
#                   passed here. If a screenshot doesn't reflect your change, unzip -l the jars in
#                   WEB-INF/lib and grep for your changed .class to see which one ships it.
#
# Progress log: every run tees its full output to <instance-dir>/setup-instance.log (truncated
# each run). Keep <instance-dir> outside any git-tracked checkout (see $XWIKI_TEST_INSTANCES_DIR
# in SKILL.md step 0), so this never shows up as an untracked/dirty file in the repo under
# comparison or in this skill's own directory. Follow it live with `tail -f <instance-dir>/setup-instance.log`
# (e.g. via the Monitor tool) instead of piping this script's own stdout through anything -
# piping through a non-`-f` `tail -N` or similar summarizer buffers ALL output until the whole
# script exits, which defeats the purpose of watching it live.
set -euo pipefail

# Print this script's own header comment as the usage text, so `--help` and a missing argument
# both explain the interface instead of dying on an unbound variable.
usage() {
  sed -n '2,${/^#/!q; s/^#\( \|$\)//; p}' "$0"
  exit "${1:-1}"
}
if [[ "${1:-}" == -h || "${1:-}" == --help || $# -eq 0 ]]; then usage 0; fi

# Build with the JDK the branch targets, per the xwiki-build skill: xmvn (from xwiki-dev-tools)
# reads xwiki.java.version from the pom, exports the matching JAVA_HOME, then delegates to mvn.
# It matters more here than in a normal build, since this script deliberately builds OLD commits,
# which are the ones most likely to target an older Java than the machine default. Without it a
# too-new JDK fails in ways that read as code problems and are not - see xwiki-build for how to
# select the JDK by hand when xmvn is not installed.
if command -v xmvn >/dev/null 2>&1; then
  MVN=xmvn
else
  MVN=mvn
fi

VERIFY_SPECS=()
while [[ "${1:-}" == --verify ]]; do
  VERIFY_SPECS+=("$2")
  shift 2
done

if [ $# -lt 3 ]; then
  echo "ERROR: expected <instance-dir> <module-dir> <git-ref-or-HEAD> [extra-module-dir ...]" >&2
  echo >&2
  usage 1 >&2
fi

INSTANCE_DIR="$1"
MODULE_DIR="$2"
GIT_REF="$3"
shift 3
EXTRA_MODULES=("$@")

mkdir -p "$INSTANCE_DIR"
exec > >(tee "$INSTANCE_DIR/setup-instance.log") 2>&1

REPO_ROOT="$(cd "$MODULE_DIR" && git rev-parse --show-toplevel)"
# Not "$REPO_ROOT/.git": in a LINKED worktree that is a *file* pointing at the real git dir, so
# creating anything underneath it fails with "Not a directory". --git-common-dir resolves to the
# shared git directory from a main checkout and a linked worktree alike. cd+pwd because git may
# answer with a path relative to the module directory.
GIT_COMMON_DIR="$(cd "$MODULE_DIR" && cd "$(git rev-parse --git-common-dir)" && pwd)"
WORKTREE_DIR="$GIT_COMMON_DIR/xwiki-ui-before-after-worktree"

build_module() {
  local dir="$1"
  echo "--- building $dir ---"
  (cd "$dir" && "$MVN" -q clean install -DskipTests \
    -Dxwiki.revapi.skip=true -Dspoon.skip=true -Dcheckstyle.skip=true \
    -Dspotbugs.skip=true -Dlicense.skip=true)
}

if [ "$GIT_REF" = "HEAD" ]; then
  build_module "$MODULE_DIR"
  for m in "${EXTRA_MODULES[@]:-}"; do
    [ -n "$m" ] && build_module "$m"
  done
else
  echo "--- creating worktree at $GIT_REF ---"
  git -C "$REPO_ROOT" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
  REL_MODULE="${MODULE_DIR#"$REPO_ROOT"/}"
  REL_EXTRAS=()
  for m in "${EXTRA_MODULES[@]:-}"; do
    [ -n "$m" ] && REL_EXTRAS+=("${m#"$REPO_ROOT"/}")
  done
  # Sparse + no-checkout: a full worktree add here would materialize the ENTIRE repo (10k+
  # files) just to build one small module, which is both slow and spews a huge "Updating
  # files: N%" progress dump into any captured/piped output. Cone-mode sparse-checkout limits
  # the actual checkout to the module(s) we're building plus each ancestor directory's own
  # files (pom.xml at every level of the reactor), which is all a `cd module && mvn` build needs.
  git -C "$REPO_ROOT" worktree add --quiet --no-checkout "$WORKTREE_DIR" "$GIT_REF"
  git -C "$WORKTREE_DIR" sparse-checkout init --cone
  git -C "$WORKTREE_DIR" sparse-checkout set "$REL_MODULE" "${REL_EXTRAS[@]:-}"
  git -C "$WORKTREE_DIR" checkout --quiet "$GIT_REF"
  build_module "$WORKTREE_DIR/$REL_MODULE"
  for REL_EXTRA in "${REL_EXTRAS[@]:-}"; do
    [ -n "$REL_EXTRA" ] && build_module "$WORKTREE_DIR/$REL_EXTRA"
  done
  git -C "$REPO_ROOT" worktree remove "$WORKTREE_DIR" --force
fi

echo "--- stopping instance (if running) ---"
(cd "$INSTANCE_DIR" && java -jar ./jetty/start.jar STOP.KEY=xwiki STOP.PORT=8079 --stop) || true
sleep 2

echo "--- swapping jar(s) into $INSTANCE_DIR ---"
# Don't scrape pom.xml with grep/sed for the artifactId/version: a pom's FIRST <artifactId>/
# <version> tags belong to its <parent> block, and even after skipping that, dependency/plugin
# declarations further down can have their own <version> tags that a naive first-match grep
# picks up instead of the project's own (which may not even have an explicit <version> tag at
# all if it inherits the parent's). Ask Maven itself instead - it's the only thing that
# actually resolves inheritance correctly.
evaluate() {
  # -o (offline) first since it's faster and works once maven-help-plugin is cached; fall back
  # to online on the first-ever run on a machine that doesn't have it yet.
  (cd "$1" && "$MVN" -q -o help:evaluate -Dexpression="$2" -DforceStdout 2>/dev/null) \
    || (cd "$1" && "$MVN" -q help:evaluate -Dexpression="$2" -DforceStdout)
}
# For each --verify spec, run it against the jar of whichever module's ARTIFACT_ID contains
# the spec's jarHint - tying verification to the exact jar this run just swapped, rather than
# re-searching WEB-INF/lib after the fact (which can ambiguously match an unrelated jar whose
# artifactId happens to contain the same substring, e.g. "tree-webjar" also matching
# "xwiki-platform-index-tree-webjar").
VERIFIED_SPECS=()
verify_against() {
  local target="$1" path_in_jar="$2" pattern="$3"
  local entry
  # path_in_jar may contain a glob (e.g. .../18.6.0-SNAPSHOT/finder.js) - resolve it against the
  # jar's own file list rather than assuming the exact version-numbered path.
  entry="$(unzip -Z1 "$target" | grep -x -- "$(echo "$path_in_jar" | sed 's/\*/[^\/]*/g')" | head -1)"
  if [ -z "$entry" ]; then
    echo "VERIFY FAILED: no entry matching $path_in_jar in $target" >&2
    exit 1
  fi
  if unzip -p "$target" "$entry" | grep -q -- "$pattern"; then
    echo "verified $target:$entry matches /$pattern/"
  else
    echo "VERIFY FAILED: $target:$entry does not match /$pattern/ - the swap did not land the expected code" >&2
    exit 1
  fi
}

ALL_MODULES=("$MODULE_DIR" "${EXTRA_MODULES[@]:-}")
for m in "${ALL_MODULES[@]}"; do
  [ -z "$m" ] && continue
  ARTIFACT_ID="$(evaluate "$m" project.artifactId)"
  VERSION="$(evaluate "$m" project.version)"
  JAR="$HOME/.m2/repository/org/xwiki/platform/$ARTIFACT_ID/$VERSION/$ARTIFACT_ID-$VERSION.jar"
  TARGET="$INSTANCE_DIR/webapps/xwiki/WEB-INF/lib/$ARTIFACT_ID-$VERSION.jar"
  if [ -f "$TARGET" ]; then
    cp "$JAR" "$TARGET"
    echo "swapped $ARTIFACT_ID-$VERSION.jar"
  else
    echo "WARNING: $TARGET does not exist in the instance - this module's jar isn't deployed there under this name. Check WEB-INF/lib manually (unzip -l + grep for your class)." >&2
  fi
  for i in "${!VERIFY_SPECS[@]}"; do
    spec="${VERIFY_SPECS[$i]}"
    JAR_HINT="${spec%%:*}"
    case "$ARTIFACT_ID" in
      *"$JAR_HINT"*)
        REST="${spec#*:}"
        verify_against "$TARGET" "${REST%%:*}" "${REST#*:}"
        VERIFIED_SPECS+=("$i")
        ;;
    esac
  done
done

if [ "${#VERIFY_SPECS[@]}" -gt "${#VERIFIED_SPECS[@]}" ]; then
  echo "VERIFY FAILED: some --verify specs didn't match any swapped module's artifactId - check the jarHint" >&2
  exit 1
fi

echo "--- starting instance ---"
# setsid is required, not just nohup: nohup only ignores SIGHUP, it does NOT move the process
# into its own session. Without setsid, the long-running XWiki JVM stays a direct descendant
# of whatever shell invoked this script - if that shell's stdout is being captured by a tool
# (e.g. piped through `tail`, or tracked as a background job), the tool will consider itself
# "still running" for as long as the JVM lives, which is indefinitely. setsid + input from
# /dev/null fully detaches it into a new session so this script returns promptly once the
# instance is up, while the server keeps running independently.
(cd "$INSTANCE_DIR" && setsid nohup ./start_xwiki.sh < /dev/null > "$INSTANCE_DIR/boot.log" 2>&1 &)

echo "--- waiting for instance to come up ---"
for i in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/xwiki/bin/view/Main/WebHome 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then
    echo "instance is up (attempt $i)"
    exit 0
  fi
  sleep 3
done
echo "WARNING: instance did not come up within the timeout - check $INSTANCE_DIR/boot.log" >&2
exit 1
