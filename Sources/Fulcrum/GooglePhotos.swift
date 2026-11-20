import AppKit
import CryptoKit
import Foundation
import Network
import Security
import UniformTypeIdentifiers

/// Google Photos via the Library API. Uses your own OAuth client (Desktop app type), a loopback redirect with PKCE,
/// and keeps the refresh token in the Keychain. Since Google's 2025 API changes an app can only upload, make albums,
/// and add its own uploads to its own albums — there is no API for favourites or keywords.
final class GooglePhotos: @unchecked Sendable {
    static let shared = GooglePhotos()

    static let scopes = [
        "https://www.googleapis.com/auth/photoslibrary.appendonly",
        "https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata",
    ]

    enum GPError: LocalizedError {
        case notConfigured, notConnected, cancelled, http(Int, String), bad(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add your Google OAuth client ID and secret first."
            case .notConnected: "Connect your Google account first."
            case .cancelled: "Google sign-in was cancelled."
            case let .http(code, body): "Google Photos returned \(code): \(body.prefix(300))"
            case let .bad(s): s
            }
        }
    }

    // MARK: Credentials

    var clientID: String {
        get { UserDefaults.standard.string(forKey: "googleClientID") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "googleClientID") }
    }
    var clientSecret: String {
        get { Keychain.get("googleClientSecret") ?? "" }
        set { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "googleClientSecret") }
    }
    var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
    var isConnected: Bool { Keychain.get("googleRefreshToken") != nil }

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var listener: NWListener?
    private var pendingWaiter: CodeWaiter?

    /// Abandons a sign-in that's waiting for the browser (e.g. the tab was closed).
    func cancelSignIn() {
        pendingWaiter?.finish(.failure(GPError.cancelled))
        pendingWaiter = nil
        listener?.cancel()
    }

    func disconnect() {
        Keychain.set(nil, for: "googleRefreshToken")
        accessToken = nil
        UserDefaults.standard.removeObject(forKey: "googleAlbums")
    }

    // MARK: Sign-in (loopback + PKCE)

    func connect() async throws {
        guard isConfigured else { throw GPError.notConfigured }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(24)

        let (port, waiter) = try await startLoopback(expectState: state)
        let redirect = "http://127.0.0.1:\(port)"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        let authURL = c.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }
        let code = try await waiter.wait()

        let json = try await tokenRequest([
            "code": code, "client_id": clientID, "client_secret": clientSecret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String else { throw GPError.bad("Google didn't return a refresh token.") }
        Keychain.set(refresh, for: "googleRefreshToken")
        storeAccess(json)
    }

    /// Listens once on 127.0.0.1 for Google's redirect and returns the auth code. Gives up after 5 minutes.
    private func startLoopback(expectState: String) async throws -> (UInt16, CodeWaiter) {
        cancelSignIn()   // only one sign-in at a time
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        listener = l
        let waiter = CodeWaiter()
        pendingWaiter = waiter
        let finish: (Result<String, Error>) -> Void = { r in
            if waiter.finish(r) { l.cancel() }
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let items = URLComponents(string: "http://x" + path)?.queryItems ?? []
                let get = { (k: String) in items.first { $0.name == k }?.value }
                let ok = get("code") != nil && get("state") == expectState
                let page = ok ? "Fulcrum is connected to Google Photos. You can close this tab."
                              : "Sign-in didn't complete (\(get("error") ?? "no code")). You can close this tab."
                let body = "<html><body style='font:16px -apple-system;padding:40px'>\(page)</body></html>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                if path.hasPrefix("/favicon") { return }
                if ok, let code = get("code") { finish(.success(code)) }
                else { finish(.failure(get("error") == "access_denied" ? GPError.cancelled : GPError.bad("Google sign-in failed: \(get("error") ?? "unknown")"))) }
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { c in
            var resumed = false
            l.stateUpdateHandler = { s in
                guard !resumed else { return }
                switch s {
                case .ready: resumed = true; c.resume(returning: l.port?.rawValue ?? 0)
                case let .failed(e): resumed = true; c.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: .global())
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { finish(.failure(GPError.cancelled)) }
        return (port, waiter)
    }

    /// Hands the auth code from the listener's queue to the waiting sign-in, exactly once.
    final class CodeWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<String, Error>?
        private var result: Result<String, Error>?

        @discardableResult func finish(_ r: Result<String, Error>) -> Bool {
            lock.lock()
            guard result == nil else { lock.unlock(); return false }
            result = r
            let c = cont; cont = nil
            lock.unlock()
            c?.resume(with: r)
            return true
        }

        func wait() async throws -> String {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if let r = result { lock.unlock(); c.resume(with: r) } else { cont = c; lock.unlock() }
            }
        }
    }

    private func storeAccess(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        accessExpiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
    }

    private func token() async throws -> String {
        if let t = accessToken, Date() < accessExpiry { return t }
        guard isConfigured else { throw GPError.notConfigured }
        guard let refresh = Keychain.get("googleRefreshToken") else { throw GPError.notConnected }
        let json = try await tokenRequest([
            "client_id": clientID, "client_secret": clientSecret, "refresh_token": refresh, "grant_type": "refresh_token",
        ])
        storeAccess(json)
        guard let t = accessToken else { throw GPError.bad("No access token from Google.") }
        return t
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "+&=/")
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if code == 400 || code == 401, form["grant_type"] == "refresh_token" { Keychain.set(nil, for: "googleRefreshToken") }
            throw GPError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return json
    }

    // MARK: API

    private func api(_ method: String, _ path: String, json body: Any? = nil, raw: Data? = nil,
                     headers: [String: String] = [:]) async throws -> Data {
        var r = URLRequest(url: URL(string: "https://photoslibrary.googleapis.com/v1/" + path)!)
        r.httpMethod = method
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let raw { r.httpBody = raw }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GPError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    /// Album title → id for albums this app created. Cached; refreshed from Google when a title is missing.
    private var albumIDs: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "googleAlbums") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "googleAlbums") }
    }

    private func albumID(_ title: String) async throws -> String {
        if let id = albumIDs[title] { return id }
        // Look through albums Fulcrum made before (e.g. on another Mac).
        var pageToken: String?
        repeat {
            var path = "albums?pageSize=50&excludeNonAppCreatedData=true"
            if let pageToken { path += "&pageToken=\(pageToken)" }
            let json = try JSONSerialization.jsonObject(with: try await api("GET", path)) as? [String: Any] ?? [:]
            for a in json["albums"] as? [[String: Any]] ?? [] {
                if let t = a["title"] as? String, let id = a["id"] as? String { albumIDs[t] = id }
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil && albumIDs[title] == nil
        if let id = albumIDs[title] { return id }
        let created = try JSONSerialization.jsonObject(with: try await api("POST", "albums", json: ["album": ["title": title]])) as? [String: Any]
        guard let id = created?["id"] as? String else { throw GPError.bad("Couldn't create the album “\(title)”.") }
        albumIDs[title] = id
        return id
    }

    /// Uploads one photo (edited JPEG or original RAW) and puts it in an album for each of `albums`.
    func upload(_ file: URL, albums: [String]) async throws {
        let bytes = try Data(contentsOf: file)
        let tokenData = try await api("POST", "uploads", raw: bytes, headers: [
            "Content-Type": "application/octet-stream",
            "X-Goog-Upload-Content-Type": UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
            "X-Goog-Upload-Protocol": "raw",
            "X-Goog-Upload-File-Name": file.lastPathComponent,
        ])
        guard let uploadToken = String(data: tokenData, encoding: .utf8), !uploadToken.isEmpty else {
            throw GPError.bad("Upload of \(file.lastPathComponent) returned no token.")
        }
        var ids: [String] = []
        for a in albums { ids.append(try await albumID(a)) }
        var body: [String: Any] = ["newMediaItems": [["simpleMediaItem": ["uploadToken": uploadToken, "fileName": file.lastPathComponent]]]]
        if let first = ids.first { body["albumId"] = first }
        let result = try JSONSerialization.jsonObject(with: try await api("POST", "mediaItems:batchCreate", json: body)) as? [String: Any]
        let item = (result?["newMediaItemResults"] as? [[String: Any]])?.first
        if let status = item?["status"] as? [String: Any], let msg = status["message"] as? String,
           (status["code"] as? Int ?? 0) != 0 {
            throw GPError.bad("\(file.lastPathComponent): \(msg)")
        }
        guard let mediaID = (item?["mediaItem"] as? [String: Any])?["id"] as? String else {
            throw GPError.bad("\(file.lastPathComponent): Google didn't confirm the upload.")
        }
        for id in ids.dropFirst() {
            _ = try await api("POST", "albums/\(id):batchAddMediaItems", json: ["mediaItemIds": [mediaID]])
        }
    }

    private static func randomString(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal generic-password Keychain storage.
enum Keychain {
    private static let service = "local.fulcrum.photo"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String?, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
