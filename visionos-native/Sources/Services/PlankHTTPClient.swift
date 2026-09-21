import Foundation
import Security

enum PlankHTTPError: LocalizedError, Sendable {
    case invalidAddress
    case invalidCertificate
    case invalidResponse(String)
    case rejected(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "The workstation address is invalid."
        case .invalidCertificate:
            return "The workstation did not present a valid PLANK certificate."
        case let .invalidResponse(message):
            return message
        case let .rejected(code, message):
            return message.isEmpty ? "The Host rejected the request (\(code))." : message
        }
    }
}

private final class PlankTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              Self.isQualifiedPlankTrust(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private static func isQualifiedPlankTrust(_ trust: SecTrust) -> Bool {
        guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first,
              let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeRSA as String,
              let keySize = attributes[kSecAttrKeySizeInBits] as? Int,
              keySize >= 3072 else {
            return false
        }

        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error) &&
            SecTrustGetCertificateCount(trust) == 1
    }
}

private final class ServerInfoParser: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private(set) var statusCode: Int?
    private(set) var statusMessage = ""

    private var currentElement: String?
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "root" {
            statusCode = Int(attributeDict["status_code"] ?? "")
            statusMessage = attributeDict["status_message"] ?? ""
        }
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if currentElement == elementName {
            values[elementName] = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentElement = nil
        currentText = ""
    }
}

final class PlankHTTPClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    private(set) var identity: PlankHostIdentity?
    private(set) var sessionToken: String?

    init(host: HostBookmark) throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        components.port = Int(host.port)
        guard let url = components.url else {
            throw PlankHTTPError.invalidAddress
        }
        baseURL = url

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["Connection": "close"]
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv13
        session = URLSession(
            configuration: configuration,
            delegate: PlankTrustDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func fetchServerInfo() async throws -> PlankHostIdentity {
        let data = try await request(path: "serverinfo")
        let parserDelegate = ServerInfoParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse(), let statusCode = parserDelegate.statusCode else {
            throw PlankHTTPError.invalidResponse("The Host returned malformed server information.")
        }
        guard statusCode == 200 else {
            throw PlankHTTPError.rejected(statusCode, parserDelegate.statusMessage)
        }

        let values = parserDelegate.values
        let hostIdentity = PlankHostIdentity(
            name: values["hostname"].flatMap { $0.isEmpty ? nil : $0 } ?? "PLANK Host",
            uniqueID: values["uniqueid"] ?? "",
            version: values["PlankHostVersion"] ?? values["appversion"] ?? "",
            supportsAuthentication: values["PlankAuth"] == "1"
        )
        identity = hostIdentity
        return hostIdentity
    }

    func authenticate(username: String, password: String) async throws -> PlankAuthentication {
        guard !username.isEmpty, sessionToken == nil else {
            throw PlankHTTPError.invalidResponse("The authentication request is no longer valid.")
        }

        var response = try await postAuthentication(
            path: "start",
            body: ["username": username]
        )

        for _ in 0..<16 {
            guard let state = response["state"] as? String else {
                throw PlankHTTPError.invalidResponse("The Host returned an invalid authentication response.")
            }

            switch state {
            case "authenticated":
                guard let token = response["session_token"] as? String, !token.isEmpty else {
                    throw PlankHTTPError.invalidResponse("Authentication returned no session token.")
                }
                sessionToken = token
                return PlankAuthentication(
                    sessionToken: token,
                    desktopStage: response["desktop_stage"] as? String ?? ""
                )
            case "denied":
                throw PlankHTTPError.rejected(401, "The username or password was not accepted.")
            case "busy":
                throw PlankHTTPError.rejected(503, "The Host is busy. Please try again shortly.")
            case "challenge":
                guard let conversationID = response["conversation_id"] as? String,
                      let messages = response["messages"] as? [[String: Any]] else {
                    throw PlankHTTPError.invalidResponse("The Host returned an invalid sign-in challenge.")
                }
                let answers = try messages.map { message -> String in
                    switch message["style"] as? Int {
                    case 1: return password
                    case 2: return username
                    case 3, 4: return ""
                    default:
                        throw PlankHTTPError.invalidResponse("The Host requested an unsupported sign-in prompt.")
                    }
                }
                response = try await postAuthentication(
                    path: "respond",
                    body: ["conversation_id": conversationID, "responses": answers]
                )
            default:
                throw PlankHTTPError.invalidResponse("The Host returned an unknown authentication state.")
            }
        }

        throw PlankHTTPError.invalidResponse("The Host sign-in exceeded its challenge limit.")
    }

    private func request(path: String) async throws -> Data {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        return data
    }

    private func postAuthentication(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = baseURL.appending(path: "plank/auth/\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlankHTTPError.invalidResponse("The Host returned malformed authentication data.")
        }
        return object
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw PlankHTTPError.invalidResponse("The Host returned no HTTP response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw PlankHTTPError.rejected(response.statusCode, "The Host rejected the request.")
        }
    }
}
