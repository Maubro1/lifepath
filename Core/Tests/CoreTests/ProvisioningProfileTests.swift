import XCTest
@testable import Core

final class ProvisioningProfileTests: XCTestCase {
    // A real profile is CMS-signed binary wrapping an XML plist; simulate with junk around it.
    func wrap(_ plist: String) -> Data {
        Data([0x30, 0x82, 0x01, 0xFF]) + Data(plist.utf8) + Data([0x00, 0xA0, 0x82])
    }

    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>ExpirationDate</key><date>2026-11-21T10:00:00Z</date></dict></plist>
    """

    func testReadsExpirationDate() {
        XCTAssertEqual(ProvisioningProfile.expirationDate(from: wrap(plist)),
                       ISO8601DateFormatter().date(from: "2026-11-21T10:00:00Z"))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(ProvisioningProfile.expirationDate(from: Data([1, 2, 3])))
    }

    func testMissingPlistEndReturnsNil() {
        XCTAssertNil(ProvisioningProfile.expirationDate(from: wrap(String(plist.dropLast(8)))))
    }

    func testPlistWithoutDateReturnsNil() {
        let noDate = plist.replacingOccurrences(of: "ExpirationDate", with: "Other")
        XCTAssertNil(ProvisioningProfile.expirationDate(from: wrap(noDate)))
    }
}
