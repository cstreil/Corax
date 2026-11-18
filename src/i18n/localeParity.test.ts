// Guards the locale catalogs: a translation may never change the shape of the
// source catalog, drop a `{{placeholder}}`, or break an inline tag. Runs for
// every locale folder, so a new language is covered the moment it is added.
//
// Catalogs come in through Vite's glob (same mechanism as src/i18n/index.ts)
// rather than the filesystem, which keeps the test free of Node typings.
import { describe, expect, it } from "vitest";

const SOURCE = "en";

/**
 * Locales that must mirror the source key for key. The machine-translated ones
 * are allowed to lag behind: i18next falls back to English for a missing key,
 * so a gap shows English text but never an empty string. `de` is translated by
 * hand and is expected to stay complete.
 */
const COMPLETE_LOCALES = new Set(["de"]);

type Json = string | number | boolean | null | Json[] | { [key: string]: Json };

interface CatalogModule {
  eager: true;
  import: "default";
}

const CATALOGS = import.meta.glob("./locales/*/*.json", {
  eager: true,
  import: "default",
} as CatalogModule) as Record<string, Json>;

const pathOf = (locale: string, namespace: string) => `./locales/${locale}/${namespace}`;

const namespaces = Object.keys(CATALOGS)
  .filter((file) => file.startsWith(`./locales/${SOURCE}/`))
  .map((file) => file.slice(`./locales/${SOURCE}/`.length))
  .sort();

const locales = [...new Set(Object.keys(CATALOGS).map((file) => file.split("/")[2]))].sort();

/** Flatten to `a.b[0].c` so keys and leaves compare independently of nesting. */
function flatten(value: Json, prefix = "", out = new Map<string, Json>()): Map<string, Json> {
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

/** `{{name}}` placeholders, order-insensitive, whitespace-tolerant. */
const placeholders = (text: string): string[] =>
  [...text.matchAll(/\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/g)].map((match) => match[1]).sort();

/** Inline tags such as `<b>`, `</b>`, `<kbd>`, `<code>`. */
const tags = (text: string): string[] =>
  [...text.matchAll(/<\/?([a-z][a-z0-9]*)[^>]*>/g)].map((match) => match[1]).sort();

const sourceCatalogs = new Map(
  namespaces.map((namespace) => [namespace, flatten(CATALOGS[pathOf(SOURCE, namespace)])]),
);

describe("locale catalogs", () => {
  for (const locale of locales) {
    describe(locale, () => {
      for (const namespace of namespaces) {
        it(`${namespace} keeps the source structure`, () => {
          const source = sourceCatalogs.get(namespace)!;
          const raw = CATALOGS[pathOf(locale, namespace)];
          expect(raw, `${locale}/${namespace} is missing`).toBeDefined();

          const target = flatten(raw);
          const missing = [...source.keys()].filter((key) => !target.has(key));
          const extra = [...target.keys()].filter((key) => !source.has(key));

          if (COMPLETE_LOCALES.has(locale)) {
            expect(missing, `untranslated keys in ${locale}/${namespace}`).toEqual([]);
          }
          // An extra key is never a fallback - it is a key the UI does not know.
          expect(extra, `unknown keys in ${locale}/${namespace}`).toEqual([]);

          for (const [key, sourceValue] of source) {
            const targetValue = target.get(key);
            if (targetValue === undefined) continue;

            expect(typeof targetValue, `${locale}/${namespace}:${key} type`).toBe(
              typeof sourceValue,
            );
            if (typeof sourceValue !== "string" || typeof targetValue !== "string") continue;

            // A blank value renders as nothing at all; English would be better.
            expect(targetValue.trim(), `${locale}/${namespace}:${key} is empty`).not.toBe("");
            expect(placeholders(targetValue), `${locale}/${namespace}:${key} placeholders`).toEqual(
              placeholders(sourceValue),
            );
            expect(tags(targetValue), `${locale}/${namespace}:${key} tags`).toEqual(
              tags(sourceValue),
            );
          }
        });
      }
    });
  }
});
