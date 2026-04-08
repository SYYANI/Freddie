import XCTest
@testable import ReadPaper

final class ArxivClientTests: XCTestCase {
    func testNormalizeModernIDURLAndVersion() throws {
        let identifier = try ArxivClient.normalizeIdentifier("https://arxiv.org/pdf/2303.08774v2.pdf")
        XCTAssertEqual(identifier.baseID, "2303.08774")
        XCTAssertEqual(identifier.version, "v2")
        XCTAssertEqual(identifier.queryID, "2303.08774v2")
    }

    func testNormalizeLegacyID() throws {
        let identifier = try ArxivClient.normalizeIdentifier("arXiv:hep-th/9901001v1")
        XCTAssertEqual(identifier.baseID, "hep-th/9901001")
        XCTAssertEqual(identifier.version, "v1")
    }

    func testParseAtomEntry() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <id>http://arxiv.org/abs/2303.08774v1</id>
            <updated>2023-03-15T00:00:00Z</updated>
            <published>2023-03-15T00:00:00Z</published>
            <title> Sparks of Artificial General Intelligence </title>
            <summary> A test summary. </summary>
            <author><name>Author One</name></author>
            <author><name>Author Two</name></author>
            <category term="cs.CL"/>
            <link href="http://arxiv.org/abs/2303.08774v1" rel="alternate" type="text/html"/>
            <link title="pdf" href="http://arxiv.org/pdf/2303.08774v1" rel="related" type="application/pdf"/>
          </entry>
        </feed>
        """
        let entries = try ArxivAtomParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].arxivID, "2303.08774")
        XCTAssertEqual(entries[0].arxivVersion, "v1")
        XCTAssertEqual(entries[0].title, "Sparks of Artificial General Intelligence")
        XCTAssertEqual(entries[0].authors, ["Author One", "Author Two"])
        XCTAssertEqual(entries[0].categories, ["cs.CL"])
        XCTAssertEqual(entries[0].pdfURL?.absoluteString, "http://arxiv.org/pdf/2303.08774v1")
    }
}
