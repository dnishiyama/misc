#!/usr/bin/env ts-node

import { Client } from 'pg';
import ExcelJS from 'exceljs';
import { exit } from 'process';

interface ExportOptions {
  dbUrl: string;
  outputFile: string;
  rowLimit: number;
}

async function parseArgs(): Promise<ExportOptions> {
  const args = process.argv.slice(2);
  let dbUrl: string | undefined;
  let outputFile = 'database-export.xlsx';
  let rowLimit = 100;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--db-url' && i + 1 < args.length) {
      dbUrl = args[i + 1];
      i++;
    } else if (arg === '--output' && i + 1 < args.length) {
      const nextArg = args[i + 1];
      if (nextArg) {
        outputFile = nextArg;
      }
      i++;
    } else if (arg === '--limit' && i + 1 < args.length) {
      const nextArg = args[i + 1];
      if (nextArg) {
        rowLimit = parseInt(nextArg, 10);
      }
      i++;
    }
  }

  if (!dbUrl) {
    console.error('Error: --db-url is required');
    console.log('Usage: ts-node export-db-to-excel.ts --db-url <connection-string> [--output <filename>] [--limit <number>]');
    exit(1);
  }

  return {
    dbUrl,
    outputFile,
    rowLimit,
  };
}

async function getPublicTables(client: Client): Promise<string[]> {
  const result = await client.query(`
    SELECT table_name 
    FROM information_schema.tables 
    WHERE table_schema = 'public' 
    AND table_type = 'BASE TABLE'
    ORDER BY table_name
  `);

  return result.rows.map((row) => row.table_name as string);
}

async function getTableData(args: { client: Client; tableName: string; limit: number }) {
  const { client, tableName, limit } = args;
  
  console.log(`Exporting table: ${tableName}`);
  
  const result = await client.query(`
    SELECT * FROM "${tableName}" LIMIT $1
  `, [limit]);

  return result;
}

async function exportToExcel(args: { tables: string[]; client: Client; outputFile: string; rowLimit: number }) {
  const { tables, client, outputFile, rowLimit } = args;
  
  const workbook = new ExcelJS.Workbook();
  
  for (const tableName of tables) {
    try {
      const result = await getTableData({ client, tableName, limit: rowLimit });
      
      if (result.rows.length === 0) {
        console.log(`  Skipping ${tableName} (no data)`);
        continue;
      }

      // Sanitize sheet name (Excel has restrictions)
      let sheetName = tableName.substring(0, 31); // Max 31 characters
      sheetName = sheetName.replace(/[:\\/?*\[\]]/g, '_'); // Remove invalid characters
      
      const worksheet = workbook.addWorksheet(sheetName);
      
      // Get column names from the result
      const columns = result.fields.map((field) => ({
        header: field.name,
        key: field.name,
        width: 15,
      }));
      
      worksheet.columns = columns;
      
      // Add rows
      result.rows.forEach((row) => {
        // Convert values to Excel-friendly formats
        const processedRow: Record<string, unknown> = {};
        for (const [key, value] of Object.entries(row)) {
          if (value === null) {
            processedRow[key] = null;
          } else if (value instanceof Date) {
            processedRow[key] = value;
          } else if (typeof value === 'object') {
            processedRow[key] = JSON.stringify(value);
          } else {
            processedRow[key] = value;
          }
        }
        worksheet.addRow(processedRow);
      });
      
      // Style the header row
      worksheet.getRow(1).font = { bold: true };
      worksheet.getRow(1).fill = {
        type: 'pattern',
        pattern: 'solid',
        fgColor: { argb: 'FFD3D3D3' },
      };
      
      console.log(`  Exported ${result.rows.length} rows from ${tableName}`);
    } catch (error) {
      console.error(`  Error exporting table ${tableName}:`, error);
    }
  }
  
  await workbook.xlsx.writeFile(outputFile);
  console.log(`\nExport complete! File saved to: ${outputFile}`);
}

async function main() {
  const options = await parseArgs();
  
  const client = new Client({
    connectionString: options.dbUrl,
  });

  try {
    console.log('Connecting to database...');
    await client.connect();
    console.log('Connected!\n');

    const tables = await getPublicTables(client);
    console.log(`Found ${tables.length} tables in public schema\n`);

    if (tables.length === 0) {
      console.log('No tables found in public schema');
      return;
    }

    await exportToExcel({
      tables,
      client,
      outputFile: options.outputFile,
      rowLimit: options.rowLimit,
    });

  } catch (error) {
    console.error('Error:', error);
    exit(1);
  } finally {
    await client.end();
  }
}

main();


