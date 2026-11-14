import Foundation

public enum ProvisioningProfile {
    /// Reads `ExpirationDate` from an `embedded.mobileprovision`: a CMS-signed blob that wraps an XML plist.
    public static func expirationDate(from data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }
}
