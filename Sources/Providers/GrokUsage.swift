import Foundation

/// Parses Grok Build's `GET /v1/billing?format=credits`.
///
/// The same call the Grok CLI makes. Shape observed live from
/// `cli-chat-proxy.grok.com` (2026-09-06), matching what the CLI logs as
/// "billing: fetched credits config":
///
/// ```json
/// { "config": {
///     "creditUsagePercent": 67.0,          // proto-JSON: omitted entirely when 0
///     "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
///                        "start": "2026-08-30T18:22:54.007137+00:00",
///                        "end":   "2026-09-06T18:22:54.007137+00:00" },
///     "onDemandCap": { "val": 0 },         // pay-as-you-go; 0/absent when disabled
///     "productUsage": [{ "product": "GrokBuild", "usagePercent": 67.0 }],
///     "isUnifiedBillingUser": true } }
/// ```
///
/// The response is a proto3 message serialized as JSON, so zero-valued fields
/// are dropped: an absent `creditUsagePercent` means 0, not a schema change.
/// Unknown fields (`productUsage`, prepaid balance, top-up method) are ignored.
enum GrokUsage {
    static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"

    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        guard let data = json.data(using: .utf8) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return try windows(from: data)
    }

    static func windows(from data: Data) throws -> [LimitWindow] {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let config = body["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let periodType = (period["type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !periodType.isEmpty,
              let start = GrokCredentials.date(period["start"] as? String),
              let end = GrokCredentials.date(period["end"] as? String),
              end > start
        else {
            throw UsageProviderError.badResponse(status: 0)
        }

        // proto-JSON omits zero values, so an absent percent is a genuine 0% —
        // but a present, non-numeric value is a schema change and must throw.
        let percent: Double
        if let raw = config["creditUsagePercent"] {
            guard let number = number(raw), number.isFinite else {
                throw UsageProviderError.badResponse(status: 0)
            }
            percent = number
        } else {
            percent = 0
        }

        var windows: [LimitWindow] = []
        if periodType == weeklyPeriodType {
            windows.append(LimitWindow(
                id: "weekly",
                label: "Weekly limit",
                usedFraction: percent / 100,
                resetsAt: end
            ))
        }

        // A missing cap means no pay-as-you-go (proto-JSON also drops a 0 cap).
        // Only a positive ceiling is worth a row — a "Disabled" badge is not a
        // meter, and Codenotch has nowhere to put one. A present non-object is
        // a schema change, not a disabled cap.
        if let cap = try onDemandValue(config["onDemandCap"]), cap > 0 {
            let used = try onDemandValue(config["onDemandUsed"]) ?? 0
            windows.append(LimitWindow(
                id: "on_demand",
                label: "Extra usage",
                usedFraction: used / cap,
                resetsAt: end
            ))
        }

        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered(
                "This Grok account has not migrated to weekly billing yet"
            )
        }
        return windows
    }

    static func planName(from data: Data) -> String? {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plan = (body["subscription_tier_display"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty
        else { return nil }
        return plan
    }

    /// `{ "val": 2500 }` — proto-JSON's wrapper for a numeric field that can
    /// be omitted at zero. A present non-object is drift and must throw.
    private static func onDemandValue(_ any: Any?) throws -> Double? {
        guard let any else { return nil }
        guard let object = any as? [String: Any],
              let cap = number(object["val"] ?? 0), cap.isFinite
        else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return cap
    }

    static func number(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return number.doubleValue }
        if let text = any as? String { return Double(text) }
        return nil
    }
}
