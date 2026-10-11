//
//  AppConfig.swift
//  SwiftChat
//
//  Created on 03/25/26.
//  Copyright © 2026 Sacha Servan-Schreiber. All rights reserved.
//

import Foundation
import Combine
import OpenAI

/// A model available for chat
struct ModelType: Identifiable, Codable, Hashable, Equatable {
    let id: String
    let displayName: String
    let fullName: String
    let iconName: String
    let isMultimodal: Bool

    var modelName: String { id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ModelType, rhs: ModelType) -> Bool { lhs.id == rhs.id }
}

/// Models response from OpenAI API
struct ModelListResponse: Codable {
    let object: String
    let data: [ModelAPI]
}

struct ModelAPI: Codable {
    let id: String
    let object: String
    let created: Int
    let owned_by: String
}

/// Application-wide configuration
@MainActor
class AppConfig: ObservableObject {
    static let shared = AppConfig()

    // MARK: - Configuration

    /// Set your API key here or via environment
    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "apiKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "apiKey") }
    }

    /// OpenAI-compatible API host (no scheme, no path)
    var apiHost: String = "ai.valentiin.com"

    /// Base path for the API
    var apiBasePath: String = "/v1"

    /// System prompt sent with every conversation
    var systemPrompt: String = "You are a helpful AI assistant."

    /// Additional rules appended to the system prompt
    var rules: String = ""

    // MARK: - State

    @Published private(set) var isInitialized = false
    @Published private(set) var initializationError: Error?
    @Published var currentModel: ModelType? {
        didSet {
            if let model = currentModel {
                UserDefaults.standard.set(model.id, forKey: "selectedModel")
            }
        }
    }
    @Published private(set) var availableModels: [ModelType] = []
    @Published private(set) var networkMonitor = NetworkMonitor()

    private init() {
        loadCachedModels()
        loadLastSelectedModel()
        isInitialized = true

        Task {
            await fetchModels()
        }
    }

    // MARK: - Models

    private func loadCachedModels() {
        if let data = UserDefaults.standard.data(forKey: "cachedModels"),
           let models = try? JSONDecoder().decode([ModelType].self, from: data) {
            self.availableModels = models
        } else {
            self.availableModels = []
        }
    }

    private func cacheModels(_ models: [ModelType]) {
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: "cachedModels")
        }
    }

    /// Fetches models from the API
    func fetchModels() async {
        guard !apiKey.isEmpty, apiKey != "YOUR_API_KEY" else { return }

        let urlString = "https://\(apiHost)\(apiBasePath)/models"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("Failed to fetch models: HTTP status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }

            let decoder = JSONDecoder()
            let modelResponse = try decoder.decode(ModelListResponse.self, from: data)

            // Map the API models to ModelType.
            // We set isMultimodal to false by default as we don't know without a mapping,
            // but for OpenAI compatible APIs, the model name might hint it.
            let fetchedModels = modelResponse.data.map { apiModel in
                let displayName = apiModel.id
                let fullName = apiModel.id
                let isMultimodal = apiModel.id.contains("vision") || apiModel.id.contains("gpt-4o")

                return ModelType(
                    id: apiModel.id,
                    displayName: displayName,
                    fullName: fullName,
                    iconName: "openai-icon",
                    isMultimodal: isMultimodal
                )
            }

            if !fetchedModels.isEmpty {
                let sorted = fetchedModels.sorted { $0.id < $1.id }
                self.availableModels = sorted
                self.cacheModels(sorted)

                // If current model is not in the new list, update it.
                if let current = self.currentModel, !sorted.contains(where: { $0.id == current.id }) {
                    self.currentModel = self.availableModels.first
                } else if self.currentModel == nil {
                    self.currentModel = self.availableModels.first
                }
            }

        } catch {
            print("Error fetching models: \(error)")
        }
    }

    private func loadLastSelectedModel() {
        if let savedId = UserDefaults.standard.string(forKey: "selectedModel"),
           let model = availableModels.first(where: { $0.id == savedId }) {
            currentModel = model
        } else {
            currentModel = availableModels.first
        }
    }

    func filteredModelTypes() -> [ModelType] {
        return availableModels
    }

    /// The model used for generating chat titles (nil = skip title generation)
    var titleModel: ModelType? {
        availableModels.first(where: { $0.id == "gpt-4.1-mini" }) ?? availableModels.first
    }

    // MARK: - OpenAI Client

    func makeClient() -> OpenAI {
        let config = OpenAI.Configuration(
            token: apiKey,
            host: apiHost,
            basePath: apiBasePath
        )
        return OpenAI(configuration: config)
    }
}
