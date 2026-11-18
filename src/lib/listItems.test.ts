import { describe, expect, it } from "vitest";
import type { ThreadSummary } from "../ipc/types";
import { buildListItems, indexAtOffset, rangeWithPinnedIndex, type Bundle } from "./listItems";

const NOW = new Date(2026, 9, 18, 15, 0).getTime();
const HOUR = 3_600_000;

const thread = (id: number, lastMessageAt: number): ThreadSummary => ({
  id,
  accountId: 1,
  accountEmail: "me@x.com",
  subject: `s${id}`,
  snippet: "",
  participants: [],
  lastMessageAt,
  messageCount: 1,
  unreadCount: 0,
  isStarred: false,
  hasAttachments: false,
  snoozedUntil: null,
  labels: [],
});

const bundle = (key: string): Bundle => ({ key, name: key, unread: false, threads: [thread(99, NOW)] });

const shape = (items: ReturnType<typeof buildListItems>) =>
  items.map((it) =>
    it.kind === "header"
      ? `h:${it.key}`
      : it.kind === "bundle"
        ? `b:${it.bundle.key}`
        : it.kind === "expanded"
          ? `x:${it.thread.id}`
          : `t:${it.thread.id}`,
  );

describe("buildListItems", () => {
  const today = [thread(1, NOW - HOUR), thread(2, NOW - 2 * HOUR)];
  const yesterday = [thread(3, NOW - 24 * HOUR)];

  it("is unchanged without bundles", () => {
    expect(shape(buildListItems([...today, ...yesterday], true, [], NOW))).toEqual([
      "h:today",
      "t:1",
      "t:2",
      "h:yesterday",
      "t:3",
    ]);
    expect(shape(buildListItems(today, false, [], NOW))).toEqual(["t:1", "t:2"]);
  });

  it("leads the list with bundles, above the first date header", () => {
    expect(shape(buildListItems([...today, ...yesterday], true, [bundle("a"), bundle("b")], NOW))).toEqual([
      "b:a",
      "b:b",
      "h:today",
      "t:1",
      "t:2",
      "h:yesterday",
      "t:3",
    ]);
  });

  it("leads with bundles when ungrouped or empty too", () => {
    expect(shape(buildListItems(today, true, [bundle("a")], NOW))).toEqual(["b:a", "h:today", "t:1", "t:2"]);
    expect(shape(buildListItems(today, false, [bundle("a")], NOW))).toEqual(["b:a", "t:1", "t:2"]);
    expect(shape(buildListItems([], true, [bundle("a")], NOW))).toEqual(["b:a"]);
  });

  it("subtitles only the Today header with the full date", () => {
    const items = buildListItems([...today, ...yesterday], true, [], NOW);
    const headers = items.filter((it) => it.kind === "header");
    expect(headers[0].kind === "header" && headers[0].subtitle).toBeTruthy();
    expect(headers[1].kind === "header" && headers[1].subtitle).toBeUndefined();
  });
});

describe("buildListItems sections", () => {
  it("places a header above each keyed thread when ungrouped", () => {
    const a = { id: 1, lastMessageAt: 0 } as ThreadSummary;
    const b = { id: 2, lastMessageAt: 0 } as ThreadSummary;
    const items = buildListItems([a, b], false, [], 0, new Map([[2, { label: "Related" }]]));
    expect(items.map((i) => i.kind)).toEqual(["thread", "header", "thread"]);
    expect(items[1]).toMatchObject({ kind: "header", label: "Related" });
  });
});

describe("buildListItems expanded thread", () => {
  const today = [thread(1, NOW - HOUR), thread(2, NOW - 2 * HOUR)];
  const yesterday = [thread(3, NOW - 24 * HOUR)];

  it("inserts the panel directly below its own row", () => {
    expect(shape(buildListItems([...today, ...yesterday], true, [], NOW, undefined, 2))).toEqual([
      "h:today",
      "t:1",
      "t:2",
      "x:2",
      "h:yesterday",
      "t:3",
    ]);
  });

  it("works ungrouped and with bundles", () => {
    expect(shape(buildListItems(today, false, [], NOW, undefined, 1))).toEqual(["t:1", "x:1", "t:2"]);
    expect(shape(buildListItems(today, true, [bundle("a")], NOW, undefined, 1))).toEqual([
      "b:a",
      "h:today",
      "t:1",
      "x:1",
      "t:2",
    ]);
  });

  it("adds nothing for a closed or absent thread", () => {
    expect(shape(buildListItems(today, false, [], NOW, undefined, null))).toEqual(["t:1", "t:2"]);
    expect(shape(buildListItems(today, false, [], NOW, undefined, 99))).toEqual(["t:1", "t:2"]);
  });
});

describe("indexAtOffset", () => {
  const uniform = [
    { index: 0, start: 0, size: 40 },
    { index: 1, start: 40, size: 40 },
    { index: 2, start: 80, size: 40 },
  ];

  it("maps a uniform list the way the old division did", () => {
    expect(indexAtOffset(uniform, 0)).toBe(0);
    expect(indexAtOffset(uniform, 39)).toBe(0);
    expect(indexAtOffset(uniform, 40)).toBe(1);
    expect(indexAtOffset(uniform, 79)).toBe(1);
    expect(indexAtOffset(uniform, 80)).toBe(2);
  });

  it("keeps the whole opened panel on its own row", () => {
    // Row 2 is the opened thread's panel: 600px instead of 40.
    const withPanel = [
      { index: 0, start: 0, size: 40 },
      { index: 1, start: 40, size: 40 },
      { index: 2, start: 80, size: 600 },
      { index: 3, start: 680, size: 40 },
    ];
    expect(indexAtOffset(withPanel, 80)).toBe(2);
    expect(indexAtOffset(withPanel, 400)).toBe(2);
    expect(indexAtOffset(withPanel, 679)).toBe(2);
    expect(indexAtOffset(withPanel, 680)).toBe(3);
  });

  it("clamps outside the measured range", () => {
    expect(indexAtOffset(uniform, -50)).toBe(0);
    expect(indexAtOffset(uniform, 10_000)).toBe(2);
    expect(indexAtOffset([], 100)).toBe(0);
  });
});

describe("rangeWithPinnedIndex", () => {
  const range = { startIndex: 10, endIndex: 14, overscan: 2, count: 100 };

  it("keeps the default window when nothing is pinned", () => {
    expect(rangeWithPinnedIndex(range, -1)).toEqual([8, 9, 10, 11, 12, 13, 14, 15, 16]);
  });

  it("pins an index outside the window", () => {
    expect(rangeWithPinnedIndex(range, 40)).toEqual([8, 9, 10, 11, 12, 13, 14, 15, 16, 40]);
  });

  it("does not duplicate an index already in the window", () => {
    expect(rangeWithPinnedIndex(range, 12)).toEqual([8, 9, 10, 11, 12, 13, 14, 15, 16]);
  });
});
