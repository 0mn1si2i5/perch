import SwiftUI
import PerchCore

struct ProviderUsageView: View {
    let usage: ProviderUsage?
    let error: String?
    let refreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let usage {
                if !ProviderUsagePresentation.windows(usage).isEmpty {
                    QuotaRowView(quota: ProviderUsagePresentation.display(usage: usage, error: error))
                }
                ForEach(Array(ProviderUsagePresentation.rows(usage).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.label).foregroundStyle(.secondary).frame(minWidth: 20, alignment: .leading)
                        Text(row.value).monospacedDigit().fixedSize()
                        Spacer(minLength: 4)
                        if let unit = row.unit { Text(unit).foregroundStyle(.secondary).fixedSize() }
                    }
                    .help(ProviderUsagePresentation.details(usage))
                }
            } else if error != nil || refreshing {
                QuotaRowView(quota: ProviderUsagePresentation.display(usage: nil, error: error))
            } else {
                Text("点击刷新获取额度").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
    }
}
