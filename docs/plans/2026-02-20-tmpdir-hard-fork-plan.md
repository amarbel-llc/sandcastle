# Tmpdir Hard-Fork Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Vendor the sandbox-runtime source and replace hardcoded `/tmp/claude` with per-invocation unique tmpdir based on `os.tmpdir()`.

**Architecture:** Clone upstream TypeScript source into this repo. Add a `tmpdir` parameter to `generateProxyEnvVars()` and `getDefaultWritePaths()`, thread it from `sandcastle-cli.mjs` through `SandboxManager`. Default to `mkdtempSync()` for per-invocation uniqueness, with `--tmpdir` flag for override. Clean up default tmpdir on exit.

**Tech Stack:** TypeScript, Node.js, Nix flakes, commander.js

---

### Task 1: Vendor upstream source into repo

**Files:**
- Create: `src/` (entire directory from upstream)
- Create: `vendor/` (seccomp binaries from upstream)
- Modify: `package.json` (from upstream, will be modified later)
- Create: `tsconfig.json` (from upstream)
- Modify: `.gitignore`

**Step 1: Copy upstream source tree**

Copy the following from `/tmp/sandbox-runtime` into the sandcastle repo root:
- `src/` directory (all TypeScript source)
- `vendor/` directory (seccomp binaries)
- `package.json`
- `package-lock.json`
- `tsconfig.json`
- `.npmrc`

Do NOT copy: `.git/`, `.github/`, `.husky/`, `.vscode/`, `test/`, `scripts/`, `.prettierrc.json`, `eslint.config.js`, `tsconfig.test.json`, `LICENSE` (sandcastle has its own), `README.md`.

**Step 2: Update .gitignore**

Add these entries to `.gitignore`:

```
node_modules
dist
```

**Step 3: Verify the source tree is present**

Run: `ls src/sandbox/sandbox-utils.ts`
Expected: file exists

Run: `ls vendor/seccomp/x64/apply-seccomp`
Expected: file exists

**Step 4: Commit**

```
git add src/ vendor/ package.json package-lock.json tsconfig.json .npmrc .gitignore
git commit -m "Vendor sandbox-runtime source from upstream

Hard-fork of anthropic-experimental/sandbox-runtime at
96800ee98b66ac4029c22b04cb19950dc85afb11."
```

---

### Task 2: Update flake.nix to build from local source

**Files:**
- Modify: `flake.nix`

**Step 1: Replace fetchFromGitHub with local source**

In `flake.nix`, replace the `src = pkgs.fetchFromGitHub { ... };` block
with:

```nix
src = pkgs.lib.cleanSource ./.;
```

Remove the `npmDepsHash` line — it will need to be recalculated after
`npm install`. Actually, `buildNpmPackage` still needs `npmDepsHash`.
Run `nix build` and let it fail to get the correct hash, then update.

Also remove `dontNpmBuild = true;` — we now build from source via
`npm run build` (already in `buildPhase`).

**Step 2: Verify the Nix build succeeds**

Run: `nix build --show-trace`
Expected: builds successfully, `./result/bin/sandcastle` exists

If `npmDepsHash` is wrong, the error will print the expected hash.
Update `flake.nix` with the correct hash and rebuild.

**Step 3: Verify the binary works**

Run: `./result/bin/sandcastle echo hello`
Expected: prints `hello`

**Step 4: Commit**

```
git add flake.nix
git commit -m "Build sandbox-runtime from vendored source

Switch from fetchFromGitHub to local source tree."
```

---

### Task 3: Parameterize tmpdir in sandbox-utils.ts

**Files:**
- Modify: `src/sandbox/sandbox-utils.ts:277-304`

**Step 1: Add tmpdir parameter to getDefaultWritePaths**

Change the function signature and body at line 277:

```typescript
export function getDefaultWritePaths(tmpdir?: string): string[] {
  const homeDir = homedir()
  const writePaths = [
    '/dev/stdout',
    '/dev/stderr',
    '/dev/null',
    '/dev/tty',
    '/dev/dtracehelper',
    '/dev/autofs_nowait',
    path.join(homeDir, '.npm/_logs'),
    path.join(homeDir, '.claude/debug'),
  ]

  if (tmpdir) {
    writePaths.push(tmpdir)
    // On macOS, /tmp is a symlink to /private/tmp
    if (tmpdir.startsWith('/tmp/')) {
      writePaths.push('/private' + tmpdir)
    } else if (tmpdir.startsWith('/private/tmp/')) {
      writePaths.push(tmpdir.replace('/private', ''))
    }
  }

  return writePaths
}
```

This removes the hardcoded `/tmp/claude` and `/private/tmp/claude` paths
and instead adds the actual tmpdir (with macOS symlink handling).

**Step 2: Add tmpdir parameter to generateProxyEnvVars**

Change the function signature at line 298:

```typescript
export function generateProxyEnvVars(
  httpProxyPort?: number,
  socksProxyPort?: number,
  tmpdir?: string,
): string[] {
  const envVars: string[] = [`SANDBOX_RUNTIME=1`]

  if (tmpdir) {
    envVars.push(`TMPDIR=${tmpdir}`)
  }
  // ... rest of function unchanged
```

This removes the `CLAUDE_TMPDIR` env var read and the `/tmp/claude`
default. The tmpdir is now passed explicitly.

**Step 3: Verify TypeScript compiles**

Run: `cd /Users/sfriedenberg/eng/repos/sandcastle && npx tsc --noEmit`
Expected: type errors in callers (sandbox-manager.ts,
macos-sandbox-utils.ts, linux-sandbox-utils.ts) because they don't pass
the new parameter yet. That's expected and will be fixed in Task 4.

**Step 4: Commit**

```
git add src/sandbox/sandbox-utils.ts
git commit -m "Parameterize tmpdir in sandbox-utils

Accept tmpdir as parameter in getDefaultWritePaths() and
generateProxyEnvVars() instead of reading CLAUDE_TMPDIR env var."
```

---

### Task 4: Thread tmpdir through sandbox-manager and platform utils

**Files:**
- Modify: `src/sandbox/sandbox-manager.ts`
- Modify: `src/sandbox/macos-sandbox-utils.ts:691`
- Modify: `src/sandbox/linux-sandbox-utils.ts:1014`

**Step 1: Add tmpdir to module state in sandbox-manager.ts**

Add a module-level variable near the other state variables:

```typescript
let sandboxTmpdir: string | undefined
```

**Step 2: Add setter function**

Add a public function to set the tmpdir:

```typescript
export function setTmpdir(dir: string): void {
  sandboxTmpdir = dir
}
```

**Step 3: Update getDefaultWritePaths calls**

There are 3 call sites in sandbox-manager.ts that call
`getDefaultWritePaths()`. Update each to pass `sandboxTmpdir`:

- Line ~386: `return { allowOnly: getDefaultWritePaths(sandboxTmpdir), denyWithinAllow: [] }`
- Line ~412: `const allowOnly = [...getDefaultWritePaths(sandboxTmpdir), ...allowPaths]`
- Line ~525: `allowOnly: [...getDefaultWritePaths(sandboxTmpdir), ...userAllowWrite],`

**Step 4: Update generateProxyEnvVars call in macos-sandbox-utils.ts**

At line ~691:

```typescript
const proxyEnvArgs = generateProxyEnvVars(httpProxyPort, socksProxyPort, sandboxTmpdir)
```

This requires importing `sandboxTmpdir` or passing it as a parameter to
the wrapping function. Check how `httpProxyPort` flows in — it's passed
as a parameter to `wrapCommandWithSandboxMacOS()`. Add `tmpdir` to that
function's parameter list and thread it through.

**Step 5: Update generateProxyEnvVars call in linux-sandbox-utils.ts**

At line ~1014:

```typescript
const proxyEnv = generateProxyEnvVars(
  3128,
  1080,
  sandboxTmpdir,
)
```

Same approach: add `tmpdir` to `wrapCommandWithSandboxLinux()` parameter
list.

**Step 6: Update wrapWithSandbox in sandbox-manager.ts to pass tmpdir**

In the `wrapWithSandbox()` function where it calls
`wrapCommandWithSandboxMacOS()` and `wrapCommandWithSandboxLinux()`,
pass `sandboxTmpdir` as the new tmpdir parameter.

**Step 7: Export setTmpdir from index.ts**

Add to `src/index.ts`:

```typescript
export { setTmpdir } from './sandbox/sandbox-manager.js'
```

**Step 8: Verify TypeScript compiles cleanly**

Run: `npx tsc --noEmit`
Expected: no errors

**Step 9: Commit**

```
git add src/sandbox/sandbox-manager.ts src/sandbox/macos-sandbox-utils.ts src/sandbox/linux-sandbox-utils.ts src/index.ts
git commit -m "Thread tmpdir through sandbox manager and platform utils

Pass tmpdir from module state to getDefaultWritePaths() and
generateProxyEnvVars() in all call sites."
```

---

### Task 5: Add --tmpdir flag and per-invocation uniqueness to CLI

**Files:**
- Modify: `sandcastle-cli.mjs`

**Step 1: Add --tmpdir option to commander**

Add after the `--shell` option:

```javascript
.option('--tmpdir <path>', 'override the temporary directory used inside the sandbox')
```

**Step 2: Replace the existing tmpdir logic**

Replace the current block (lines 71-75):

```javascript
// Ensure the sandbox TMPDIR exists before initializing.
// sandbox-runtime sets TMPDIR to this path for child processes but
// does not create it, causing tools like bats to fail at startup.
const sandboxTmpdir = process.env.SANDBOX_TMPDIR || '/tmp/sandcastle'
fs.mkdirSync(sandboxTmpdir, { recursive: true })
```

With:

```javascript
let sandboxTmpdir
let cleanupTmpdir = false

if (options.tmpdir) {
  sandboxTmpdir = options.tmpdir
  fs.mkdirSync(sandboxTmpdir, { recursive: true })
} else {
  sandboxTmpdir = fs.mkdtempSync(path.join(os.tmpdir(), 'sandcastle-'))
  cleanupTmpdir = true
}

SandboxManager.setTmpdir(sandboxTmpdir)
```

**Step 3: Add cleanup on exit**

Add before `logForDebugging('Initializing sandbox...')`:

```javascript
process.on('exit', () => {
  if (cleanupTmpdir && sandboxTmpdir) {
    try {
      fs.rmSync(sandboxTmpdir, { recursive: true, force: true })
    } catch {
      // Best-effort cleanup
    }
  }
})
```

Note: there's already a `process.on('exit', ...)` handler later in the
file for `controlReader?.close()`. Either merge them or keep separate —
Node.js supports multiple exit handlers.

**Step 4: Update the import**

The file currently imports `{ SandboxManager }` from `'./index.js'`.
Since we added `setTmpdir` as a method on the SandboxManager namespace
export, this should work via `SandboxManager.setTmpdir(...)`.

**Step 5: Verify the build**

Run: `nix build --show-trace`
Expected: builds successfully

**Step 6: Test default behavior**

Run: `./result/bin/sandcastle --debug echo hello`
Expected: debug output shows a tmpdir like
`/var/folders/.../T/sandcastle-XXXXXX` (macOS) or
`/tmp/sandcastle-XXXXXX` (Linux), and `hello` is printed.

**Step 7: Test --tmpdir override**

Run: `./result/bin/sandcastle --debug --tmpdir /tmp/my-sandbox echo hello`
Expected: debug output shows `/tmp/my-sandbox` as tmpdir, `hello` is
printed, and `/tmp/my-sandbox` still exists after the command exits.

**Step 8: Test default cleanup**

Run without --tmpdir, note the tmpdir path from debug output, then
verify it's been removed after exit:

```
./result/bin/sandcastle --debug echo hello 2>&1 | grep sandcastle-
ls /var/folders/.../T/sandcastle-*  # should not exist
```

**Step 9: Commit**

```
git add sandcastle-cli.mjs
git commit -m "Add --tmpdir flag with per-invocation unique directories

Default: mkdtempSync creates unique dir under os.tmpdir().
Override: --tmpdir <path> uses an explicit path (not cleaned up).
Default tmpdir is cleaned up on process exit."
```

---

### Task 6: Verify end-to-end and run existing tests

**Files:** none (verification only)

**Step 1: Run Nix build**

Run: `nix build --show-trace`
Expected: success

**Step 2: Run existing bats tests**

Run: `just test`
Expected: all existing tests pass (they exercise the sandcastle CLI)

**Step 3: Run nix flake check**

Run: `nix flake check`
Expected: success

**Step 4: Commit any fixups needed**

If tests revealed issues, fix and commit.
