import SwiftUI

/// Bumps a caller-owned token whenever the calendar day rolls over or the app returns to
/// the foreground. Because the token is the host view's own `@State`, writing it re-runs the
/// host's body — so relative date labels ("in 3 days", "Today") recompute against the
/// current date instead of freezing at whenever the view first appeared.
private struct DayChangeRefresh: ViewModifier {
    @Binding var token: Int
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                token &+= 1
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { token &+= 1 }
            }
    }
}

extension View {
    /// Re-evaluates this view's body on day-change and on foregrounding so time-relative
    /// content stays current. Pair with a `@State private var dayToken = 0` in the host.
    func refreshOnDayChange(_ token: Binding<Int>) -> some View {
        modifier(DayChangeRefresh(token: token))
    }
}
