# Obscura SDK Packaging & Publishing

## Overview

Two packages under `sdk/`:

| Package | Purpose | Publish via |
|---------|---------|-------------|
| `obscura_ts` | TypeScript SDK library | `npm pack` / `npm publish` |
| `obscura_tsdemo` | Demo app using `obscura-ts` | `bundle.sh` (device deploy) |

`obscura_tsdemo` depends on `obscura_ts` via `"obscura-ts": "file:../obscura_ts"` in package.json.

## Directory Structure

```
sdk/
  obscura_ts/                  # SDK
    src/                       # TypeScript source
    dist/                      # Compiled JS (npm run build)
    examples/                  # Self-tests (TS source)
    examples-dist/             # Compiled examples (npm run build:examples)
    scripts/
      bundle.sh                # → deployment tarball
      prepare-bin.js           # Copy binaries to bin/<platform>/
      check.js                 # Arch detection for prebuild
    bin/                       # Platform binaries
      linux-arm64/obscura      # npm structure: bin/<platform>/
      linux-x64/obscura
    package.json
  obscura_tsdemo/              # Demo
    src/                       # Demo TS source
    dist/                      # Compiled JS
    scripts/
      bundle.sh                # Calls SDK bundle.sh, then packages demo only
      check.js                 # Arch detection + auto-build SDK
    package.json
  deploy_and_test.sh           # Device deployment script
  scripts/
    run_template.sh            # POSIX ash-compatible run.sh template
```

## Build Pipeline

```
build.sh                    → Rust binary (obscura, obscura-worker)
  --arch aarch64|x86_64
  --release|--debug
  --domono|--no-domono      # ARM64 bootstrap.js loading (default on)
  --stealth|--no-stealth    # Anti-detection features (default on)

npm run build               → TypeScript → dist/*.js
  npm run build:arm64       # = OBSCURA_ARCH=arm64 npm run build
  npm run build:aarch64     # alias
  npm run build:x64         # alias
  npm run build:x86_64      # alias

npm run build:examples      → TypeScript → examples-dist/*.js

bundle.sh                   → deployment tarball
  --arch aarch64|x86_64
  --debug|--release
```

## Two Package Types

### npm Package (`npm pack`)

```
obscura-ts-0.1.0.tgz
  dist/           # .js + .d.ts + .map
  src/            # TS source
  bin/
    linux-arm64/  # per-platform subdirs
    linux-x64/
  examples-dist/  # compiled examples
  package.json
```

- `playwright-core` is a `dependency` — npm installs it automatically, NOT bundled
- `files` field in package.json controls what's included
- `prebuild` script auto-detects arch, warns if binary missing
- `prepare-bin.js` copies binaries from cargo output to `bin/<platform>/`
- `npm pack` for distribution, `npm publish` for registry

### Deployment Package (`bundle.sh`)

```
obscura-ts-linux-arm64.tar.gz (or -debug.tar.gz for debug)
  bin/obscura            # Flat (no platform subdir)
  bin/obscura-worker
  dist/                  # Only .js (no .d.ts/.map/src/)
  examples/              # Compiled examples
  node_modules/
    obscura-ts/package.json  # {"main":"../../dist/index.js"}
    playwright-core/         # Full playwright-core (symlink + tar -h)
  package.json
  run.sh                 # POSIX ash, Node.js 18+ detection
```

- Self-contained: binaries + playwright-core
- `run.sh` auto-detects Node.js 18+
- `tar czhf` follows symlinks (playwright-core from `node_modules/`)
- `.d.ts`, `.map`, `src/` stripped from `dist/`
- Naming convention: `-debug` suffix for debug builds, no suffix for release

## Device Deployment

```bash
# One command: auto-build → push → extract → test
./deploy_and_test.sh \
  --device 30.207.92.96:61222 \
  --sdk-package ./obscura_ts/obscura-ts-linux-arm64-debug.tar.gz

# SDK-only (no demo pushed):
./deploy_and_test.sh --sdk-package ./obscura_ts/obscura-ts-linux-arm64.tar.gz

# With demo:
./deploy_and_test.sh \
  --sdk-package ./obscura_ts/obscura-ts-linux-arm64.tar.gz \
  --package ./obscura_tsdemo/obscura-tsdemo-linux-arm64.tar.gz
```

`deploy_and_test.sh` flow:
1. `check_package` — auto-build via build.sh + bundle.sh if missing
2. `connect_device` — ADB
3. `push_node_if_needed` — Node.js 18
4. `push_package` — push tarball to device
5. `extract_package` — extract + symlink demo→SDK
6. `run_tests` — SDK-only: `basic`, `baidu_simple_test`; demo: `verify`, `useragent`, `scrape`, `stealth`

## node_modules Layout (Deployment)

```
/data/obscura-ts/node_modules/
  obscura-ts/            # Directory (NOT symlink), contains only:
    package.json         # {"main":"../../dist/index.js"}
  playwright-core/       # Full playwright-core (tar -h followed symlink)
```

**Why not `node_modules/obscura-ts -> ..`?** That would make `bin/` visible at two paths:
- `/data/obscura-ts/bin/` (actual)
- `/data/obscura-ts/node_modules/obscura-ts/bin/` (via symlink)

Using a directory with `package.json` + `main` field avoids this.

**Demo linkage** — `deploy_and_test.sh` creates:
```
/data/obscura-test/obscura-tsdemo/node_modules/
  obscura-ts -> /data/obscura-ts
  playwright-core -> /data/obscura-ts/node_modules/playwright-core
```

## Arch-Specific Builds

Both SDK and demo support `npm run build:<arch>`:

```bash
npm run build           # host arch detection
npm run build:arm64     # = build:aarch64
npm run build:x64       # = build:x86_64
OBSCURA_ARCH=arm64 npm run build  # env var
```

`prebuild` script (`scripts/check.js`) auto-checks:
1. SDK `node_modules` → missing? `npm install`
2. SDK `dist/` → missing? `npm run build`
3. Binary for target arch → missing? auto `prepare-bin.js` if cargo output exists; warn otherwise

## domono Feature Flag

Controlled by `build.sh --domono` (default on) / `--no-domono`:

- **On**: ARM64 snapshot disabled (crashes during deserialization). bootstrap.js loaded explicitly.
- **Off**: Original behavior — snapshot always used.

```bash
./_scripts/build.sh --arch aarch64 --release           # domono on (default)
./_scripts/build.sh --arch aarch64 --release --no-domono  # domono off
```

Feature in `crates/obscura-js/Cargo.toml`: `domono = []`.
Code in `crates/obscura-js/src/runtime.rs`: `#[cfg(feature = "domono")]`.

## Version Check

SDK auto-checks Node.js version at `require('obscura-ts')`:

```
obscura-ts requires Node.js >= 18, current: v12.14.0
Please use Node.js 18+ to run, for example:
  /path/to/node-v18.20.4-linux-arm64/bin/node your_script.js
Or use run.sh which auto-detects the correct Node.js version.
```

## Common Mistakes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Cannot find module 'obscura-ts'` | SDK `dist/` not compiled | `npm run build` |
| `Cannot find module 'playwright-core'` | `node_modules` not installed | `npm install` |
| ARM64 `page.title: expected string, got object` | bootstrap.js not loaded | Use `--domono` |
| Deployment tarball missing playwright-core | symlink not followed | Use `tar czhf` or `cp -rL` |
| `tsc: not found` | `node_modules` deleted | `npm install` |
| Demo build fails | SDK not compiled | `npm run build:arm64` |
| No output with old Node.js | Node < 18 | SDK blocks at require() |
