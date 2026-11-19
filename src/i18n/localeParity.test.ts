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

/**
 * Strings that stay English in a hand-translated locale on purpose: product and
 * protocol names, units, format-only strings, e-mail/URL examples, search syntax
 * and the demo rows of the onboarding preview that would look wrong translated.
 * Anything else has to be translated, so a newly added English string fails here
 * instead of shipping silently. Regenerate only after reviewing the value.
 */
const UNTRANSLATED_BY_DESIGN: Record<string, readonly string[]> = {
  "calendar.json": ["allDayMore"],
  "commands.json": ["section.Navigation", "section.Meta"],
  "common.json": [
    // Names, protocols, units and addresses that read the same in German.
    "view.inbox",
    "view.spam",
    "action.spam",
    "syncState.offline",
    "topbar.offline",
    "unit.bytes",
    "unit.kilobytes",
    "unit.megabytes",
    // Search chips and operators: the values are typed syntax.
    "search.ops.is",
    "search.values.in.inbox",
    "search.values.in.spam",
    "search.chip.label",
    "search.chip.in",
    "search.explain.in",
    "search.explain.sentence",
    "search.reason.content",
    "label.title",
    "sidebar.labels",
    // Pure format strings.
    "snoozeFmt.dateAt",
  ],
  "compose.json": [
    // Reply/forward prefixes stay English so threading keeps recognising them.
    "replyPrefix",
    "forwardPrefix",
    "ccBcc",
    "cc",
    "bcc",
    "recipientPlaceholder",
    "fmt.linkPlaceholder",
  ],
  "onboarding.json": [
    // Providers, hosts and ports.
    "provider.fastmail",
    "provider.icloud",
    "provider.gmail",
    "field.port",
    "placeholder.displayName",
    "placeholder.imapHost",
    "placeholder.smtpHost",
    "flow.personalize.themes.system",
    // Demo inbox: titles, senders, clock times and the keys/refs the preview
    // resolves in code. Subjects, snippets and weekday labels are translated.
    "preview.title",
    "preview.tabs[1].name",
    "preview.tabs[2].name",
    "preview.paletteItems[0].key",
    "preview.paletteItems[1].key",
    "preview.paletteItems[2].key",
    "preview.paletteItems[3].key",
    "preview.rows[0].from",
    "preview.rows[0].labels[0]",
    "preview.rows[0].time",
    "preview.rows[0].group",
    "preview.rows[1].from",
    "preview.rows[1].time",
    "preview.rows[1].group",
    "preview.rows[2].from",
    "preview.rows[2].labels[0]",
    "preview.rows[2].labels[1]",
    "preview.rows[2].time",
    "preview.rows[2].group",
    "preview.rows[3].from",
    "preview.rows[3].labels[0]",
    "preview.rows[3].group",
    "preview.rows[4].from",
    "preview.rows[4].group",
    "preview.rows[5].from",
    "preview.rows[5].group",
    "preview.rows[6].from",
    "preview.rows[6].group",
    "preview.rows[7].from",
    "preview.rows[7].group",
    "preview.rows[8].from",
    "preview.rows[8].group",
    "preview.searchQuery",
    "preview.search.query",
    "preview.search.results[0].from",
    "preview.search.results[0].labels[0]",
    "preview.search.results[0].time",
    "preview.search.results[0].group",
    "preview.search.results[1].from",
    "preview.search.results[1].group",
    "preview.search.results[2].from",
    "preview.search.results[2].group",
  ],
  "settings.json": [
    // Section names, system/theme names and generic nouns spelled alike.
    "section.labels",
    "navigation.system",
    "theme.snow",
    "theme.carbon",
    "theme.system",
    "language.system",
    "font.system",
    "sync.foreground",
    "labels.title",
    "labels.nameLabel",
    "labels.autoRuleName",
    "labels.tab",
    "snippets.nameLabel",
    "splits.nameLabel",
    "splits.cond.placeholders.sender",
    "rules.nameLabel",
    "rules.optional",
    "inboxUi.avatar",
    "about.version",
    "rag.indexLabel",
    "mcp.status",
    "mcp.port",
    "accent.colors.orange",
    "ai.statusLabel",
    "ai.tier.intelligent",
    // Model ids, endpoints, key formats and provider names are not prose.
    "ai.loading",
    "ai.apiKeyPlaceholder",
    "ai.baseUrlPlaceholder",
    "ai.modelPlaceholder",
    "oauth.googleClientIdPlaceholder",
    "oauth.googleClientSecretPlaceholder",
    "oauth.msClientIdPlaceholder",
    "oauth.msClientSecretPlaceholder",
    "oauth.guide.googleTitle",
    "oauth.guide.msTitle",
    "accounts.provider.imap",
    "accounts.provider.gmail",
    "accounts.provider.microsoft",
    "decision.provider.openai",
    "decision.provider.commandcode",
    "decision.formatLabel",
    "decision.format.openrouter",
    "decision.format.openai",
    // Pure format strings.
    "sync.progress",
    "splits.routesTo",
    "accounts.via",
  ],
  "thread.json": [
    "attachment.preview.details",
    "attachment.preview.dimensions",
    "attachment.kind.video",
    "attachment.kind.audio",
  ],
};

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

          // A hand-translated locale must not carry English text, except for the
          // documented names, units, formats and demo rows above.
          if (COMPLETE_LOCALES.has(locale)) {
            const allowed = new Set(UNTRANSLATED_BY_DESIGN[namespace] ?? []);
            const stillEnglish = [...source]
              .filter(
                ([key, value]) =>
                  typeof value === "string" && value === target.get(key) && !allowed.has(key),
              )
              .map(([key]) => key);
            expect(stillEnglish, `English left in ${locale}/${namespace}`).toEqual([]);
          }

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
