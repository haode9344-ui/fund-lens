import CoreData
import Foundation
import UserNotifications

let investmentDisclaimer = "以上分析仅供参考，不构成任何投资建议，基金投资有风险，入市需谨慎"

enum PredictionDirection: String, Codable, CaseIterable {
    case bullish = "偏多"
    case bearish = "偏空"
    case none = "不判断"
}

enum TailSignalKind: String, Codable {
    case volumeUp = "放量上涨"
    case volumeDown = "放量下跌"
    case invalid = "缩量无效"
    case failed = "数据失败"
}

struct FundAnalysis: Identifiable, Codable, Equatable {
    var id: String { code }
    let code: String
    let name: String
    let fundType: String
    let latestNav: Double
    let todayPct: Double
    let navDate: String
    let updateTime: String
    let targetIndexCode: String
    let targetIndexName: String
    let etfCode: String
    let etfName: String
    let holdings: [HoldingSignal]
    let indexSignal: TimedSignal
    let sectorEtfSignals: [TimedSignal]
    let filters: [FilterSignal]
    let indexScore: Double
    let holdingsScore: Double
    let sectorEtfScore: Double
    let rawScore: Double
    let initialDirection: PredictionDirection
    let finalDirection: PredictionDirection
    let confidence: String
    let updatedAt: Date
    let coreReasons: [String]
    let riskTips: [String]
    let errorMessage: String?

    var hasFreshFailure: Bool { errorMessage != nil }

    func failedCopy(_ message: String) -> FundAnalysis {
        FundAnalysis(
            code: code,
            name: name,
            fundType: fundType,
            latestNav: latestNav,
            todayPct: todayPct,
            navDate: navDate,
            updateTime: updateTime,
            targetIndexCode: targetIndexCode,
            targetIndexName: targetIndexName,
            etfCode: etfCode,
            etfName: etfName,
            holdings: holdings,
            indexSignal: indexSignal,
            sectorEtfSignals: sectorEtfSignals,
            filters: filters,
            indexScore: 0,
            holdingsScore: 0,
            sectorEtfScore: 0,
            rawScore: 0,
            initialDirection: .none,
            finalDirection: .none,
            confidence: "低",
            updatedAt: Date(),
            coreReasons: ["数据拉取失败，不能沿用旧数据判断。"],
            riskTips: [message],
            errorMessage: message
        )
    }
}

struct HoldingSignal: Identifiable, Codable, Equatable {
    var id: String { code }
    let code: String
    let name: String
    let industry: String
    let weightPct: Double
    let todayPct: Double?
    let volumeA: Double?
    let volumeBEquivalent: Double?
    let volumeRatio: Double?
    let signal: TailSignalKind
    let contribution: Double
}

struct TimedSignal: Identifiable, Codable, Equatable {
    var id: String { code }
    let code: String
    let name: String
    let todayPct: Double?
    let volumeA: Double?
    let volumeBEquivalent: Double?
    let volumeRatio: Double?
    let signal: TailSignalKind
    let contribution: Double
    let error: String?
}

struct FilterSignal: Identifiable, Codable, Equatable {
    var id: String { title }
    let title: String
    let value: String
    let status: String
    let downgraded: Bool
}

struct PredictionRecord: Identifiable, Codable, Equatable {
    var id: String { "\(fundCode)_\(date)" }
    let fundCode: String
    let date: String
    let predictedDirection: PredictionDirection
    let confidence: String
    let rawScore: Double
    let updatedAt: Date
    var actualPct: Double?
    var hit: Bool?
}

struct SavedFund: Identifiable, Equatable {
    var id: String { code }
    let code: String
    let name: String
    let fundType: String
    let latestNav: Double
    let todayPct: Double
    let targetIndexCode: String
    let targetIndexName: String
    let etfCode: String
    let etfName: String
    let lastPredictionDirection: PredictionDirection
    let confidence: String
    let updatedAt: Date
    let lastError: String?
}

struct FundEstimate {
    let code: String
    let name: String
    let latestNav: Double
    let todayPct: Double
    let navDate: String
    let updateTime: String
}

struct FundPosition {
    let etfCode: String
    let etfName: String
    let indexCode: String
    let indexName: String
    let holdings: [RawHolding]
}

struct RawHolding {
    let code: String
    let name: String
    let industry: String
    let weightPct: Double
}

struct EtfSnapshot {
    let code: String
    let changePct: Double?
    let premiumDiscountPct: Double?
}

struct TrendPoint {
    let minute: Int
    let price: Double
    let volume: Double
}

actor RequestRateLimiter {
    static let shared = RequestRateLimiter()
    private var hitsByKey: [String: [Date]] = [:]

    func wait(key: String) async {
        let now = Date()
        var hits = hitsByKey[key, default: []].filter { now.timeIntervalSince($0) < 60 }
        if hits.count >= 20, let first = hits.first {
            let delay = max(0.1, 60 - now.timeIntervalSince(first))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let after = Date()
            hits = hits.filter { after.timeIntervalSince($0) < 60 }
        }
        hits.append(Date())
        hitsByKey[key] = hits
    }
}

final class NetworkClient {
    func data(from url: URL, referer: String) async throws -> Data {
        let key = "\(url.host ?? "")\(url.path)"
        await RequestRateLimiter.shared.wait(key: key)
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 iPhone XiaoYou", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "XiaoYou.Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "接口请求失败：\(url.host ?? "")"])
        }
        return data
    }
}

final class AlipayFundService {
    private let client = NetworkClient()

    func load(code: String) async throws -> FundAnalysis {
        guard code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "XiaoYou", code: 100, userInfo: [NSLocalizedDescriptionKey: "基金代码必须是 6 位数字"])
        }
        let estimate = try await loadEstimate(code: code)
        let position = try await loadPosition(code: code)

        guard !position.indexCode.isEmpty else {
            throw NSError(domain: "XiaoYou", code: 101, userInfo: [NSLocalizedDescriptionKey: "没有拿到跟踪指数代码，本次不能判断"])
        }
        guard !position.holdings.isEmpty else {
            throw NSError(domain: "XiaoYou", code: 102, userInfo: [NSLocalizedDescriptionKey: "没有拿到前十大重仓股，本次不能判断"])
        }

        let etfSnapshot = try? await loadEtfSnapshot(code: position.etfCode)
        let indexSignal = await loadTimedSignal(
            code: position.indexCode,
            name: position.indexName.isEmpty ? position.indexCode : position.indexName,
            secid: indexSecid(position.indexCode),
            upScore: 60,
            downScore: -60
        )

        let holdingSignals = await withTaskGroup(of: HoldingSignal.self) { group in
            for holding in position.holdings.prefix(10) {
                group.addTask { await self.loadHoldingSignal(holding) }
            }
            var rows: [HoldingSignal] = []
            for await row in group { rows.append(row) }
            return rows.sorted { $0.weightPct > $1.weightPct }
        }

        let etfSignals = await withTaskGroup(of: TimedSignal.self) { group in
            for etf in sectorEtfCodes(primary: position.etfCode).prefix(3) {
                group.addTask {
                    await self.loadTimedSignal(
                        code: etf,
                        name: "ETF \(etf)",
                        secid: "\(marketPrefix(etf)).\(etf)",
                        upScore: 5,
                        downScore: -5
                    )
                }
            }
            var rows: [TimedSignal] = []
            for await row in group { rows.append(row) }
            return rows
        }

        let market = await loadMarketFilters()
        let us = await loadUSSummary()
        let northbound = await loadNorthboundSummary()

        let indexScore = indexSignal.contribution
        let holdingRaw = holdingSignals.reduce(0) { $0 + $1.contribution }
        let holdingsScore = holdingRaw * 0.4
        let sectorEtfScore = etfSignals.isEmpty ? 0 : etfSignals.reduce(0) { $0 + $1.contribution } / Double(etfSignals.count)
        let rawScore = indexScore + holdingsScore + sectorEtfScore

        let initialDirection: PredictionDirection
        if rawScore > 20 {
            initialDirection = .bullish
        } else if rawScore < -20 {
            initialDirection = .bearish
        } else {
            initialDirection = .none
        }

        let conflict = hasSignalConflict(indexScore: indexScore, holdingsScore: holdingsScore, etfScore: sectorEtfScore)
        var filters = buildFilters(
            initial: initialDirection,
            etfSnapshot: etfSnapshot,
            marketFilters: market,
            northbound: northbound,
            us: us
        )
        if conflict {
            filters.insert(FilterSignal(title: "信号冲突", value: "指数、重仓股、ETF联动方向不一致", status: "强制不判断", downgraded: true), at: 0)
        }

        let downgraded = filters.contains { $0.downgraded }
        let finalDirection: PredictionDirection = downgraded ? .none : initialDirection
        let confidence = confidenceText(
            direction: finalDirection,
            indexSignal: indexSignal,
            holdings: holdingSignals,
            conflict: conflict
        )
        let coreReasons = coreReasons(
            direction: finalDirection,
            indexSignal: indexSignal,
            holdings: holdingSignals,
            etfs: etfSignals,
            downgraded: filters.first { $0.downgraded }
        )
        let risks = riskTips(confidence: confidence, filters: filters, holdings: holdingSignals, rawScore: rawScore)

        let analysis = FundAnalysis(
            code: code,
            name: estimate.name,
            fundType: inferFundType(name: estimate.name),
            latestNav: estimate.latestNav,
            todayPct: estimate.todayPct,
            navDate: estimate.navDate,
            updateTime: estimate.updateTime,
            targetIndexCode: position.indexCode,
            targetIndexName: position.indexName,
            etfCode: position.etfCode,
            etfName: position.etfName,
            holdings: holdingSignals,
            indexSignal: indexSignal,
            sectorEtfSignals: etfSignals,
            filters: filters,
            indexScore: indexScore,
            holdingsScore: holdingsScore,
            sectorEtfScore: sectorEtfScore,
            rawScore: rawScore,
            initialDirection: initialDirection,
            finalDirection: finalDirection,
            confidence: confidence,
            updatedAt: Date(),
            coreReasons: coreReasons,
            riskTips: risks,
            errorMessage: nil
        )
        try CoreDataStore.shared.save(analysis: analysis)
        try CoreDataStore.shared.savePrediction(analysis: analysis)
        return analysis
    }

    func loadUSSummary() async -> String {
        async let ndx = loadQuoteSummary(secid: "100.NDX", name: "纳斯达克")
        async let spx = loadQuoteSummary(secid: "100.SPX", name: "标普500")
        let ndxValue = await ndx
        let spxValue = await spx
        let rows = [ndxValue, spxValue]
        return rows.filter { !$0.isEmpty }.joined(separator: "；")
    }

    private func loadEstimate(code: String) async throws -> FundEstimate {
        let url = URL(string: "http://fundgz.1234567.com.cn/js/\(code).js?rt=\(Int(Date().timeIntervalSince1970 * 1000))")!
        let data = try await client.data(from: url, referer: "http://fund.eastmoney.com/")
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw NSError(domain: "XiaoYou", code: 201, userInfo: [NSLocalizedDescriptionKey: "基金估值接口解析失败"])
        }
        let jsonText = String(text[start...end])
        guard let jsonData = jsonText.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw NSError(domain: "XiaoYou", code: 202, userInfo: [NSLocalizedDescriptionKey: "基金估值接口返回异常"])
        }
        return FundEstimate(
            code: code,
            name: string(json["name"]) ?? "基金 \(code)",
            latestNav: double(json["gsz"]) ?? double(json["dwjz"]) ?? 0,
            todayPct: double(json["gszzl"]) ?? 0,
            navDate: string(json["jzrq"]) ?? "",
            updateTime: string(json["gztime"]) ?? ""
        )
    }

    private func loadPosition(code: String, allowEtfLookup: Bool = true) async throws -> FundPosition {
        let url = URL(string: "https://fundmobapi.eastmoney.com/FundMNewApi/FundMNInverstPosition?FCODE=\(code)&deviceid=xxx&version=6.3.8&product=EFund&plat=Iphone")!
        let data = try await client.data(from: url, referer: "https://fundmobapi.eastmoney.com/")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let datas = root["Datas"] as? [String: Any] else {
            throw NSError(domain: "XiaoYou", code: 301, userInfo: [NSLocalizedDescriptionKey: "基金重仓股接口解析失败"])
        }
        let etfCode = string(datas["ETFCODE"]) ?? ""
        let etfName = string(datas["ETFSHORTNAME"]) ?? ""
        let stocks = (datas["fundStocks"] as? [[String: Any]] ?? []).compactMap { row -> RawHolding? in
            guard let code = string(row["GPDM"]), let name = string(row["GPJC"]) else { return nil }
            let weight = double(row["JZBL"]) ?? 0
            guard weight > 0 else { return nil }
            return RawHolding(code: code, name: name, industry: string(row["INDEXNAME"]) ?? "", weightPct: weight)
        }

        if stocks.isEmpty, allowEtfLookup, !etfCode.isEmpty, etfCode != code {
            let target = try await loadPosition(code: etfCode, allowEtfLookup: false)
            let known = knownIndex(forETF: etfCode)
            return FundPosition(
                etfCode: etfCode,
                etfName: etfName,
                indexCode: known?.code ?? target.indexCode,
                indexName: known?.name ?? target.indexName,
                holdings: target.holdings
            )
        }

        let known = knownIndex(forETF: code) ?? knownIndex(forETF: etfCode)
        return FundPosition(
            etfCode: etfCode,
            etfName: etfName,
            indexCode: known?.code ?? "",
            indexName: known?.name ?? "",
            holdings: stocks
        )
    }

    private func loadEtfSnapshot(code: String) async throws -> EtfSnapshot {
        guard !code.isEmpty else { throw NSError(domain: "XiaoYou", code: 401, userInfo: [NSLocalizedDescriptionKey: "没有关联 ETF 代码"]) }
        let url = URL(string: "https://push2.eastmoney.com/api/qt/stock/get?secid=\(marketPrefix(code)).\(code)&fields=f43,f116,f117,f170&rt=\(Int(Date().timeIntervalSince1970 * 1000))")!
        let data = try await client.data(from: url, referer: "https://quote.eastmoney.com/")
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let quote = (payload?["data"] as? [String: Any]) ?? [:]
        let premium = await loadEtfPremium(code: code)
        return EtfSnapshot(
            code: code,
            changePct: normalizePct(double(quote["f170"])),
            premiumDiscountPct: premium
        )
    }

    private func loadEtfPremium(code: String) async -> Double? {
        let url = URL(string: "https://datacenter.eastmoney.com/stock/fundselector/api/data/get?type=RPTA_APP_FUNDSELECT&sty=SECURITY_CODE,PREMIUM_DISCOUNT_RATIO&source=FUND_SELECTOR&client=APP&filter=(SECURITY_CODE%3D%22\(code)%22)&p=1&ps=1&isIndexFilter=1")!
        do {
            let data = try await client.data(from: url, referer: "https://datacenter.eastmoney.com/")
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let result = (payload?["result"] as? [String: Any]) ?? [:]
            let rows = result["data"] as? [[String: Any]]
            return rows?.first.flatMap { double($0["PREMIUM_DISCOUNT_RATIO"]) }
        } catch {
            return nil
        }
    }

    private func loadHoldingSignal(_ holding: RawHolding) async -> HoldingSignal {
        let signal = await loadTimedSignal(
            code: holding.code,
            name: holding.name,
            secid: "\(marketPrefix(holding.code)).\(holding.code)",
            upScore: holding.weightPct,
            downScore: -holding.weightPct
        )
        return HoldingSignal(
            code: holding.code,
            name: holding.name,
            industry: holding.industry,
            weightPct: holding.weightPct,
            todayPct: signal.todayPct,
            volumeA: signal.volumeA,
            volumeBEquivalent: signal.volumeBEquivalent,
            volumeRatio: signal.volumeRatio,
            signal: signal.signal,
            contribution: signal.contribution
        )
    }

    private func loadTimedSignal(code: String, name: String, secid: String?, upScore: Double, downScore: Double) async -> TimedSignal {
        guard let secid else {
            return TimedSignal(code: code, name: name, todayPct: nil, volumeA: nil, volumeBEquivalent: nil, volumeRatio: nil, signal: .failed, contribution: 0, error: "指数代码缺失")
        }
        let url = URL(string: "https://push2.eastmoney.com/api/qt/stock/trends2/get?secid=\(secid)&fields1=f1,f2,f3,f4&fields2=f51,f52,f53,f54,f55,f56,f57,f58&rt=\(Int(Date().timeIntervalSince1970 * 1000))")!
        do {
            let data = try await client.data(from: url, referer: "https://quote.eastmoney.com/")
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let payloadData = (payload?["data"] as? [String: Any]) ?? [:]
            let trends = payloadData["trends"] as? [String] ?? []
            let points = trends.compactMap(parseTrendPoint)
            let windowA = points.filter { $0.minute >= 14 * 60 + 40 && $0.minute < 14 * 60 + 50 }
            let windowB = points.filter { $0.minute >= 14 * 60 + 50 && $0.minute <= 14 * 60 + 58 }
            guard !windowA.isEmpty, windowB.count >= 2 else {
                return TimedSignal(code: code, name: name, todayPct: nil, volumeA: nil, volumeBEquivalent: nil, volumeRatio: nil, signal: .failed, contribution: 0, error: "14:40-14:58 分钟数据不足")
            }
            let volumeA = windowA.reduce(0) { $0 + $1.volume }
            let volumeB = windowB.reduce(0) { $0 + $1.volume } * 1.25
            guard volumeA > 0 else {
                return TimedSignal(code: code, name: name, todayPct: nil, volumeA: volumeA, volumeBEquivalent: volumeB, volumeRatio: nil, signal: .invalid, contribution: 0, error: "区间A成交量为0")
            }
            let ratio = volumeB / volumeA
            let delta = (windowB.last!.price / max(windowB.first!.price, 0.0001) - 1) * 100
            guard ratio >= 1.5 else {
                return TimedSignal(code: code, name: name, todayPct: delta, volumeA: volumeA, volumeBEquivalent: volumeB, volumeRatio: ratio, signal: .invalid, contribution: 0, error: nil)
            }
            if delta > 0 {
                return TimedSignal(code: code, name: name, todayPct: delta, volumeA: volumeA, volumeBEquivalent: volumeB, volumeRatio: ratio, signal: .volumeUp, contribution: upScore, error: nil)
            }
            if delta < 0 {
                return TimedSignal(code: code, name: name, todayPct: delta, volumeA: volumeA, volumeBEquivalent: volumeB, volumeRatio: ratio, signal: .volumeDown, contribution: downScore, error: nil)
            }
            return TimedSignal(code: code, name: name, todayPct: delta, volumeA: volumeA, volumeBEquivalent: volumeB, volumeRatio: ratio, signal: .invalid, contribution: 0, error: nil)
        } catch {
            return TimedSignal(code: code, name: name, todayPct: nil, volumeA: nil, volumeBEquivalent: nil, volumeRatio: nil, signal: .failed, contribution: 0, error: error.localizedDescription)
        }
    }

    private func loadMarketFilters() async -> [FilterSignal] {
        let hs300 = await loadQuoteSummary(secid: "1.000300", name: "沪深300")
        let chinext = await loadQuoteSummary(secid: "0.399006", name: "创业板")
        return [
            FilterSignal(title: "沪深300", value: hs300.isEmpty ? "接口拉取失败" : hs300, status: "仅辅助过滤", downgraded: false),
            FilterSignal(title: "创业板", value: chinext.isEmpty ? "接口拉取失败" : chinext, status: "仅辅助过滤", downgraded: false)
        ]
    }

    private func loadQuoteSummary(secid: String, name: String) async -> String {
        let url = URL(string: "https://push2.eastmoney.com/api/qt/stock/get?secid=\(secid)&fields=f43,f170,f171&rt=\(Int(Date().timeIntervalSince1970 * 1000))")!
        do {
            let data = try await client.data(from: url, referer: "https://quote.eastmoney.com/")
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let quote = (payload?["data"] as? [String: Any]) ?? [:]
            guard let change = normalizePct(double(quote["f170"])) else { return "" }
            return "\(name) \(signedPct(change))"
        } catch {
            return ""
        }
    }

    private func loadNorthboundSummary() async -> String {
        let url = URL(string: "https://push2.eastmoney.com/api/qt/kamt.rtmin/get?fields1=f1,f2,f3&fields2=f51,f52,f53,f54,f55&rt=\(Int(Date().timeIntervalSince1970 * 1000))")!
        do {
            let data = try await client.data(from: url, referer: "https://quote.eastmoney.com/")
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let body = (payload?["data"] as? [String: Any]) ?? [:]
            let rows = body["s2n"] as? [String] ?? []
            guard let last = rows.last else { return "" }
            return "北向资金 \(last)"
        } catch {
            return ""
        }
    }

    private func buildFilters(initial: PredictionDirection, etfSnapshot: EtfSnapshot?, marketFilters: [FilterSignal], northbound: String, us: String) -> [FilterSignal] {
        let premium = etfSnapshot?.premiumDiscountPct
        let etfDowngrade = initial == .bullish && premium != nil && premium! >= 1
        var filters = [
            FilterSignal(title: "ETF折溢价", value: premium.map(signedPct) ?? "接口拉取失败", status: etfDowngrade ? "溢价偏高，偏多降级" : "通过", downgraded: etfDowngrade),
            FilterSignal(title: "北向资金", value: northbound.isEmpty ? "接口拉取失败" : northbound, status: "仅辅助过滤", downgraded: false)
        ]
        filters.append(contentsOf: marketFilters)
        filters.append(FilterSignal(title: "美股昨夜", value: us.isEmpty ? "接口拉取失败" : us, status: "次日9:15验证", downgraded: false))
        return filters
    }

    private func hasSignalConflict(indexScore: Double, holdingsScore: Double, etfScore: Double) -> Bool {
        let scores = [indexScore, holdingsScore, etfScore].filter { abs($0) >= 5 }
        return scores.contains { $0 > 0 } && scores.contains { $0 < 0 }
    }

    private func confidenceText(direction: PredictionDirection, indexSignal: TimedSignal, holdings: [HoldingSignal], conflict: Bool) -> String {
        guard direction != .none, !conflict else { return "低" }
        let activeWeight = holdings.filter { $0.signal == .volumeUp || $0.signal == .volumeDown }.reduce(0) { $0 + $1.weightPct }
        if indexSignal.signal != .failed, activeWeight >= 30 { return "高" }
        if indexSignal.signal != .failed || activeWeight >= 15 { return "中" }
        return "低"
    }

    private func coreReasons(direction: PredictionDirection, indexSignal: TimedSignal, holdings: [HoldingSignal], etfs: [TimedSignal], downgraded: FilterSignal?) -> [String] {
        if direction == .none {
            if let downgraded { return ["\(downgraded.title)触发：\(downgraded.status)", "信号不够一致，本次不强行给方向"] }
            return ["指数、重仓股或ETF联动没有形成一致方向", "不使用旧数据，不强行判断"]
        }
        var rows: [String] = []
        rows.append("跟踪指数尾盘\(indexSignal.signal.rawValue)，贡献 \(formatNumber(indexSignal.contribution)) 分")
        let active = holdings.filter { $0.contribution != 0 }.sorted { abs($0.contribution) > abs($1.contribution) }.prefix(3)
        if !active.isEmpty {
            rows.append("重仓股按占比加权，主要来自 \(active.map { "\($0.name)\($0.signal.rawValue)" }.joined(separator: "、"))")
        }
        let activeEtf = etfs.filter { $0.contribution != 0 }
        if !activeEtf.isEmpty { rows.append("同板块ETF尾盘给出联动确认") }
        return Array(rows.prefix(3))
    }

    private func riskTips(confidence: String, filters: [FilterSignal], holdings: [HoldingSignal], rawScore: Double) -> [String] {
        var rows: [String] = []
        if confidence != "高" { rows.append("置信度为\(confidence)，说明关键真实数据没有完全同向") }
        let failedCount = holdings.filter { $0.signal == .failed }.count
        if failedCount > 0 { rows.append("\(failedCount)只重仓股尾盘数据拉取失败，已按0分处理") }
        if abs(rawScore) <= 20 { rows.append("原始总分在 -20 到 +20，属于不强行判断区间") }
        if let degraded = filters.first(where: { $0.downgraded }) { rows.append("\(degraded.title)：\(degraded.status)") }
        return Array(rows.prefix(2))
    }
}

final class CoreDataStore {
    static let shared = CoreDataStore()
    let container: NSPersistentContainer

    var context: NSManagedObjectContext { container.viewContext }

    private init() {
        container = NSPersistentContainer(name: "FundLensStore", managedObjectModel: Self.model())
        container.loadPersistentStores { _, error in
            if let error { fatalError("CoreData load failed: \(error)") }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    private static func model() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = [
            entity("FundEntity", [
                attr("code", .stringAttributeType),
                attr("name", .stringAttributeType),
                attr("fundType", .stringAttributeType),
                attr("latestNav", .doubleAttributeType),
                attr("todayPct", .doubleAttributeType),
                attr("targetIndexCode", .stringAttributeType),
                attr("targetIndexName", .stringAttributeType),
                attr("etfCode", .stringAttributeType),
                attr("etfName", .stringAttributeType),
                attr("lastPredictionDirection", .stringAttributeType),
                attr("confidence", .stringAttributeType),
                attr("updatedAt", .dateAttributeType),
                attr("lastError", .stringAttributeType, optional: true)
            ]),
            entity("HoldingEntity", [
                attr("id", .stringAttributeType),
                attr("fundCode", .stringAttributeType),
                attr("code", .stringAttributeType),
                attr("name", .stringAttributeType),
                attr("industry", .stringAttributeType),
                attr("weightPct", .doubleAttributeType)
            ]),
            entity("PredictionRecordEntity", [
                attr("id", .stringAttributeType),
                attr("fundCode", .stringAttributeType),
                attr("date", .stringAttributeType),
                attr("predictedDirection", .stringAttributeType),
                attr("confidence", .stringAttributeType),
                attr("rawScore", .doubleAttributeType),
                attr("updatedAt", .dateAttributeType),
                attr("hasActual", .booleanAttributeType),
                attr("actualPct", .doubleAttributeType),
                attr("hit", .booleanAttributeType)
            ])
        ]
        return model
    }

    private static func entity(_ name: String, _ attributes: [NSAttributeDescription]) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = "NSManagedObject"
        entity.properties = attributes
        return entity
    }

    private static func attr(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
        let attr = NSAttributeDescription()
        attr.name = name
        attr.attributeType = type
        attr.isOptional = optional
        return attr
    }

    func fetchFunds() throws -> [SavedFund] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FundEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return try context.fetch(request).map {
            SavedFund(
                code: $0.value(forKey: "code") as? String ?? "",
                name: $0.value(forKey: "name") as? String ?? "",
                fundType: $0.value(forKey: "fundType") as? String ?? "",
                latestNav: $0.value(forKey: "latestNav") as? Double ?? 0,
                todayPct: $0.value(forKey: "todayPct") as? Double ?? 0,
                targetIndexCode: $0.value(forKey: "targetIndexCode") as? String ?? "",
                targetIndexName: $0.value(forKey: "targetIndexName") as? String ?? "",
                etfCode: $0.value(forKey: "etfCode") as? String ?? "",
                etfName: $0.value(forKey: "etfName") as? String ?? "",
                lastPredictionDirection: PredictionDirection(rawValue: $0.value(forKey: "lastPredictionDirection") as? String ?? "") ?? .none,
                confidence: $0.value(forKey: "confidence") as? String ?? "低",
                updatedAt: $0.value(forKey: "updatedAt") as? Date ?? .distantPast,
                lastError: $0.value(forKey: "lastError") as? String
            )
        }
    }

    func save(analysis: FundAnalysis) throws {
        let object = try fundObject(code: analysis.code) ?? NSEntityDescription.insertNewObject(forEntityName: "FundEntity", into: context)
        object.setValue(analysis.code, forKey: "code")
        object.setValue(analysis.name, forKey: "name")
        object.setValue(analysis.fundType, forKey: "fundType")
        object.setValue(analysis.latestNav, forKey: "latestNav")
        object.setValue(analysis.todayPct, forKey: "todayPct")
        object.setValue(analysis.targetIndexCode, forKey: "targetIndexCode")
        object.setValue(analysis.targetIndexName, forKey: "targetIndexName")
        object.setValue(analysis.etfCode, forKey: "etfCode")
        object.setValue(analysis.etfName, forKey: "etfName")
        object.setValue(analysis.finalDirection.rawValue, forKey: "lastPredictionDirection")
        object.setValue(analysis.confidence, forKey: "confidence")
        object.setValue(analysis.updatedAt, forKey: "updatedAt")
        object.setValue(analysis.errorMessage, forKey: "lastError")

        let old = NSFetchRequest<NSManagedObject>(entityName: "HoldingEntity")
        old.predicate = NSPredicate(format: "fundCode == %@", analysis.code)
        for row in try context.fetch(old) { context.delete(row) }
        for holding in analysis.holdings {
            let row = NSEntityDescription.insertNewObject(forEntityName: "HoldingEntity", into: context)
            row.setValue("\(analysis.code)_\(holding.code)", forKey: "id")
            row.setValue(analysis.code, forKey: "fundCode")
            row.setValue(holding.code, forKey: "code")
            row.setValue(holding.name, forKey: "name")
            row.setValue(holding.industry, forKey: "industry")
            row.setValue(holding.weightPct, forKey: "weightPct")
        }
        try context.save()
    }

    func deleteFund(code: String) throws {
        for entity in ["FundEntity", "HoldingEntity", "PredictionRecordEntity"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = entity == "FundEntity" ? NSPredicate(format: "code == %@", code) : NSPredicate(format: "fundCode == %@", code)
            for object in try context.fetch(request) { context.delete(object) }
        }
        try context.save()
    }

    func markFundFailure(code: String, message: String) throws {
        let object = try fundObject(code: code) ?? NSEntityDescription.insertNewObject(forEntityName: "FundEntity", into: context)
        object.setValue(code, forKey: "code")
        object.setValue(object.value(forKey: "name") as? String ?? "基金 \(code)", forKey: "name")
        object.setValue(object.value(forKey: "fundType") as? String ?? "类型待确认", forKey: "fundType")
        object.setValue(object.value(forKey: "latestNav") as? Double ?? 0, forKey: "latestNav")
        object.setValue(object.value(forKey: "todayPct") as? Double ?? 0, forKey: "todayPct")
        object.setValue(object.value(forKey: "targetIndexCode") as? String ?? "", forKey: "targetIndexCode")
        object.setValue(object.value(forKey: "targetIndexName") as? String ?? "", forKey: "targetIndexName")
        object.setValue(object.value(forKey: "etfCode") as? String ?? "", forKey: "etfCode")
        object.setValue(object.value(forKey: "etfName") as? String ?? "", forKey: "etfName")
        object.setValue(PredictionDirection.none.rawValue, forKey: "lastPredictionDirection")
        object.setValue("低", forKey: "confidence")
        object.setValue(Date(), forKey: "updatedAt")
        object.setValue(message, forKey: "lastError")
        try context.save()
    }

    func savePrediction(analysis: FundAnalysis) throws {
        let date = dateText(Date())
        let id = "\(analysis.code)_\(date)"
        let object = try predictionObject(id: id) ?? NSEntityDescription.insertNewObject(forEntityName: "PredictionRecordEntity", into: context)
        let hasActual = object.value(forKey: "hasActual") as? Bool ?? false
        let actualPct = object.value(forKey: "actualPct") as? Double ?? 0
        let hit = object.value(forKey: "hit") as? Bool ?? false
        object.setValue(id, forKey: "id")
        object.setValue(analysis.code, forKey: "fundCode")
        object.setValue(date, forKey: "date")
        object.setValue(analysis.finalDirection.rawValue, forKey: "predictedDirection")
        object.setValue(analysis.confidence, forKey: "confidence")
        object.setValue(analysis.rawScore, forKey: "rawScore")
        object.setValue(analysis.updatedAt, forKey: "updatedAt")
        object.setValue(hasActual, forKey: "hasActual")
        object.setValue(actualPct, forKey: "actualPct")
        object.setValue(hit, forKey: "hit")
        try context.save()
    }

    func fetchPredictions(code: String) throws -> [PredictionRecord] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "PredictionRecordEntity")
        request.predicate = NSPredicate(format: "fundCode == %@", code)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return try context.fetch(request).map {
            let hasActual = $0.value(forKey: "hasActual") as? Bool ?? false
            return PredictionRecord(
                fundCode: code,
                date: $0.value(forKey: "date") as? String ?? "",
                predictedDirection: PredictionDirection(rawValue: $0.value(forKey: "predictedDirection") as? String ?? "") ?? .none,
                confidence: $0.value(forKey: "confidence") as? String ?? "低",
                rawScore: $0.value(forKey: "rawScore") as? Double ?? 0,
                updatedAt: $0.value(forKey: "updatedAt") as? Date ?? .distantPast,
                actualPct: hasActual ? ($0.value(forKey: "actualPct") as? Double ?? 0) : nil,
                hit: hasActual ? ($0.value(forKey: "hit") as? Bool ?? false) : nil
            )
        }
    }

    func updateActual(fundCode: String, date: String, actualPct: Double) throws {
        let id = "\(fundCode)_\(date)"
        guard let object = try predictionObject(id: id) else { return }
        let predicted = PredictionDirection(rawValue: object.value(forKey: "predictedDirection") as? String ?? "") ?? .none
        let actualDirection: PredictionDirection = actualPct > 0 ? .bullish : actualPct < 0 ? .bearish : .none
        object.setValue(true, forKey: "hasActual")
        object.setValue(actualPct, forKey: "actualPct")
        object.setValue(predicted == actualDirection, forKey: "hit")
        try context.save()
    }

    private func fundObject(code: String) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FundEntity")
        request.predicate = NSPredicate(format: "code == %@", code)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func predictionObject(id: String) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "PredictionRecordEntity")
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}

final class NotificationService {
    static let shared = NotificationService()

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func scheduleTradingReminders() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: (0..<40).flatMap { ["close_\($0)", "us_\($0)"] })
        var count = 0
        for offset in 0..<90 where count < 20 {
            let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(offset) * 86400)
            guard isChinaATradingDay(day) else { continue }
            if let close = Calendar.current.date(bySettingHour: 14, minute: 55, second: 0, of: day), close > Date() {
                schedule(id: "close_\(count)", date: close, title: "小又 14:55 提醒", body: "⏰ 距收盘还有5分钟，即将生成明日预判，请注意查看")
            }
            if let us = Calendar.current.date(bySettingHour: 9, minute: 15, second: 0, of: day), us > Date() {
                schedule(id: "us_\(count)", date: us, title: "小又 9:15 美股验证", body: "🌏 开盘前检查美股昨夜表现和基金预判风险")
            }
            count += 1
        }
    }

    func notifyCloseReminder() {
        notify(id: "close_now", title: "小又 14:55 提醒", body: "⏰ 距收盘还有5分钟，即将生成明日预判，请注意查看")
    }

    func notifyPrediction(_ analysis: FundAnalysis) {
        notify(
            id: "prediction_\(analysis.code)_\(dateText(Date()))",
            title: "\(analysis.name) 明日预判：\(analysis.finalDirection.rawValue)",
            body: "置信度：\(analysis.confidence)\n核心依据：\(analysis.coreReasons.prefix(2).joined(separator: "+"))"
        )
    }

    func notifyFailure(code: String, error: String) {
        notify(
            id: "failure_\(code)_\(dateText(Date()))",
            title: "基金 \(code) 数据拉取失败",
            body: "\(error)\n本次不使用旧数据判断。"
        )
    }

    func notifyUSValidation(fund: SavedFund, usSummary: String) {
        let body: String
        if fund.lastPredictionDirection == .bullish, usSummary.contains("-") {
            body = "🌏 \(usSummary)\n\(fund.name)：请注意风险"
        } else {
            body = "🌏 \(usSummary)\n\(fund.name)：预判维持\(fund.lastPredictionDirection.rawValue)"
        }
        notify(id: "us_\(fund.code)_\(dateText(Date()))", title: "美股验证", body: body)
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func schedule(id: String, date: Date, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }
}

struct KnownIndex {
    let code: String
    let name: String
}

func knownIndex(forETF code: String) -> KnownIndex? {
    [
        "159796": KnownIndex(code: "H30319", name: "中证电池指数"),
        "159755": KnownIndex(code: "H30319", name: "中证电池指数"),
        "159767": KnownIndex(code: "H30319", name: "中证电池指数"),
        "159840": KnownIndex(code: "H30319", name: "中证电池指数"),
        "510300": KnownIndex(code: "000300", name: "沪深300"),
        "510500": KnownIndex(code: "000905", name: "中证500"),
        "159915": KnownIndex(code: "399006", name: "创业板指"),
        "588000": KnownIndex(code: "000688", name: "科创50")
    ][code]
}

func sectorEtfCodes(primary: String) -> [String] {
    [
        "159796": ["159796", "159755", "159767"],
        "159755": ["159755", "159796", "159767"],
        "159767": ["159767", "159796", "159755"],
        "159840": ["159840", "159796", "159755"],
        "510300": ["510300"],
        "510500": ["510500"],
        "159915": ["159915"],
        "588000": ["588000"]
    ][primary] ?? (primary.isEmpty ? [] : [primary])
}

func indexSecid(_ code: String) -> String? {
    guard !code.isEmpty else { return nil }
    if code.first?.isLetter == true { return "1.\(code)" }
    if code.hasPrefix("399") { return "0.\(code)" }
    if code.hasPrefix("0") || code.hasPrefix("H") { return "1.\(code)" }
    return "\(marketPrefix(code)).\(code)"
}

func marketPrefix(_ code: String) -> String {
    code.hasPrefix("6") || code.hasPrefix("5") || code.hasPrefix("9") ? "1" : "0"
}

func inferFundType(name: String) -> String {
    if name.contains("债") { return "债券型" }
    if name.contains("指数") || name.uppercased().contains("ETF") || name.contains("联接") || name.uppercased().contains("LOF") { return "指数型" }
    if name.contains("混合") { return "混合型" }
    if name.contains("股票") { return "股票型" }
    return "类型待确认"
}

func parseTrendPoint(_ row: String) -> TrendPoint? {
    let parts = row.split(separator: ",").map(String.init)
    guard parts.count >= 6, let minute = minuteOfDay(parts[0]) else { return nil }
    let price = double(parts[safe: 2]) ?? double(parts[safe: 1])
    let volume = double(parts[safe: 5]) ?? double(parts[safe: 4])
    guard let price, let volume, price > 0 else { return nil }
    return TrendPoint(minute: minute, price: price, volume: volume)
}

func minuteOfDay(_ value: String) -> Int? {
    let time = value.split(separator: " ").last.map(String.init) ?? value
    let parts = time.split(separator: ":").compactMap { Int($0) }
    guard parts.count >= 2 else { return nil }
    return parts[0] * 60 + parts[1]
}

func normalizePct(_ value: Double?) -> Double? {
    guard let value, abs(value) < 900_000_000 else { return nil }
    return value / 100
}

func string(_ value: Any?) -> String? {
    if let value = value as? String, !value.isEmpty { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
}

func double(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value.replacingOccurrences(of: "%", with: "")) }
    return nil
}

func signedPct(_ value: Double) -> String {
    "\(value >= 0 ? "+" : "")\(String(format: "%.2f", value))%"
}

func formatNumber(_ value: Double) -> String {
    String(format: "%.1f", value)
}

func volumeText(_ value: Double?) -> String {
    guard let value else { return "--" }
    let absValue = abs(value)
    if absValue >= 100_000_000 { return "\(String(format: "%.2f", value / 100_000_000))亿" }
    if absValue >= 10_000 { return "\(String(format: "%.1f", value / 10_000))万" }
    return String(format: "%.0f", value)
}

func dateText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

func timeText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

let chinaMarketClosedDates: Set<String> = [
    "2026-01-01", "2026-01-02",
    "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-23",
    "2026-04-06",
    "2026-05-01", "2026-05-04", "2026-05-05",
    "2026-06-19",
    "2026-09-25",
    "2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06", "2026-10-07"
]

func isChinaATradingDay(_ date: Date) -> Bool {
    let weekday = Calendar.current.component(.weekday, from: date)
    if weekday == 1 || weekday == 7 { return false }
    return !chinaMarketClosedDates.contains(dateText(date))
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
