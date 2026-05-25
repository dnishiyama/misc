#!/usr/bin/env ts-node

import { Client } from 'pg';
import { exit } from 'process';

interface ActivityResult {
  db_name: string;
  last_activity: Date | null;
  error?: string;
}

interface CheckOptions {
  dbUrl: string;
  sortBy: 'name' | 'activity';
  includeSystem: boolean;
}

async function parseArgs(): Promise<CheckOptions> {
  const args = process.argv.slice(2);
  let dbUrl: string | undefined;
  let sortBy: 'name' | 'activity' = 'activity';
  let includeSystem = false;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--db-url' && i + 1 < args.length) {
      dbUrl = args[i + 1];
      i++;
    } else if (arg === '--sort' && i + 1 < args.length) {
      const nextArg = args[i + 1];
      if (nextArg === 'name' || nextArg === 'activity') {
        sortBy = nextArg;
      }
      i++;
    } else if (arg === '--include-system') {
      includeSystem = true;
    }
  }

  if (!dbUrl) {
    console.error('Error: --db-url is required');
    console.log('Usage: ts-node check-db-activity.ts --db-url <connection-string> [--sort name|activity] [--include-system]');
    console.log('\nOptions:');
    console.log('  --db-url         PostgreSQL connection string (required)');
    console.log('  --sort           Sort by "name" or "activity" (default: activity)');
    console.log('  --include-system Include system databases (postgres, template0, template1)');
    exit(1);
  }

  return {
    dbUrl,
    sortBy,
    includeSystem,
  };
}

async function getAllDatabases(args: { client: Client; includeSystem: boolean }): Promise<string[]> {
  const { client, includeSystem } = args;
  
  let query = `
    SELECT datname 
    FROM pg_database 
    WHERE datistemplate = false
  `;
  
  if (!includeSystem) {
    query += ` AND datname NOT IN ('postgres', 'template0', 'template1')`;
  }
  
  query += ` ORDER BY datname`;

  const result = await client.query(query);
  return result.rows.map((row) => row.datname as string);
}

async function getLastActivity(args: { dbUrl: string; dbName: string }): Promise<ActivityResult> {
  const { dbUrl, dbName } = args;
  
  // Parse the connection string and replace the database name
  const url = new URL(dbUrl);
  const pathParts = url.pathname.split('/');
  pathParts[pathParts.length - 1] = dbName;
  url.pathname = pathParts.join('/');
  
  const client = new Client({
    connectionString: url.toString(),
  });

  try {
    await client.connect();
    
    const result = await client.query(`
      SELECT
        current_database() AS db_name,
        MAX(
          GREATEST(
            last_vacuum,
            last_autovacuum,
            last_analyze,
            last_autoanalyze
          )
        ) AS last_activity
      FROM pg_stat_all_tables
    `);

    const row = result.rows[0];
    return {
      db_name: row?.db_name as string ?? dbName,
      last_activity: row?.last_activity as Date | null ?? null,
    };
  } catch (error) {
    return {
      db_name: dbName,
      last_activity: null,
      error: error instanceof Error ? error.message : String(error),
    };
  } finally {
    await client.end();
  }
}

function formatDuration(date: Date | null): string {
  if (!date) {
    return 'Never / No stats';
  }

  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffSeconds = Math.floor(diffMs / 1000);
  const diffMinutes = Math.floor(diffSeconds / 60);
  const diffHours = Math.floor(diffMinutes / 60);
  const diffDays = Math.floor(diffHours / 24);

  if (diffDays > 0) {
    return `${diffDays} day${diffDays === 1 ? '' : 's'} ago`;
  } else if (diffHours > 0) {
    return `${diffHours} hour${diffHours === 1 ? '' : 's'} ago`;
  } else if (diffMinutes > 0) {
    return `${diffMinutes} minute${diffMinutes === 1 ? '' : 's'} ago`;
  } else {
    return `${diffSeconds} second${diffSeconds === 1 ? '' : 's'} ago`;
  }
}

function printResults(args: { results: ActivityResult[]; sortBy: 'name' | 'activity' }) {
  const { results, sortBy } = args;
  
  // Sort results
  const sorted = [...results].sort((a, b) => {
    if (sortBy === 'name') {
      return a.db_name.localeCompare(b.db_name);
    } else {
      // Sort by activity (most recent first)
      if (a.last_activity === null && b.last_activity === null) {
        return a.db_name.localeCompare(b.db_name);
      }
      if (a.last_activity === null) return 1;
      if (b.last_activity === null) return -1;
      return b.last_activity.getTime() - a.last_activity.getTime();
    }
  });

  console.log('\n╔════════════════════════════════════════════════════════════════╗');
  console.log('║           Database Activity Report                             ║');
  console.log('╚════════════════════════════════════════════════════════════════╝\n');

  const maxDbNameLength = Math.max(...sorted.map((r) => r.db_name.length), 'Database'.length);
  const maxActivityLength = Math.max(...sorted.map((r) => formatDuration(r.last_activity).length), 'Last Activity'.length);

  // Print header
  console.log(
    'Database'.padEnd(maxDbNameLength + 2) +
    'Last Activity'.padEnd(maxActivityLength + 2) +
    'Timestamp'
  );
  console.log('─'.repeat(maxDbNameLength + maxActivityLength + 35));

  // Print rows
  sorted.forEach((result) => {
    const dbName = result.db_name.padEnd(maxDbNameLength + 2);
    const duration = formatDuration(result.last_activity).padEnd(maxActivityLength + 2);
    const timestamp = result.last_activity 
      ? result.last_activity.toISOString()
      : result.error 
        ? `Error: ${result.error}`
        : 'No activity recorded';

    console.log(`${dbName}${duration}${timestamp}`);
  });

  console.log('\n' + '─'.repeat(maxDbNameLength + maxActivityLength + 35));
  console.log(`Total databases: ${results.length}`);
  
  const activeCount = results.filter((r) => r.last_activity !== null).length;
  const inactiveCount = results.length - activeCount;
  console.log(`Active: ${activeCount} | Inactive/No Stats: ${inactiveCount}\n`);

  // Show warning about stats
  console.log('⚠️  Note: Activity is based on vacuum/analyze timestamps.');
  console.log('    Stats reset on Postgres restart. This is an approximation.\n');
}

async function main() {
  const options = await parseArgs();
  
  // Connect to the default database to get list of all databases
  const mainClient = new Client({
    connectionString: options.dbUrl,
  });

  try {
    console.log('Connecting to PostgreSQL instance...');
    await mainClient.connect();
    console.log('Connected!\n');

    console.log('Fetching list of databases...');
    const databases = await getAllDatabases({
      client: mainClient,
      includeSystem: options.includeSystem,
    });
    console.log(`Found ${databases.length} database${databases.length === 1 ? '' : 's'}\n`);

    if (databases.length === 0) {
      console.log('No databases found.');
      return;
    }

    console.log('Checking activity for each database...');
    const results: ActivityResult[] = [];

    for (const dbName of databases) {
      process.stdout.write(`  Checking ${dbName}...`);
      const result = await getLastActivity({
        dbUrl: options.dbUrl,
        dbName,
      });
      results.push(result);
      console.log(' ✓');
    }

    printResults({ results, sortBy: options.sortBy });

  } catch (error) {
    console.error('Error:', error);
    exit(1);
  } finally {
    await mainClient.end();
  }
}

main();

