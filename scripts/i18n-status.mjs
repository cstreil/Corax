#!/usr/bin/env node
// Translation progress for src/i18n/locales.
//
// `en` is the source of truth. A value counts as translated once it differs from
// the English text, so a freshly scaffolded locale starts at 0% - it carries the
// English strings on purpose, which keeps the UI readable while the work is in
// progress instead of rendering blanks.
//
//   node scripts/i18n-status.mjs              all locales, one line each
//   node scripts/i18n-status.mjs de           per namespace for one locale
//   node scripts/i18n-status.mjs de --missing open keys, path and English text
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(fileURLToPath(new URL(".", import.meta.url)), "..");
const LOCALES_DIR = path.join(ROOT, "src/i18n/locales");
const SOURCE = "en";

const args = process.argv.slice(2);
const listMissing = args.includes("--missing");
const localeArg = args.find((arg) => !arg.startsWith("--"));

function flatten(value, prefix = "", out = new Map()) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => flatten(item, `${prefix}[${index}]`, out));
  } else if (value !== null && typeof value === "object") {
    for (const [key, child] of Object.entries(value)) {
      flatten(child, prefix ? `${prefix}.${key}` : key, out);
    }
  } else {
    out.set(prefix, value);
  }
  return out;
}

function read(locale, namespace) {
  const file = path.join(LOCALES_DIR, locale, namespace);
  try {
    return flatten(JSON.parse(fs.readFileSync(file, "utf8")));
  } catch (error) {
    console.error(`  ! ${locale}/${namespace}: ${error.message}`);
    return new Map();
  }
}

const namespaces = fs
  .readdirSync(path.join(LOCALES_DIR, SOURCE))
  .filter((file) => file.endsWith(".json"))
  .sort();

const locales = fs
  .readdirSync(LOCALES_DIR, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .filter((locale) => locale !== SOURCE)
  .sort();

const source = new Map(namespaces.map((ns) => [ns, read(SOURCE, ns)]));

function stats(locale) {
  const rows = [];
  for (const namespace of namespaces) {
    const base = source.get(namespace);
    const target = read(locale, namespace);
    const missing = [];
    const open = [];
    let total = 0;
    let translated = 0;
    for (const [key, sourceValue] of base) {
      // Numbers and booleans in the demo data are not text to translate.
      if (typeof sourceValue !== "string") continue;
      total += 1;
      const value = target.get(key);
      if (value === undefined) {
        missing.push(key);
        open.push([key, sourceValue]);
      } else if (typeof value === "string" && value !== sourceValue) {
        translated += 1;
      } else {
        // Still the English text: a placeholder, or a string that is the same
        // in both languages ("Comail", "OK"). Both read as not yet reviewed.
        open.push([key, sourceValue]);
      }
    }
    rows.push({ namespace, total, translated, missing, open });
  }
  return rows;
}

const pad = (value, width) => String(value).padStart(width);

const targets = localeArg ? locales.filter((locale) => locale === localeArg) : locales;
if (targets.length === 0) {
  console.error(`unknown locale: ${localeArg} (available: ${locales.join(", ")})`);
  process.exit(2);
}

for (const locale of targets) {
  const rows = stats(locale);
  const total = rows.reduce((sum, row) => sum + row.total, 0);
  const translated = rows.reduce((sum, row) => sum + row.translated, 0);
  const percent = total === 0 ? 0 : Math.round((translated / total) * 100);

  if (!localeArg) {
    console.log(
      `${locale}  ${pad(translated, 5)}/${total}  ${pad(percent, 4)}%  ${rows
        .filter((row) => row.missing.length > 0)
        .map((row) => `${row.namespace.replace(/\.json$/, "")}:${row.missing.length}`)
        .join(" ")}`,
    );
    continue;
  }

  console.log(`${locale}  ${translated}/${total} translated (${percent}%)`);
  for (const row of rows) {
    const open = row.total - row.translated;
    console.log(
      `  ${row.namespace.padEnd(18)} ${pad(row.total, 5)} keys  ${pad(
        row.translated,
        5,
      )} done  ${pad(open, 5)} open`,
    );
    if (listMissing && row.open.length > 0) {
      for (const [key, sourceValue] of row.open) {
        const kind = row.missing.includes(key) ? "missing" : "open   ";
        console.log(`    ${kind}  ${key}  ${JSON.stringify(sourceValue.slice(0, 70))}`);
      }
    }
  }
}
