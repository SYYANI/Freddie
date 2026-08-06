import Foundation
import SwiftData
import CryptoKit

@MainActor
final class AbstractTranslationService {
    private let translationClient: TranslationLLMClientProtocol
    private let routeResolver: LLMRouteResolver
    private let glossaryProvider: () -> String
    
    init(
        translationClient: TranslationLLMClientProtocol = TranslationLLMClient(),
        routeResolver: LLMRouteResolver = LLMRouteResolver(),
        glossaryProvider: @escaping () -> String = { TranslationGlossaryPreference.current() }
    ) {
        self.translationClient = translationClient
        self.routeResolver = routeResolver
        self.glossaryProvider = glossaryProvider
    }
    
    func translateAbstract(
        paper: Paper,
        settings: AppSettings,
        targetLanguage: String? = nil,
        modelContext: ModelContext,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        guard !paper.abstractText.isEmpty else {
            throw AbstractTranslationError.emptyAbstract
        }
        
        let actualTargetLanguage = targetLanguage ?? settings.targetLanguage
        let preferences = TranslationPreferencesSnapshot(
            targetLanguage: actualTargetLanguage,
            htmlTranslationConcurrency: settings.htmlTranslationConcurrency,
            babelDocQPS: settings.babelDocQPS,
            babelDocVersion: settings.babelDocVersion,
            translationGlossary: glossaryProvider()
        )
        
        onProgress?("Resolving translation route...")
        
        // 尝试解析路由
        let route: ResolvedLLMModelRoute
        do {
            route = try routeResolver.resolveHTMLRoute(settings: settings, modelContext: modelContext)
        } catch {
            throw AbstractTranslationError.routeResolutionFailed(error)
        }
        
        // 检查缓存
        let sourceHash = Hashing.sha256Hex(paper.abstractText)
        if let cached = try getCachedTranslation(
            paper: paper,
            targetLanguage: actualTargetLanguage,
            route: route,
            cacheIdentity: preferences.translationCacheIdentity(for: route.snapshot),
            modelContext: modelContext
        ) {
            return cached
        }
        
        onProgress?("Translating abstract...")
        
        // 使用真实的翻译客户端
        let translatedText: String
        do {
            translatedText = try await translationClient.translate(
                paper.abstractText,
                targetLanguage: actualTargetLanguage,
                route: route.snapshot,
                apiKey: route.apiKey,
                context: AcademicTranslationContext(
                    documentTitle: paper.title,
                    sectionTitle: "Abstract",
                    glossary: preferences.translationGlossary
                )
            )
        } catch {
            throw AbstractTranslationError.translationFailed(error)
        }
        
        // 保存到缓存
        let segment = TranslationSegment(
            paperID: paper.id,
            sourceType: "abstract",
            targetLanguage: actualTargetLanguage,
            sourceHash: sourceHash,
            sourceText: paper.abstractText,
            translatedText: translatedText,
            providerProfileID: route.snapshot.providerProfileID,
            modelProfileID: route.snapshot.modelProfileID,
            modelName: preferences.translationCacheIdentity(for: route.snapshot)
        )
        
        modelContext.insert(segment)
        try modelContext.save()
        
        return translatedText
    }
    
    func getCachedTranslation(
        paper: Paper,
        targetLanguage: String,
        route: ResolvedLLMModelRoute,
        cacheIdentity: String? = nil,
        modelContext: ModelContext
    ) throws -> String? {
        guard !paper.abstractText.isEmpty else { return nil }
        
        let sourceHash = Hashing.sha256Hex(paper.abstractText)
        
        // 获取所有TranslationSegment
        let descriptor = FetchDescriptor<TranslationSegment>()
        let allSegments = try modelContext.fetch(descriptor)
        
        // 手动过滤缓存
        return allSegments.first { segment in
            segment.paperID == paper.id &&
            segment.sourceType == "abstract" &&
            segment.sourceHash == sourceHash &&
            segment.targetLanguage == targetLanguage &&
            segment.providerProfileID == route.snapshot.providerProfileID &&
            segment.modelProfileID == route.snapshot.modelProfileID &&
            segment.modelName == (cacheIdentity ?? route.snapshot.translationCacheIdentity)
        }?.translatedText
    }
    
    func clearCache(for paper: Paper, modelContext: ModelContext) throws {
        // 获取所有TranslationSegment
        let descriptor = FetchDescriptor<TranslationSegment>()
        let allSegments = try modelContext.fetch(descriptor)
        
        // 过滤出符合条件的segment
        let segmentsToDelete = allSegments.filter { segment in
            segment.paperID == paper.id && segment.sourceType == "abstract"
        }
        
        for segment in segmentsToDelete {
            modelContext.delete(segment)
        }
        
        try modelContext.save()
    }
    
    func clearCacheForLanguage(
        paper: Paper,
        targetLanguage: String,
        modelContext: ModelContext
    ) throws {
        // 获取所有TranslationSegment
        let descriptor = FetchDescriptor<TranslationSegment>()
        let allSegments = try modelContext.fetch(descriptor)
        
        // 过滤出符合条件的segment
        let segmentsToDelete = allSegments.filter { segment in
            segment.paperID == paper.id && 
            segment.sourceType == "abstract" &&
            segment.targetLanguage == targetLanguage
        }
        
        for segment in segmentsToDelete {
            modelContext.delete(segment)
        }
        
        try modelContext.save()
    }
    
    func checkTranslationConfiguration(
        settings: AppSettings,
        modelContext: ModelContext
    ) throws -> ResolvedLLMModelRoute {
        do {
            return try routeResolver.resolveHTMLRoute(settings: settings, modelContext: modelContext)
        } catch {
            throw AbstractTranslationError.routeResolutionFailed(error)
        }
    }
    
    func getAvailableTargetLanguages() -> [TranslationTargetLanguage] {
        TranslationTargetLanguage.supported
    }
    
    func getCurrentTargetLanguage(settings: AppSettings) -> TranslationTargetLanguage {
        let supportedLanguages = TranslationTargetLanguage.supported
        return supportedLanguages.first { $0.code == settings.targetLanguage } ?? TranslationTargetLanguage.simplifiedChinese
    }
}

enum AbstractTranslationError: LocalizedError {
    case emptyAbstract
    case routeResolutionFailed(Error)
    case translationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .emptyAbstract:
            return "Abstract is empty."
        case .routeResolutionFailed(let error):
            return "Failed to resolve translation route: \(error.localizedDescription)"
        case .translationFailed(let error):
            return "Translation failed: \(error.localizedDescription)"
        }
    }
}
