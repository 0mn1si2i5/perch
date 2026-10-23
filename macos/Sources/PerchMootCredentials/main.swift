import Foundation
import PerchCore
struct Request: Decodable { var operation: String; var ref: String; var secret: String? }
do {
    let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let store = MootCredentialStore()
    switch request.operation {
    case "read": FileHandle.standardOutput.write(try store.read(ref: request.ref))
    case "put": try store.put(ref: request.ref, secret: Data((request.secret ?? "").utf8))
    case "remove": try store.remove(ref: request.ref)
    default: throw MootRPCError(code: "invalidOperation", message: "Unknown credential operation")
    }
} catch { FileHandle.standardError.write(Data("Keychain operation unavailable; save the credential in Perch.\n".utf8)); exit(1) }
