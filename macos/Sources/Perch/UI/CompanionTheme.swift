import SwiftUI

/// A character owns its panel palette. Add future characters here rather than scattering colors through views.
struct CompanionTheme {
    let background: Color
    let accent: Color
    let colorScheme: ColorScheme

    static let pox = CompanionTheme(
        background: Color(red: 0.09, green: 0.105, blue: 0.125),
        accent: Color(red: 0.89, green: 0.70, blue: 0.30),
        colorScheme: .dark
    )
}

extension PetModel {
    var theme: CompanionTheme { .pox }
}
