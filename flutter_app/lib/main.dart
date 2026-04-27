import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const XiaoyouApp());
}

class XiaoyouApp extends StatelessWidget {
  const XiaoyouApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '小又',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.blue),
        scaffoldBackgroundColor: AppColors.bg,
        fontFamily: '.SF Pro Text',
        useMaterial3: true,
      ),
      home: const PortfolioHome(),
    );
  }
}

class PortfolioHome extends StatefulWidget {
  const PortfolioHome({super.key});

  @override
  State<PortfolioHome> createState() => _PortfolioHomeState();
}

class _PortfolioHomeState extends State<PortfolioHome> {
  final FundService _service = FundService();
  final Map<String, FundAnalysis> _cache = {};
  List<PortfolioItem> _owned = [];
  List<PortfolioItem> _simulated = [];
  int _tab = 0;
  bool _loading = true;

  List<PortfolioItem> get _currentItems => _tab == 0 ? _owned : _simulated;
  String get _currentTitle => _tab == 0 ? '持有持仓' : '模拟持仓';
  String get _storageKey => _tab == 0 ? 'owned_portfolio' : 'simulated_portfolio';

  @override
  void initState() {
    super.initState();
    _loadPortfolios();
  }

  Future<void> _loadPortfolios() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _owned = _decodePortfolio(prefs.getString('owned_portfolio'));
      _simulated = _decodePortfolio(prefs.getString('simulated_portfolio'));
      _loading = false;
    });
    await _refreshCurrent();
  }

  List<PortfolioItem> _decodePortfolio(String? value) {
    if (value == null || value.isEmpty) return [];
    final rows = jsonDecode(value) as List<dynamic>;
    return rows.map((row) => PortfolioItem.fromJson(row as Map<String, dynamic>)).toList();
  }

  Future<void> _saveCurrent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_currentItems.map((item) => item.toJson()).toList()));
  }

  Future<void> _refreshCurrent() async {
    final items = List<PortfolioItem>.from(_currentItems);
    if (items.isEmpty) return;
    for (final item in items) {
      try {
        final analysis = await _service.load(item.code);
        if (!mounted) return;
        setState(() => _cache[item.code] = analysis);
      } catch (_) {
        // Keep the previous analysis visible when one data source is temporarily slow.
      }
    }
  }

  Future<void> _addFund() async {
    final result = await showModalBottomSheet<PortfolioItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AddFundSheet(title: _currentTitle),
    );
    if (result == null) return;
    final target = _tab == 0 ? _owned : _simulated;
    final existing = target.indexWhere((item) => item.code == result.code);
    setState(() {
      if (existing >= 0) {
        target[existing] = result;
      } else {
        target.add(result);
      }
    });
    await _saveCurrent();
    await _refreshCurrent();
  }

  Future<void> _removeFund(PortfolioItem item) async {
    setState(() => _currentItems.removeWhere((row) => row.code == item.code));
    await _saveCurrent();
  }

  PortfolioSummary _summary() {
    double amount = 0;
    double income = 0;
    for (final item in _currentItems) {
      amount += item.amount;
      final analysis = _cache[item.code];
      if (analysis != null) income += item.amount * analysis.todayPct / 100;
    }
    return PortfolioSummary(amount: amount, todayIncome: income);
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary();
    return Scaffold(
      appBar: AppBar(
        title: const Text('小又', style: TextStyle(fontWeight: FontWeight.w900)),
        centerTitle: false,
        backgroundColor: AppColors.bg,
        surfaceTintColor: AppColors.bg,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addFund,
        backgroundColor: AppColors.blue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: const Icon(CupertinoIcons.add, size: 28),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) async {
          setState(() => _tab = index);
          await _refreshCurrent();
        },
        destinations: const [
          NavigationDestination(icon: Icon(CupertinoIcons.briefcase), label: '持有'),
          NavigationDestination(icon: Icon(CupertinoIcons.chart_bar_square), label: '模拟'),
        ],
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : RefreshIndicator(
              onRefresh: _refreshCurrent,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                children: [
                  HeaderSummary(
                    title: _currentTitle,
                    totalAmount: summary.amount,
                    todayIncome: summary.todayIncome,
                    count: _currentItems.length,
                  ),
                  const SizedBox(height: 14),
                  if (_currentItems.isEmpty)
                    EmptyPortfolioCard(title: _currentTitle, onAdd: _addFund)
                  else
                    ..._currentItems.map((item) {
                      final analysis = _cache[item.code];
                      return FundPositionCard(
                        item: item,
                        analysis: analysis,
                        onTap: analysis == null
                            ? null
                            : () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => FundDetailPage(
                                      item: item,
                                      analysis: analysis,
                                      onRefresh: () async {
                                        final fresh = await _service.load(item.code);
                                        if (mounted) setState(() => _cache[item.code] = fresh);
                                        return fresh;
                                      },
                                    ),
                                  ),
                                );
                              },
                        onDelete: () => _removeFund(item),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}

class HeaderSummary extends StatelessWidget {
  const HeaderSummary({
    super.key,
    required this.title,
    required this.totalAmount,
    required this.todayIncome,
    required this.count,
  });

  final String title;
  final double totalAmount;
  final double todayIncome;
  final int count;

  @override
  Widget build(BuildContext context) {
    final positive = todayIncome >= 0;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(22),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          Text(
            money(totalAmount),
            style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _SummaryChip(label: '今日估算', value: signedMoney(todayIncome), positive: positive),
              const SizedBox(width: 10),
              _SummaryChip(label: '基金数', value: '$count 只', positive: true),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.value, required this.positive});

  final String label;
  final String value;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(
              value,
              style: TextStyle(
                color: positive ? const Color(0xFFFF5A4F) : const Color(0xFF54C77A),
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class EmptyPortfolioCard extends StatelessWidget {
  const EmptyPortfolioCard({super.key, required this.title, required this.onAdd});

  final String title;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(CupertinoIcons.plus_app, size: 34, color: AppColors.blue),
          const SizedBox(height: 12),
          Text('$title还没有基金', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          const Text('点右下角加号，输入基金代码和金额。下拉页面可以刷新最新分析。', style: TextStyle(color: AppColors.muted, height: 1.45)),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: onAdd, icon: const Icon(CupertinoIcons.add), label: const Text('添加基金')),
        ],
      ),
    );
  }
}

class FundPositionCard extends StatelessWidget {
  const FundPositionCard({
    super.key,
    required this.item,
    required this.analysis,
    required this.onTap,
    required this.onDelete,
  });

  final PortfolioItem item;
  final FundAnalysis? analysis;
  final VoidCallback? onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final todayIncome = analysis == null ? 0.0 : item.amount * analysis!.todayPct / 100;
    final positive = todayIncome >= 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: CardShell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(analysis?.name ?? '基金 ${item.code}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 6),
                        Text(
                          analysis == null
                              ? '${item.code} · 分析中'
                              : '${item.code} · 今天 ${analysis.analysisDate} · 净值日 ${analysis.latestDate}',
                          style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  IconButton(onPressed: onDelete, icon: const Icon(CupertinoIcons.delete, color: AppColors.muted)),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _Metric(label: '持有金额', value: money(item.amount))),
                  Expanded(
                    child: _Metric(
                      label: '今日估算',
                      value: analysis == null ? '分析中' : '${pct(analysis!.todayPct)} / ${signedMoney(todayIncome)}',
                      color: positive ? AppColors.red : AppColors.green,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.softBlue, borderRadius: BorderRadius.circular(14)),
                child: Row(
                  children: [
                    const Icon(CupertinoIcons.sparkles, color: AppColors.blue, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        analysis?.summaryLine ?? '正在读取净值、持仓和公告...',
                        style: const TextStyle(fontWeight: FontWeight.w800, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FundDetailPage extends StatefulWidget {
  const FundDetailPage({
    super.key,
    required this.item,
    required this.analysis,
    required this.onRefresh,
  });

  final PortfolioItem item;
  final FundAnalysis analysis;
  final Future<FundAnalysis> Function() onRefresh;

  @override
  State<FundDetailPage> createState() => _FundDetailPageState();
}

class _FundDetailPageState extends State<FundDetailPage> {
  late FundAnalysis _analysis = widget.analysis;

  Future<void> _refresh() async {
    final fresh = await widget.onRefresh();
    if (mounted) setState(() => _analysis = fresh);
  }

  @override
  Widget build(BuildContext context) {
    final buyAmount = widget.item.amount * _analysis.buyRatio;
    final sellAmount = widget.item.amount * _analysis.sellRatio;
    return Scaffold(
      appBar: AppBar(
        title: const Text('基金分析', style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: AppColors.bg,
        surfaceTintColor: AppColors.bg,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          children: [
            CardShell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_analysis.code} · 今天 ${_analysis.analysisDate} · 最新净值日 ${_analysis.latestDate}',
                    style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(_analysis.name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, height: 1.08)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: _Metric(label: '今天', value: _analysis.todayState, color: signalColor(_analysis.todayState))),
                      Expanded(child: _Metric(label: '明天', value: _analysis.tomorrowTrend, color: signalColor(_analysis.tomorrowTrend))),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: AppColors.softBlue, borderRadius: BorderRadius.circular(16)),
                    child: Text(_analysis.todayReason, style: const TextStyle(fontWeight: FontWeight.w800, height: 1.45)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            CardShell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('今天怎么做', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  Text(_analysis.action, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _Metric(label: '建议买入', value: money(buyAmount))),
                      Expanded(child: _Metric(label: '建议卖出', value: money(sellAmount))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(_analysis.actionReason, style: const TextStyle(color: AppColors.muted, height: 1.45, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_analysis.liquorSpecial != null) ...[
              CardShell(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('白酒专项判断', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 12),
                    Text(_analysis.liquorSpecial!, style: const TextStyle(height: 1.5, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            CardShell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('重仓股与公告', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  if (_analysis.announcements.isEmpty)
                    const Text('暂未抓到高影响公告。', style: TextStyle(color: AppColors.muted))
                  else
                    ..._analysis.announcements.take(5).map((item) => AnnouncementTile(item: item)),
                  const Divider(height: 28),
                  ..._analysis.holdings.take(10).map((item) => StockHoldingRow(item: item)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AddFundSheet extends StatefulWidget {
  const AddFundSheet({super.key, required this.title});

  final String title;

  @override
  State<AddFundSheet> createState() => _AddFundSheetState();
}

class _AddFundSheetState extends State<AddFundSheet> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _codeController.text.trim();
    final amount = double.tryParse(_amountController.text.trim()) ?? 0;
    if (!RegExp(r'^\d{6}$').hasMatch(code)) return;
    if (amount <= 0) return;
    Navigator.pop(context, PortfolioItem(code: code, amount: amount));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
        decoration: const BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('添加到${widget.title}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
            const SizedBox(height: 14),
            CupertinoTextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              placeholder: '搜索基金代码，例如 161725',
              padding: const EdgeInsets.all(15),
              decoration: inputDecoration(),
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              placeholder: widget.title == '持有持仓' ? '我持有的金额' : '模拟金额',
              padding: const EdgeInsets.all(15),
              decoration: inputDecoration(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(CupertinoIcons.add),
                label: const Text('添加并分析'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CardShell extends StatelessWidget {
  const CardShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.line),
        boxShadow: AppShadows.card,
      ),
      child: child,
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(height: 5),
        Text(value, style: TextStyle(color: color ?? AppColors.ink, fontSize: 18, fontWeight: FontWeight.w900)),
      ],
    );
  }
}

class AnnouncementTile extends StatelessWidget {
  const AnnouncementTile({super.key, required this.item});

  final Announcement item;

  @override
  Widget build(BuildContext context) {
    final color = item.sentiment == '负面' ? AppColors.green : item.sentiment == '正面' ? AppColors.red : AppColors.muted;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: item.severity >= 80 ? const Color(0xFFFFF1EF) : AppColors.softGrey,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: item.severity >= 80 ? const Color(0xFFFFC7C0) : AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Pill(text: item.category),
              Pill(text: item.sentiment, color: color),
              Pill(text: '强度 ${item.severity}'),
            ],
          ),
          const SizedBox(height: 8),
          Text(item.title, style: const TextStyle(fontWeight: FontWeight.w900, height: 1.35)),
          const SizedBox(height: 5),
          Text(item.reason, style: const TextStyle(color: AppColors.muted, height: 1.35, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class StockHoldingRow extends StatelessWidget {
  const StockHoldingRow({super.key, required this.item});

  final StockHolding item;

  @override
  Widget build(BuildContext context) {
    final quote = item.changePct == null ? '暂无行情' : pct(item.changePct!);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 3),
                Text('${item.code} · ${item.industry}', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
              ],
            ),
          ),
          Text('占 ${item.holdingPct.toStringAsFixed(2)}% · $quote', style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: AppColors.line)),
      child: Text(text, style: TextStyle(color: color ?? AppColors.muted, fontSize: 12, fontWeight: FontWeight.w900)),
    );
  }
}

class FundService {
  final http.Client _client = http.Client();

  Future<FundAnalysis> load(String code) async {
    final fund = await _loadFundBase(code);
    final rawHoldings = await _loadHoldings(code);
    final theme = inferTheme(fund.name);
    final holdings = await _enrichHoldings(applyThemeFallback(rawHoldings, theme));
    final announcements = await _loadAnnouncements(holdings.take(5).toList());
    final market = await _loadMarket(fund);
    return _analyze(fund, holdings, announcements, market, theme);
  }

  Future<FundBase> _loadFundBase(String code) async {
    final uri = Uri.parse('https://fund.eastmoney.com/pingzhongdata/$code.js?v=${DateTime.now().millisecondsSinceEpoch}');
    final response = await _client.get(uri).timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) throw Exception('基金数据源暂时不可用');
    final raw = utf8.decode(response.bodyBytes);
    final name = RegExp(r'''var\s+fS_name\s*=\s*["']([^"']*)["'];''').firstMatch(raw)?.group(1) ?? '基金 $code';
    final trendText = RegExp(r'var\s+Data_netWorthTrend\s*=\s*(\[.*?\]);', dotAll: true).firstMatch(raw)?.group(1);
    if (trendText == null) throw Exception('没有抓到净值走势');
    final rows = jsonDecode(trendText) as List<dynamic>;
    final points = rows
        .whereType<Map<String, dynamic>>()
        .where((row) => row['x'] != null && row['y'] != null)
        .map((row) => NavPoint(
              date: dateFromMillis((row['x'] as num).toInt()),
              value: toDouble(row['y']),
              equityReturn: toNullableDouble(row['equityReturn']),
            ))
        .toList();
    if (points.length < 20) throw Exception('历史净值太少，暂时无法分析');
    return FundBase(code: code, name: name, points: points);
  }

  Future<List<StockHolding>> _loadHoldings(String code) async {
    final year = DateTime.now().year;
    final uri = Uri.parse('https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$code&topline=10&year=$year&month=');
    final response = await _client.get(uri).timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) return [];
    final raw = utf8.decode(response.bodyBytes);
    var content = RegExp(r'content:"(.*?)",arryear', dotAll: true).firstMatch(raw)?.group(1) ?? raw;
    content = content.replaceAll(r'\"', '"').replaceAll(r'\/', '/');
    final rows = RegExp(r'<tr>(.*?)</tr>', dotAll: true).allMatches(content);
    final holdings = <StockHolding>[];
    for (final row in rows) {
      final cells = RegExp(r'<td.*?>(.*?)</td>', dotAll: true).allMatches(row.group(1)!).map((cell) => stripTags(cell.group(1)!)).toList();
      if (cells.length < 7) continue;
      final stockCode = RegExp(r'\d{6}').firstMatch(cells[1])?.group(0);
      if (stockCode == null) continue;
      holdings.add(
        StockHolding(
          code: stockCode,
          name: cells[2],
          industry: '行业暂缺',
          holdingPct: toDouble(cells[6].replaceAll('%', '').replaceAll(',', '')),
        ),
      );
      if (holdings.length >= 10) break;
    }
    return holdings;
  }

  Future<List<StockHolding>> _enrichHoldings(List<StockHolding> holdings) async {
    if (holdings.isEmpty) return holdings;
    final secids = holdings.map((item) => '${marketFromCode(item.code)}.${item.code}').join(',');
    final uri = Uri.parse('https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=$secids&fields=f2,f3,f12,f14,f62,f100,f184');
    try {
      final response = await _client.get(uri).timeout(const Duration(seconds: 8));
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final data = payload['data'] as Map<String, dynamic>?;
      final rows = (data?['diff'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();
      final quoteMap = {for (final row in rows) row['f12'].toString(): row};
      return holdings.map((holding) {
        final quote = quoteMap[holding.code];
        final change = quote == null ? null : toNullableDouble(quote['f3']);
        final quoteIndustry = quote == null ? '' : (quote['f100'] ?? '').toString();
        final industry = quoteIndustry.isNotEmpty ? quoteIndustry : holding.industry;
        return holding.copyWith(
          industry: normalizeIndustry(industry, fallback: holding.industry),
          changePct: change,
          contributionPct: change == null ? null : holding.holdingPct * change / 100,
        );
      }).toList();
    } catch (_) {
      return holdings;
    }
  }

  Future<MarketSnapshot> _loadMarket(FundBase fund) async {
    final uri = Uri.parse('https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=1.000001,0.399001,0.399006,1.000300&fields=f2,f3,f12,f14');
    try {
      final response = await _client.get(uri).timeout(const Duration(seconds: 8));
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final data = payload['data'] as Map<String, dynamic>?;
      final rows = (data?['diff'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      final changes = rows.map((row) => toDouble(row['f3'])).toList();
      final avg = changes.isEmpty ? 0.0 : changes.reduce((a, b) => a + b) / changes.length;
      return MarketSnapshot(label: avg > 0.4 ? '市场偏强' : avg < -0.4 ? '市场偏弱' : '市场震荡', averageChange: avg);
    } catch (_) {
      final returns = recentReturns(fund.points, 10);
      final avg = returns.isEmpty ? 0.0 : returns.reduce((a, b) => a + b) / returns.length;
      return MarketSnapshot(label: avg > 0 ? '基金风格偏强' : '基金风格震荡', averageChange: avg);
    }
  }

  Future<List<Announcement>> _loadAnnouncements(List<StockHolding> holdings) async {
    final tasks = holdings.map((holding) async {
      final params = Uri(queryParameters: {
        'sr': '-1',
        'page_size': '8',
        'page_index': '1',
        'ann_type': 'A',
        'client_source': 'web',
        'stock_list': holding.code,
      }).query;
      final uri = Uri.parse('https://np-anotice-stock.eastmoney.com/api/security/ann?$params');
      final response = await _client.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return <Announcement>[];
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final data = payload['data'] as Map<String, dynamic>?;
      final rows = (data?['list'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();
      return rows.map((row) => classifyAnnouncement(row, holding)).toList();
    });
    final results = await Future.wait(tasks.map((task) => task.catchError((_) => <Announcement>[])));
    final seen = <String>{};
    final all = results.expand((items) => items).where((item) => seen.add(item.title)).toList();
    all.sort((a, b) {
      final rank = a.rank.compareTo(b.rank);
      if (rank != 0) return rank;
      return b.severity.compareTo(a.severity);
    });
    return all;
  }

  FundAnalysis _analyze(FundBase fund, List<StockHolding> holdings, List<Announcement> announcements, MarketSnapshot market, String theme) {
    final points = fund.points;
    final last = points.last;
    final returns = dailyReturns(points);
    final last5 = returns.takeLast(5).sum;
    final last20 = returns.takeLast(20).sum;
    final volatility = std(returns.takeLast(30));
    final drawdown = maxDrawdown(points.takeLast(90)) * 100;
    final contribution = holdings.where((item) => item.contributionPct != null).map((item) => item.contributionPct!).sum;
    final hasRealtime = holdings.any((item) => item.changePct != null);
    final latestReturn = last.equityReturn ?? (returns.isEmpty ? 0 : returns.last);
    final todayPct = hasRealtime ? contribution : latestReturn;
    final expected = 0.55 * (returns.takeLast(5).averageOrZero) + 0.30 * (returns.takeLast(10).averageOrZero) + 0.15 * (returns.takeLast(30).averageOrZero);
    final probabilityUp = 100 / (1 + exp(-(expected / max(std(returns.takeLast(30)), 0.0001))));
    final majorNegative = announcements.where((item) => item.sentiment == '负面' && item.severity >= 80).firstOrNull;
    final isLiquor = theme == '白酒';
    final confidence = hasRealtime && volatility < 1.15 && majorNegative == null ? '中' : '低';
    final todayState = todayPct > 0.35 ? '偏涨' : todayPct < -0.35 ? '偏跌' : '震荡';
    final tomorrowTrend = !hasRealtime && probabilityUp >= 52 ? '震荡，略偏强' : probabilityUp > 58 ? '偏强' : probabilityUp < 42 ? '偏弱' : '震荡';

    var buyRatio = 0.10;
    var sellRatio = confidence == '低' ? 0.10 : 0.05;
    var action = '观望为主';
    if (isLiquor && confidence == '低') {
      action = '观望，不追涨';
      buyRatio = 0.05;
      sellRatio = majorNegative == null ? 0.10 : 0.15;
    } else if (probabilityUp > 62 && majorNegative == null) {
      action = '小额分批买';
      buyRatio = 0.12;
      sellRatio = 0;
    } else if (probabilityUp < 43 || majorNegative != null) {
      action = '不急买，仓位重可减';
      buyRatio = 0;
      sellRatio = 0.15;
    }

    final todayReason = [
      '今天是 ${todayDateString()}，最新正式净值公布到 ${last.date}。',
      '市场状态：${market.label}，主要指数均值 ${pct(market.averageChange)}。',
      hasRealtime ? '重仓股估算贡献 ${pct(contribution)}。' : '重仓实时行情未接入，用最新净值涨跌和短期动量估算。',
      '近5日 ${pct(last5)}，90日回撤 ${pct(drawdown)}。',
      if (majorNegative != null) '${majorNegative.stockName} 有重大负面公告：${majorNegative.title}。',
    ].join('');

    final actionReason = [
      '买入按计划新增仓位计算，卖出按当前该基金持仓计算。',
      '明日上涨概率约 ${probabilityUp.toStringAsFixed(0)}%，置信度 $confidence。',
      if (isLiquor) '白酒处在修复波动期，重点看消费情绪、估值和龙头公告。',
      if (majorNegative != null) '重大负面公告出现后，短期情绪可能被压制。',
    ].join('');

    return FundAnalysis(
      code: fund.code,
      name: fund.name,
      theme: theme.isEmpty ? '主题待确认' : theme,
      analysisDate: todayDateString(),
      latestDate: last.date,
      latestValue: last.value,
      todayPct: todayPct,
      todayState: todayState,
      tomorrowTrend: tomorrowTrend,
      probabilityUp: probabilityUp,
      action: action,
      buyRatio: buyRatio,
      sellRatio: sellRatio,
      confidence: confidence,
      todayReason: todayReason,
      actionReason: actionReason,
      summaryLine: '$todayState · 明天$tomorrowTrend · $action',
      holdings: holdings,
      announcements: announcements,
      liquorSpecial: isLiquor
          ? '估值位置：${drawdown < -15 ? '中偏低' : '中'}；龙头业绩：${majorNegative == null ? '关注茅台、五粮液、泸州老窖经营数据' : '五粮液管理层公告偏负面'}；消费情绪：${last20 > 0 ? '中性修复' : '偏弱'}；节假日效应：${holidayEffect()}；机构拥挤度：${volatility > 1.4 ? '中高' : '中'}。'
          : null,
    );
  }
}

class PortfolioItem {
  PortfolioItem({required this.code, required this.amount});

  final String code;
  final double amount;

  factory PortfolioItem.fromJson(Map<String, dynamic> json) => PortfolioItem(
        code: json['code'].toString(),
        amount: toDouble(json['amount']),
      );

  Map<String, dynamic> toJson() => {'code': code, 'amount': amount};
}

class PortfolioSummary {
  PortfolioSummary({required this.amount, required this.todayIncome});

  final double amount;
  final double todayIncome;
}

class FundBase {
  FundBase({required this.code, required this.name, required this.points});

  final String code;
  final String name;
  final List<NavPoint> points;
}

class NavPoint {
  NavPoint({required this.date, required this.value, this.equityReturn});

  final String date;
  final double value;
  final double? equityReturn;
}

class StockHolding {
  StockHolding({
    required this.code,
    required this.name,
    required this.industry,
    required this.holdingPct,
    this.changePct,
    this.contributionPct,
  });

  final String code;
  final String name;
  final String industry;
  final double holdingPct;
  final double? changePct;
  final double? contributionPct;

  StockHolding copyWith({String? industry, double? changePct, double? contributionPct}) {
    return StockHolding(
      code: code,
      name: name,
      industry: industry ?? this.industry,
      holdingPct: holdingPct,
      changePct: changePct ?? this.changePct,
      contributionPct: contributionPct ?? this.contributionPct,
    );
  }
}

class Announcement {
  Announcement({
    required this.title,
    required this.stockName,
    required this.sentiment,
    required this.category,
    required this.reason,
    required this.severity,
    required this.rank,
  });

  final String title;
  final String stockName;
  final String sentiment;
  final String category;
  final String reason;
  final int severity;
  final int rank;
}

class MarketSnapshot {
  MarketSnapshot({required this.label, required this.averageChange});

  final String label;
  final double averageChange;
}

class FundAnalysis {
  FundAnalysis({
    required this.code,
    required this.name,
    required this.theme,
    required this.analysisDate,
    required this.latestDate,
    required this.latestValue,
    required this.todayPct,
    required this.todayState,
    required this.tomorrowTrend,
    required this.probabilityUp,
    required this.action,
    required this.buyRatio,
    required this.sellRatio,
    required this.confidence,
    required this.todayReason,
    required this.actionReason,
    required this.summaryLine,
    required this.holdings,
    required this.announcements,
    required this.liquorSpecial,
  });

  final String code;
  final String name;
  final String theme;
  final String analysisDate;
  final String latestDate;
  final double latestValue;
  final double todayPct;
  final String todayState;
  final String tomorrowTrend;
  final double probabilityUp;
  final String action;
  final double buyRatio;
  final double sellRatio;
  final String confidence;
  final String todayReason;
  final String actionReason;
  final String summaryLine;
  final List<StockHolding> holdings;
  final List<Announcement> announcements;
  final String? liquorSpecial;
}

class AppColors {
  static const bg = Color(0xFFF5F7FB);
  static const ink = Color(0xFF171821);
  static const muted = Color(0xFF707684);
  static const line = Color(0xFFE1E6EF);
  static const blue = Color(0xFF0A84FF);
  static const softBlue = Color(0xFFEAF4FF);
  static const softGrey = Color(0xFFF7F8FB);
  static const red = Color(0xFFD33829);
  static const green = Color(0xFF248A3D);
}

class AppShadows {
  static const card = [
    BoxShadow(color: Color(0x101C2333), blurRadius: 26, offset: Offset(0, 12)),
  ];
}

BoxDecoration inputDecoration() {
  return BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: AppColors.line),
  );
}

Announcement classifyAnnouncement(Map<String, dynamic> row, StockHolding holding) {
  final title = (row['title_ch'] ?? row['title'] ?? '').toString();
  final majorNegative = RegExp(r'留置|纪律审查|监察调查|立案|被查|处罚|刑事|失联|违规|风险提示|退市|违约').hasMatch(title);
  final managerRisk = RegExp(r'(董事长|总经理|实控人|控股股东|核心管理层|高管).*(留置|调查|被查|处罚)|(?:留置|调查|被查|处罚).*(董事长|总经理|实控人|控股股东|高管)').hasMatch(title);
  final report = RegExp(r'季度报告|年度报告|半年度报告|经营数据|业绩|财务|利润|营收').hasMatch(title);
  final investor = RegExp(r'投资者关系活动记录表|调研活动|业绩说明会').hasMatch(title);
  final routine = RegExp(r'独立董事述职|信息披露制度|关联交易预计|日常关联交易|内部控制|董事会决议|监事会决议|股东大会|章程|实施细则').hasMatch(title);
  final positive = RegExp(r'增长|预增|回购|增持|分红|超预期|创新高|提价|盈利').hasMatch(title);

  if (majorNegative || managerRisk) {
    return Announcement(
      title: title,
      stockName: holding.name,
      sentiment: '负面',
      category: '重大负面',
      severity: managerRisk ? 95 : 88,
      rank: 1,
      reason: '核心管理层或公司治理重大风险事件，可能影响短期情绪和估值。',
    );
  }
  if (positive) {
    return Announcement(title: title, stockName: holding.name, sentiment: '正面', category: '重大正面', severity: 82, rank: 2, reason: '可能改善短期情绪，但要看股价是否提前反映。');
  }
  if (report) {
    return Announcement(title: title, stockName: holding.name, sentiment: '经营数据', category: '财报/经营数据', severity: 70, rank: 3, reason: '直接影响龙头业绩预期，是基金判断的重要数据。');
  }
  if (investor) {
    return Announcement(title: title, stockName: holding.name, sentiment: '中性', category: '调研/投资者关系', severity: 46, rank: 5, reason: '可作为经营口径和机构关注度参考，通常不是强预警。');
  }
  if (routine) {
    return Announcement(title: title, stockName: holding.name, sentiment: '例行', category: '例行公告', severity: 28, rank: 9, reason: '例行披露，通常不直接改变基金短期判断。');
  }
  return Announcement(title: title, stockName: holding.name, sentiment: '中性', category: '普通公告', severity: 45, rank: 6, reason: '相关公告，等待行情验证。');
}

List<StockHolding> applyThemeFallback(List<StockHolding> holdings, String theme) {
  if (theme.isEmpty) return holdings;
  return holdings.map((item) {
    final industry = item.industry;
    if (industry == '未知' || industry == 'undefined' || industry == '行业暂缺' || industry.isEmpty) {
      return item.copyWith(industry: theme);
    }
    return item;
  }).toList();
}

String inferTheme(String name) {
  if (RegExp(r'白酒|酒').hasMatch(name)) return '白酒';
  if (RegExp(r'医药|医疗|生物').hasMatch(name)) return '医药';
  if (RegExp(r'半导体|芯片').hasMatch(name)) return '半导体';
  if (RegExp(r'新能源|电池|光伏|电力设备').hasMatch(name)) return '新能源';
  if (RegExp(r'军工').hasMatch(name)) return '军工';
  return '';
}

String normalizeIndustry(String value, {required String fallback}) {
  if (value.isEmpty || value == '未知' || value == 'undefined') return fallback;
  return value;
}

String marketFromCode(String code) => RegExp(r'^[569]').hasMatch(code) ? '1' : '0';

String stripTags(String value) {
  return value.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&').trim();
}

double toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString().replaceAll(',', '') ?? '') ?? 0;
}

double? toNullableDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().replaceAll(',', ''));
}

String dateFromMillis(int millis) {
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String todayDateString() {
  final date = DateTime.now();
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

List<double> dailyReturns(List<NavPoint> points) {
  final rows = <double>[];
  for (var i = 1; i < points.length; i += 1) {
    final prev = points[i - 1].value;
    if (prev > 0) rows.add((points[i].value / prev - 1) * 100);
  }
  return rows;
}

List<double> recentReturns(List<NavPoint> points, int days) => dailyReturns(points).takeLast(days);

double std(List<double> values) {
  if (values.length < 2) return 0;
  final avg = values.averageOrZero;
  final variance = values.map((item) => pow(item - avg, 2)).reduce((a, b) => a + b) / values.length;
  return sqrt(variance);
}

double maxDrawdown(List<NavPoint> points) {
  var peak = 0.0;
  var worst = 0.0;
  for (final point in points) {
    peak = max(peak, point.value);
    if (peak > 0) worst = min(worst, point.value / peak - 1);
  }
  return worst;
}

String holidayEffect() {
  final month = DateTime.now().month;
  return {1, 2, 9, 10}.contains(month) ? '节假日前后，催化较强' : '非春节/中秋/国庆窗口，催化偏弱';
}

Color signalColor(String text) {
  if (text.contains('跌') || text.contains('弱')) return AppColors.green;
  if (text.contains('涨') || text.contains('强')) return AppColors.red;
  return AppColors.ink;
}

String money(double value) {
  final sign = value < 0 ? '-' : '';
  final fixed = value.abs().toStringAsFixed(2);
  final parts = fixed.split('.');
  final chars = parts[0].split('').reversed.toList();
  final groups = <String>[];
  for (var i = 0; i < chars.length; i += 3) {
    groups.add(chars.skip(i).take(3).toList().reversed.join());
  }
  return '$sign¥${groups.reversed.join(',')}.${parts[1]}';
}

String signedMoney(double value) => value >= 0 ? '+${money(value)}' : '-${money(value.abs())}';
String pct(double value) => '${value >= 0 ? '+' : ''}${value.toStringAsFixed(2)}%';

extension NumberListX on Iterable<double> {
  double get sum => fold(0, (a, b) => a + b);
  double get averageOrZero => isEmpty ? 0 : sum / length;
}

extension ListTakeLastX<T> on List<T> {
  List<T> takeLast(int count) => skip(max(0, length - count)).toList();
}

extension FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
