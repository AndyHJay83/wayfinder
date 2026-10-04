import SwiftUI

/// How long you'll be parked: "Pick up / drop off" or a number of hours. Parking costs are
/// worked out for this stay.
struct StayPicker: View {
    @Binding var minutes: Int

    static let dropOffMinutes = 10
    static let choices: [Int] = [10, 30, 60, 90, 120, 180, 240, 300, 360, 480, 600, 720, 1440]

    static func label(_ minutes: Int) -> String {
        switch minutes {
        case ...dropOffMinutes: "Pick up / drop off"
        case ..<60: "\(minutes) min"
        case 60: "1 hour"
        case 1440: "All day"
        default: minutes % 60 == 0 ? "\(minutes / 60) hours" : String(format: "%.1f hours", Double(minutes) / 60)
        }
    }

    var body: some View {
        Picker(selection: $minutes) {
            ForEach(Array(Set(Self.choices + [minutes])).sorted(), id: \.self) { Text(Self.label($0)).tag($0) }
        } label: {
            Label("Staying for", systemImage: "clock")
        }
        .pickerStyle(.menu)
    }
}
