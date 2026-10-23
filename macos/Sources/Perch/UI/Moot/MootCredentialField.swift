import SwiftUI
import PerchCore
struct MootCredentialField: View {
    @Binding var connection: MootConnection
    @State private var secret = ""
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("API Key（存入系统钥匙串）", text: $secret)
            Button("保存凭据") {
                let ref = connection.credentialRef ?? "connection-" + connection.id
                let value = secret
                Task { do { try await MootCredentialBridge().put(ref: ref, secret: value); connection.credentialRef = ref; secret = ""; message = "已保存凭据；API 总开关与能力备用需另行设置。" } catch { message = error.localizedDescription } }
            }.disabled(secret.isEmpty)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
