import SwiftUI

@MainActor
final class AlipayPortfolioViewModel: ObservableObject {
    @Published var funds: [SavedFund] = []
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var showingAdd = false

    private let service = AlipayFundService()
    private var timer: Timer?
    private var last1455Key = ""
    private var last1458Key = ""
    private var last0915Key = ""

    init() {
        loadSavedFunds()
        NotificationService.shared.requestAuthorization()
        NotificationService.shared.scheduleTradingReminders()
        startTimer()
    }

    deinit {
        timer?.invalidate()
    }

    func loadSavedFunds() {
        do {
            funds = try CoreDataStore.shared.fetchFunds()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func add(code: String) async {
        await refresh(code: code, showResultNotification: false)
    }

    func refreshAll(showResultNotification: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let codes = funds.map(\.code)
        for code in codes {
            await refresh(code: code, showResultNotification: showResultNotification)
        }
        loadSavedFunds()
    }

    func refresh(code: String, showResultNotification: Bool) async {
        do {
            let analysis = try await service.load(code: code)
            if showResultNotification {
                NotificationService.shared.notifyPrediction(analysis)
            }
            errorMessage = nil
        } catch {
            errorMessage = "数据拉取失败：\(error.localizedDescription)。本次不使用旧数据判断。"
            do {
                try CoreDataStore.shared.markFundFailure(code: code, message: errorMessage ?? "数据拉取失败")
            } catch {
                errorMessage = error.localizedDescription
            }
            NotificationService.shared.notifyFailure(code: code, error: error.localizedDescription)
        }
        loadSavedFunds()
    }

    func delete(_ fund: SavedFund) {
        do {
            try CoreDataStore.shared.deleteFund(code: fund.code)
            loadSavedFunds()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkTimedTasks()
            }
        }
    }

    private func checkTimedTasks() async {
        let now = Date()
        guard isChinaATradingDay(now) else { return }
        let key = dateText(now)
        let minute = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)

        if minute >= 14 * 60 + 55, minute < 14 * 60 + 58, last1455Key != key {
            last1455Key = key
            NotificationService.shared.notifyCloseReminder()
        }

        if minute >= 14 * 60 + 58, minute <= 15 * 60, last1458Key != key {
            last1458Key = key
            await refreshAll(showResultNotification: true)
        }

        if minute >= 9 * 60 + 15, minute < 9 * 60 + 18, last0915Key != key {
            last0915Key = key
            let us = await service.loadUSSummary()
            for fund in funds {
                NotificationService.shared.notifyUSValidation(fund: fund, usSummary: us.isEmpty ? "美股数据拉取失败" : us)
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AlipayPortfolioViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    HeaderPanel(count: model.funds.count, refreshing: model.isRefreshing)

                    if let error = model.errorMessage {
                        ErrorBanner(text: error)
                    }

                    if model.funds.isEmpty {
                        EmptyAlipayView {
                            model.showingAdd = true
                        }
                    } else {
                        ForEach(model.funds) { fund in
                            NavigationLink(value: fund.code) {
                                SavedFundCard(fund: fund)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    model.delete(fund)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }

                    DisclaimerView()
                }
                .padding(16)
            }
            .refreshable {
                await model.refreshAll()
            }
            .navigationTitle("小又")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.showingAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("添加基金")
                }
            }
            .sheet(isPresented: $model.showingAdd) {
                AddFundSheet { code in
                    model.showingAdd = false
                    Task { await model.add(code: code) }
                }
                .presentationDetents([.medium])
            }
            .navigationDestination(for: String.self) { code in
                FundDetailContainer(code: code)
            }
        }
    }
}

struct HeaderPanel: View {
    let count: Int
    let refreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("支付宝")
                        .font(.largeTitle.bold())
                    Text("独立数据空间 · SwiftUI · CoreData")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(count)只")
                    .font(.headline.bold())
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.blue.opacity(0.12), in: Capsule())
            }

            Text("14:55 收盘提醒，14:58 按真实尾盘数据生成明日预判。数据失败会明确提示，不沿用旧数据判断。")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if refreshing {
                ProgressView()
            }
        }
        .panelStyle()
    }
}

struct EmptyAlipayView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.secondary)
            Text("这里还没有基金")
                .font(.title3.bold())
            Text("点右上角 + 输入 6 位基金代码，系统会拉取基金名称、类型、净值、跟踪指数、关联ETF和前十大重仓股。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("添加基金", action: onAdd)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .panelStyle()
    }
}

struct AddFundSheet: View {
    @State private var code = ""
    let onSubmit: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("输入基金代码")
                    .font(.title.bold())
                TextField("例如 012863", text: $code)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                Text("只保存到支付宝页面，不和持有/模拟共用。")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button {
                    onSubmit(code)
                } label: {
                    Text("确认并拉取真实数据")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.range(of: #"^\d{6}$"#, options: .regularExpression) == nil)
                Spacer()
                DisclaimerView()
            }
            .padding()
        }
    }
}

struct SavedFundCard: View {
    let fund: SavedFund

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(fund.name)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Text("\(fund.code) · \(fund.fundType) · \(timeText(fund.updatedAt))")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DirectionBadge(direction: fund.lastPredictionDirection)
            }

            if let lastError = fund.lastError, !lastError.isEmpty {
                ErrorBanner(text: lastError)
            }

            HStack {
                MetricBlock(title: "最新净值", value: String(format: "%.4f", fund.latestNav))
                MetricBlock(title: "今日涨跌", value: signedPct(fund.todayPct), color: fund.todayPct >= 0 ? .red : .green)
            }

            HStack {
                Text("置信度：\(fund.confidence)")
                Spacer()
                Text("点击查看详情")
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(.secondary)
        }
        .panelStyle()
    }
}

struct FundDetailContainer: View {
    let code: String
    @State private var analysis: FundAnalysis?
    @State private var records: [PredictionRecord] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var actualSheetRecord: PredictionRecord?

    private let service = AlipayFundService()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if isLoading {
                    ProgressView("正在拉取真实数据...")
                        .frame(maxWidth: .infinity)
                        .panelStyle()
                }

                if let error {
                    ErrorBanner(text: error)
                }

                if let analysis {
                    FundTopCard(analysis: analysis)
                    TimedSignalCard(title: "模块1：跟踪指数尾盘", subtitle: "\(analysis.targetIndexName) \(analysis.targetIndexCode)", signal: analysis.indexSignal)
                    HoldingsTailCard(analysis: analysis)
                    SectorETFCard(signals: analysis.sectorEtfSignals)
                    FilterCard(filters: analysis.filters)
                    LogicCard(analysis: analysis)
                    PredictionHistoryCard(records: records) { record in
                        actualSheetRecord = record
                    }
                    DisclaimerView()
                } else if !isLoading {
                    Text("暂无详情，请下拉刷新。")
                        .foregroundStyle(.secondary)
                        .panelStyle()
                    DisclaimerView()
                }
            }
            .padding(16)
        }
        .navigationTitle("基金分析")
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $actualSheetRecord) { record in
            ActualInputSheet(record: record) { value in
                do {
                    try CoreDataStore.shared.updateActual(fundCode: code, date: record.date, actualPct: value)
                    records = try CoreDataStore.shared.fetchPredictions(code: code)
                } catch {
                    self.error = error.localizedDescription
                }
                actualSheetRecord = nil
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            analysis = try await service.load(code: code)
            records = try CoreDataStore.shared.fetchPredictions(code: code)
            error = nil
        } catch {
            self.error = "数据拉取失败：\(error.localizedDescription)。本次不使用旧数据判断。"
        }
    }
}

struct FundTopCard: View {
    let analysis: FundAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(analysis.code) · \(analysis.fundType)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
            Text(analysis.name)
                .font(.largeTitle.bold())
            HStack {
                MetricBlock(title: "最新净值", value: String(format: "%.4f", analysis.latestNav))
                MetricBlock(title: "今日涨跌", value: signedPct(analysis.todayPct), color: analysis.todayPct >= 0 ? .red : .green)
            }
            DirectionBadge(direction: analysis.finalDirection, large: true)
            Text("置信度：\(analysis.confidence) · 更新时间 \(timeText(analysis.updatedAt))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            BulletSection(title: "核心依据", rows: Array(analysis.coreReasons.prefix(3)), symbol: "checkmark.circle.fill", color: .blue)
            BulletSection(title: "风险提示", rows: Array(analysis.riskTips.prefix(2)), symbol: "exclamationmark.triangle.fill", color: .orange)
        }
        .panelStyle()
    }
}

struct TimedSignalCard: View {
    let title: String
    let subtitle: String
    let signal: TimedSignal

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            Text(subtitle).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            SignalGrid(signal: signal)
        }
        .panelStyle()
    }
}

struct SignalGrid: View {
    let signal: TimedSignal

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                MetricBlock(title: "今日涨跌幅", value: signal.todayPct.map(signedPct) ?? "--", color: (signal.todayPct ?? 0) >= 0 ? .red : .green)
                MetricBlock(title: "量比", value: signal.volumeRatio.map { String(format: "%.2f", $0) } ?? "--")
            }
            GridRow {
                MetricBlock(title: "区间A成交量", value: volumeText(signal.volumeA))
                MetricBlock(title: "B等效成交量", value: volumeText(signal.volumeBEquivalent))
            }
            GridRow {
                MetricBlock(title: "信号", value: signal.signal.rawValue, color: signalColor(signal.signal))
                MetricBlock(title: "贡献得分", value: formatNumber(signal.contribution), color: signal.contribution >= 0 ? .red : .green)
            }
        }
        if let error = signal.error {
            Text("数据提示：\(error)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }
}

struct HoldingsTailCard: View {
    let analysis: FundAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("模块2：前十大重仓股尾盘详情")
                .font(.title3.bold())
            ForEach(analysis.holdings) { holding in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(holding.name) \(holding.code)").font(.headline.bold())
                            Text(holding.industry.isEmpty ? "行业待确认" : holding.industry)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("占 \(String(format: "%.2f", holding.weightPct))%")
                            .font(.headline.bold())
                    }
                    ProgressView(value: min(holding.weightPct / 15, 1))
                        .tint(signalColor(holding.signal))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        SmallChip("涨跌 \(holding.todayPct.map(signedPct) ?? "--")")
                        SmallChip("A量 \(volumeText(holding.volumeA))")
                        SmallChip("B等效 \(volumeText(holding.volumeBEquivalent))")
                        SmallChip("量比 \(holding.volumeRatio.map { String(format: "%.2f", $0) } ?? "--")")
                        SmallChip(holding.signal.rawValue, color: signalColor(holding.signal))
                        SmallChip("贡献 \(formatNumber(holding.contribution))", color: holding.contribution >= 0 ? .red : .green)
                    }
                    Divider()
                }
            }
            Text("重仓股加权总分：\(formatNumber(analysis.holdingsScore)) · 方向：\(analysis.holdingsScore > 0 ? "偏多" : analysis.holdingsScore < 0 ? "偏空" : "不判断")")
                .font(.headline.bold())
        }
        .panelStyle()
    }
}

struct SectorETFCard: View {
    let signals: [TimedSignal]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模块3：同板块ETF联动")
                .font(.title3.bold())
            if signals.isEmpty {
                Text("暂无关联ETF，不能用旧数据补。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(signals) { signal in
                    TimedSignalCard(title: signal.name, subtitle: signal.code, signal: signal)
                        .padding(.vertical, 2)
                }
            }
        }
        .panelStyle()
    }
}

struct FilterCard: View {
    let filters: [FilterSignal]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模块4：辅助过滤指标")
                .font(.title3.bold())
            ForEach(filters) { filter in
                HStack(alignment: .top) {
                    Text(filter.title)
                        .font(.headline.bold())
                        .frame(width: 88, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(filter.value)
                        Text(filter.status)
                            .foregroundStyle(filter.downgraded ? .green : .secondary)
                    }
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                Divider()
            }
        }
        .panelStyle()
    }
}

struct LogicCard: View {
    let analysis: FundAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("模块5：判断逻辑说明")
                .font(.title3.bold())
            LogicRow("第一层 跟踪指数", "\(formatNumber(analysis.indexScore)) 分")
            LogicRow("第二层 重仓股加权", "\(formatNumber(analysis.holdingsScore)) 分")
            LogicRow("第三层 ETF联动", "\(formatNumber(analysis.sectorEtfScore)) 分")
            LogicRow("原始总分", "\(formatNumber(analysis.rawScore)) → 初步判断：\(analysis.initialDirection.rawValue)")
            ForEach(analysis.filters) { filter in
                LogicRow(filter.title, filter.downgraded ? "降级：\(filter.status)" : filter.status)
            }
            LogicRow("最终结论", analysis.finalDirection.rawValue)
            LogicRow("置信度", analysis.confidence)
        }
        .panelStyle()
    }
}

struct LogicRow: View {
    let left: String
    let right: String

    init(_ left: String, _ right: String) {
        self.left = left
        self.right = right
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(left).foregroundStyle(.secondary).frame(width: 128, alignment: .leading)
            Text(right).fontWeight(.bold)
            Spacer()
        }
        .font(.subheadline)
    }
}

struct PredictionHistoryCard: View {
    let records: [PredictionRecord]
    let onInput: (PredictionRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模块6：历史预判记录")
                .font(.title3.bold())
            if records.isEmpty {
                Text("暂无记录。每次判断会自动保存，实际次日涨跌幅由你手动录入。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records.prefix(20)) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.date).font(.headline.bold())
                            Text("\(record.predictedDirection.rawValue) · \(record.confidence)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let actual = record.actualPct {
                            Text("\(signedPct(actual)) \(record.hit == true ? "✓" : "✗")")
                                .font(.headline.bold())
                                .foregroundStyle(record.hit == true ? .red : .green)
                        } else {
                            Button("录入实际") { onInput(record) }
                                .buttonStyle(.bordered)
                        }
                    }
                    Divider()
                }
                HistoryStats(records: records)
            }
        }
        .panelStyle()
    }
}

struct HistoryStats: View {
    let records: [PredictionRecord]

    var body: some View {
        let completed = records.filter { $0.hit != nil }
        let hits = completed.filter { $0.hit == true }.count
        let high = completed.filter { $0.confidence == "高" }
        let mid = completed.filter { $0.confidence == "中" }
        Text("总预判 \(records.count) 次 · 命中 \(hits) 次 · 总命中率 \(rate(hits, completed.count)) · 高置信 \(rate(high.filter { $0.hit == true }.count, high.count)) · 中置信 \(rate(mid.filter { $0.hit == true }.count, mid.count))")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func rate(_ hit: Int, _ total: Int) -> String {
        total == 0 ? "--" : "\(Int(round(Double(hit) / Double(total) * 100)))%"
    }
}

struct ActualInputSheet: View {
    let record: PredictionRecord
    let onSave: (Double) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("录入 \(record.date) 次日实际涨跌幅")
                    .font(.title2.bold())
                TextField("例如 -0.72 或 1.35", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                Button {
                    if let value = Double(text.replacingOccurrences(of: "%", with: "")) {
                        onSave(value)
                    }
                } label: {
                    Text("保存")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                DisclaimerView()
            }
            .padding()
        }
    }
}

struct DirectionBadge: View {
    let direction: PredictionDirection
    var large = false

    var body: some View {
        Text(direction.rawValue)
            .font(large ? .system(size: 44, weight: .black) : .headline.bold())
            .foregroundStyle(direction == .bullish ? .red : direction == .bearish ? .green : .secondary)
            .padding(.horizontal, large ? 0 : 10)
            .padding(.vertical, large ? 0 : 6)
            .background(large ? Color.clear : directionColor.opacity(0.12), in: Capsule())
    }

    private var directionColor: Color {
        direction == .bullish ? .red : direction == .bearish ? .green : .gray
    }
}

struct MetricBlock: View {
    let title: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SmallChip: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(color.opacity(0.10), in: Capsule())
    }
}

struct BulletSection: View {
    let title: String
    let rows: [String]
    let symbol: String
    let color: Color

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline.bold())
                ForEach(rows, id: \.self) { row in
                    HStack(alignment: .top) {
                        Image(systemName: symbol).foregroundStyle(color)
                        Text(row).font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }
}

struct ErrorBanner: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct DisclaimerView: View {
    var body: some View {
        Text(investmentDisclaimer)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

func signalColor(_ signal: TailSignalKind) -> Color {
    switch signal {
    case .volumeUp: return .red
    case .volumeDown: return .green
    case .invalid: return .secondary
    case .failed: return .orange
    }
}

extension View {
    func panelStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            )
    }
}
