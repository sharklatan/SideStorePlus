//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

enum AnisetteProvider {
    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] Fetching anisette via On-Device Anisette (ODA)...")
            return try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
        } else {
            debugLog("[AnisetteProvider] Fetching anisette via remote server...")
            return try await fetchRemote(handler: handler)
        }
    }

    private static func serverHeaders(
        for serverURL: URL,
        identifier: UUID,
        existingBlob: Data?,
        baseHeaders: AnisetteRequestHeaders
    ) async throws -> AnisetteRequestHeaders {
        let endpoint = serverURL
            .appendingPathComponent("v3")
            .appendingPathComponent("client_info")
        let cleanIdentifier = identifier.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let payload: [String: String] = [
            "identifier": cleanIdentifier,
            "adi_pb": existingBlob?.base64EncodedString() ?? ""
        ]

        func parseProfile(_ data: Data) -> (String, String)? {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let clientInfo = json["client_info"] as? String,
                  let userAgent = json["user_agent"] as? String,
                  !clientInfo.isEmpty, !userAgent.isEmpty else { return nil }
            return (clientInfo, userAgent)
        }

        var post = URLRequest(url: endpoint)
        post.httpMethod = "POST"
        post.timeoutInterval = SideSign.Constants.Anisette.remoteRequestTimeout
        post.cachePolicy = .reloadIgnoringLocalCacheData
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (postData, postResponse) = try await URLSession.shared.data(for: post)
        guard let postHTTP = postResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        var profile: (String, String)?
        if (200..<300).contains(postHTTP.statusCode) {
            guard let parsed = parseProfile(postData) else {
                throw URLError(.cannotParseResponse)
            }
            profile = parsed
        } else if postHTTP.statusCode != 404 && postHTTP.statusCode != 405 {
            // A recognized server rejected this opaque state. Do not fall back to
            // its global GET profile, because that could cross server identities.
            throw URLError(.badServerResponse)
        } else if existingBlob?.isEmpty == false {
            let normalizedServer = serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let normalizedPrevious = UserDefaults.standard.menuAnisetteURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard normalizedServer == normalizedPrevious else {
                // Only the server that previously succeeded may use legacy GET for
                // opaque state. Other failover servers cannot prove the binding.
                throw URLError(.unsupportedURL)
            }
        }

        // GET remains compatible for fresh provisioning and for existing state on
        // the same legacy V3 server that previously succeeded.
        if profile == nil {
            var get = URLRequest(url: endpoint)
            get.httpMethod = "GET"
            get.timeoutInterval = SideSign.Constants.Anisette.remoteRequestTimeout
            get.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: get)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let parsed = parseProfile(data) else {
                throw URLError(.badServerResponse)
            }
            profile = parsed
        }

        guard let profile else { throw URLError(.cannotParseResponse) }
        var resolved = baseHeaders
        // For remote ADI the server is authoritative for the profile paired
        // with its opaque state. Device ID and other local fields stay local.
        resolved.clientInfo = profile.0
        resolved.userAgent = profile.1
        return resolved
    }

    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let provider = SideSign.AnisetteDataManager.shared
        let existingBlob = AnisetteConfigManager.shared.anisetteAdiBlob.flatMap { Data(base64Encoded: $0) }

        // Migrate only stock clients without ADI state. Existing installations keep
        // their previous server until they deliberately reprovision.
        let legacySource = "https://servers.sidestore.io/servers.json"
        if existingBlob?.isEmpty != false,
           UserDefaults.standard.menuAnisetteList == legacySource {
            UserDefaults.standard.menuAnisetteList = AnisetteServersManager.defaultSource
            UserDefaults.standard.menuAnisetteURL = AppConstants.Anisette.Servers.defaultServerURL
            _ = try? await AnisetteServersManager.shared.syncWithRemote(
                sourceURLString: AnisetteServersManager.defaultSource,
                forceRemote: true
            )
        }

        let serverUrlStrings = await AnisetteServersManager.shared.getActiveServerURLs()
        let servers = serverUrlStrings.compactMap { URL(string: $0) }
        guard !servers.isEmpty else {
            throw AnisetteError.noServersConfigured
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        let startIndex = servers.firstIndex(where: { $0.absoluteString == lastServer }) ?? 0

        let identifier = await AnisetteConfigManager.shared.resolveDeviceIdentifier()
        let headers = await AnisetteConfigManager.shared.makeRequestHeaders()

        let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteDataWithFailover(
            servers: UserDefaults.standard.disableAnisetteRotation ? [servers[startIndex]] : servers,
            startIndex: startIndex,
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers,
            headersForServer: { serverURL in
                try await self.serverHeaders(
                    for: serverURL,
                    identifier: identifier,
                    existingBlob: existingBlob,
                    baseHeaders: headers
                )
            },
            onError: { error in
                if let anisetteError = error as? SideSign.AnisetteError,
                   case .outdatedV1Server(let serverURL, _) = anisetteError {
                    if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                        return true
                    }
                    if let handler = handler {
                        let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                        if shouldContinue {
                            UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                        }
                        return shouldContinue
                    }
                }
                return false
            },
            onSuccess: { successfulServer in
                UserDefaults.standard.menuAnisetteURL = successfulServer.absoluteString
                debugLog("[AnisetteProvider] Successfully fetched Anisette data from \(successfulServer.absoluteString)")
            }
        )

        if let freshBlob = newAdiBlob {
            AnisetteConfigManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
        }

        return anisetteData
    }
}
