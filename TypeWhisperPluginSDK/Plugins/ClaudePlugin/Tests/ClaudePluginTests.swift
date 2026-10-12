import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ClaudePlugin

final class ClaudePluginTests: XCTestCase {
    private static let cachedModelsKey = "fetchedLLMModels.v1"
    private static let selectedLLMModelKey = "selectedLLMModel"
    private static let modelsURL = "https://api.anthropic.com/v1/models"
    private static let messagesURL = "https://api.anthropic.com/v1/messages"

    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testScreenshotAutomationSkipsAutomaticModelRefresh() {
        XCTAssertFalse(
            ClaudeAutomaticRefreshPolicy.allowsRefreshOnAppear(
                arguments: ["TypeWhisper", "--store-screenshots"]
            )
        )
        XCTAssertTrue(ClaudeAutomaticRefreshPolicy.allowsRefreshOnAppear(arguments: ["TypeWhisper"]))
    }

    // MARK: - Existing selection behavior

    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertNil(
            (plugin as? LLMModelSelectable)?.preferredModelId ?? nil,
            "preferredModelId must be nil until the user selects a model"
        )

        let target = try XCTUnwrap(plugin.supportedModels.first?.id)
        plugin.selectLLMModel(target)

        let preferred = (plugin as? LLMModelSelectable)?.preferredModelId
        XCTAssertEqual(preferred, target)
    }

    // MARK: - Fallback list

    func testFallbackModelsWhenNoCacheOrKey() throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            [
                "claude-opus-4-8",
                "claude-sonnet-5",
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5",
            ]
        )
        XCTAssertFalse(
            plugin.supportedModels.contains { $0.id == "claude-haiku-4-5-20251001" },
            "the dated haiku id must be replaced by the alias in the fallback list"
        )
        XCTAssertFalse(plugin.isModelCacheFresh)
    }

    // MARK: - Pagination

    func testPaginationAssemblesAllPagesSortedNewestFirstWithAfterId() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("a-old-model", "A Old", "2024-01-01T00:00:00Z")],
                        hasMore: true,
                        lastId: "cursor-1"
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
                .success(
                    Self.modelsPage(
                        models: [("z-new-model", "Z New", "2026-05-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let ok = await plugin.refreshModels()
        XCTAssertTrue(ok)

        // Both pages assembled and sorted newest-first regardless of page order.
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["z-new-model", "a-old-model"])
        XCTAssertTrue(plugin.isModelCacheFresh)

        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "limit" })?.value,
            "1000"
        )
        XCTAssertNil(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after_id" }),
            "first page must not carry an after_id"
        )
        let secondAfterId = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "after_id" })?.value
        XCTAssertEqual(secondAfterId, "cursor-1")
        // Requests must carry the Anthropic auth headers.
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-api-key"), "claude-key")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testMissingPaginationCursorKeepsExistingCache() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-kept", displayName: "Cached Kept", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("partial-model", "Partial", "2026-01-01T00:00:00Z")],
                        hasMore: true,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let refreshed = await plugin.refreshModels()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["cached-kept"])
        XCTAssertEqual(store.sessions[0].requestedRequests.count, 1)
    }

    func testRepeatedPaginationCursorKeepsExistingCache() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-kept", displayName: "Cached Kept", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(models: [], hasMore: true, lastId: "cursor-1"),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
                .success(
                    Self.modelsPage(
                        models: [("partial-model", "Partial", "2026-01-01T00:00:00Z")],
                        hasMore: true,
                        lastId: "cursor-1"
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let refreshed = await plugin.refreshModels()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["cached-kept"])
        XCTAssertEqual(store.sessions[0].requestedRequests.count, 2)
    }

    func testPaginationSafetyLimitKeepsExistingCache() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-kept", displayName: "Cached Kept", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let outcomes: [PluginHTTPClientTestOutcome] = (0..<20).map { index in
            .success(
                Self.modelsPage(
                    models: [("partial-\(index)", "Partial \(index)", "2026-01-01T00:00:00Z")],
                    hasMore: true,
                    lastId: "cursor-\(index)"
                ),
                Self.httpResponse(url: Self.modelsURL, statusCode: 200)
            )
        }
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: outcomes)
        }

        let refreshed = await plugin.refreshModels()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["cached-kept"])
        XCTAssertEqual(store.sessions[0].requestedRequests.count, 20)
    }

    // MARK: - Cache TTL

    func testFreshCacheServedWithoutRefetch() throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-fresh", displayName: "Cached Fresh", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(
            defaults: [Self.cachedModelsKey: cacheData],
            secrets: ["api-key": "claude-key"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.isModelCacheFresh)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["cached-fresh"])
    }

    func testStaleCacheServedImmediatelyThenRefreshes() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-stale", displayName: "Cached Stale", createdAt: 1_000)],
            fetchedAt: Date(timeIntervalSinceNow: -100_000) // > 24h old
        )
        // Activate without a key so the background refresh does not race the test.
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.isModelCacheFresh)
        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            ["cached-stale"],
            "the stale cache is still served immediately"
        )

        plugin.setApiKey("claude-key")
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("refreshed-model", "Refreshed", "2026-01-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let ok = await plugin.refreshModels()
        XCTAssertTrue(ok)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["refreshed-model"])
        XCTAssertTrue(plugin.isModelCacheFresh)
    }

    func testRefreshFailureKeepsExistingCache() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-kept", displayName: "Cached Kept", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"boom"}}"#.utf8),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 500)
                ),
            ])
        }

        let ok = await plugin.refreshModels()
        XCTAssertFalse(ok, "a failed fetch must not report success")
        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            ["cached-kept"],
            "the existing cache must keep being served after a failed fetch"
        )
    }

    // MARK: - Refresh coordination

    func testActivationAndManualRefreshShareOneInFlightRequest() async throws {
        let staleCache = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-stale", displayName: "Cached Stale", createdAt: 1_000)],
            fetchedAt: Date(timeIntervalSinceNow: -100_000)
        )
        let fetcher = ControlledClaudeModelFetcher()
        let plugin = ClaudePlugin { apiKey in
            await fetcher.fetch(apiKey: apiKey)
        }
        let host = try PluginTestHostServices(
            defaults: [Self.cachedModelsKey: staleCache],
            secrets: ["api-key": "shared-key"]
        )

        plugin.activate(host: host)
        try await fetcher.waitForRequestCount(1)

        let manualRefresh = Task { await plugin.refreshModels() }
        await Self.waitForRefreshWaiterCount(2, plugin: plugin)
        XCTAssertEqual(plugin.inFlightModelRefreshWaiterCountForTesting, 2)

        await fetcher.resolveFirst(
            apiKey: "shared-key",
            models: [ClaudeFetchedModel(id: "shared-result", displayName: "Shared", createdAt: 2_000)]
        )

        let manualRefreshSucceeded = await manualRefresh.value
        let recordedKeys = await fetcher.recordedKeys()
        XCTAssertTrue(manualRefreshSucceeded)
        XCTAssertEqual(recordedKeys, ["shared-key"])
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["shared-result"])
    }

    func testAPIKeyChangeDiscardsOlderInFlightResult() async throws {
        let fetcher = ControlledClaudeModelFetcher()
        let plugin = ClaudePlugin { apiKey in
            await fetcher.fetch(apiKey: apiKey)
        }
        let host = try PluginTestHostServices()
        plugin.activate(host: host)
        plugin.setApiKey("old-key")

        let oldRefresh = Task { await plugin.refreshModels() }
        try await fetcher.waitForRequestCount(1)

        plugin.setApiKey("new-key")
        let newRefresh = Task { await plugin.refreshModels() }
        try await fetcher.waitForRequestCount(2)

        await fetcher.resolveFirst(
            apiKey: "new-key",
            models: [ClaudeFetchedModel(id: "new-model", displayName: "New", createdAt: 2_000)]
        )
        let newRefreshSucceeded = await newRefresh.value
        XCTAssertTrue(newRefreshSucceeded)

        await fetcher.resolveFirst(
            apiKey: "old-key",
            models: [ClaudeFetchedModel(id: "old-model", displayName: "Old", createdAt: 1_000)]
        )
        let oldRefreshSucceeded = await oldRefresh.value
        let recordedKeys = await fetcher.recordedKeys()
        XCTAssertFalse(oldRefreshSucceeded)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["new-model"])
        XCTAssertEqual(recordedKeys, ["old-key", "new-key"])
        let persistedData = try XCTUnwrap(host.userDefault(forKey: Self.cachedModelsKey) as? Data)
        let persistedCache = try JSONDecoder().decode(ClaudeModelCache.self, from: persistedData)
        XCTAssertEqual(persistedCache.models.map(\.id), ["new-model"])
    }

    func testDeactivateDiscardsInFlightResultWithoutNotification() async throws {
        let fetcher = ControlledClaudeModelFetcher()
        let plugin = ClaudePlugin { apiKey in
            await fetcher.fetch(apiKey: apiKey)
        }
        let host = try PluginTestHostServices()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")
        let notificationsBeforeRefresh = host.capabilitiesChangedCount

        let refresh = Task { await plugin.refreshModels() }
        try await fetcher.waitForRequestCount(1)
        plugin.deactivate()

        await fetcher.resolveFirst(
            apiKey: "claude-key",
            models: [ClaudeFetchedModel(id: "stale-model", displayName: "Stale", createdAt: 1_000)]
        )

        let refreshSucceeded = await refresh.value
        XCTAssertFalse(refreshSucceeded)
        XCTAssertNil(plugin.cacheLastUpdated)
        XCTAssertEqual(host.capabilitiesChangedCount, notificationsBeforeRefresh)
    }

    // MARK: - Selection preservation

    func testProcessThrowsWhenReplyStoppedAtMaxTokens() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "claude-key"])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"content":[{"type":"text","text":"half a sen"}],"stop_reason":"max_tokens"}"#.utf8),
                    Self.httpResponse(url: Self.messagesURL, statusCode: 200)
                ),
            ])
        }

        do {
            _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: "claude-sonnet-4-6")
            XCTFail("Expected the truncated reply to throw")
        } catch let error as PluginChatError {
            guard case .apiError(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("cut off"), message)
        }
    }

    func testProcessReturnsTextThatFollowsThinkingBlocks() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host) // no key on host → no background model refresh
        plugin.setApiKey("claude-key")

        let body = #"""
        {"content":[
            {"type":"thinking","thinking":"","signature":"sig"},
            {"type":"redacted_thinking","data":"opaque"},
            {"type":"text","text":"Hello"},
            {"type":"text","text":" world\n"}
        ],"stop_reason":"end_turn"}
        """#
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(body.utf8), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
            ])
        }

        let reply = try await plugin.process(systemPrompt: "sys", userText: "hi", model: "claude-sonnet-5")
        XCTAssertEqual(reply, "Hello world", "thinking blocks before the answer must not hide the text blocks")
    }

    func testSelectedModelIsPreservedWhenNotInList() throws {
        let host = try PluginTestHostServices(
            defaults: [Self.selectedLLMModelKey: "claude-haiku-4-5-20251001"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.preferredModelId, "claude-haiku-4-5-20251001")
        XCTAssertTrue(
            plugin.supportedModels.contains { $0.id == "claude-haiku-4-5-20251001" },
            "a selected model that is not in the list must be appended so it stays selectable"
        )
        // Fallback entries still present.
        XCTAssertTrue(plugin.supportedModels.contains { $0.id == "claude-opus-4-8" })
    }

    func testSelectionPreservedAgainstFetchedListThatDropsIt() async throws {
        let host = try PluginTestHostServices(
            defaults: [Self.selectedLLMModelKey: "claude-legacy-pinned"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("claude-opus-4-8", "Claude Opus 4.8", "2026-01-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        _ = await plugin.refreshModels()
        XCTAssertEqual(plugin.preferredModelId, "claude-legacy-pinned")
        XCTAssertTrue(
            plugin.supportedModels.contains { $0.id == "claude-legacy-pinned" },
            "the still-selected model must survive even when the fetched list omits it"
        )
    }

    // MARK: - Unify: validation seeds the cache

    func testValidateApiKeySeedsModelCache() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host) // no key → no background refresh
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("validated-model", "Validated", "2026-03-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let valid = await plugin.validateApiKey("claude-key")
        XCTAssertTrue(valid)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["validated-model"])
        XCTAssertTrue(plugin.isModelCacheFresh)
    }

    func testValidateApiKeyFailureReturnsFalse() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("bad-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data("{}".utf8), Self.httpResponse(url: Self.modelsURL, statusCode: 401)),
            ])
        }

        let valid = await plugin.validateApiKey("bad-key")
        XCTAssertFalse(valid)
    }

    // MARK: - Sampling parameter correctness

    func testUnselectedProcessingUsesNewestCachedModel() async throws {
        let cacheData = try Self.encodeCache(
            models: [
                ClaudeFetchedModel(id: "newest-model", displayName: "Newest", createdAt: 2_000),
                ClaudeFetchedModel(id: "older-model", displayName: "Older", createdAt: 1_000),
            ],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(
            defaults: [Self.cachedModelsKey: cacheData],
            secrets: ["api-key": "claude-key"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.messagesResponse(text: "ok"),
                    Self.httpResponse(url: Self.messagesURL, statusCode: 200)
                ),
            ])
        }

        _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: nil)

        let request = try XCTUnwrap(store.sessions[0].requestedRequests.first)
        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "newest-model")
        XCTAssertNil(plugin.selectedLLMModelId, "using the newest default must not persist a selection")
    }

    func testModelRejectsSamplingParamsByFamily() {
        for id in [
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-sonnet-5",
            "claude-fable-5",
            "claude-mythos-5",
            "claude-mythos-preview",
            "claude-opus-4-9",
            "claude-haiku-5",
            "claude-future-unknown",
        ] {
            XCTAssertTrue(
                ClaudePlugin.modelRejectsSamplingParams(id),
                "\(id) rejects sampling params and must have temperature omitted"
            )
        }

        for id in [
            "claude-sonnet-4-6",
            "claude-opus-4-6",
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
            "claude-3-5-sonnet-20241022",
        ] {
            XCTAssertFalse(
                ClaudePlugin.modelRejectsSamplingParams(id),
                "\(id) honors sampling params and must keep the temperature override"
            )
        }
    }

    func testMessagesRequestOmitsTemperatureForNewerModelAndKeepsForOlder() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "llmTemperatureMode": PluginLLMTemperatureMode.custom.rawValue,
                "llmTemperatureValue": 0.7,
            ]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host) // no key on host → no background model refresh
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Self.messagesResponse(text: "ok"), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
                .success(Self.messagesResponse(text: "ok"), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
                .success(Self.messagesResponse(text: "ok"), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
            ])
        }

        _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: "claude-opus-4-8")
        _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: "claude-sonnet-4-6")
        _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: "claude-future-unknown")

        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 3)

        let opusBody = try Self.jsonBody(from: requests[0])
        XCTAssertNil(opusBody["temperature"], "temperature must be omitted for claude-opus-4-8")

        let sonnetBody = try Self.jsonBody(from: requests[1])
        XCTAssertEqual(sonnetBody["temperature"] as? Double, 0.7, "temperature must be sent for claude-sonnet-4-6")

        let futureBody = try Self.jsonBody(from: requests[2])
        XCTAssertNil(futureBody["temperature"], "temperature must be omitted for unknown future models")
    }

    // MARK: - Descriptive errors

    func testNotFoundNamesModelErrorTypeAndRequestId() async throws {
        let error = try await Self.processError(
            outcomes: [
                .success(
                    Self.errorBody(type: "not_found_error", message: "model: claude-opus-9"),
                    Self.httpResponse(url: Self.messagesURL, statusCode: 404, headers: ["request-id": "req_header"])
                ),
            ],
            model: "claude-opus-9"
        )
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.hasPrefix("Model claude-opus-9 isn't available to this API key: model: claude-opus-9."), message)
        XCTAssertTrue(message.contains("Refresh the model list"), message)
        XCTAssertTrue(message.contains("[HTTP 404 not_found_error · model claude-opus-9 · request req_header]"), message)
    }

    func testRequestIdFallsBackToErrorBody() async throws {
        let error = try await Self.processError(outcomes: [
            .success(
                Self.errorBody(type: "invalid_request_error", message: "max_tokens: too large", requestId: "req_from_body"),
                Self.httpResponse(url: Self.messagesURL, statusCode: 400)
            ),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.hasPrefix("Claude rejected the request: max_tokens: too large."), message)
        XCTAssertTrue(message.contains("request req_from_body"), message)
    }

    func testAuthenticationFailureExplainsWhereToFixTheKey() async throws {
        let error = try await Self.processError(outcomes: [
            .success(
                Self.errorBody(type: "authentication_error", message: "invalid x-api-key"),
                Self.httpResponse(url: Self.messagesURL, statusCode: 401)
            ),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.hasPrefix("Anthropic rejected the API key: invalid x-api-key."), message)
        XCTAssertTrue(message.contains("Settings › Integrations › Claude"), message)
    }

    func testRateLimitNamesRetryDelayAndExhaustedLimit() async throws {
        let error = try await Self.processError(outcomes: [
            .success(
                Self.errorBody(type: "rate_limit_error", message: "Number of request tokens has exceeded your per-minute rate limit"),
                Self.httpResponse(
                    url: Self.messagesURL,
                    statusCode: 429,
                    headers: [
                        // Longer than the client's retry budget, so it is not retried.
                        "retry-after": "40",
                        "anthropic-ratelimit-output-tokens-limit": "400000",
                        "anthropic-ratelimit-output-tokens-remaining": "0",
                        "anthropic-ratelimit-output-tokens-reset": "2026-10-12T10:00:00Z",
                    ]
                )
            ),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.hasPrefix("Anthropic's rate limit was reached:"), message)
        XCTAssertTrue(message.contains("Retry in 40 s."), message)
        XCTAssertTrue(message.contains("Output-token limit (400000) used up; it is fully replenished at"), message)
        XCTAssertTrue(message.contains("HTTP 429 rate_limit_error"), message)
    }

    func testSpendCapIsToldApartFromRateLimit() async throws {
        let error = try await Self.processError(outcomes: [
            .success(
                Self.errorBody(
                    type: "rate_limit_error",
                    message: "You have reached your API usage limits.",
                    errorCode: "enforced_spend_limit_reached"
                ),
                Self.httpResponse(url: Self.messagesURL, statusCode: 429)
            ),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.hasPrefix("Your organization reached its monthly API spend cap: You have reached your API usage limits."), message)
        XCTAssertFalse(message.contains("Retry in"), message)
    }

    func testOverloadedSuggestsRetrying() async throws {
        let error = try await Self.processError(outcomes: [
            .success(
                Self.errorBody(type: "overloaded_error", message: "Overloaded"),
                Self.httpResponse(url: Self.messagesURL, statusCode: 529)
            ),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.hasPrefix("Anthropic's API is overloaded right now: Overloaded."), message)
        XCTAssertTrue(message.contains("HTTP 529 overloaded_error"), message)
    }

    func testHTMLErrorPageIsSummarized() async throws {
        let html = "<html><head><title>502 Bad Gateway</title></head><body>cloudflare</body></html>"
        let error = try await Self.processError(outcomes: [
            .success(
                Data(html.utf8),
                Self.httpResponse(url: Self.messagesURL, statusCode: 502, headers: ["Content-Type": "text/html"])
            ),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.hasPrefix("Anthropic returned HTTP 502: upstream returned an HTML error page"), message)
        XCTAssertTrue(message.contains("502 Bad Gateway"), message)
    }

    func testEmptyJSONErrorBodyIsExplained() async throws {
        let error = try await Self.processError(outcomes: [
            .success(Data("{}".utf8), Self.httpResponse(url: Self.messagesURL, statusCode: 500)),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.hasPrefix("Anthropic had an internal error: the response carried no error details."), message)
    }

    func testRefusalIsReportedWithCategoryInsteadOfPartialText() async throws {
        let body = #"""
        {"content":[{"type":"text","text":"Partial"}],"stop_reason":"refusal",
         "stop_details":{"type":"refusal","category":"cyber","explanation":"This request may enable harm"}}
        """#
        let error = try await Self.processError(outcomes: [
            .success(Data(body.utf8), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.hasPrefix("Claude declined this request (cyber): This request may enable harm."), message)
        XCTAssertFalse(message.contains("Partial"), message)
    }

    func testMaxTokensWithoutTextExplainsTheMissingAnswer() async throws {
        let body = #"{"content":[{"type":"thinking","thinking":"","signature":"sig"}],"stop_reason":"max_tokens"}"#
        let error = try await Self.processError(outcomes: [
            .success(Data(body.utf8), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.contains("output limit before writing an answer"), message)
    }

    func testContextWindowStopIsExplained() async throws {
        let body = #"{"content":[{"type":"text","text":"Part"}],"stop_reason":"model_context_window_exceeded"}"#
        let error = try await Self.processError(outcomes: [
            .success(Data(body.utf8), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.hasPrefix("The text is too long for claude-sonnet-4-6's context window."), message)
    }

    func testReplyWithoutTextNamesStopReasonAndBlocks() async throws {
        let body = #"{"content":[{"type":"thinking","thinking":"","signature":"sig"}],"stop_reason":"end_turn"}"#
        let error = try await Self.processError(outcomes: [
            .success(Data(body.utf8), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
        ])
        let message = Self.apiErrorMessage(error)
        XCTAssertTrue(message.contains("stop reason: end_turn; content blocks: thinking"), message)
    }

    func testTimeoutBecomesNetworkErrorWithTheTimeout() async throws {
        let error = try await Self.processError(outcomes: [.failure(URLError(.timedOut))])
        guard case .networkError(let message)? = error as? PluginChatError else {
            return XCTFail("Expected PluginChatError.networkError, got \(error)")
        }
        XCTAssertTrue(message.hasPrefix("Anthropic didn't answer within 60 s."), message)
        XCTAssertTrue(message.contains("URLError \(URLError.Code.timedOut.rawValue)"), message)
    }

    func testCancellationIsRethrownUntouched() async throws {
        let error = try await Self.processError(outcomes: [.failure(URLError(.cancelled))])
        XCTAssertEqual((error as? URLError)?.code, .cancelled)
    }

    func testValidationFailureReasonTellsBadKeyFromOutage() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        plugin.setApiKey("bad-key")
        let rejectingStore = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            rejectingStore.makeSession(outcomes: [
                .success(
                    Self.errorBody(type: "authentication_error", message: "invalid x-api-key"),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 401)
                ),
            ])
        }
        let rejected = await plugin.validateApiKey("bad-key")
        XCTAssertFalse(rejected)
        let authFailure = try XCTUnwrap(plugin.lastModelRefreshFailure)
        XCTAssertTrue(authFailure.isAuthenticationFailure)
        XCTAssertTrue(authFailure.message.hasPrefix("Anthropic rejected the API key: invalid x-api-key."), authFailure.message)

        plugin.setApiKey("good-key")
        XCTAssertNil(plugin.lastModelRefreshFailure, "a new key must clear the previous key's failure")
        let outageStore = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            outageStore.makeSession(outcomes: [
                .success(
                    Self.errorBody(type: "api_error", message: "Internal server error"),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 500)
                ),
            ])
        }
        let outage = await plugin.validateApiKey("good-key")
        XCTAssertFalse(outage)
        let outageFailure = try XCTUnwrap(plugin.lastModelRefreshFailure)
        XCTAssertFalse(outageFailure.isAuthenticationFailure)
        XCTAssertEqual(outageFailure.statusCode, 500)
        XCTAssertTrue(outageFailure.message.hasPrefix("Anthropic had an internal error: Internal server error."), outageFailure.message)
    }

    func testOfflineRefreshRecordsNetworkReason() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [.failure(URLError(.notConnectedToInternet))])
        }

        let refreshed = await plugin.refreshModels()
        XCTAssertFalse(refreshed)
        let failure = try XCTUnwrap(plugin.lastModelRefreshFailure)
        XCTAssertNil(failure.statusCode)
        XCTAssertTrue(failure.message.hasPrefix("This Mac is offline"), failure.message)
    }

    // MARK: - Helpers

    private static func waitForRefreshWaiterCount(_ expectedCount: Int, plugin: ClaudePlugin) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while plugin.inFlightModelRefreshWaiterCountForTesting < expectedCount,
              clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func modelsPage(
        models: [(id: String, displayName: String, createdAt: String)],
        hasMore: Bool,
        lastId: String?
    ) -> Data {
        var body: [String: Any] = [
            "data": models.map { model in
                [
                    "id": model.id,
                    "display_name": model.displayName,
                    "created_at": model.createdAt,
                    "type": "model",
                ]
            },
            "has_more": hasMore,
        ]
        if let lastId {
            body["last_id"] = lastId
        }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func messagesResponse(text: String) -> Data {
        let body: [String: Any] = [
            "content": [["type": "text", "text": text]],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func encodeCache(models: [ClaudeFetchedModel], fetchedAt: Date) throws -> Data {
        try JSONEncoder().encode(ClaudeModelCache(models: models, fetchedAt: fetchedAt))
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func httpResponse(
        url: String,
        statusCode: Int,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    private static func errorBody(type: String, message: String, errorCode: String? = nil, requestId: String = "req_body") -> Data {
        var error: [String: Any] = ["type": type, "message": message]
        if let errorCode {
            error["details"] = ["error_code": errorCode]
        }
        let body: [String: Any] = ["type": "error", "error": error, "request_id": requestId]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// Runs one Messages request against `outcomes` and returns the thrown error.
    private static func processError(
        outcomes: [PluginHTTPClientTestOutcome],
        model: String = "claude-sonnet-4-6"
    ) async throws -> Error {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host) // no key on host → no background model refresh
        plugin.setApiKey("claude-key")
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: outcomes)
        }
        do {
            let reply = try await plugin.process(systemPrompt: "sys", userText: "hi", model: model)
            throw ClaudeTestExpectationError(description: "expected an error, got reply \(reply)")
        } catch let error as ClaudeTestExpectationError {
            throw error
        } catch {
            return error
        }
    }

    private static func apiErrorMessage(_ error: Error, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .apiError(let message)? = error as? PluginChatError else {
            XCTFail("Expected PluginChatError.apiError, got \(error)", file: file, line: line)
            return ""
        }
        return message
    }
}

private struct ClaudeTestExpectationError: Error, CustomStringConvertible {
    let description: String
}

private actor ControlledClaudeModelFetcher {
    private struct RequestCountTimeoutError: Error, CustomStringConvertible {
        let expectedCount: Int
        let actualCount: Int

        var description: String {
            "Timed out after one second waiting for \(expectedCount) Claude model request(s); observed \(actualCount)"
        }
    }

    private struct PendingRequest {
        let apiKey: String
        let continuation: CheckedContinuation<[ClaudeFetchedModel]?, Never>
    }

    private var keys: [String] = []
    private var pendingRequests: [PendingRequest] = []

    func fetch(apiKey: String) async -> [ClaudeFetchedModel]? {
        keys.append(apiKey)
        return await withCheckedContinuation { continuation in
            pendingRequests.append(
                PendingRequest(apiKey: apiKey, continuation: continuation)
            )
        }
    }

    func waitForRequestCount(_ expectedCount: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while keys.count < expectedCount, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard keys.count >= expectedCount else {
            throw RequestCountTimeoutError(
                expectedCount: expectedCount,
                actualCount: keys.count
            )
        }
    }

    func resolveFirst(apiKey: String, models: [ClaudeFetchedModel]?) {
        guard let index = pendingRequests.firstIndex(where: { $0.apiKey == apiKey }) else {
            preconditionFailure("No pending Claude model request for \(apiKey)")
        }
        let request = pendingRequests.remove(at: index)
        request.continuation.resume(returning: models)
    }

    func recordedKeys() -> [String] {
        keys
    }
}
