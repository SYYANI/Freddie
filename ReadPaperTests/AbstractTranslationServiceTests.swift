import XCTest
import SwiftData
@testable import ReadPaper

@MainActor
final class AbstractTranslationServiceTests: XCTestCase {
    private var modelContainer: ModelContainer!
    private var modelContext: ModelContext!
    private var service: AbstractTranslationService!
    
    override func setUp() async throws {
        let schema = Schema([
            Paper.self,
            PaperAttachment.self,
            TranslationSegment.self,
            AppSettings.self,
            LLMProviderProfile.self,
            LLMModelProfile.self,
            Note.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: schema, configurations: config)
        modelContext = ModelContext(modelContainer)
        
        // 创建模拟的翻译客户端
        let mockClient = MockTranslationClient()
        service = AbstractTranslationService(translationClient: mockClient)
    }
    
    override func tearDown() async throws {
        modelContext = nil
        modelContainer = nil
        service = nil
    }
    
    func testEmptyAbstractThrowsError() async throws {
        // 创建一个没有abstract的paper
        let paper = Paper(
            id: UUID(),
            arxivID: nil,
            arxivVersion: nil,
            doi: nil,
            title: "Test Paper",
            abstractText: "",
            authors: [],
            categories: [],
            publishedAt: nil,
            updatedAt: nil,
            pdfURLString: nil,
            htmlURLString: nil,
            localDirectoryPath: "",
            tags: [],
            isFavorite: false,
            createdAt: Date(),
            modifiedAt: Date()
        )
        modelContext.insert(paper)
        
        let settings = AppSettings()
        modelContext.insert(settings)
        
        do {
            _ = try await service.translateAbstract(
                paper: paper,
                settings: settings,
                modelContext: modelContext
            )
            XCTFail("Should have thrown emptyAbstract error")
        } catch let error as AbstractTranslationError {
            if case .emptyAbstract = error {
                // 预期错误
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testRouteResolutionFailure() async throws {
        // 创建一个有abstract的paper
        let paper = Paper(
            id: UUID(),
            arxivID: nil,
            arxivVersion: nil,
            doi: nil,
            title: "Test Paper",
            abstractText: "This is a test abstract.",
            authors: [],
            categories: [],
            publishedAt: nil,
            updatedAt: nil,
            pdfURLString: nil,
            htmlURLString: nil,
            localDirectoryPath: "",
            tags: [],
            isFavorite: false,
            createdAt: Date(),
            modifiedAt: Date()
        )
        modelContext.insert(paper)
        
        // 创建没有配置LLM的settings
        let settings = AppSettings()
        modelContext.insert(settings)
        
        do {
            _ = try await service.translateAbstract(
                paper: paper,
                settings: settings,
                modelContext: modelContext
            )
            XCTFail("Should have thrown routeResolutionFailed error")
        } catch let error as AbstractTranslationError {
            if case .routeResolutionFailed = error {
                // 预期错误 - 因为没有配置LLM
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            // 也可能是LLMRouteError
            print("Got expected route error: \(error)")
        }
    }
    
    func testCheckTranslationConfiguration() throws {
        let settings = AppSettings()
        modelContext.insert(settings)
        
        do {
            _ = try service.checkTranslationConfiguration(
                settings: settings,
                modelContext: modelContext
            )
            XCTFail("Should have thrown error for missing LLM configuration")
        } catch let error as AbstractTranslationError {
            if case .routeResolutionFailed = error {
                // 预期错误
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            // 也可能是LLMRouteError
            print("Got expected configuration error: \(error)")
        }
    }
    
    func testGetAvailableTargetLanguages() {
        let languages = service.getAvailableTargetLanguages()
        XCTAssertEqual(languages.count, 2)
        XCTAssertTrue(languages.contains(where: { $0.code == "EN" }))
        XCTAssertTrue(languages.contains(where: { $0.code == "zh-CN" }))
    }
    
    func testGetCurrentTargetLanguage() {
        let settings = AppSettings(targetLanguage: "zh-CN")
        let language = service.getCurrentTargetLanguage(settings: settings)
        XCTAssertEqual(language.code, "zh-CN")
        XCTAssertEqual(language.nativeName, "中文（简体）")
        
        let settingsEN = AppSettings(targetLanguage: "EN")
        let languageEN = service.getCurrentTargetLanguage(settings: settingsEN)
        XCTAssertEqual(languageEN.code, "EN")
        XCTAssertEqual(languageEN.nativeName, "English")
        
        // 测试默认值
        let settingsDefault = AppSettings(targetLanguage: "unsupported")
        let languageDefault = service.getCurrentTargetLanguage(settings: settingsDefault)
        XCTAssertEqual(languageDefault.code, "zh-CN") // 默认回退到简体中文
    }
    
    func testClearCache() throws {
        let paper = Paper(
            id: UUID(),
            arxivID: nil,
            arxivVersion: nil,
            doi: nil,
            title: "Test Paper",
            abstractText: "Test abstract",
            authors: [],
            categories: [],
            publishedAt: nil,
            updatedAt: nil,
            pdfURLString: nil,
            htmlURLString: nil,
            localDirectoryPath: "",
            tags: [],
            isFavorite: false,
            createdAt: Date(),
            modifiedAt: Date()
        )
        modelContext.insert(paper)
        
        // 创建一个翻译缓存
        let segment = TranslationSegment(
            paperID: paper.id,
            sourceType: "abstract",
            targetLanguage: "zh-CN",
            sourceHash: "testhash",
            sourceText: "Test abstract",
            translatedText: "测试摘要",
            providerProfileID: UUID(),
            modelProfileID: UUID(),
            modelName: "test-model"
        )
        modelContext.insert(segment)
        try modelContext.save()
        
        // 验证缓存存在
        let fetchRequest = FetchDescriptor<TranslationSegment>()
        let segments = try modelContext.fetch(fetchRequest)
        XCTAssertEqual(segments.count, 1)
        
        // 清除缓存
        try service.clearCache(for: paper, modelContext: modelContext)
        
        // 验证缓存已被清除
        let segmentsAfterClear = try modelContext.fetch(fetchRequest)
        XCTAssertEqual(segmentsAfterClear.count, 0)
    }
    
    func testClearCacheForLanguage() throws {
        let paper = Paper(
            id: UUID(),
            arxivID: nil,
            arxivVersion: nil,
            doi: nil,
            title: "Test Paper",
            abstractText: "Test abstract",
            authors: [],
            categories: [],
            publishedAt: nil,
            updatedAt: nil,
            pdfURLString: nil,
            htmlURLString: nil,
            localDirectoryPath: "",
            tags: [],
            isFavorite: false,
            createdAt: Date(),
            modifiedAt: Date()
        )
        modelContext.insert(paper)
        
        // 创建两个不同语言的翻译缓存
        let segment1 = TranslationSegment(
            paperID: paper.id,
            sourceType: "abstract",
            targetLanguage: "zh-CN",
            sourceHash: "testhash",
            sourceText: "Test abstract",
            translatedText: "测试摘要",
            providerProfileID: UUID(),
            modelProfileID: UUID(),
            modelName: "test-model"
        )
        
        let segment2 = TranslationSegment(
            paperID: paper.id,
            sourceType: "abstract",
            targetLanguage: "EN",
            sourceHash: "testhash",
            sourceText: "Test abstract",
            translatedText: "Test abstract in English",
            providerProfileID: UUID(),
            modelProfileID: UUID(),
            modelName: "test-model"
        )
        
        modelContext.insert(segment1)
        modelContext.insert(segment2)
        try modelContext.save()
        
        // 验证两个缓存都存在
        let fetchRequest = FetchDescriptor<TranslationSegment>()
        let segments = try modelContext.fetch(fetchRequest)
        XCTAssertEqual(segments.count, 2)
        
        // 清除特定语言的缓存
        try service.clearCacheForLanguage(
            paper: paper,
            targetLanguage: "zh-CN",
            modelContext: modelContext
        )
        
        // 验证只有特定语言的缓存被清除
        let segmentsAfterClear = try modelContext.fetch(fetchRequest)
        XCTAssertEqual(segmentsAfterClear.count, 1)
        XCTAssertEqual(segmentsAfterClear.first?.targetLanguage, "EN")
    }
}

// Mock translation client for testing
private final class MockTranslationClient: TranslationLLMClientProtocol {
    func translate(
        _ text: String,
        targetLanguage: String,
        route: LLMModelRouteSnapshot,
        apiKey: String
    ) async throws -> String {
        // 模拟翻译：简单地在文本前添加"Translated to [language]: "
        return "Translated to \(targetLanguage): \(text)"
    }
}