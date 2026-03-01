import type { Sandbox } from '@cloudflare/sandbox';
import type { MoltbotEnv } from '../types';
import { getR2BucketName, getSupabaseConfig } from '../config';
import { ensureRcloneConfig } from './r2';
import { ensureSupabaseConfig, isSupabaseConfigured, getSupabaseBucketName } from './supabase';

export interface SyncResult {
  success: boolean;
  lastSync?: string;
  error?: string;
  details?: string;
}

const RCLONE_FLAGS = '--transfers=16 --fast-list --s3-no-check-bucket';
const LAST_SYNC_FILE = '/tmp/.last-sync';

function rcloneRemote(env: MoltbotEnv, prefix: string): string {
  return `r2:${getR2BucketName(env)}/${prefix}`;
}

/**
 * Detect which config directory exists in the container.
 */
async function detectConfigDir(sandbox: Sandbox): Promise<string | null> {
  const check = await sandbox.exec(
    'test -f /root/.openclaw/openclaw.json && echo openclaw || ' +
      '(test -f /root/.clawdbot/clawdbot.json && echo clawdbot || echo none)',
  );
  const result = check.stdout?.trim();
  if (result === 'openclaw') return '/root/.openclaw';
  if (result === 'clawdbot') return '/root/.clawdbot';
  return null;
}

/**
 * Sync OpenClaw config and workspace from container to R2 for persistence.
 * Uses rclone for direct S3 API access (no FUSE mount overhead).
 */
export async function syncToR2(sandbox: Sandbox, env: MoltbotEnv): Promise<SyncResult> {
  if (!(await ensureRcloneConfig(sandbox, env))) {
    return { success: false, error: 'R2 storage is not configured' };
  }

  const configDir = await detectConfigDir(sandbox);
  if (!configDir) {
    return {
      success: false,
      error: 'Sync aborted: no config file found',
      details: 'Neither openclaw.json nor clawdbot.json found in config directory.',
    };
  }

  const remote = (prefix: string) => rcloneRemote(env, prefix);

  // Sync config (rclone sync propagates deletions)
  const configResult = await sandbox.exec(
    `rclone sync ${configDir}/ ${remote('openclaw/')} ${RCLONE_FLAGS} --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' --exclude='.git/**'`,
    { timeout: 120000 },
  );
  if (!configResult.success) {
    return {
      success: false,
      error: 'Config sync failed',
      details: configResult.stderr?.slice(-500),
    };
  }

  // Sync workspace (non-fatal, rclone sync propagates deletions)
  await sandbox.exec(
    `test -d /root/clawd && rclone sync /root/clawd/ ${remote('workspace/')} ${RCLONE_FLAGS} --exclude='skills/**' --exclude='.git/**' || true`,
    { timeout: 120000 },
  );

  // Sync skills (non-fatal)
  await sandbox.exec(
    `test -d /root/clawd/skills && rclone sync /root/clawd/skills/ ${remote('skills/')} ${RCLONE_FLAGS} || true`,
    { timeout: 120000 },
  );

  // Write timestamp
  await sandbox.exec(`date -Iseconds > ${LAST_SYNC_FILE}`);
  const tsResult = await sandbox.exec(`cat ${LAST_SYNC_FILE}`);
  const lastSync = tsResult.stdout?.trim();

  return { success: true, lastSync };
}

/**
 * Sync OpenClaw config and workspace from container to Supabase for persistence.
 * Uses Supabase Storage API for file upload/download.
 */
export async function syncToSupabase(sandbox: Sandbox, env: MoltbotEnv): Promise<SyncResult> {
  if (!(await ensureSupabaseConfig(sandbox, env))) {
    return { success: false, error: 'Supabase storage is not configured' };
  }

  const configDir = await detectConfigDir(sandbox);
  if (!configDir) {
    return {
      success: false,
      error: 'Sync aborted: no config file found',
      details: 'Neither openclaw.json nor clawdbot.json found in config directory.',
    };
  }

  const supabaseConfig = getSupabaseConfig(env);
  if (!supabaseConfig) {
    return { success: false, error: 'Supabase configuration is invalid' };
  }

  const bucketName = getSupabaseBucketName(env);

  // Helper function to upload directory to Supabase Storage
  async function uploadDirectoryToSupabase(
    localPath: string,
    remotePath: string,
    excludePatterns: string[] = [],
  ): Promise<boolean> {
    // Check if directory exists
    const dirCheck = await sandbox.exec(`test -d ${localPath} && echo yes || echo no`);
    if (dirCheck.stdout?.trim() !== 'yes') {
      console.log(`Directory does not exist: ${localPath}`);
      return true; // Not an error, just doesn't exist
    }

    // List files in directory
    const filesResult = await sandbox.exec(
      `find ${localPath} -type f ${excludePatterns.map((p) => `-not -path '${p}'`).join(' ')}`,
    );
    if (!filesResult.success) {
      console.log(`Failed to list files in ${localPath}`);
      return false;
    }

    const files = filesResult.stdout?.trim().split('\n').filter(Boolean) || [];
    
    for (const file of files) {
      const relativePath = file.replace(localPath, '').replace(/^\//, '');
      const remoteKey = `${remotePath}/${relativePath}`;
      
      // Read file content
      const fileContent = await sandbox.readFile(file);
      if (!fileContent) {
        console.log(`Failed to read file: ${file}`);
        continue;
      }

      // Upload to Supabase Storage using curl
      // Supabase Storage uses S3-compatible API
      const uploadCommand = `
        curl -X POST \\
        "${supabaseConfig.url}/storage/v1/object/${bucketName}/${remoteKey}" \\
        -H "Authorization: Bearer ${supabaseConfig.serviceKey || supabaseConfig.anonKey}" \\
        -H "Content-Type: application/octet-stream" \\
        --data-binary @-
      `;
      
      const uploadResult = await sandbox.exec(
        `echo '${fileContent.replace(/'/g, "'\\\\''")}' | ${uploadCommand}`,
        { timeout: 60000 },
      );
      
      if (!uploadResult.success) {
        console.log(`Failed to upload ${remoteKey}: ${uploadResult.stderr}`);
      }
    }

    return true;
  }

  // Sync config directory
  const configResult = await uploadDirectoryToSupabase(
    configDir,
    'openclaw',
    ['*.lock', '*.log', '*.tmp', '.git/**'],
  );
  
  if (!configResult) {
    return {
      success: false,
      error: 'Config sync to Supabase failed',
    };
  }

  // Sync workspace directory (non-fatal)
  await uploadDirectoryToSupabase(
    '/root/clawd',
    'workspace',
    ['skills/**', '.git/**'],
  );

  // Sync skills directory (non-fatal)
  await uploadDirectoryToSupabase(
    '/root/clawd/skills',
    'skills',
    ['.git/**'],
  );

  // Write timestamp
  await sandbox.exec(`date -Iseconds > ${LAST_SYNC_FILE}`);
  const tsResult = await sandbox.exec(`cat ${LAST_SYNC_FILE}`);
  const lastSync = tsResult.stdout?.trim();

  return { success: true, lastSync };
}

/**
 * Detect which storage backend is configured and sync to it.
 * Priority: R2 > Supabase (if R2 is configured, use it; otherwise use Supabase if available)
 */
export async function syncToStorage(sandbox: Sandbox, env: MoltbotEnv): Promise<SyncResult> {
  // Check R2 configuration first
  const hasR2Config = !!(env.R2_ACCESS_KEY_ID && env.R2_SECRET_ACCESS_KEY && env.CF_ACCOUNT_ID);
  
  // Check Supabase configuration
  const hasSupabaseConfig = isSupabaseConfigured(env);

  if (hasR2Config) {
    console.log('Using R2 for storage sync');
    return syncToR2(sandbox, env);
  } else if (hasSupabaseConfig) {
    console.log('Using Supabase for storage sync');
    return syncToSupabase(sandbox, env);
  } else {
    return {
      success: false,
      error: 'No storage backend configured',
      details: 'Please configure either R2 or Supabase for persistent storage.',
    };
  }
}
