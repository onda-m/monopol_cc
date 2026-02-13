//
//  HTTPDiagnostics.swift
//  monopol-p2p
//
//  RST問題の原因特定用。観測・in-flight抑止・リトライ・URLSession設定差分検証を提供。
//  既存のアーキテクチャ・状態管理・UIには一切影響しない。
//

import Foundation

// MARK: - HTTPDiagnostics
final class HTTPDiagnostics {

    static let shared = HTTPDiagnostics()
    private init() {}

    // ──────────────────────────────────────────────
    // MARK: 検証フラグ (Step B) — 本番では全て false
    // ──────────────────────────────────────────────
    /// true にすると診断用 URLSession + in-flight抑止を有効化（本番では false）
    var useDiagnosticSession: Bool = false
    /// httpMaximumConnectionsPerHost を 1 に制限（多重接続が原因か切り分け）
    var limitMaxConnections: Bool = false
    /// タイムアウトを短縮（15s）して素早く失敗を検知
    var useShortTimeout: Bool = false
    /// キャッシュを完全無視（キャッシュ不整合が原因か切り分け）
    var ignoreCacheData: Bool = false

    // ──────────────────────────────────────────────
    // MARK: In-flight 抑止 (Step A) — 診断モード時のみ有効
    // ──────────────────────────────────────────────
    private let lock = NSLock()
    private var inFlightRequests: [String: (requestId: String, startedAt: Date)] = [:]
    private var requestCounts: [String: (count: Int, lastTime: Date)] = [:]

    // ──────────────────────────────────────────────
    // MARK: URLSession (Step B) — optional + applyConfig で再生成
    // ──────────────────────────────────────────────
    private var _diagnosticSession: URLSession?

    /// フラグ変更後に呼ぶと診断用セッションを再生成する
    func applyConfig() {
        _diagnosticSession?.invalidateAndCancel()
        let config = URLSessionConfiguration.default
        if limitMaxConnections { config.httpMaximumConnectionsPerHost = 1 }
        if useShortTimeout {
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 15
        }
        if ignoreCacheData {
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
        }
        config.waitsForConnectivity = false
        _diagnosticSession = URLSession(configuration: config)
    }

    /// 検証フラグに応じた URLSession を返す
    var session: URLSession {
        guard useDiagnosticSession else { return URLSession.shared }
        if _diagnosticSession == nil { applyConfig() }
        return _diagnosticSession!
    }

    // ──────────────────────────────────────────────
    // MARK: リクエストID生成
    // ──────────────────────────────────────────────
    func generateRequestId() -> String {
        String(UUID().uuidString.prefix(6))
    }

    // ──────────────────────────────────────────────
    // MARK: 1行ログ出力ヘルパー
    // ──────────────────────────────────────────────
    private func threadLabel() -> String {
        Thread.isMainThread ? "main" : "bg"
    }

    private func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withFullTime, .withTimeZone]
        return f.string(from: Date())
    }

    private func prefix(_ requestId: String) -> String {
        "[\(timestamp())][\(threadLabel())] HTTP[\(requestId)]"
    }

    /// 改行をエスケープして1行に収める
    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    }

    // ──────────────────────────────────────────────
    // MARK: 各種ログ（すべて1行）
    // ──────────────────────────────────────────────
    private func logStart(requestId: String, url: String, timeout: TimeInterval, cachePolicy: URLRequest.CachePolicy) {
        let maxConn: String = (useDiagnosticSession && _diagnosticSession != nil) ? "\(_diagnosticSession!.configuration.httpMaximumConnectionsPerHost)" : "n/a"
        print("\(prefix(requestId)) start url=\(sanitize(url)) timeout=\(Int(timeout)) maxConn=\(maxConn) cache=\(cachePolicy.rawValue)")
    }

    private func logSuccess(requestId: String, statusCode: Int, headers: [AnyHashable: Any], bodyHead: String) {
        let ct = headers["Content-Type"] as? String ?? "n/a"
        let body = sanitize(String(bodyHead.prefix(200)))
        print("\(prefix(requestId)) status=\(statusCode) contentType=\(ct) bodyHead=\(body)")
    }

    private func logFailure(requestId: String, error: Error) {
        let e = error as NSError
        let keys = e.userInfo.isEmpty ? "" : " keys=\(e.userInfo.keys.map { "\($0)" }.joined(separator: ","))"
        print("\(prefix(requestId)) fail domain=\(e.domain) code=\(e.code) desc=\(sanitize(e.localizedDescription))\(keys)")
    }

    private func logCancel(requestId: String, url: String) {
        print("\(prefix(requestId)) CANCELLED url=\(sanitize(url))")
    }

    private func logEnd(requestId: String, durationMs: Int) {
        print("\(prefix(requestId)) end durationMs=\(durationMs)")
    }

    private func logCount(requestId: String, pathKey: String, count: Int, gapMs: Int) {
        print("\(prefix(requestId)) countCheck path=\(pathKey) count=\(count) gapMs=\(gapMs)")
    }

    // ──────────────────────────────────────────────
    // MARK: In-flight 抑止（診断モード時のみ）
    // ──────────────────────────────────────────────
    /// in-flight チェック。診断モード OFF 時は常に nil（抑止しない）。
    private func checkAndRegisterInflight(requestId: String, url: String) -> String? {
        guard useDiagnosticSession else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let pathKey = urlPathKey(url)
        let now = Date()
        if let prev = requestCounts[pathKey] {
            let gap = Int(now.timeIntervalSince(prev.lastTime) * 1000)
            requestCounts[pathKey] = (prev.count + 1, now)
            logCount(requestId: requestId, pathKey: pathKey, count: prev.count + 1, gapMs: gap)
        } else {
            requestCounts[pathKey] = (1, now)
            logCount(requestId: requestId, pathKey: pathKey, count: 1, gapMs: 0)
        }

        if let existing = inFlightRequests[url] {
            let elapsed = Int(now.timeIntervalSince(existing.startedAt) * 1000)
            print("\(prefix(requestId)) DUPLICATE_BLOCKED url=\(sanitize(url)) existingReqId=\(existing.requestId) elapsedMs=\(elapsed)")
            return existing.requestId
        }
        inFlightRequests[url] = (requestId, now)
        return nil
    }

    private func unregisterInflight(url: String) {
        guard useDiagnosticSession else { return }
        lock.lock()
        defer { lock.unlock() }
        inFlightRequests.removeValue(forKey: url)
    }

    private func urlPathKey(_ url: String) -> String {
        if let idx = url.firstIndex(of: "?") { return String(url[..<idx]) }
        return url
    }

    // ──────────────────────────────────────────────
    // MARK: 診断付きデータタスク (Step A + C)
    // ──────────────────────────────────────────────
    /// 診断ログ付き + リトライ付き dataTask。completion は必ず1回呼ばれる。
    func dataTask(
        with request: URLRequest,
        maxRetries: Int = 2,
        retryDelays: [TimeInterval] = [0.1, 0.3],
        dedupKey: String? = nil,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        let requestId = generateRequestId()
        let urlString = request.url?.absoluteString ?? "unknown"
        let key = dedupKey ?? urlString

        if let existingId = checkAndRegisterInflight(requestId: requestId, url: key) {
            print("\(prefix(requestId)) skipped inFlightBy=\(existingId)")
            return
        }

        logStart(requestId: requestId, url: urlString, timeout: request.timeoutInterval, cachePolicy: request.cachePolicy)
        let startTime = Date()

        executeWithRetry(request: request, requestId: requestId, urlString: urlString, key: key, startTime: startTime, attempt: 0, maxRetries: maxRetries, retryDelays: retryDelays, completion: completion)
    }

    private func executeWithRetry(
        request: URLRequest, requestId: String, urlString: String, key: String,
        startTime: Date, attempt: Int, maxRetries: Int, retryDelays: [TimeInterval],
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        // singleton なので [self] で保持（解放されない前提）
        let task = session.dataTask(with: request) { [self] data, response, error in
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            // --- キャンセル ---
            if let e = error as NSError?, e.code == NSURLErrorCancelled {
                logCancel(requestId: requestId, url: urlString)
                logEnd(requestId: requestId, durationMs: durationMs)
                unregisterInflight(url: key)
                completion(data, response, error)
                return
            }

            // --- エラー（リトライ可能性あり） ---
            if let error = error {
                logFailure(requestId: requestId, error: error)
                if attempt < maxRetries {
                    let delay = attempt < retryDelays.count ? retryDelays[attempt] : (retryDelays.last ?? 0.3)
                    print("\(prefix(requestId)) retry=\(attempt + 1)/\(maxRetries) delayMs=\(Int(delay * 1000))")
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.executeWithRetry(request: request, requestId: requestId, urlString: urlString, key: key, startTime: startTime, attempt: attempt + 1, maxRetries: maxRetries, retryDelays: retryDelays, completion: completion)
                    }
                    return
                }
                // リトライ上限 — 完了
                logEnd(requestId: requestId, durationMs: durationMs)
                unregisterInflight(url: key)
                completion(data, response, error)
                return
            }

            // --- 成功 ---
            if let http = response as? HTTPURLResponse {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                logSuccess(requestId: requestId, statusCode: http.statusCode, headers: http.allHeaderFields, bodyHead: body)
            }
            logEnd(requestId: requestId, durationMs: durationMs)
            unregisterInflight(url: key)
            completion(data, response, error)
        }
        task.resume()
    }
}
