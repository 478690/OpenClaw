/**
 * Configuration constants for Moltbot Sandbox
 */

import type { MoltbotEnv } from './types';

/** Port that the Moltbot gateway listens on inside the container */
export const MOLTBOT_PORT = 18789;

/** Maximum time to wait for Moltbot to start (3 minutes) */
export const STARTUP_TIMEOUT_MS = 180_000;

/**
 * R2 bucket name for persistent storage.
 * Can be overridden via R2_BUCKET_NAME env var for test isolation.
 */
export function getR2BucketName(env?: { R2_BUCKET_NAME?: string }): string {
  return env?.R2_BUCKET_NAME || 'moltbot-data';
}

/**
 * Supabase configuration interface
 */
export interface SupabaseConfig {
  url: string;
  anonKey: string;
  serviceKey?: string;
  bucket: string;
}

/**
 * Get Supabase configuration from environment
 */
export function getSupabaseConfig(env: MoltbotEnv): SupabaseConfig | null {
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY) {
    return null;
  }
  return {
    url: env.SUPABASE_URL,
    anonKey: env.SUPABASE_ANON_KEY,
    serviceKey: env.SUPABASE_SERVICE_KEY,
    bucket: env.SUPABASE_BUCKET || 'moltbot-data',
  };
}
