import Foundation
import Testing
@testable import BikeSpot_London

struct LiveActivityTokenRegistrationTests {
    @Test func successfulTokenRegistrationIsDeduplicatedButCanBeForced() {
        var tracker = LiveActivityTokenRegistrationTracker()
        let key = LiveActivityTokenRegistrationKey(
            activityId: "activity-1",
            pushToken: "token-1"
        )

        let beganInitialRegistration = tracker.begin(key)
        let beganDuplicateInFlightRegistration = tracker.begin(key)
        #expect(beganInitialRegistration)
        #expect(!beganDuplicateInFlightRegistration)
        tracker.finish(key, succeeded: true)
        let beganDuplicateCompletedRegistration = tracker.begin(key)
        let beganForcedRegistration = tracker.begin(key, force: true)
        #expect(!beganDuplicateCompletedRegistration)
        #expect(beganForcedRegistration)
    }

    @Test func failedTokenRegistrationCanRetry() {
        var tracker = LiveActivityTokenRegistrationTracker()
        let key = LiveActivityTokenRegistrationKey(
            activityId: "activity-1",
            pushToken: "token-1"
        )

        let beganInitialRegistration = tracker.begin(key)
        #expect(beganInitialRegistration)
        tracker.finish(key, succeeded: false)
        let beganRetry = tracker.begin(key)
        #expect(beganRetry)
    }

    @Test func removingActivityClearsItsRegistrationHistoryOnly() {
        var tracker = LiveActivityTokenRegistrationTracker()
        let first = LiveActivityTokenRegistrationKey(activityId: "activity-1", pushToken: "token-1")
        let second = LiveActivityTokenRegistrationKey(activityId: "activity-2", pushToken: "token-2")
        let beganFirstRegistration = tracker.begin(first)
        #expect(beganFirstRegistration)
        tracker.finish(first, succeeded: true)
        let beganSecondRegistration = tracker.begin(second)
        #expect(beganSecondRegistration)
        tracker.finish(second, succeeded: true)

        tracker.remove(activityId: first.activityId)

        let beganRemovedActivityAgain = tracker.begin(first)
        let beganRetainedActivityAgain = tracker.begin(second)
        #expect(beganRemovedActivityAgain)
        #expect(!beganRetainedActivityAgain)
    }

    @Test func legacyContentStateWithoutFreshnessTimestampStillDecodes() throws {
        let data = Data(
            #"{"standardBikes":5,"eBikes":0,"emptySpaces":10}"#.utf8
        )

        let state = try JSONDecoder().decode(DockActivityAttributes.ContentState.self, from: data)

        #expect(state.standardBikes == 5)
        #expect(state.alternatives.isEmpty)
        #expect(state.availabilityUpdatedAtEpochSeconds == nil)
    }
}
