import CoreGraphics
import Foundation
import Testing

@testable import AmanuensisCore

struct RecorderPlacementTests {
    @Test func olderSettingsStillDecode() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "recorderPlacement")
        let oldSettings = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(AppSettings.self, from: oldSettings)
        #expect(restored.recorderPlacement == nil)
        #expect(restored.recorderStyle == .mini)
    }

    @Test func draggedPositionSurvivesSaving() throws {
        var settings = AppSettings()
        settings.recorderPlacement = RecorderPlacement(x: 0.3, y: 0.8, displayID: 42)
        let restored = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
    }

    @Test func resizingKeepsTheSelectedEdgeOnAnotherDisplay() {
        let bounds = CGRect(x: -1500, y: 100, width: 1400, height: 900)
        let position = RecorderPlacement(x: 1, y: 1)
        for size in [CGSize(width: 58, height: 16), CGSize(width: 250, height: 34)] {
            let frame = position.frame(size: size, in: bounds)
            #expect(frame.maxX == bounds.maxX)
            #expect(frame.maxY == bounds.maxY)
            #expect(bounds.contains(frame))
        }
    }

    @Test func draggingRoundTripsAndClampsOutsideScreen() {
        let bounds = CGRect(x: 100, y: 50, width: 1000, height: 700)
        let frame = CGRect(x: 400, y: 200, width: 120, height: 34)
        let position = RecorderPlacement(frame: frame, in: bounds, displayID: 7)
        #expect(position.frame(size: frame.size, in: bounds) == frame)

        let outside = RecorderPlacement(
            frame: CGRect(x: -200, y: 2000, width: 120, height: 34), in: bounds, displayID: 7)
        let clamped = outside.frame(size: frame.size, in: bounds)
        #expect(clamped.minX == bounds.minX)
        #expect(clamped.maxY == bounds.maxY)
    }

    @Test func smallerDisplayFitsOversizedControls() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 30)
        let frame = RecorderPlacement.bottom.frame(size: CGSize(width: 300, height: 80), in: bounds)
        #expect(frame == bounds)
        let position = RecorderPlacement(frame: frame, in: bounds, displayID: nil)
        #expect(position.x.isFinite && position.y.isFinite)
    }
}
