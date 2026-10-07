# getzulo/package-action

Builds a ZuloOne package (`.zulopkg`) from your workspace and uploads it to
the [ZuloOne Lifecycle Portal](https://lcp.getzulo.com) — authenticated by the
workflow's own GitHub OIDC token. **No secret is stored in the repository.**

```yaml
on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write        # the OIDC token the action exchanges at login.getzulo.com

jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - id: version                      # the package is versioned by its model
        run: echo "version=$(jq -r .object.modelVersion AcmeSales/model.json)" >> "$GITHUB_OUTPUT"
      - uses: getzulo/package-action@v1
        with:
          models: AcmeSales,AcmeCommon     # model folders of the workspace
          id: acme-erp                     # the package's id in its project
          version: ${{ steps.version.outputs.version }}
          tenant: acme                     # acme.zulo.one
          client-id: acme-k3x9p2q7         # from the portal's CI credentials page; not a secret
```

## Before the first run

In the portal, **CI credentials**:

1. Create a credential with the `packages:write` scope. Its secret is not
   needed by this action — you may discard it.
2. **Trust this GitHub repository** for it: `owner/repository` and the exact ref
   the workflow runs on — `refs/heads/main`. No wildcards: "any branch may upload"
   is exactly what this check exists to prevent. That is why the example runs on
   `main` and takes the version from `model.json`: a workflow on `v*` tags would
   need a new registration for every tag (login answers `ref 'refs/tags/v1.0.2' is
   not registered…`). Bump `modelVersion` in the same commit as the change; the
   same version with the same content is a no-op (200), a new version is a new package.

## What it does

1. Downloads the `zulo` CLI (pinned by digest; a changed binary is refused).
2. `zulo package build` — deterministic: the same commit builds the same bytes
   on any machine; `builtAt` is the commit's time.
3. Asks GitHub for an OIDC token with `audience` = login's address, exchanges it
   at `login.getzulo.com/token` (`urn:ietf:params:oauth:grant-type:jwt-bearer`)
   for a five-minute token of the credential, audience `lcp`.
4. Uploads to `POST /api/v1/tenants/{tenant}/projects/{project}/packages`.
   201 — uploaded; 200 — this exact package was already there; anything else
   fails the job with the portal's reason, naming the file inside the package.

Outputs: `content-hash`, `package-id`, `file`.

## Inputs

| Input | Default | |
|---|---|---|
| `models` | — | model folders, comma-separated; `Name@1.4.0` pins the version `model.json` must say |
| `id` | — | the package id |
| `version` | the ref name | semver; a leading `v` is dropped. On a branch, pass the model's version (see the example) |
| `tenant` | — | |
| `project` | the tenant's name | |
| `client-id` | — | the credential's id |
| `workspace` | `.` | the folder holding the model folders |
| `title`, `requires-platform` | — | recorded in the manifest |
| `portal` | `https://lcp.getzulo.com` | |
| `login` | `https://login.getzulo.com` | |

Linux x64 runners only.

## The CLI

`zulo` is built from the ZuloOne platform repository (`src/ZuloOne.Cli`) and
attached to this repository's releases (`cli-<version>`, asset `zulo-linux-x64`).
The format is specified in the platform's
`docs/superpowers/specs/2026-10-07-zulo-package-format.md`.
