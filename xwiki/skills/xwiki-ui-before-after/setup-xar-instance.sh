#!/usr/bin/env bash
# Build a XAR-packaged module (wiki pages, not classes) at a given git ref and deploy it into a
# running local XWiki instance via the raw wiki Import feature - the XAR equivalent of
# setup-instance.sh's jar-swap, for modules like xwiki-platform-annotation-ui where
# <packaging>xar</packaging> means there is no jar to copy into WEB-INF/lib.
#
# Why not the Extension Manager: its install job cross-checks the XAR's declared dependency
# versions against the instance's bundled core jars, and fails outright
# ("InstallException: Dependency [...] is not compatible with core extension feature [...]") the
# moment your branch's ${project.version} has drifted from the cached test instance's version
# (e.g. after a rebase bumped 18.6.0-SNAPSHOT -> 18.7.0-SNAPSHOT). This script bypasses all of
# that by uploading the XAR as a plain attachment and using the classic Administration > Import
# page flow, which just overwrites the named wiki documents directly - no dependency graph
# involved.
#
# Usage:
#   setup-xar-instance.sh [--base-url http://localhost:8080] [--user Admin:admin] \
#     [--verify pathInXar:pattern ...] \
#     <module-dir> <git-ref-or-HEAD> [extra-module-dir ...]
#
# --base-url        Optional, default http://localhost:8080. The already-RUNNING instance to
#                    deploy into (this script does not start/stop the server - it only pushes
#                    wiki-page content over HTTP, so the target instance must already be up).
# --user             Optional, default Admin:admin. HTTP Basic credentials - Basic auth is fine
#                    for this Import-page flow (unlike annotation-rest's POST endpoint, which
#                    rejected it - see SKILL.md's CSRF gotcha for why that one needs a real
#                    browser session instead).
# --verify           Optional, repeatable. After each module's XAR is imported, independently
#                    confirm it landed by re-exporting the given page as a XAR and grepping its
#                    content - don't just trust "N Page(s) installed" (that count is real, but
#                    says nothing about whether it's actually YOUR content vs. a same-named page
#                    from a stale prior run). Format: "Space.Page:pattern", e.g.
#                    "AnnotationCode.Style:annotation-bubble-tools". Fails the whole script
#                    (exit 1) if any verify spec doesn't match.
# <module-dir>       path to the maven module to build (e.g.
#                    xwiki-platform-core/xwiki-platform-annotation/xwiki-platform-annotation-ui).
#                    Its pom.xml must have <packaging>xar</packaging>.
# <git-ref-or-HEAD>  "HEAD" to build the current working tree as-is, or a commit-ish (e.g. the
#                    commit before your fix) to build via a throwaway git worktree, left in
#                    <repo>/.git/xwiki-ui-before-after-worktree and cleaned up automatically.
# extra-module-dir   Additional XAR modules to build+import the same way (e.g. a translations-only
#                    submodule). Each is built and imported independently in the order given.
#
# Companion for non-XAR static resources (skin CSS/JS served straight from webapps/xwiki/resources,
# e.g. flamingo's comments.css): use sync-static-resource.sh instead - those aren't wiki pages at
# all and don't go through Import.
set -euo pipefail

BASE_URL="http://localhost:8080"
XWIKI_USER="Admin:admin"
VERIFY_SPECS=()

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2 ;;
    --user) XWIKI_USER="$2"; shift 2 ;;
    --verify) VERIFY_SPECS+=("$2"); shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

MODULE_DIR="$1"
GIT_REF="$2"
shift 2
EXTRA_MODULES=("$@")
ALL_MODULES=("$MODULE_DIR")
# "${EXTRA_MODULES[@]:-}" expands to a single empty-string element when the array is genuinely
# empty (a classic bash gotcha under `set -u`), which would silently create a phantom "module" -
# guard with the length check instead.
if [ "${#EXTRA_MODULES[@]}" -gt 0 ]; then
  ALL_MODULES+=("${EXTRA_MODULES[@]}")
fi

REPO_ROOT="$(cd "$MODULE_DIR" && git rev-parse --show-toplevel)"
WORKTREE_DIR="$REPO_ROOT/.git/xwiki-ui-before-after-worktree"
COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

build_module() {
  local dir="$1"
  echo "--- building $dir ---"
  (cd "$dir" && mvn -q clean package -DskipTests \
    -Dxwiki.revapi.skip=true -Dspoon.skip=true -Dcheckstyle.skip=true \
    -Dspotbugs.skip=true -Dlicense.skip=true)
}

evaluate() {
  (cd "$1" && mvn -q -o help:evaluate -Dexpression="$2" -DforceStdout 2>/dev/null) \
    || (cd "$1" && mvn -q help:evaluate -Dexpression="$2" -DforceStdout)
}

# A fresh form_token has to come from a real rendered page - it's session-bound, and a stale one
# copy-pasted from an earlier curl fetch (or from a different session) is silently rejected by
# the Import action with "Invalid or missing form token", not a helpful "expired" message.
fetch_form_token() {
  curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" --user "$XWIKI_USER" \
    "$BASE_URL/xwiki/bin/admin/XWiki/XWikiPreferences?editor=globaladmin&section=Import" \
  | grep -o 'name="form_token" type="hidden" value="[^"]*"' | head -1 \
  | sed 's/.*value="//;s/"$//'
}

import_xar() {
  local xar_path="$1" xar_name
  xar_name="$(basename "$xar_path")"

  echo "--- uploading $xar_name ---"
  local token
  token="$(fetch_form_token)"
  curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" --user "$XWIKI_USER" \
    -F "form_token=$token" \
    -F "filepath=@${xar_path};type=application/octet-stream" \
    -F "filename=" \
    -F "xredirect=/xwiki/bin/admin/XWiki/XWikiPreferences?editor=globaladmin&section=Import" \
    "$BASE_URL/xwiki/bin/upload/XWiki/XWikiPreferences" -o /dev/null -w "  upload HTTP %{http_code}\n"

  echo "--- listing pages in $xar_name ---"
  # The Import detail page pre-checks every page in the XAR (including per-locale translation
  # variants like "AnnotationCode.Translations:ca") - re-derive the exact list from its own
  # checkboxes rather than assuming a fixed page set, since that varies per module.
  local detail_html pages_file
  detail_html="$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" --user "$XWIKI_USER" \
    "$BASE_URL/xwiki/bin/import/XWiki/XWikiPreferences?editor=globaladmin&section=Import&file=${xar_name}")"
  pages_file="$(mktemp)"
  grep -o 'name="pages" type="checkbox" value="[^"]*"' <<<"$detail_html" \
    | sed 's/.*value="//;s/"$//' > "$pages_file"
  local page_count
  page_count="$(wc -l < "$pages_file")"
  if [ "$page_count" -eq 0 ]; then
    echo "ERROR: no pages found in the uploaded XAR's import-detail page - upload likely failed" >&2
    rm -f "$pages_file"
    exit 1
  fi
  echo "  found $page_count page(s)"

  echo "--- importing $xar_name ---"
  token="$(fetch_form_token)"
  local curl_args=(-s -b "$COOKIE_JAR" -c "$COOKIE_JAR" --user "$XWIKI_USER"
    -F "form_token=$token" -F "action=import" -F "name=${xar_name}")
  while IFS= read -r p; do
    curl_args+=(-F "pages=$p")
  done < "$pages_file"
  rm -f "$pages_file"

  local result
  result="$(curl "${curl_args[@]}" "$BASE_URL/xwiki/bin/import/XWiki/XWikiPreferences?editor=globaladmin&section=Import")"
  local installed errors
  installed="$(grep -o '<li>[0-9]* Page(s) installed</li>' <<<"$result" | grep -o '[0-9]*' || echo 0)"
  errors="$(grep -o '<li>[0-9]* Page(s) with error</li>' <<<"$result" | grep -o '[0-9]*' || echo '?')"
  echo "  $installed page(s) installed, $errors page(s) with error"
  if [ "$errors" != "0" ]; then
    echo "ERROR: import reported errors - inspect the response manually" >&2
    exit 1
  fi
}

verify_against() {
  local spec="$1"
  local page="${spec%%:*}" pattern="${spec#*:}"
  local space="${page%.*}" name="${page##*.}"
  local xar
  xar="$(mktemp --suffix=.xar)"
  curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" --user "$XWIKI_USER" \
    "$BASE_URL/xwiki/bin/export/${space}/${name}?format=xar" -o "$xar"
  # The page-content REST endpoint often does NOT reflect object-property content (e.g. a
  # stylesheet's "code" property) the way a raw XAR export does - always verify via export, not
  # via GET .../rest/.../pages/<name>.
  if unzip -p "$xar" "${space}/${name}.xml" 2>/dev/null | grep -q -- "$pattern"; then
    echo "verified ${page}: matches /$pattern/"
  else
    echo "VERIFY FAILED: ${page} does not match /$pattern/ after import" >&2
    rm -f "$xar"
    exit 1
  fi
  rm -f "$xar"
}

if [ "$GIT_REF" = "HEAD" ]; then
  for m in "${ALL_MODULES[@]}"; do
    build_module "$m"
  done
else
  echo "--- creating worktree at $GIT_REF ---"
  git -C "$REPO_ROOT" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
  REL_MODULES=()
  for m in "${ALL_MODULES[@]}"; do
    REL_MODULES+=("${m#"$REPO_ROOT"/}")
  done
  # Sparse + no-checkout, same rationale as setup-instance.sh: a full worktree add here would
  # materialize the entire repo just to build a couple of small modules.
  git -C "$REPO_ROOT" worktree add --quiet --no-checkout "$WORKTREE_DIR" "$GIT_REF"
  git -C "$WORKTREE_DIR" sparse-checkout init --cone
  git -C "$WORKTREE_DIR" sparse-checkout set "${REL_MODULES[@]}"
  git -C "$WORKTREE_DIR" checkout --quiet "$GIT_REF"
  for REL_MODULE in "${REL_MODULES[@]}"; do
    build_module "$WORKTREE_DIR/$REL_MODULE"
  done
  ALL_MODULES=()
  for REL_MODULE in "${REL_MODULES[@]}"; do
    ALL_MODULES+=("$WORKTREE_DIR/$REL_MODULE")
  done
fi

for m in "${ALL_MODULES[@]}"; do
  ARTIFACT_ID="$(evaluate "$m" project.artifactId)"
  VERSION="$(evaluate "$m" project.version)"
  XAR="$m/target/${ARTIFACT_ID}-${VERSION}.xar"
  if [ ! -f "$XAR" ]; then
    echo "ERROR: expected XAR not found at $XAR - check <packaging>xar</packaging> is set for this module" >&2
    exit 1
  fi
  import_xar "$XAR"
done

for spec in "${VERIFY_SPECS[@]:-}"; do
  [ -n "$spec" ] && verify_against "$spec"
done

if [ "$GIT_REF" != "HEAD" ]; then
  git -C "$REPO_ROOT" worktree remove "$WORKTREE_DIR" --force
fi

echo "--- done ---"
