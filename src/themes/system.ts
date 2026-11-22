import type { SystemColors } from "../ipc/types";

/**
 * Overlay a desktop palette on top of the resolved base theme.
 *
 * Only the tokens a desktop actually dictates are overridden - surfaces, text
 * and accent. Shadows, AI colours and the selection tints keep coming from
 * Glas/Graphit, so the app still reads as Corax instead of as a colour dump, and
 * a desktop palette can never produce an unreadable accent-on-surface pair.
 *
 * Call with `null` to drop the overlay again.
 */

/** Hex `#rrggbb` to the `r g b` triplet the text tokens are built from. */
function triplet(hex: string): string {
  const h = hex.replace("#", "");
  return `${parseInt(h.slice(0, 2), 16)} ${parseInt(h.slice(2, 4), 16)} ${parseInt(h.slice(4, 6), 16)}`;
}

/** Every token this overlay may set, so clearing it can be exhaustive. */
const TOKENS = [
  "--bg0",
  "--bg1",
  "--bg2",
  "--bg3",
  "--bg4",
  "--ink",
  "--accent",
  "--on-accent",
  "--text-muted",
  "--text-faint",
  "--hairline",
  "--hairline-strong",
] as const;

/** The two tokens carrying the accent, splittable from the rest. */
const ACCENT_TOKENS: ReadonlySet<string> = new Set(["--accent", "--on-accent"]);

export interface ApplySystemColorsOptions {
  /**
   * Whether this palette may set the accent. A user's own accent outranks the
   * desktop's: when they picked one, `applyAccent` has already put it in place,
   * so the overlay must leave it alone — and on the way out it must not remove
   * it either. Defaults to `true`, which lets the desktop's accent through
   * while the accent setting sits on its own default.
   */
  accent?: boolean;
}

export function applySystemColors(
  colors: SystemColors | null,
  options: ApplySystemColorsOptions = {},
): void {
  const root = document.documentElement;
  const withAccent = options.accent ?? true;
  if (!colors) {
    for (const token of TOKENS) {
      if (!withAccent && ACCENT_TOKENS.has(token)) continue;
      root.style.removeProperty(token);
    }
    return;
  }
  const set = (token: string, value: string) => root.style.setProperty(token, value);
  set("--bg0", colors.bg0);
  set("--bg1", colors.bg1);
  set("--bg2", colors.bg2);
  set("--bg3", colors.bg3);
  set("--bg4", colors.bg4);
  set("--ink", triplet(colors.ink));
  if (withAccent) {
    set("--accent", colors.accent);
    set("--on-accent", colors.onAccent);
  }
  // Plasma's inactive foreground is the honest "muted" text; faint is that
  // pulled further towards the canvas so it still fade into the background.
  set("--text-muted", colors.inkMuted);
  set("--text-faint", colors.inkFaint);
  set("--hairline", `rgb(${triplet(colors.hairline)} / 0.16)`);
  set("--hairline-strong", `rgb(${triplet(colors.hairline)} / 0.30)`);
}
