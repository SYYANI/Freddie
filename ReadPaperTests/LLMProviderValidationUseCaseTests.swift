import XCTest
@testable import ReadPaper

final class LLMProviderValidationUseCaseTests: XCTestCase {
    func testNormalizedBaseURLRemovesQueryFragmentAndTrailingSlash() throws {
        let validator = LLMProviderValidationUseCase()

        let normalized = try validator.normalizedBaseURL("https://api.example.com/proxy/v1/?foo=bar#frag")

        XCTAssertEqual(normalized, "https://api.example.com/proxy/v1")
    }

    func testNormalizedBaseURLRejectsUnsupportedScheme() {
        let validator = LLMProviderValidationUseCase()

        XCTAssertThrowsError(try validator.normalizedBaseURL("ftp://api.example.com/v1")) { error in
            XCTAssertEqual(error as? LLMProviderValidationError, .unsupportedBaseURLScheme)
        }
    }

    func testValidateModelNameRejectsEmptyValue() {
        let validator = LLMProviderValidationUseCase()

        XCTAssertThrowsError(try validator.validateModelName("   ")) { error in
            XCTAssertEqual(error as? LLMProviderValidationError, .emptyModel)
        }
    }

    func testTestConnectionRejectsEmptyAPIKeyBeforeRequest() async {
        let validator = LLMProviderValidationUseCase()

        do {
            _ = try await validator.testConnection(
                baseURL: "https://api.example.com/v1",
                apiKey: "   ",
                model: "test-model"
            )
            XCTFail("Expected empty API key validation to fail.")
        } catch {
            XCTAssertEqual(error as? LLMProviderValidationError, .emptyAPIKey)
        }
    }
}
