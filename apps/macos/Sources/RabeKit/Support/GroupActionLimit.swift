import Foundation

/// W7 aus dem Audit M2: the core's `undo_last` reverts one *gesture* — same
/// kind, created within 150 ms — and a group action sends its ids in one
/// `perform_action`. Above roughly 750 threads the call takes longer than that
/// window, so undo brings back only part of the group (measured: 810 threads →
/// 780 back).
///
/// Until the core carries a gesture id (noted in `ARCHITEKTUR.md` §8 for the
/// moment Comail code is replaced), the app refuses a group action above this
/// bound instead of silently losing the undo. `⌘A` may still select more; only
/// the action is refused.
public enum GroupActionLimit {
    public static let maxThreads = 500

    public static let message = "Höchstens 500 Unterhaltungen auf einmal – bitte Auswahl verkleinern."

    public static func allows(_ count: Int) -> Bool { count <= maxThreads }
}
