import Foundation

enum FixtureLoader {
    static func url(_ filename: String) -> URL {
        guard let url = Bundle(for: FixtureBundleToken.self).url(forResource: filename, withExtension: nil) else {
            fatalError("Missing bundled test fixture: \(filename)")
        }
        return url
    }

    static func optionalURL(_ filename: String) -> URL? {
        Bundle(for: FixtureBundleToken.self).url(forResource: filename, withExtension: nil)
    }

    static func string(_ filename: String, encoding: String.Encoding = .utf8) throws -> String {
        try String(contentsOf: url(filename), encoding: encoding)
    }
}

private final class FixtureBundleToken {}
