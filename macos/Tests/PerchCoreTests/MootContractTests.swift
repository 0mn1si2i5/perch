import XCTest
@testable import PerchCore
final class MootContractTests: XCTestCase {
    func testDefaultsAndPathsArePortable() throws {
        let config = MootConfig()
        XCTAssertFalse(config.apiEnabled)
        XCTAssertFalse(config.automaticRoundtable)
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(MootConfig.self, from: data), config)
        let paths = MootPaths(root: URL(fileURLWithPath: "/tmp/space 中文"))
        XCTAssertEqual(paths.executable.path, "/tmp/space 中文/current/moot")
    }
    func testUnknownProtocolRejected() throws {
        let data = Data(#"{"protocolVersion":2,"requestID":"x","ok":true,"data":{}}"#.utf8)
        XCTAssertThrowsError(try MootRPCResponse.decode(data))
    }
}
