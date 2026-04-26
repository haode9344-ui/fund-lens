import SwiftUI

struct ContentView: View {
    @State private var code = ""
    @State private var fund: FundData?
    @State private var message = "输入支付宝基金详情里的 6 位代码"
    @State private var isLoading = false

    private let service = FundService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("例如 161725", text: $code)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)

                    Button(action: analyze) {
                        HStack {
                            Spacer()
                            Text(isLoading ? "分析中..." : "分析基金")
                                .fontWeight(.bold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || code.count != 6)

                    if let fund {
                        resultView(fund)
                    } else {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .padding(.top, 28)
                    }
                }
                .padding()
            }
            .navigationTitle("Fund Lens")
        }
    }

    private func resultView(_ fund: FundData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(fund.code) · 最新净值 \(fund.latest.value, specifier: "%.4f")")
                .foregroundStyle(.secondary)
            Text(fund.name)
                .font(.largeTitle.bold())

            Text(fund.forecast.direction == "up" ? "偏涨" : "偏跌")
                .font(.system(size: 64, weight: .black))
                .foregroundStyle(fund.forecast.direction == "up" ? .red : .green)

            Text("上涨概率 \(fund.forecast.probabilityUp, specifier: "%.1f")%，预估 \(signed(fund.forecast.expectedPct))，区间 \(signed(fund.forecast.rangePct.first ?? 0)) 至 \(signed(fund.forecast.rangePct.last ?? 0))。")
                .foregroundStyle(.secondary)

            GroupBox(fund.buyView.stance) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(fund.buyView.reason)
                    Text("关联影响：\(fund.impact.label)，今日估算贡献 \(signed(fund.impact.todayContributionPct))")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(fund.holdings.prefix(8)) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.name).fontWeight(.semibold)
                        Text("\(item.code) · \(item.industry) · 占 \(item.holdingPct, specifier: "%.2f")%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(signed(item.estimatedContributionPct ?? 0))
                        .fontWeight(.bold)
                }
                Divider()
            }

            Text(fund.disclaimer)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func analyze() {
        isLoading = true
        message = "正在分析..."
        Task {
            do {
                fund = try await service.load(code: code)
            } catch {
                fund = nil
                message = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func signed(_ value: Double) -> String {
        "\(value >= 0 ? "+" : "")\(String(format: "%.2f", value))%"
    }
}
