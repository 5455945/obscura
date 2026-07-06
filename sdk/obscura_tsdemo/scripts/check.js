#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// Map arch names to platform directory
const PLATFORM_MAP = {
  'aarch64': 'linux-arm64', 'arm64': 'linux-arm64',
  'x86_64':  'linux-x64',   'x64':   'linux-x64', 'amd64': 'linux-x64',
  'darwin-arm64': 'darwin-arm64', 'darwin-x64': 'darwin-x64',
};

function getHostTag() {
  const p = process.platform, a = process.arch;
  if (p === 'linux' && a === 'x64')   return 'linux-x64';
  if (p === 'linux' && a === 'arm64') return 'linux-arm64';
  if (p === 'darwin' && a === 'x64')  return 'darwin-x64';
  if (p === 'darwin' && a === 'arm64') return 'darwin-arm64';
  return null;
}

function resolveArch(arg) {
  if (!arg) return getHostTag();
  const key = arg.toLowerCase();
  if (PLATFORM_MAP[key]) return PLATFORM_MAP[key];
  // Try direct match
  if (Object.values(PLATFORM_MAP).includes(key)) return key;
  console.error('ERROR: unknown arch: ' + arg);
  console.error('Valid: aarch64/arm64, x86_64/x64/amd64');
  process.exit(1);
}

const archArg = process.argv.find(a => a.startsWith('--arch='));
const requestedArch = archArg ? archArg.split('=')[1] : process.env.OBSCURA_ARCH;
const tag = resolveArch(requestedArch);
const hostTag = getHostTag();

console.log('Host:    ' + (hostTag || 'unknown'));
console.log('Target:  ' + tag);

// Check SDK dist
const sdkDir = path.join(__dirname, '..', '..', 'obscura_ts');
const distExists = fs.existsSync(path.join(sdkDir, 'dist', 'index.js'));
const sdkModules = fs.existsSync(path.join(sdkDir, 'node_modules', 'playwright-core'));
if (!sdkModules) {
  console.log('SDK dependencies missing, installing...');
  execSync('npm install --prefer-offline', { cwd: sdkDir, stdio: 'inherit' });
}
if (!distExists) {
  console.log('SDK not compiled, building...');
  execSync('npm run build', { cwd: sdkDir, stdio: 'inherit' });
}

// Check binary
const binFlat  = path.join(sdkDir, 'bin', 'obscura');
const binPlat  = path.join(sdkDir, 'bin', tag, 'obscura');
const hasFlat  = fs.existsSync(binFlat);
const hasPlat  = fs.existsSync(binPlat);

if (hasFlat) {
  console.log('Binary:  bin/obscura (flat)');
} else if (hasPlat) {
  console.log('Binary:  bin/' + tag + '/obscura');
} else {
  // Try to auto-prepare if the cargo build output exists
  const rustArch = tag.includes('arm64') ? 'aarch64' : 'x86_64';
  const rustTriple = tag.includes('arm64') ? 'aarch64-unknown-linux-gnu' : 'x86_64-unknown-linux-gnu';
  const projectRoot = path.join(sdkDir, '..', '..');
  const buildDir = path.join(projectRoot, 'target', rustArch, rustTriple, 'release');
  const srcBin = path.join(buildDir, 'obscura');

  if (fs.existsSync(srcBin)) {
    console.log('Binary found in cargo output, copying...');
    execSync('node scripts/prepare-bin.js ' + buildDir, { cwd: sdkDir, stdio: 'inherit' });
  } else {
    console.warn('WARNING: no binary for ' + tag);
    console.warn('  Missing: bin/' + tag + '/obscura');
    console.warn('  Missing: ' + srcBin);
    console.warn('  Build: ./_scripts/build.sh --arch ' + rustArch + ' --release');
    console.warn('  Then:  cd sdk/obscura_ts && node scripts/prepare-bin.js');
    if (requestedArch !== hostTag && hostTag) {
      console.warn('  Note: host is ' + hostTag + ', target is ' + tag);
    }
  }
}
