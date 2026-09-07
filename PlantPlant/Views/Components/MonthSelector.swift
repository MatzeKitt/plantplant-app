import SwiftUI

/// A wrapping row of 12 toggleable month chips. Used in the editor to pick which months a
/// seasonal watering interval applies to. Selection is a set of 1...12 (January = 1).
struct MonthSelector: View {
    @Binding var selection: Set<Int>

    /// Localized short month names in calendar order, paired with their 1-based month number.
    private var months: [(number: Int, name: String)] {
        let symbols = Calendar.current.shortMonthSymbols
        return symbols.enumerated().map { (number: $0.offset + 1, name: $0.element) }
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(months, id: \.number) { month in
                let isOn = selection.contains(month.number)
                Button {
                    if isOn { selection.remove(month.number) } else { selection.insert(month.number) }
                } label: {
                    Text(month.name)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(minWidth: 44)
                        .background(
                            isOn ? CareType.water.tint : Color.secondary.opacity(0.15),
                            in: Capsule()
                        )
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(month.name)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}
