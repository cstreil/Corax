import SwiftUI

/// Focus for a field in an overlay that just appeared.
///
/// `@FocusState` set in `onAppear` is often dropped: the field is not in the
/// window yet, and SwiftUI leaves focus where it was — in the mail search field,
/// exactly the live-test finding of M2.8a (after `V` the cursor stood in the
/// list search instead of the folder picker).
///
/// `defaultFocus` asks for the focus declaratively, and the tick afterwards
/// catches the round where the window attaches the overlay late. Both together
/// are cheap and idempotent; setting the same value twice does nothing.
extension View {
    func focusWhenShown(_ binding: FocusState<Bool>.Binding) -> some View {
        self
            .defaultFocus(binding, true)
            .task {
                // One run-loop turn, then the field exists and can take focus.
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(30))
                binding.wrappedValue = true
            }
    }
}
