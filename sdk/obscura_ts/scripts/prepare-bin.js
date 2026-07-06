#!/usr/bin/env node

/**
 * Prepare binary files for npm publishing
 *
 * This script copies obscura and obscura-worker binaries to the bin/ directory
 * organized by platform. The bin/ directory is included in the npm package.
 *
 * Usage:
 *   node scripts/prepare-bin.js [build-dir]
 *
 * Examples:
 *   node scripts/prepare-bin.js                           # Auto-detect platform
 *   node scripts/prepare-bin.js ./target/x86_64          # Use specific build dir
 *   node scripts/prepare-bin.js ./target/aarch64         # For ARM64 builds
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

// Platform detection（可通过 --platform 覆盖，或从 build dir 推断）
function getPlatform(buildDir) {
  const platformArg = process.argv.find(a => a.startsWith('--platform='));
  if (platformArg) return platformArg.split('=')[1];

  if (buildDir && buildDir.includes('/aarch64')) return 'linux-arm64';
  if (buildDir && buildDir.includes('/x86_64'))  return 'linux-x64';

  const platform = os.platform();
  const arch = os.arch();

  if (platform === 'linux') {
    if (arch === 'x64') return 'linux-x64';
    if (arch === 'arm64') return 'linux-arm64';
  } else if (platform === 'darwin') {
    if (arch === 'x64') return 'darwin-x64';
    if (arch === 'arm64') return 'darwin-arm64';
  } else if (platform === 'win32') {
    if (arch === 'x64') return 'win32-x64';
  }

  throw new Error(`Unsupported platform: ${platform}-${arch}`);
}

// Find build directory
function findBuildDir(customDir) {
  if (customDir) {
    return path.resolve(customDir);
  }

  // Try common build locations
  const candidates = [
    './target/x86_64/x86_64-unknown-linux-gnu/release',
    './target/aarch64/aarch64-unknown-linux-gnu/release',
    './target/release',
    '../../target/x86_64/x86_64-unknown-linux-gnu/release',
    '../../target/aarch64/aarch64-unknown-linux-gnu/release',
    '../../target/release',
  ];

  for (const candidate of candidates) {
    const fullPath = path.resolve(__dirname, '..', candidate);
    if (fs.existsSync(fullPath)) {
      return fullPath;
    }
  }

  throw new Error(
    'Build directory not found. Please build obscura first:\n' +
    '  ./_scripts/build.sh --arch x86_64 --release\n' +
    'Or specify the build directory:\n' +
    '  node scripts/prepare-bin.js ./target/x86_64/x86_64-unknown-linux-gnu/release'
  );
}

// Copy binary files
function copyBinaries(buildDir, platform) {
  const binDir = path.resolve(__dirname, '..', 'bin', platform);

  // Create bin directory
  if (!fs.existsSync(binDir)) {
    fs.mkdirSync(binDir, { recursive: true });
    console.log(`Created directory: ${binDir}`);
  }

  // Binary files to copy
  const binaries = ['obscura', 'obscura-worker'];
  const isWindows = platform.startsWith('win32');

  let copiedCount = 0;

  for (const binary of binaries) {
    const ext = isWindows ? '.exe' : '';
    const srcPath = path.join(buildDir, binary + ext);
    const destPath = path.join(binDir, binary + ext);

    if (fs.existsSync(srcPath)) {
      fs.copyFileSync(srcPath, destPath);

      // Make executable on Unix-like systems
      if (!isWindows) {
        fs.chmodSync(destPath, 0o755);
      }

      const stats = fs.statSync(destPath);
      const sizeMB = (stats.size / 1024 / 1024).toFixed(2);
      console.log(`✓ Copied ${binary}${ext} (${sizeMB} MB)`);
      copiedCount++;
    } else {
      console.log(`⚠ Warning: ${srcPath} not found, skipping`);
    }
  }

  if (copiedCount === 0) {
    throw new Error('No binary files found to copy');
  }

  console.log(`\n✓ Successfully prepared ${copiedCount} binary file(s) for ${platform}`);
  console.log(`  Location: ${binDir}`);
}

// Main
async function main() {
  console.log('Preparing binary files for npm publishing...\n');

  const customDir = process.argv[2];
  const buildDir = findBuildDir(customDir);
  const platform = getPlatform(buildDir);

  console.log(`Platform: ${platform}`);
  console.log(`Build directory: ${buildDir}\n`);

  copyBinaries(buildDir, platform);

  console.log('\n✓ Binary preparation complete!');
  console.log('\nNext steps:');
  console.log('  1. Test the package: npm pack');
  console.log('  2. Publish to npm: npm publish');
}

main().catch((err) => {
  console.error('\n✗ Error:', err.message);
  process.exit(1);
});
