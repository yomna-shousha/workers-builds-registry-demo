# Workers Builds Registry Demo

Demo project showing how to use **Cloudflare Workers Builds** with a custom npm registry and automated SBOM (Software Bill of Materials) generation.

---

## What This Does

This project demonstrates a complete CI/CD pipeline using Workers Builds that:

1. **Installs dependencies from a custom/private npm registry** -- using an `.npmrc` file and an `NPM_TOKEN` secret, so Workers Builds can authenticate to your registry without developers needing to rewrite lockfiles.

2. **Builds an Astro site** -- compiles the project on Cloudflare's infrastructure.

3. **Generates an SBOM** -- creates a `sbom.json` file (CycloneDX format) from the actual `node_modules` that were installed during the build. This SBOM reflects exactly what gets deployed -- not what was on a developer's laptop.

4. **Pushes the SBOM and lockfile back to GitHub** -- uploads both `sbom.json` and `package-lock.json` to the repository via the GitHub API so your security team can scan them. Each commit includes the Workers Build UUID for traceability.

5. **Deploys to Cloudflare Workers** -- runs `wrangler deploy` to ship the built site.

### What the security team gets

After every deploy, two files are updated on the repo:

| File | What it is | What security can do with it |
|---|---|---|
| `sbom.json` | CycloneDX SBOM listing every dependency and version | Run vulnerability scanners (Snyk, Grype, Trivy, etc.) against the exact bill of materials that was deployed |
| `package-lock.json` | The lockfile generated on Cloudflare's build infra | Verify the exact dependency tree and registry sources. This is the lockfile that matches the deployed build -- not a developer's local one |

Both files are pushed in a **single commit** by Workers Builds with a message like:
```
chore: update build artifacts from Workers Build d6cae80a-a3e4-... [skip ci]
```

The Build UUID in the commit message lets the security team trace both artifacts back to the exact build and deployment. Using a single commit (instead of one per file) is important -- it prevents the push-back from triggering additional builds.

---

## Setup Guide

### Step 1: Workers Builds Settings (Cloudflare Dashboard)

Go to your Worker > **Settings** > **Build** and set:

| Setting | Value |
|---|---|
| **Build command** | `npm run ci:build && bash scripts/push-sbom.sh` |
| **Deploy command** | `npx wrangler deploy` |
| **Root directory** | `/` |

### Step 2: Add Build Secrets (REQUIRED)

Go to your Worker > **Settings** > **Build** > **Variables and secrets**.

Add the following as **encrypted secrets** (not plain variables):

| Name | Type | How to get it | Purpose |
|---|---|---|---|
| `NPM_TOKEN` | **Secret** | Generate a read-only token from your private npm registry. For npm: `npm token create --read-only`. For GitHub Packages / Artifactory / etc., see your registry's docs. | Authenticates Workers Builds to your private npm registry during `npm install` |
| `GITHUB_TOKEN` | **Secret** | Go to https://github.com/settings/tokens > **Fine-grained tokens** > **Generate new token**. Scope it to your repo with **Contents: Read and write** permission. | Allows the build to push the generated SBOM and lockfile back to your GitHub repo |

> **IMPORTANT:** Both must be added as **encrypted secrets**, not plain-text variables. Plain-text variables are visible in the dashboard and build logs.

> **NOTE:** If you don't use a private registry, you can skip `NPM_TOKEN`. If you don't need SBOM/lockfile push-back, you can skip `GITHUB_TOKEN` and remove `&& bash scripts/push-sbom.sh` from the build command.

### Step 3: Configure Build Watch Paths (REQUIRED)

Go to your Worker > **Settings** > **Build** > **Build watch paths**.

| Field | Value |
|---|---|
| **Include paths** | `*` |
| **Exclude paths** | `sbom.json, package-lock.json` |

> **WHY THIS IS REQUIRED:** The push-back script commits `sbom.json` and `package-lock.json` to your repo after each build. Without this exclusion, those commits trigger another build, which pushes again, which triggers another build -- an infinite loop. Adding both files to the exclude paths tells Workers Builds to ignore commits that only change those files.

### Step 4: Configure `.npmrc` for Your Registry

Edit the `.npmrc` file in the repo root to point to your actual registry. Replace the placeholder values:

```ini
# For a generic private registry:
//registry.your-company.com/:_authToken=${NPM_TOKEN}
@yourscope:registry=https://registry.your-company.com/

# For GitHub Packages:
//npm.pkg.github.com/:_authToken=${NPM_TOKEN}
@your-org:registry=https://npm.pkg.github.com

# For Artifactory:
//your-company.jfrog.io/artifactory/api/npm/npm-local/:_authToken=${NPM_TOKEN}
@yourscope:registry=https://your-company.jfrog.io/artifactory/api/npm/npm-local/
```

The `${NPM_TOKEN}` placeholder is automatically replaced at build time by the secret you added in Step 2.

---

## What Happens on Each Push to `main`

```
git push origin main
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│  Workers Builds triggers                                 │
│                                                          │
│  1. npm install                                          │
│     └─ .npmrc + NPM_TOKEN secret authenticates          │
│        to your private registry                          │
│     └─ Generates package-lock.json on Cloudflare infra  │
│                                                          │
│  2. npm run build                                        │
│     └─ Astro compiles the site                          │
│                                                          │
│  3. npm run generate-sbom                                │
│     └─ @cyclonedx/cyclonedx-npm creates sbom.json       │
│        from the actual installed node_modules            │
│                                                          │
│  4. bash scripts/push-sbom.sh                            │
│     └─ Uploads sbom.json + package-lock.json to GitHub   │
│        in a SINGLE commit (uses GITHUB_TOKEN secret)     │
│     └─ Commit message includes build UUID                │
│     └─ Both files are in watch path excludes,            │
│        so this commit does NOT trigger a new build       │
│                                                          │
│  5. npx wrangler deploy                                  │
│     └─ Deploys the built Worker to Cloudflare            │
└──────────────────────────────────────────────────────────┘
       │
       ▼
  Security team reviews on GitHub:
    - sbom.json         → run vulnerability scanners
    - package-lock.json → audit the dependency tree
  Both match the exact build that was deployed.
```

---

## Customizing Which Files Get Pushed Back

The list of files pushed back to GitHub is controlled in one place:

**`scripts/push-sbom.sh`**, the `FILES` array:

```bash
# Files to push: add or remove entries here.
FILES=("sbom.json" "package-lock.json")
```

All files in this array are pushed in a **single commit** to avoid triggering extra builds.

### To add a file

Add it to the `FILES` array. For example, to also push an `npm audit` report:

```bash
FILES=("sbom.json" "package-lock.json" "audit-report.json")
```

You'd also need to generate that file in the build. Add a script to `package.json`:

```json
"generate-audit": "npm audit --json > audit-report.json || true"
```

And chain it into the `ci:build` script:

```json
"ci:build": "npm run build && npm run generate-sbom && npm run generate-audit"
```

### To remove a file

Remove it from the `FILES` array. For example, to stop pushing the lockfile:

```bash
FILES=("sbom.json")
```

### IMPORTANT: Update Build Watch Paths when you change this

Every file pushed back to GitHub **must** be in the Build Watch Paths **exclude list**, or it will trigger an infinite build loop.

Go to your Worker > **Settings** > **Build** > **Build watch paths** > **Exclude paths** and make sure every file listed in `push_file` calls is excluded:

| Files pushed back | Exclude paths value |
|---|---|
| `sbom.json` only | `sbom.json` |
| `sbom.json` + `package-lock.json` | `sbom.json, package-lock.json` |
| `sbom.json` + `package-lock.json` + `audit-report.json` | `sbom.json, package-lock.json, audit-report.json` |

**Rule of thumb: if `push_file` pushes it, the exclude paths must list it.**

---

## The Problem This Solves

When your project depends on packages from a private/custom npm registry:

1. Developers generate a lockfile locally (pointing to the private registry)
2. They push it to the repo
3. Workers Builds can't reach the private registry -- the build fails
4. **Workaround:** developers rewrite the registry URL in the lockfile before pushing -- fragile and error-prone
5. Security team can't trust the lockfile because it's been mutated
6. No way to guarantee the SBOM or lockfile matches what was actually deployed

**This demo fixes all of that.** The `.npmrc` + `NPM_TOKEN` approach authenticates Workers Builds to your registry natively. The lockfile stays honest. The SBOM and lockfile are generated from the actual production build and pushed back for scanning.

---

## Key Files

| File | Purpose |
|---|---|
| `.npmrc` | Registry auth config -- references `${NPM_TOKEN}` env var. Edit this to point to your registry. |
| `wrangler.jsonc` | Workers deployment config. Includes `nodejs_compat` flag. |
| `scripts/push-sbom.sh` | Pushes generated SBOM and lockfile back to GitHub via the Contents API. Requires `GITHUB_TOKEN`. |
| `package.json` | Contains `ci:build` and `generate-sbom` scripts used by the build command. |
| `astro.config.mjs` | Astro config with Cloudflare adapter. |

---

## Local Development

```bash
npm install
npm run dev
```

Make sure you're authenticated to your private registry locally (`npm login --registry=...`).

---

## Important Notes

- **Use `&&` not `&` in build commands.** `&&` runs commands sequentially. `&` backgrounds the first command, so `npm run build` would start before `npm install` finishes.
- **Both secrets must be encrypted.** Add them as "Secret" type, not "Variable" type, in the Workers Builds settings.
- **Both `sbom.json` and `package-lock.json` must be in the exclude paths.** Without this, the push-back commits trigger an infinite build loop.
- **`NPM_TOKEN` is build-time only.** It's not available at runtime -- it's only injected during the build step.
- **The push-back commits include `[skip ci]`** in the message as a safety measure, though the watch path exclusion is the primary mechanism that prevents loops.
- **Developers should `git pull` before pushing.** Since Workers Builds pushes artifacts back to the repo, the remote may be ahead. A normal `git pull` before pushing handles this -- standard git workflow.
