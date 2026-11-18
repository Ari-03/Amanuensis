import Foundation
import Testing

@testable import AmanuensisCore

struct APIBaseURLTests {
    private func parsed(_ text: String) -> String? {
        try? APIBaseURL.parse(text).get().absoluteString
    }

    @Test func normalizesToADirectoryEndpointPathsAppendTo() {
        #expect(parsed("  HTTPS://api.example.com/v1 ") == "https://api.example.com/v1/")
        #expect(parsed("https://api.example.com/v1/") == "https://api.example.com/v1/")
        #expect(parsed("https://Router.Example.com:8443/api/v1") == "https://router.example.com:8443/api/v1/")
        let base = URL(string: parsed("https://api.example.com/openai/v1")!)!
        #expect(
            URL(string: "models", relativeTo: base)?.absoluteString
                == "https://api.example.com/openai/v1/models")
    }

    @Test func plainHTTPIsOnlyForThisMac() {
        #expect(parsed("http://localhost:11434/v1") == "http://localhost:11434/v1/")
        #expect(parsed("http://127.0.0.1:1234/v1") == "http://127.0.0.1:1234/v1/")
        #expect(parsed("http://[::1]:8080/v1") != nil)
        for remote in [
            "http://192.168.1.20:11434/v1", "http://example.com/v1", "http://127.0.0.1.example.com/v1",
            "http://localhost.example.com/v1",
        ] {
            #expect(APIBaseURL.parse(remote) == .failure(.insecureRemote), "\(remote)")
        }
    }

    @Test func hardeningRejectsTrickAddressesAndCollapsesSlashes() {
        // "+1" parses as a number, but it is not a loopback octet.
        #expect(APIBaseURL.parse("http://127.+1.0.1/v1") == .failure(.insecureRemote))
        #expect(APIBaseURL.parse("http://localhost:99999/v1") == .failure(.badPort))
        #expect(APIBaseURL.parse("http://localhost:0/v1") == .failure(.badPort))
        #expect(parsed("http://localhost:65535/v1") == "http://localhost:65535/v1/")
        for dots in [
            "https://example.com/v1/../admin", "https://example.com/./v1", "https://example.com/v1/%2e%2E/x",
            "https://example.com/v1/%2E",
        ] {
            #expect(APIBaseURL.parse(dots) == .failure(.dotSegments), "\(dots)")
        }
        #expect(parsed("https://example.com/v1//") == "https://example.com/v1/")
        #expect(parsed("https://example.com") == "https://example.com/")
        // A missing scheme is the commonest typing mistake; it gets its own message.
        for bare in ["localhost:11434/v1", "api.example.com/v1"] {
            #expect(APIBaseURL.parse(bare) == .failure(.missingScheme), "\(bare)")
        }
        #expect(APIBaseURL.Problem.missingScheme.message.contains("https://"))
    }

    @Test func rejectsAddressesThatCouldLeakOrMisroute() {
        #expect(APIBaseURL.parse("") == .failure(.empty))
        #expect(APIBaseURL.parse("ftp://example.com/v1") == .failure(.unsupportedScheme))
        #expect(APIBaseURL.parse("file:///etc/v1") == .failure(.unreadable))
        #expect(APIBaseURL.parse("https://user:secret@example.com/v1") == .failure(.credentialsInAddress))
        #expect(APIBaseURL.parse("https://example.com/v1?key=1") == .failure(.queryOrFragment))
        #expect(APIBaseURL.parse("https://example.com/v1#x") == .failure(.queryOrFragment))
    }
}
