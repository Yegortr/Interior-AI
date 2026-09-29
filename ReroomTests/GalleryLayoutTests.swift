import SwiftData
import XCTest
@testable import Reroom

final class GalleryLayoutTests: XCTestCase {
    func testGridIsTwoEdgeToEdgeColumnsOfThreeByFour() {
        let frames = GalleryMetrics.frames(mode: .grid, width: 393, scale: 3, ratios: [0.75, 1.5, 0.5])
        XCTAssertEqual(frames[0].minX, 0)
        XCTAssertEqual(frames[1].maxX, 393, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frames[1].minX - frames[0].maxX, 2)
        XCTAssertEqual(frames[0].height / frames[0].width, 4.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(frames[1].size, frames[0].size)                   // ratios ignored in the grid
        XCTAssertEqual(frames[2].minY, frames[0].maxY + 2, accuracy: 0.001)
    }

    func testListUsesEachDesignsRatioWithInsets() {
        let frames = GalleryMetrics.frames(mode: .list, width: 393, scale: 3, ratios: [0.75, 16.0 / 9.0])
        XCTAssertEqual(frames[0].minX, 16)
        XCTAssertEqual(frames[0].width, 361)
        XCTAssertEqual(frames[0].height, 361 / 0.75, accuracy: 0.34)
        XCTAssertEqual(frames[1].height, 361 * 9 / 16, accuracy: 0.34)
        XCTAssertEqual(frames[1].minY, frames[0].maxY + 16, accuracy: 0.001)
    }

    func testAspectFillRequestCoversTheCell() {
        let id = UUID()
        // Landscape result in a portrait 3:4 grid cell: the height must be covered.
        let request = DesignImageRequest.aspectFill(designID: id, kind: .result, size: CGSize(width: 195, height: 260), scale: 3, imageAspect: 4.0 / 3.0)
        XCTAssertGreaterThanOrEqual(request.maxPixelSize, Int(260 * 3 * 4.0 / 3.0))
        XCTAssertEqual(request.maxPixelSize % 64, 0)
        XCTAssertEqual(request.key, "\(id.uuidString)-result-\(request.maxPixelSize)")
    }

    func testZoomAlignmentIsTheCellShapedCentreOfThePicture() {
        let hero = CGRect(x: 20, y: 100, width: 400, height: 300)      // a 4:3 picture
        let crop = hero.centeredCrop(aspect: 3.0 / 4.0)                // lined up with a 3:4 cell
        XCTAssertEqual(crop.height, 300, accuracy: 0.001)
        XCTAssertEqual(crop.width, 225, accuracy: 0.001)
        XCTAssertEqual(crop.midX, hero.midX, accuracy: 0.001)
        XCTAssertEqual(CGRect(x: 0, y: 0, width: 300, height: 400).centeredCrop(aspect: 0.75), CGRect(x: 0, y: 0, width: 300, height: 400))
        XCTAssertTrue(CGRect.null.centeredCrop(aspect: 0.75).isNull)
    }
}

@MainActor
final class GalleryFilterTests: XCTestCase {
    func testFiltersMatchTheOldPredicates() throws {
        let schema = Schema([Design.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let design = Design(roomType: .bedroom, style: .modern, notes: "", originalImageData: Data(), aspectRatio: .gridCard)
        container.mainContext.insert(design)
        design.isFavorite = true
        let room = DesignTileContent(design)
        XCTAssertTrue(GalleryFilter.all.includes(room))
        XCTAssertTrue(GalleryFilter.rooms.includes(room))
        XCTAssertFalse(GalleryFilter.gardens.includes(room))
        XCTAssertTrue(GalleryFilter.favorites.includes(room))

        design.kindRaw = DesignKind.garden.rawValue
        design.isFavorite = false
        let garden = DesignTileContent(design)
        XCTAssertFalse(GalleryFilter.rooms.includes(garden))
        XCTAssertTrue(GalleryFilter.gardens.includes(garden))
        XCTAssertFalse(GalleryFilter.favorites.includes(garden))
    }
}
