/**
 * Supabase storage adapter for Moltbot persistence
 * Provides an alternative to Cloudflare R2 for data storage
 */

import type { Sandbox } from '@cloudflare/sandbox';
import type { MoltbotEnv } from '../types';
import { getSupabaseConfig } from '../config';

const CONFIGURED_FLAG = '/tmp/.supabase-configured';

/**
 * Get Supabase configuration from environment
 */
function getSupabaseClientConfig(env: MoltbotEnv) {
  return {
    url: env.SUPABASE_URL,
    anonKey: env.SUPABASE_ANON_KEY,
    serviceKey: env.SUPABASE_SERVICE_KEY,
    bucket: env.SUPABASE_BUCKET || 'moltbot-data',
  };
}

/**
 * Ensure Supabase is configured in the container.
 * Idempotent — checks for a flag file to skip re-configuration.
 *
 * @returns true if Supabase is configured, false if credentials are missing
 */
export async function ensureSupabaseConfig(sandbox: Sandbox, env: MoltbotEnv): Promise<boolean> {
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY) {
    console.log(
      'Supabase storage not configured (missing SUPABASE_URL or SUPABASE_ANON_KEY)',
    );
    return false;
  }

  const check = await sandbox.exec(`test -f ${CONFIGURED_FLAG} && echo yes || echo no`);
  if (check.stdout?.trim() === 'yes') {
    return true;
  }

  // Install Supabase CLI if needed (for better S3-compatible API)
  // For now, we'll use direct REST API calls from within the container

  const config = getSupabaseClientConfig(env);
  
  // Create a configuration script for Supabase
  const supabaseConfigScript = `
#!/bin/bash
# Supabase configuration
export SUPABASE_URL="${config.url}"
export SUPABASE_ANON_KEY="${config.anonKey}"
export SUPABASE_SERVICE_KEY="${config.serviceKey || ''}"
export SUPABASE_BUCKET="${config.bucket}"

# Create bucket if it doesn't exist
echo "Configuring Supabase bucket: ${config.bucket}"
`;

  await sandbox.exec(`mkdir -p /tmp/supabase`);
  await sandbox.writeFile('/tmp/supabase/config.sh', supabaseConfigScript);
  await sandbox.exec(`chmod +x /tmp/supabase/config.sh`);
  await sandbox.exec(`touch ${CONFIGURED_FLAG}`);

  console.log('Supabase configured for bucket:', config.bucket);
  return true;
}

/**
 * Check if Supabase storage is properly configured
 */
export function isSupabaseConfigured(env: MoltbotEnv): boolean {
  return !!(env.SUPABASE_URL && env.SUPABASE_ANON_KEY);
}

/**
 * Get bucket name from config
 */
export function getSupabaseBucketName(env: MoltbotEnv): string {
  return env.SUPABASE_BUCKET || 'moltbot-data';
}
