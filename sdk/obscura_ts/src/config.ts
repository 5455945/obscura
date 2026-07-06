/**
 * Configuration defaults and resolution for obscura-ts SDK
 */

import * as path from 'path';
import * as fs from 'fs';
import { LaunchOptions, ResolvedLaunchOptions } from './types';

/**
 * Default configuration values
 */
export const DEFAULTS = {
  port: 9222,
  host: '127.0.0.1',
  stealth: false,
  workers: 1,
  timeout: 30000,
  allowFileAccess: false,
  allowPrivateNetwork: false,
  quiet: false,
  verbose: false,
} as const;

/**
 * Search paths for obscura binary (relative to project root)
 *
 * Includes both standard cargo output (target/release/) and
 * build.sh output directories (target/<arch>/<triple>/<profile>/).
 */
const BINARY_SEARCH_PATHS = [
  // Standard cargo output
  'target/release/obscura',
  'target/debug/obscura',
  // build.sh output — x86_64
  'target/x86_64/x86_64-unknown-linux-gnu/release/obscura',
  'target/x86_64/x86_64-unknown-linux-gnu/debug/obscura',
  // build.sh output — aarch64 (cross-compile)
  'target/aarch64/aarch64-unknown-linux-gnu/release/obscura',
  'target/aarch64/aarch64-unknown-linux-gnu/debug/obscura',
  // build.sh stealth output
  'target/stealth/aarch64-unknown-linux-gnu/debug/obscura',
  'target/stealth/aarch64-unknown-linux-gnu/release/obscura',
  // Legacy / alternate locations
  'dist/obscura',
  '../../target/release/obscura',
  '../../target/debug/obscura',
  '../../dist/obscura',
  // Packaged deployment (bin/ directory at project root)
  'bin/obscura',
  '../bin/obscura',
  '../../bin/obscura',
];

/**
 * Get platform-specific binary name
 */
function getBinaryName(): string {
  return process.platform === 'win32' ? 'obscura.exe' : 'obscura';
}

/**
 * Get platform-specific binary directory
 */
function getPlatformBinDir(): string {
  const platform = process.platform;
  const arch = process.arch;

  if (platform === 'linux') {
    return arch === 'x64' ? 'linux-x64' : 'linux-arm64';
  } else if (platform === 'darwin') {
    return arch === 'x64' ? 'darwin-x64' : 'darwin-arm64';
  } else if (platform === 'win32') {
    return arch === 'x64' ? 'win32-x64' : 'win32-arm64';
  }

  throw new Error(`Unsupported platform: ${platform}-${arch}`);
}

/**
 * Resolve the obscura binary path
 *
 * Search order:
 * 1. Explicit executablePath from options
 * 2. PATH environment variable
 * 3. SDK bundled binaries (bin/<platform>/)
 * 4. Known build output locations
 */
export function resolveExecutablePath(explicitPath?: string, cwd?: string): string {
  // 1. Explicit path
  if (explicitPath) {
    if (fs.existsSync(explicitPath)) {
      return path.resolve(explicitPath);
    }
    throw new Error(`obscura binary not found at: ${explicitPath}`);
  }

  // 2. Search in PATH
  const pathEnv = process.env.PATH || '';
  const pathSeparator = process.platform === 'win32' ? ';' : ':';
  const dirs = pathEnv.split(pathSeparator);

  for (const dir of dirs) {
    const candidate = path.join(dir, 'obscura');
    if (fs.existsSync(candidate)) {
      return candidate;
    }
    // Windows: also check .exe
    if (process.platform === 'win32') {
      const exeCandidate = candidate + '.exe';
      if (fs.existsSync(exeCandidate)) {
        return exeCandidate;
      }
    }
  }

  // 3. Search SDK bundled binaries (bin/<platform>/ and bin/)
  const binaryName = getBinaryName();
  const platformDir = getPlatformBinDir();
  const bundledPaths = [
    path.resolve(__dirname, '..', 'bin', platformDir, binaryName),
    path.resolve(__dirname, '..', '..', 'bin', platformDir, binaryName),
    path.resolve(__dirname, '..', '..', '..', 'bin', platformDir, binaryName),
    // Bundled without platform subdir (obscura-ts deployment package)
    path.resolve(__dirname, '..', 'bin', binaryName),
    path.resolve(__dirname, '..', '..', 'bin', binaryName),
    path.resolve(__dirname, '..', '..', '..', 'bin', binaryName),
  ];

  for (const candidate of bundledPaths) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  // 4. Search known build locations relative to SDK or project root
  const searchRoots = [
    cwd || process.cwd(),
    path.resolve(__dirname, '..', '..', '..'), // SDK dir -> project root
    path.resolve(__dirname, '..', '..', '..', '..'), // dist dir -> project root
  ];

  for (const root of searchRoots) {
    for (const relativePath of BINARY_SEARCH_PATHS) {
      const candidate = path.resolve(root, relativePath);
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }

  throw new Error(
    'obscura binary not found. Build it with `./_scripts/build.sh --arch x86_64 --release` ' +
    'or specify executablePath in launch options.'
  );
}

/**
 * Resolve launch options with defaults
 */
export function resolveLaunchOptions(options?: LaunchOptions): ResolvedLaunchOptions {
  const opts = options || {};

  return {
    executablePath: resolveExecutablePath(opts.executablePath, opts.cwd),
    port: opts.port ?? DEFAULTS.port,
    host: opts.host ?? DEFAULTS.host,
    stealth: opts.stealth ?? DEFAULTS.stealth,
    proxy: opts.proxy,
    workers: opts.workers ?? DEFAULTS.workers,
    userAgent: opts.userAgent,
    v8Flags: opts.v8Flags,
    timeout: opts.timeout ?? DEFAULTS.timeout,
    cwd: opts.cwd,
    allowFileAccess: opts.allowFileAccess ?? DEFAULTS.allowFileAccess,
    allowPrivateNetwork: opts.allowPrivateNetwork ?? DEFAULTS.allowPrivateNetwork,
    quiet: opts.quiet ?? DEFAULTS.quiet,
    verbose: opts.verbose ?? DEFAULTS.verbose,
  };
}

/**
 * Build command-line arguments for obscura serve
 */
export function buildServeArgs(config: ResolvedLaunchOptions): string[] {
  const args: string[] = ['serve'];

  args.push('--port', config.port.toString());
  args.push('--host', config.host);

  if (config.stealth) {
    args.push('--stealth');
  }

  if (config.proxy) {
    args.push('--proxy', config.proxy);
  }

  if (config.workers > 1) {
    args.push('--workers', config.workers.toString());
  }

  if (config.userAgent) {
    args.push('--user-agent', config.userAgent);
  }

  if (config.allowFileAccess) {
    args.push('--allow-file-access');
  }

  if (config.quiet) {
    args.push('--quiet');
  }

  return args;
}

/**
 * Build global arguments (before the subcommand)
 */
export function buildGlobalArgs(config: ResolvedLaunchOptions): string[] {
  const args: string[] = [];

  if (config.v8Flags) {
    args.push('--v8-flags', config.v8Flags);
  }

  if (config.allowPrivateNetwork) {
    args.push('--allow-private-network');
  }

  if (config.verbose) {
    args.push('--verbose');
  }

  return args;
}
