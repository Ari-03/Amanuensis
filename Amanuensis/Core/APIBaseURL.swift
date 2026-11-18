import Foundation

/// The one check for an OpenAI-compatible server's address. Settings keep the text; everything that
/// sends a request, and the configuration sheet, parses it through here.
enum APIBaseURL {
    enum Problem: Error, Equatable {
        case empty, missingScheme, unreadable, unsupportedScheme, credentialsInAddress, queryOrFragment
        case badPort, dotSegments
        /// Plain http would expose the API key and the audio to anyone on the network path.
        case insecureRemote

        var message: String {
            switch self {
            case .empty: "Enter the server's base URL, such as https://example.com/v1."
            case .missingScheme: "Start the address with https://, or http:// for a server on this Mac."
            case .unreadable: "This is not a valid URL."
            case .badPort: "Use a port number from 1 to 65535."
            case .dotSegments: "Remove the . or .. parts from the address's path."
            case .unsupportedScheme: "Use an https:// address."
            case .credentialsInAddress:
                "Remove the user name or password from the address. Use the API key field."
            case .queryOrFragment: "Remove the ? or # part of the address."
            case .insecureRemote: "Use https. Plain http is allowed only for a server on this Mac."
            }
        }
    }

    /// A normalized base URL ending in "/", so endpoint paths such as "models" append to it.
    /// `https` is required except for loopback hosts, where `http` is allowed.
    static func parse(_ text: String) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        // Without "://", URLComponents reads "localhost:11434/v1" as a scheme and a path.
        guard trimmed.contains("://") else { return .failure(.missingScheme) }
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(), !host.isEmpty
        else { return .failure(.unreadable) }
        guard scheme == "https" || scheme == "http" else { return .failure(.unsupportedScheme) }
        guard components.user == nil, components.password == nil else {
            return .failure(.credentialsInAddress)
        }
        guard components.query == nil, components.fragment == nil else { return .failure(.queryOrFragment) }
        if let port = components.port, !(1...65535).contains(port) { return .failure(.badPort) }
        // Rejected rather than resolved, so the saved address is exactly where requests go.
        let segments = components.percentEncodedPath.split(separator: "/").map {
            $0.removingPercentEncoding ?? String($0)
        }
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return .failure(.dotSegments) }
        guard scheme == "https" || isLoopback(host) else { return .failure(.insecureRemote) }
        components.scheme = scheme
        // IPv6 literals keep their spelling; the setter would need brackets.
        if !host.contains(":") { components.host = host }
        // Exactly one trailing slash, so "/v1//" cannot become "/v1//models".
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path + "/"
        guard let url = components.url else { return .failure(.unreadable) }
        return .success(url)
    }

    /// Names that only ever reach this Mac. Being on this Mac is not proof that inference stays here,
    /// so it only relaxes the transport rule, never the local-only policy.
    static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare == "::1" { return true }
        let octets = bare.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127"
            && octets.allSatisfy { octet in
                !octet.isEmpty && octet.allSatisfy { ("0"..."9").contains($0) } && UInt8(octet) != nil
            }
    }
}
