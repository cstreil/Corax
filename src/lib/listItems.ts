import { defaultRangeExtractor, type Range } from "@tanstack/react-virtual";
import type { ThreadSummary } from "../ipc/types";
import { dateGroup, longDate } from "./format";

/** One inbox tab (other than Important) to preview as a bundle row. */
export type BundleTab = { key: string; name: string; splitId?: number; labelId?: number };

/** A non-Important inbox tab collapsed into one comfortable-list row. */
/** `count` is the tab's badge; `unread` says whether to style the row unread.
 *  They differ for a split that badges every conversation (`countAll`). */
export type Bundle = BundleTab & { count?: number; unread: boolean; threads: ThreadSummary[] };

/** One virtualized row: a date header, a bundle, a thread, or the opened
 *  thread's panel. Headers, bundles and thread rows share one row height; the
 *  expanded panel is the single taller item, so the list is no longer
 *  uniform-height and the cursor + gutter-sweep math reads the virtualizer's
 *  measured offsets instead of multiplying by a constant. */
export type ListItem =
  | { kind: "header"; key: string; label: string; subtitle?: string }
  | { kind: "bundle"; bundle: Bundle }
  | { kind: "thread"; thread: ThreadSummary }
  | { kind: "expanded"; thread: ThreadSummary };

/** A header to show directly above one thread (search result groups). */
export type SectionHeader = { label: string; subtitle?: string };

/** One laid-out row, as the virtualizer reports it. */
export type RowOffset = { index: number; start: number; size: number };

/** The item index at a scroll offset, from the virtualizer's measured rows.
 *  Rows are no longer uniform - the opened thread's panel is taller than a row
 *  - so the pointer-to-index mapping reads the measured offsets instead of
 *  dividing by a constant. An offset above the first row clamps to it, one
 *  below the last clamps to the last. */
export function indexAtOffset(rows: readonly RowOffset[], offset: number): number {
  for (const row of rows) {
    if (offset < row.start + row.size) return row.index;
  }
  return rows.length > 0 ? rows[rows.length - 1].index : 0;
}

/** Virtualizer range extractor that keeps one index rendered even when it is
 *  outside the visible range. The opened conversation is a virtualized item;
 *  unmounting it would drop the inline composer's unsaved text, because its
 *  autosave only runs every few seconds. */
export function rangeWithPinnedIndex(range: Range, pinnedIndex: number): number[] {
  const indexes = defaultRangeExtractor(range);
  if (pinnedIndex >= 0 && !indexes.includes(pinnedIndex)) {
    indexes.push(pinnedIndex);
    indexes.sort((a, b) => a - b);
  }
  return indexes;
}

/** Interleave date-group headers into the thread rows. When grouping is off the
 *  result is just the threads, one item each - identical to the old behavior -
 *  plus any `sections` headers, each placed above the thread id it is keyed by.
 *  Bundles always lead the list, above the first date header.
 *
 *  `expandedThreadId` inserts that thread's panel directly below its own row,
 *  so opening a conversation pushes the rest of the list down instead of
 *  replacing it. A thread that is not in `threads` adds no panel. */
export function buildListItems(
  threads: ThreadSummary[],
  grouped: boolean,
  bundles: Bundle[] = [],
  now = Date.now(),
  sections?: ReadonlyMap<number, SectionHeader>,
  expandedThreadId?: number | null,
): ListItem[] {
  const bundleItems: ListItem[] = bundles.map((bundle) => ({ kind: "bundle", bundle }));
  const pushThread = (items: ListItem[], thread: ThreadSummary) => {
    items.push({ kind: "thread", thread });
    if (expandedThreadId != null && thread.id === expandedThreadId) {
      items.push({ kind: "expanded", thread });
    }
  };
  if (!grouped) {
    const items: ListItem[] = [...bundleItems];
    for (const thread of threads) {
      const header = sections?.get(thread.id);
      if (header) items.push({ kind: "header", key: `s-${thread.id}`, ...header });
      pushThread(items, thread);
    }
    return items;
  }
  const items: ListItem[] = [...bundleItems];
  let lastKey: string | null = null;
  for (const thread of threads) {
    const g = dateGroup(thread.lastMessageAt, now);
    if (g.key !== lastKey) {
      items.push({
        kind: "header",
        key: g.key,
        label: g.label,
        subtitle: g.key === "today" ? longDate(thread.lastMessageAt) : undefined,
      });
      lastKey = g.key;
    }
    pushThread(items, thread);
  }
  return items;
}
