import Foundation

struct FundResponse: Decodable {
    let ok: Bool
    let data: FundData?
    let error: String?
}

struct FundData: Decodable {
    let code: String
    let name: String
    let latest: LatestValue
    let forecast: Forecast
    let impact: Impact
    let buyView: BuyView
    let holdings: [Holding]
    let disclaimer: String
}

struct LatestValue: Decodable {
    let date: String
    let value: Double
}

struct Forecast: Decodable {
    let direction: String
    let probabilityUp: Double
    let expectedPct: Double
    let rangePct: [Double]
    let volatilityPct: Double
    let maxDrawdownPct: Double
}

struct Impact: Decodable {
    let label: String
    let topHoldingExposurePct: Double
    let todayContributionPct: Double
}

struct BuyView: Decodable {
    let stance: String
    let reason: String
    let riskLevel: String
}

struct Holding: Identifiable, Decodable {
    var id: String { code }
    let code: String
    let name: String
    let holdingPct: Double
    let changePct: Double?
    let industry: String
    let estimatedContributionPct: Double?
}

final class FundService {
    private let baseURL = URL(string: "http://127.0.0.1:8765")!

    func load(code: String) async throws -> FundData {
        let url = baseURL.appending(path: "/api/fund/\(code)")
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(FundResponse.self, from: data)
        if let fund = response.data {
            return fund
        }
        throw NSError(domain: "FundLens", code: 1, userInfo: [
            NSLocalizedDescriptionKey: response.error ?? "分析失败"
        ])
    }
}
