import Foundation

@main
struct StartingScreenResetChecks {
    static func main() {
        let departure = Date(timeIntervalSince1970: 1_000)
        var policy = StartingScreenResetPolicy()
        precondition(!policy.shouldResetOnReturn(afterMinutes: 5, at: departure))
        policy.enteredBackground(at: departure)
        precondition(!policy.shouldResetOnReturn(afterMinutes: 5, at: departure.addingTimeInterval(299)))
        policy.enteredBackground(at: departure)
        precondition(policy.shouldResetOnReturn(afterMinutes: 5, at: departure.addingTimeInterval(300)))
        precondition(!policy.shouldResetOnReturn(afterMinutes: 5, at: departure.addingTimeInterval(301)), "Only reset once per return")
        policy.enteredBackground(at: departure)
        precondition(!policy.shouldResetOnReturn(afterMinutes: 0, at: departure.addingTimeInterval(86_400)), "Never preserves the current screen")
        policy.enteredBackground(at: departure)
        policy.explicitNavigation()
        precondition(!policy.shouldResetOnReturn(afterMinutes: 5, at: departure.addingTimeInterval(600)), "Deep links before activation win")
        policy.enteredBackground(at: departure)
        precondition(policy.shouldResetOnReturn(afterMinutes: 1, at: departure.addingTimeInterval(60)), "Use the current preference")
        policy.enteredBackground(at: departure.addingTimeInterval(600))
        precondition(!policy.shouldResetOnReturn(afterMinutes: 5, at: departure.addingTimeInterval(610)), "A new quick switch gets a fresh interval")
        print("Starting screen reset checks passed")
    }
}
