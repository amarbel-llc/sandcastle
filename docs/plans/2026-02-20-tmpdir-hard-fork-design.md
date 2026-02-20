# Tmpdir Hard-Fork Design

## Goal

Hard-fork `anthropic-experimental/sandbox-runtime` into this repo and
replace the hardcoded `/tmp/claude` temporary directory with
per-invocation unique directories based on `os.tmpdir()`.

## Changes

### 1. Vendor upstream source

Clone `sandbox-runtime` source (`src/`, `package.json`, `tsconfig.json`,
vendor/, test/) into this repo at the root level. Remove `fetchFromGitHub`
from `flake.nix` and build from local source.

### 2. Modify `src/sandbox/sandbox-utils.ts`

- `generateProxyEnvVars()`: accept a `tmpdir` parameter instead of reading
  `CLAUDE_TMPDIR` or defaulting to `/tmp/claude`. Pass the chosen tmpdir
  through as `TMPDIR` in the sandboxed process environment.
- `getDefaultWritePaths()`: accept a `tmpdir` parameter. Replace hardcoded
  `/tmp/claude` and `/private/tmp/claude` with the actual tmpdir path.

### 3. Per-invocation unique tmpdir

In `sandcastle-cli.mjs`:

- **Default**: `fs.mkdtempSync(path.join(os.tmpdir(), 'sandcastle-'))`
  creates a unique directory per invocation (e.g.
  `/var/folders/.../T/sandcastle-abc123` on macOS,
  `/tmp/sandcastle-xyz789` on Linux).
- **Override**: `--tmpdir <path>` CLI flag uses the exact path provided,
  created with `mkdirSync({ recursive: true })` if needed.
- The chosen path is threaded through `SandboxManager` ->
  `sandbox-utils` so the sandboxed process sees it as `TMPDIR` and has
  read/write access.

### 4. Cleanup

On process exit:

- If using the default (unique) tmpdir: recursively remove it.
- If `--tmpdir` was explicitly provided: leave it alone (the caller owns
  it).

### 5. Nix build changes

`flake.nix` switches from `fetchFromGitHub` to building entirely from
local source. `sandcastle-cli.mjs` stays at the root and is copied into
the output during `installPhase`, same as today.

## Files touched

| File | Change |
|------|--------|
| `flake.nix` | Remove `fetchFromGitHub`, build from local `src/` |
| `src/sandbox/sandbox-utils.ts` | Parameterize tmpdir in `generateProxyEnvVars` and `getDefaultWritePaths` |
| `src/sandbox/sandbox-manager.ts` | Thread tmpdir parameter through to utils |
| `sandcastle-cli.mjs` | Add `--tmpdir` flag, `mkdtempSync` default, cleanup on exit |

## Out of scope (future work)

- Renaming remaining `CLAUDE_*` env vars and `claude`-specific paths
- Renaming `SANDBOX_RUNTIME` env var
- Removing Claude-specific default write paths (`.claude/debug`, etc.)
