import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { queryClient } from "../queries/client";
import type { ThreadDetail } from "../ipc/types";
import { SPLIT_IMPORTANT, useUi } from "../stores/ui";
import { ALL_COMMANDS } from "./commands";
import { buildCommandContext } from "./context";

const preserved = {
  calendarDrawer: "week" as const,
  calendarFocusDay: 1746057600000,
  calendarView: "month" as const,
  sidebarPinned: true,
  accountFilter: 7,
};

beforeEach(() => {
  queryClient.clear();
  useUi.setState(useUi.getInitialState(), true);
  useUi.setState({
    ...preserved,
    calendarScreen: true,
    view: "sent",
    labelFilter: 90,
    folderFilter: 91,
    splitId: 92,
    searchOpen: true,
    searchQuery: "old query",
    openThreadId: 101,
    focusedMessageId: 102,
    selectedThreadId: 103,
    selectedIndex: 4,
    selection: [103, 104],
    selectAnchorId: 104,
  });
});

afterEach(() => {
  queryClient.clear();
  useUi.setState(useUi.getInitialState(), true);
});

async function runCommand(id: string) {
  const command = ALL_COMMANDS.find((candidate) => candidate.id === id);
  expect(command, id).toBeDefined();
  const context = buildCommandContext();
  expect(command!.when?.(context) ?? true).toBe(true);
  await command!.run(context);
}

function expectMailState(selectAnchorId: number | null = null) {
  expect(useUi.getState()).toMatchObject({
    ...preserved,
    calendarScreen: false,
    folderFilter: null,
    searchOpen: false,
    openThreadId: null,
    focusedMessageId: null,
    selectedThreadId: null,
    selectedIndex: 0,
    selection: [],
    selectAnchorId,
  });
}

describe("account switch commands", () => {
  it("reset the stale folder and selection when the scope changes", async () => {
    queryClient.setQueryData(["accounts"], [{ id: 3 }, { id: 8 }]);
    await runCommand("account-filter-1");
    expect(useUi.getState()).toMatchObject({
      accountFilter: 3,
      folderFilter: null,
      selection: [],
      selectAnchorId: null,
      selectedThreadId: null,
      selectedIndex: 0,
    });
  });

  it("leave the folder alone when re-picking the current account", async () => {
    queryClient.setQueryData(["accounts"], [{ id: 3 }, { id: 7 }]);
    await runCommand("account-filter-2");
    expect(useUi.getState()).toMatchObject({ accountFilter: 7, folderFilter: 91, selection: [103, 104] });
  });
});

describe("calendar to mail command navigation", () => {
  it.each([false, true])("cached label command (isAuto=%s) returns to mail", async (isAuto) => {
    // Slot zero must follow label position, not query-cache insertion order.
    queryClient.setQueryData(["labels"], [
      { id: 99, name: "Later", position: 10, isAuto: false },
      { id: 42, name: "Target", position: 0, isAuto },
    ]);
    await runCommand("go-label-0");
    // Auto-label navigation historically retains the range-selection anchor.
    expectMailState(isAuto ? 104 : null);
    expect(useUi.getState()).toMatchObject({
      view: isAuto ? "inbox" : "all",
      splitId: null,
      labelFilter: 42,
      searchQuery: isAuto ? "" : "old query",
    });
  });

  it.each([
    "inbox", "starred", "drafts", "sent", "done", "snoozed", "trash", "spam", "all",
  ] as const)("go-%s uses the real command context to leave calendar", async (view) => {
    await runCommand(`go-${view}`);
    expectMailState();
    expect(useUi.getState()).toMatchObject({
      view,
      splitId: view === "inbox" ? SPLIT_IMPORTANT : null,
      labelFilter: null,
      searchQuery: "old query",
    });
  });
});

describe("open attachment command", () => {
  const attachment = (id: number, isInline = false) => ({
    id,
    filename: `dokument-${id}.pdf`,
    mimeType: "application/pdf",
    size: 2048,
    isInline,
  });
  const message = (id: number, attachments: ReturnType<typeof attachment>[]) => ({
    id,
    attachments,
    from: { name: "Ada", email: "ada@example.test" },
    date: 1_700_000_000_000,
    subject: "Vertrag",
  });
  const seed = (messages: ReturnType<typeof message>[]) =>
    queryClient.setQueryData(["thread", 101], {
      thread: { id: 101 },
      messages,
    } as unknown as ThreadDetail);

  it("previews the focused message and skips inline images", async () => {
    seed([message(102, [attachment(1, true), attachment(2), attachment(3)]), message(103, [attachment(4)])]);
    await runCommand("open-attachment");
    expect(useUi.getState().attachmentPreview).toMatchObject({
      index: 0,
      items: [{ id: 2 }, { id: 3 }],
      subject: "Vertrag",
    });
  });

  it("falls back to the last message when nothing is focused", async () => {
    useUi.setState({ focusedMessageId: null });
    seed([message(102, [attachment(1)]), message(103, [attachment(4)])]);
    await runCommand("open-attachment");
    expect(useUi.getState().attachmentPreview?.items.map((a) => a.id)).toEqual([4]);
  });

  it("does nothing when the message only carries inline images", async () => {
    seed([message(102, [attachment(1, true)])]);
    await runCommand("open-attachment");
    expect(useUi.getState().attachmentPreview).toBeNull();
  });

  it("is available in a conversation only and is the sole binding for 'a'", () => {
    const command = ALL_COMMANDS.find((candidate) => candidate.id === "open-attachment");
    expect(command?.keys).toEqual(["a"]);
    const context = buildCommandContext();
    expect(command?.when?.(context)).toBe(true);
    const bound = ALL_COMMANDS.filter(
      (candidate) => candidate.keys?.includes("a") && (candidate.when?.(context) ?? true),
    );
    expect(bound.map((candidate) => candidate.id)).toEqual(["open-attachment"]);
    useUi.setState({ openThreadId: null });
    expect(command?.when?.(buildCommandContext())).toBe(false);
  });
});
