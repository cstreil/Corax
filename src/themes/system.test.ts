import { beforeEach, describe, expect, it } from "vitest";
import type { SystemColors } from "../ipc/types";
import { applySystemColors } from "./system";

/**
 * The overlay writes to `<html>`; the test runner has no DOM, so this records
 * what it would have set. Values are the real Plasma roles read on the KDE
 * test machine.
 */
function installFakeDocument(): Map<string, string> {
  const props = new Map<string, string>();
  const style = {
    setProperty: (name: string, value: string) => props.set(name, value),
    removeProperty: (name: string) => props.delete(name),
  };
  (globalThis as { document?: unknown }).document = { documentElement: { style } };
  return props;
}

const KDE: SystemColors = {
  source: "kde",
  mode: "dark",
  bg0: "#141618",
  bg1: "#202326",
  bg2: "#292c30",
  bg3: "#2d3033",
  bg4: "#3b3d40",
  ink: "#fcfcfc",
  inkMuted: "#a1a9b1",
  inkFaint: "#949595",
  accent: "#3daee9",
  onAccent: "#fcfcfc",
  hairline: "#3f4144",
};

let props: Map<string, string>;

beforeEach(() => {
  props = installFakeDocument();
});

describe("applySystemColors", () => {
  it("paints surfaces, text and the desktop accent", () => {
    applySystemColors(KDE);
    expect(props.get("--bg0")).toBe("#141618");
    expect(props.get("--bg4")).toBe("#3b3d40");
    expect(props.get("--ink")).toBe("252 252 252");
    expect(props.get("--accent")).toBe("#3daee9");
    expect(props.get("--on-accent")).toBe("#fcfcfc");
    expect(props.get("--text-muted")).toBe("#a1a9b1");
    expect(props.get("--hairline")).toBe("rgb(63 65 68 / 0.16)");
  });

  it("leaves a user's own accent alone when asked to", () => {
    // `applyAccent` ran first and put the user's preset in place.
    props.set("--accent", "#2f6bd0");
    props.set("--on-accent", "#ffffff");
    applySystemColors(KDE, { accent: false });
    expect(props.get("--accent")).toBe("#2f6bd0");
    expect(props.get("--on-accent")).toBe("#ffffff");
    // The rest of the palette still applies.
    expect(props.get("--bg0")).toBe("#141618");
  });

  it("does not invent an accent when it is not allowed to set one", () => {
    applySystemColors(KDE, { accent: false });
    expect(props.has("--accent")).toBe(false);
    expect(props.has("--on-accent")).toBe(false);
  });

  it("clears every token it set", () => {
    applySystemColors(KDE);
    expect(props.size).toBeGreaterThan(0);
    applySystemColors(null);
    expect(props.size).toBe(0);
  });

  it("clearing keeps a user's accent", () => {
    // The regression this guards: clearing the overlay used to drop `--accent`
    // too, wiping a picked preset on every theme change - on macOS as well,
    // where there is never a palette to clear.
    props.set("--accent", "#2f6bd0");
    props.set("--on-accent", "#ffffff");
    applySystemColors(KDE, { accent: false });
    applySystemColors(null, { accent: false });
    expect(props.get("--accent")).toBe("#2f6bd0");
    expect(props.get("--on-accent")).toBe("#ffffff");
    expect(props.has("--bg0")).toBe(false);
  });
});
