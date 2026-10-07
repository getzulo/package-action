#!/usr/bin/env bash
# getzulo/package-action — build with `zulo package build`, upload with the
# workflow's GitHub OIDC token exchanged at login.getzulo.com. No stored secret.
set -euo pipefail

# The CLI, built from the platform repository (src/ZuloOne.Cli) and pinned by
# digest: a changed binary is refused, not run.
CLI_RELEASE="cli-0.1.0"
CLI_SHA256_LINUX_X64="2d809986672aeac60830061372da28928fcc64f55f3b11c6a7a47ef6a441c8b3"

fail() { echo "::error::$*" >&2; exit 1; }

[ "${RUNNER_OS:-Linux}" = "Linux" ] && [ "${RUNNER_ARCH:-X64}" = "X64" ] \
  || fail "getzulo/package-action runs on Linux x64 runners (this is ${RUNNER_OS:-?}/${RUNNER_ARCH:-?})."
[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] \
  || fail "No GitHub OIDC token available. Give the job 'permissions: id-token: write'."
command -v jq >/dev/null || fail "jq is required on the runner."

tmp="${RUNNER_TEMP:-/tmp}/zulo-package-action"
mkdir -p "$tmp"
cli="$tmp/zulo"
if [ ! -x "$cli" ]; then
  curl -fsSL -o "$cli" "https://github.com/getzulo/package-action/releases/download/${CLI_RELEASE}/zulo-linux-x64" \
    || fail "Could not download the zulo CLI (${CLI_RELEASE})."
  echo "${CLI_SHA256_LINUX_X64}  $cli" | sha256sum -c --quiet - \
    || fail "The downloaded zulo CLI does not match its pinned digest. Refusing to run it."
  chmod +x "$cli"
fi

# The same commit builds the same bytes: builtAt is the commit's time, never the clock.
if git -C "$ZULO_WORKSPACE" rev-parse HEAD >/dev/null 2>&1; then
  export SOURCE_DATE_EPOCH="$(git -C "$ZULO_WORKSPACE" log -1 --format=%ct)"
fi

version="${ZULO_VERSION#v}"
out="$tmp/${ZULO_ID}-${version}.zulopkg"
args=(package build --workspace "$ZULO_WORKSPACE" --models "$ZULO_MODELS" --id "$ZULO_ID" --version "$version" --out "$out")
[ -n "$ZULO_TITLE" ] && args+=(--title "$ZULO_TITLE")
[ -n "$ZULO_REQUIRES_PLATFORM" ] && args+=(--requires-platform "$ZULO_REQUIRES_PLATFORM")
"$cli" "${args[@]}" | tee "$tmp/build.txt"
hash="$(sed -n 's/^contentHash  //p' "$tmp/build.txt")"

# GitHub OIDC → login: a five-minute token of the credential, for the portal only.
login="${ZULO_LOGIN%/}"
oidc="$(curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${login}" | jq -r .value)"
[ -n "$oidc" ] && [ "$oidc" != "null" ] || fail "GitHub did not issue an OIDC token."
echo "::add-mask::$oidc"

exchange="$(curl -sS -w '\n%{http_code}' "${login}/token" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  --data-urlencode "client_id=${ZULO_CLIENT_ID}" \
  --data-urlencode "assertion=${oidc}" \
  --data-urlencode "resource=lcp")"
code="${exchange##*$'\n'}"; body="${exchange%$'\n'*}"
if [ "$code" != "200" ]; then
  fail "login refused the exchange (${code}): $(echo "$body" | jq -r '.error_description // .error // .' 2>/dev/null || echo "$body"). The credential must trust ${GITHUB_REPOSITORY} at ${GITHUB_REF}."
fi
token="$(echo "$body" | jq -r .access_token)"
echo "::add-mask::$token"

project="${ZULO_PROJECT:-$ZULO_TENANT}"
url="${ZULO_PORTAL%/}/api/v1/tenants/${ZULO_TENANT}/projects/${project}/packages"
upload="$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer ${token}" -H "Content-Type: application/zip" \
  --data-binary "@${out}" "$url")"
code="${upload##*$'\n'}"; body="${upload%$'\n'*}"
case "$code" in
  201) echo "Uploaded ${ZULO_ID} ${version} (${hash}) to ${ZULO_TENANT}/${project}." ;;
  200) echo "${ZULO_ID} ${version} with this exact content is already in the library — nothing added." ;;
  *)   fail "The portal refused the package (${code}): $(echo "$body" | jq -r 'if .file then "\(.file): \(.error)" else (.error // .) end' 2>/dev/null || echo "$body")" ;;
esac

{
  echo "content-hash=${hash}"
  echo "package-id=$(echo "$body" | jq -r .id)"
  echo "file=${out}"
} >> "$GITHUB_OUTPUT"
{
  echo "### ZuloOne package"
  echo "| | |"
  echo "|---|---|"
  echo "| package | \`${ZULO_ID} ${version}\` |"
  echo "| contentHash | \`${hash}\` |"
  echo "| tenant / project | ${ZULO_TENANT} / ${project} |"
  echo "| state | $(echo "$body" | jq -r .state) |"
} >> "$GITHUB_STEP_SUMMARY"
