/**
 * Shared type definitions for obscura-ts SDK
 */

/**
 * Launch options for starting an obscura CDP server
 */
export interface LaunchOptions {
  /** Path to obscura binary (auto-detected if not specified) */
  executablePath?: string;
  /** CDP server port (default: 9222) */
  port?: number;
  /** Bind host (default: "127.0.0.1") */
  host?: string;
  /** Enable stealth mode (anti-detection + tracker blocking) */
  stealth?: boolean;
  /** HTTP/SOCKS5 proxy URL */
  proxy?: string;
  /** Number of parallel worker processes (default: 1) */
  workers?: number;
  /** Custom User-Agent string */
  userAgent?: string;
  /** V8 engine flags (e.g. "--max-old-space-size=4096") */
  v8Flags?: string;
  /** Launch timeout in milliseconds (default: 30000) */
  timeout?: number;
  /** Working directory for obscura process */
  cwd?: string;
  /** Allow file:// navigation */
  allowFileAccess?: boolean;
  /** Allow connections to private/loopback addresses */
  allowPrivateNetwork?: boolean;
  /** Suppress logs */
  quiet?: boolean;
  /** Enable verbose logging */
  verbose?: boolean;
}

/**
 * Options for connecting to an existing CDP server
 */
export interface ConnectOptions {
  /** WebSocket endpoint URL (e.g. "ws://127.0.0.1:9222") */
  endpointURL: string;
  /** Connection timeout in milliseconds (default: 30000) */
  timeout?: number;
}

/**
 * Navigation options for page.goto()
 */
export interface GotoOptions {
  /** Wait until condition: "load" | "domcontentloaded" | "networkidle" */
  waitUntil?: 'load' | 'domcontentloaded' | 'networkidle' | 'commit';
  /** Navigation timeout in milliseconds */
  timeout?: number;
  /** Referer header value */
  referer?: string;
}

/**
 * Wait options for page.waitForSelector()
 */
export interface WaitOptions {
  /** Wait for element state: "visible" | "hidden" | "attached" | "detached" */
  state?: 'visible' | 'hidden' | 'attached' | 'detached';
  /** Timeout in milliseconds (default: 30000) */
  timeout?: number;
}

/**
 * Screenshot options
 */
export interface ScreenshotOptions {
  /** Output file path */
  path?: string;
  /** Image type: "png" | "jpeg" */
  type?: 'png' | 'jpeg';
  /** JPEG quality (0-100) */
  quality?: number;
  /** Full page screenshot */
  fullPage?: boolean;
  /** Clip region */
  clip?: { x: number; y: number; width: number; height: number };
}

/**
 * Cookie data structure
 */
export interface Cookie {
  name: string;
  value: string;
  domain?: string;
  path?: string;
  expires?: number;
  httpOnly?: boolean;
  secure?: boolean;
  sameSite?: 'Strict' | 'Lax' | 'None';
}

/**
 * Network request info
 */
export interface NetworkRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  resourceType: string;
}

/**
 * Console message from the page
 */
export interface ConsoleMessage {
  type: string;
  text: string;
  location?: { url: string; lineNumber: number; columnNumber: number };
}

/**
 * Version info from CDP server
 */
export interface VersionInfo {
  Browser: string;
  'Protocol-Version': string;
  'User-Agent': string;
  'V8-Version': string;
  'WebKit-Version': string;
  webSocketDebuggerUrl: string;
}

/**
 * Target/page info from CDP server
 */
export interface TargetInfo {
  description: string;
  devtoolsFrontendUrl: string;
  id: string;
  title: string;
  type: string;
  url: string;
  webSocketDebuggerUrl: string;
}

/**
 * Resolved configuration with all defaults filled in
 */
export interface ResolvedLaunchOptions {
  executablePath: string;
  port: number;
  host: string;
  stealth: boolean;
  proxy?: string;
  workers: number;
  userAgent?: string;
  v8Flags?: string;
  timeout: number;
  cwd?: string;
  allowFileAccess: boolean;
  allowPrivateNetwork: boolean;
  quiet: boolean;
  verbose: boolean;
}
