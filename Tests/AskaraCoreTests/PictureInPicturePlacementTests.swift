import CoreGraphics
import Foundation
import Testing
@testable import AskaraCore

@Suite struct PictureInPicturePlacementTests {
    private let screen = CGRect(x: 0, y: 30, width: 1440, height: 870)
    private let size = CGSize(width: 379, height: 193)
    private let bleed = PictureInPicturePlacement.transparentMargin

    @Test func smallPointerTravelIsAClickNotADrag() {
        #expect(!PictureInPicturePlacement.isDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102, y: 101)))
        #expect(PictureInPicturePlacement.isDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 140, y: 100)))
    }

    @Test func windowKeepsTheGrabbedSpotUnderThePointer() {
        let origin = PictureInPicturePlacement.origin(pointer: CGPoint(x: 600, y: 350),
                                                      grabOffset: CGPoint(x: 40, y: 40), size: size, within: screen)
        #expect(origin == CGPoint(x: 560, y: 310))
    }

    @Test func pictureCanTouchEveryEdgeBecauseTheTransparentMarginMayLeaveTheScreen() {
        let topLeft = PictureInPicturePlacement.clamp(origin: CGPoint(x: -500, y: -500), size: size, within: screen)
        #expect(topLeft == CGPoint(x: -bleed.width, y: 30 - bleed.height))
        let bottomRight = PictureInPicturePlacement.clamp(origin: CGPoint(x: 5000, y: 5000), size: size, within: screen)
        #expect(bottomRight == CGPoint(x: 1440 - size.width + bleed.width, y: 900 - size.height + bleed.height))
    }

    @Test func withoutBleedTheWholeWindowStaysInside() {
        let corner = PictureInPicturePlacement.clamp(origin: CGPoint(x: 5000, y: 5000), size: size, within: screen,
                                                     bleed: .zero)
        #expect(corner == CGPoint(x: 1440 - size.width, y: 900 - size.height))
    }

    @Test func windowLargerThanTheScreenIsPinnedToItsTopLeft() {
        let huge = CGSize(width: 3000, height: 2000)
        #expect(PictureInPicturePlacement.clamp(origin: CGPoint(x: 50, y: 50), size: huge, within: screen)
                == CGPoint(x: -bleed.width, y: 30 - bleed.height))
    }

    @Test func settingDefaultsToOffAndOldFilesStillDecode() throws {
        #expect(!BrowserPreferences().pipFreePlacement)
        let old = try JSONDecoder().decode(BrowserPreferences.self, from: Data(#"{"httpsOnly":true}"#.utf8))
        #expect(!old.pipFreePlacement)
        var prefs = BrowserPreferences()
        prefs.pipFreePlacement = true
        let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.pipFreePlacement)
    }
}
