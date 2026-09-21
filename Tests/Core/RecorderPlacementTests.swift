import CoreGraphics
import Foundation
import Testing

@testable import AmanuensisCore

struct RecorderPlacementTests {
    @Test func hoverExpansionKeepsTheSameCenterAtEveryPreset() {
        let bounds = CGRect(x: -1500, y: 80, width: 1400, height: 900)
        for preset in RecorderPlacement.presets {
            let idle = preset.frame(size: CGSize(width: 36, height: 6), in: bounds)
            for size in [
                CGSize(width: 72, height: 34), CGSize(width: 100, height: 34), CGSize(width: 171, height: 34),
            ] {
                let open = preset.frame(size: size, in: bounds)
                #expect(open.midX == idle.midX)
                #expect(open.midY == idle.midY)
                #expect(bounds.contains(open))
            }
        }
    }

    @Test func formerPanelStyleLoadsAsMini() throws {
        let style = try JSONDecoder().decode(RecorderStyle.self, from: Data("\"panel\"".utf8))
        #expect(style == .mini)
        #expect(RecorderStyle.allCases.map(\.rawValue) == ["mini", "notch", "hidden"])
    }

    @Test func everyScreenTargetCanBeReachedByDragging() {
        let bounds = CGRect(x: -1500, y: 80, width: 1400, height: 900)
        let size = CGSize(width: 72, height: 34)
        #expect(RecorderPlacement.presets.count == 17)
        for preset in RecorderPlacement.presets {
            let frame = preset.frame(size: size, in: bounds)
            let dropped = RecorderPlacement.nearestPreset(
                to: CGPoint(x: frame.midX + 5, y: frame.midY - 4), size: size, in: bounds, displayID: 42)
            #expect(dropped.x == preset.x && dropped.y == preset.y)
            #expect(dropped.displayID == 42)
        }
    }

    @Test func snappingUsesScreenDistanceAndHandlesOffscreenDrops() {
        let bounds = CGRect(x: 0, y: 0, width: 2000, height: 800)
        let size = CGSize(width: 72, height: 34)
        let outside = RecorderPlacement.nearestPreset(
            to: CGPoint(x: -100, y: 1000), size: size, in: bounds, displayID: nil)
        #expect(outside == RecorderPlacement(x: 0, y: 1))
        let middle = RecorderPlacement.nearestPreset(
            to: CGPoint(x: bounds.midX, y: bounds.midY), size: size, in: bounds, displayID: nil)
        #expect(middle == RecorderPlacement(x: 0.5, y: 0.5))
    }

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

    @Test func oversizedControlsStayOnAnotherDisplay() {
        let bounds = CGRect(x: -1500, y: 100, width: 1400, height: 900)
        let position = RecorderPlacement(x: 1, y: 1)
        for size in [CGSize(width: 36, height: 6), CGSize(width: 250, height: 34)] {
            let frame = position.frame(size: size, in: bounds)
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
        #expect(outside.x == 0 && outside.y == 1)
        #expect(bounds.contains(clamped))
    }

    @Test func smallerDisplayFitsOversizedControls() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 30)
        let frame = RecorderPlacement.bottom.frame(size: CGSize(width: 300, height: 80), in: bounds)
        #expect(frame == bounds)
        let position = RecorderPlacement(frame: frame, in: bounds, displayID: nil)
        #expect(position.x.isFinite && position.y.isFinite)
    }
}
