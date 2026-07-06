/**
 * Process launcher for obscura CDP server
 */

import { ChildProcess, spawn } from 'child_process';
import * as http from 'http';
import { ResolvedLaunchOptions, VersionInfo } from './types';
import { buildServeArgs, buildGlobalArgs } from './config';

/**
 * Launched obscura process handle
 */
export interface LaunchedProcess {
  /** The child process */
  process: ChildProcess;
  /** CDP WebSocket URL */
  wsEndpoint: string;
  /** HTTP endpoint base URL */
  httpEndpoint: string;
  /** Kill the process */
  kill(): Promise<void>;
}

/**
 * Launch obscura as a CDP server
 *
 * Spawns the obscura process with `serve` subcommand and waits for
 * the CDP server to become ready by polling /json/version.
 */
export async function launchObscura(config: ResolvedLaunchOptions): Promise<LaunchedProcess> {
  const globalArgs = buildGlobalArgs(config);
  const serveArgs = buildServeArgs(config);
  const allArgs = [...globalArgs, ...serveArgs];

  const child = spawn(config.executablePath, allArgs, {
    cwd: config.cwd,
    stdio: config.quiet ? 'ignore' : ['ignore', 'pipe', 'pipe'],
    env: {
      ...process.env,
      // Ensure no terminal color codes in output
      NO_COLOR: '1',
    },
  });

  const httpEndpoint = `http://${config.host}:${config.port}`;
  const wsEndpoint = `ws://${config.host}:${config.port}`;

  // Track process exit for early failure detection
  let exited = false;
  let exitCode: number | null = null;
  let exitError = '';

  child.on('exit', (code, signal) => {
    exited = true;
    exitCode = code;
    if (code !== null && code !== 0) {
      exitError = `obscura exited with code ${code}`;
      if (signal) {
        exitError += ` (signal: ${signal})`;
      }
    }
  });

  child.on('error', (err) => {
    exited = true;
    exitError = `Failed to start obscura: ${err.message}`;
  });

  // Forward stderr to console in non-quiet mode
  if (!config.quiet && child.stderr) {
    child.stderr.on('data', (data) => {
      process.stderr.write(data);
    });
  }

  // Wait for CDP server to be ready
  const startTime = Date.now();
  const pollInterval = 100; // ms
  let lastError = '';

  while (Date.now() - startTime < config.timeout) {
    if (exited) {
      throw new Error(exitError || 'obscura process exited before CDP server was ready');
    }

    try {
      const version = await fetchJsonVersion(httpEndpoint);
      if (version) {
        // Server is ready
        const handle: LaunchedProcess = {
          process: child,
          wsEndpoint,
          httpEndpoint,
          kill: async () => {
            if (!exited) {
              child.kill('SIGTERM');
              // Wait for graceful shutdown
              await new Promise<void>((resolve) => {
                const timeout = setTimeout(() => {
                  if (!exited && child.pid) {
                    try {
                      process.kill(child.pid, 'SIGKILL');
                    } catch {
                      // Process already gone
                    }
                  }
                  resolve();
                }, 5000);

                child.on('exit', () => {
                  clearTimeout(timeout);
                  resolve();
                });
              });
            }
          },
        };
        return handle;
      }
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err);
    }

    // Wait before next poll
    await sleep(pollInterval);
  }

  // Timeout reached - kill the process and throw
  if (child.pid) {
    try {
      process.kill(child.pid, 'SIGKILL');
    } catch {
      // Process may already be gone
    }
  }

  throw new Error(
    `Timed out waiting for obscura CDP server at ${httpEndpoint} ` +
    `(timeout: ${config.timeout}ms). Last error: ${lastError}`
  );
}

/**
 * Fetch version info from CDP server's /json/version endpoint
 */
async function fetchJsonVersion(httpEndpoint: string): Promise<VersionInfo | null> {
  return new Promise((resolve, reject) => {
    const url = `${httpEndpoint}/json/version`;
    const req = http.get(url, { timeout: 2000 }, (res) => {
      if (res.statusCode !== 200) {
        res.resume();
        resolve(null);
        return;
      }

      let data = '';
      res.on('data', (chunk) => {
        data += chunk;
      });
      res.on('end', () => {
        try {
          const json = JSON.parse(data) as VersionInfo;
          if (json.Browser && json.webSocketDebuggerUrl) {
            resolve(json);
          } else {
            resolve(null);
          }
        } catch {
          resolve(null);
        }
      });
    });

    req.on('error', () => {
      resolve(null);
    });

    req.on('timeout', () => {
      req.destroy();
      resolve(null);
    });
  });
}

/**
 * Sleep for a given number of milliseconds
 */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
