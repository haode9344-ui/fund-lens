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

class _PortfolioHomeState extends State<PortfolioHome> with WidgetsBindingObserver {
  final FundService _service = FundService();
  final Map<String, FundAnalysis> _cache = {};
  Timer? _autoRefreshTimer;
  List<PortfolioItem> _owned = [];
  List<PortfolioItem> _simulated = [];
  int _tab = 0;
  bool _loading = true;
  bool _refreshing = false;

  List<PortfolioItem> get _currentItems => _tab == 0 ? _owned : _simulated;
  String get _currentTitle => _tab == 0 ? '持有持仓' : '模拟持仓';
  String get _storageKey => _tab == 0 ? 'owned_portfolio' : 'simulated_portfolio';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPortfolios();
    _autoRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (shouldAutoRefreshData()) _refreshCurrent();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshCurrent();
  }

  Future<void> _loadPortfolios() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('portfolio_total_capital');
    setState(() {
      _owned = _decodePortfolio(prefs.getString('owned_portfolio'));
      _simulated = _decodePortfolio(prefs.getString('simulated_portfolio'));
      _loading = false;
    });
    await _refreshCurrent(clearFirst: true);
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

  Future<void> _refreshCurrent({bool clearFirst = false}) async {
    final items = List<PortfolioItem>.from(_currentItems);
    if (items.isEmpty) return;
    if (_refreshing) return;
    _refreshing = true;
    var changedItems = false;
    try {
      for (final item in items) {
        try {
          if (clearFirst && mounted) setState(() => _cache.remove(item.code));
          final analysis = await _service.load(item);
          if (!mounted) return;
          setState(() {
            _cache[item.code] = analysis;
            changedItems = _replaceCurrentItem(analysis.settledItem) || changedItems;
          });
        } catch (_) {
          // Keep the previous analysis visible when one data source is temporarily slow.
        }
      }
      if (changedItems) await _saveCurrent();
    } finally {
      _refreshing = false;
    }
  }

  bool _replaceCurrentItem(PortfolioItem item) {
    final target = _tab == 0 ? _owned : _simulated;
    final index = target.indexWhere((row) => row.code == item.code);
    if (index < 0) return false;
    if (jsonEncode(target[index].toJson()) == jsonEncode(item.toJson())) return false;
    target[index] = item;
    return true;
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

  Future<FundAnalysis> _updateFund(PortfolioItem updated) async {
    final target = _tab == 0 ? _owned : _simulated;
    final index = target.indexWhere((item) => item.code == updated.code);
    if (index >= 0) {
      setState(() => target[index] = updated);
      await _saveCurrent();
    }
    final fresh = await _service.load(updated);
    if (mounted) {
      setState(() {
        _cache[updated.code] = fresh;
        final index = target.indexWhere((item) => item.code == updated.code);
        if (index >= 0) target[index] = fresh.settledItem;
      });
      await _saveCurrent();
    }
    return fresh;
  }

  PortfolioSummary _summary() {
    double amount = 0;
    double income = 0;
    for (final item in _currentItems) {
      final analysis = _cache[item.code];
      final value = positionValue(item);
      amount += value;
      if (analysis != null) income += value * analysis.todayPct / 100;
    }
    return PortfolioSummary(amount: amount, todayIncome: income);
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary();
    return Scaffold(
      appBar: AppBar(
        title: const Text('小又', style: TextStyle(fontWeight: FontWeight.w900)),
        centerTitle: true,
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
          await _refreshCurrent(clearFirst: true);
        },
        destinations: const [
          NavigationDestination(icon: Icon(CupertinoIcons.briefcase), label: '持有'),
          NavigationDestination(icon: Icon(CupertinoIcons.chart_bar_square), label: '模拟'),
        ],
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : RefreshIndicator(
              onRefresh: () => _refreshCurrent(clearFirst: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                children: [
                  HeaderSummary(
                    title: _currentTitle,
                    totalAmount: summary.amount,
                    todayIncome: summary.todayIncome,
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
                                      onUpdateItem: _updateFund,
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
  });

  final String title;
  final double totalAmount;
  final double todayIncome;

  @override
  Widget build(BuildContext context) {
    final positive = todayIncome >= 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(18),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Row(
            children: [
              _SummaryChip(label: '持仓金额', value: money(totalAmount), positive: true),
              const SizedBox(width: 10),
              _SummaryChip(label: '今日估算', value: signedMoney(todayIncome), positive: positive),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: positive ? const Color(0xFFFF5A4F) : const Color(0xFF54C77A),
                fontSize: 16,
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
    final data = analysis;
    final currentValue = positionValue(item);
    final pending = item.pendingAmount;
    final todayIncome = data == null ? 0.0 : currentValue * data.todayPct / 100;
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
                        Text(data?.name ?? '基金 ${item.code}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 6),
                        Text(
                          data == null
                              ? '${item.code} · 分析中'
                              : '${item.code} · 今天 ${data.analysisDate} · ${data.realtimeStatus}',
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
                  Expanded(child: _Metric(label: '持有金额', value: money(currentValue))),
                  Expanded(
                    child: _Metric(
                      label: '今日变化',
                      value: data == null ? '分析中' : '${pct(data.todayPct)} / ${signedMoney(todayIncome)}',
                      color: positive ? AppColors.red : AppColors.green,
                    ),
                  ),
                ],
              ),
              if (pending > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '买入确认中：${money(pending)}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ],
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
                        data?.summaryLine ?? '正在读取净值、持仓和公告...',
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
    required this.onUpdateItem,
  });

  final PortfolioItem item;
  final FundAnalysis analysis;
  final Future<FundAnalysis> Function(PortfolioItem) onUpdateItem;

  @override
  State<FundDetailPage> createState() => _FundDetailPageState();
}

class _FundDetailPageState extends State<FundDetailPage> {
  late PortfolioItem _item = widget.item;
  late FundAnalysis _analysis = widget.analysis;

  Future<void> _refresh() async {
    final fresh = await widget.onUpdateItem(_item);
    if (mounted) {
      setState(() {
        _analysis = fresh;
        _item = fresh.settledItem;
      });
    }
  }


  @override
  Widget build(BuildContext context) {
    final currentValue = positionValue(_item);
    final buyAmount = currentValue * _analysis.buyRatio;
    final sellAmount = currentValue * _analysis.sellRatio;
    final reasonSide = actionReasonSide(_analysis.action, _analysis.buyRatio, _analysis.sellRatio);
    final showBuyReason = reasonSide == 'buy' && buyAmount > 0.01;
    final showSellReason = reasonSide == 'sell' && sellAmount > 0.01;
    final showBuyAmount = showBuyReason;
    final showSellAmount = showSellReason;
    final hasOperation = showBuyAmount || showSellAmount;
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
                      Expanded(
                        child: PredictionMetric(
                          label: '今天',
                          locked: _analysis.todayLockedAt.isNotEmpty,
                          value: _analysis.todayState,
                          color: signalColor(_analysis.todayState),
                        ),
                      ),
                      Expanded(
                        child: PredictionMetric(
                          label: '明天',
                          locked: _analysis.tomorrowLockedAt.isNotEmpty,
                          value: _analysis.tomorrowTrend,
                          color: signalColor(_analysis.tomorrowTrend),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(child: _Metric(label: '持有金额', value: money(currentValue))),
                      Expanded(
                        child: _Metric(
                          label: '今日涨跌',
                          value: pct(_analysis.todayPct),
                          color: _analysis.todayPct > 0
                              ? AppColors.red
                              : _analysis.todayPct < 0
                                  ? AppColors.green
                                  : AppColors.ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(child: _Metric(label: '净值/估值', value: _analysis.realtimeNavText)),
                      Expanded(child: _Metric(label: _analysis.updateMetricLabel, value: _analysis.updateMetricValue)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  FeeWindowSummaryCard(item: _analysis.settledItem, latestNav: _analysis.latestValue),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_analysis.intradayPoints.isNotEmpty) ...[
              IntradayChartCard(
                points: _analysis.intradayPoints,
                note: _analysis.intradayNote,
                fallbackPct: _analysis.todayPct,
              ),
              const SizedBox(height: 12),
            ],
            CardShell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('今天怎么做', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(_analysis.action, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  if (hasOperation)
                    Row(
                      children: [
                        if (showBuyAmount) Expanded(child: _Metric(label: '建议买入', value: money(buyAmount), color: AppColors.red)),
                        if (showBuyAmount && showSellAmount) const SizedBox(width: 12),
                        if (showSellAmount) Expanded(child: _Metric(label: '建议卖出', value: money(sellAmount), color: AppColors.green)),
                      ],
                    )
                  else
                    const Text('今天先观望，等更清楚的盘面信号。', style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _Metric(label: '后面几天', value: _analysis.futureDaysText)),
                      const SizedBox(width: 12),
                      Expanded(child: _Metric(label: '波动大小', value: _analysis.volatilityText)),
                      const SizedBox(width: 12),
                      Expanded(child: _Metric(label: '下跌风险', value: _analysis.downsideRiskText)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  GuideBox(title: '新手结论', text: _analysis.actionReason),
                  if (showBuyReason) ...[
                    const SizedBox(height: 12),
                    ReasonBox(title: '买入原因', text: _analysis.buyReason, color: AppColors.red),
                  ],
                  if (showSellReason) ...[
                    const SizedBox(height: 12),
                    ReasonBox(title: '卖出原因', text: _analysis.sellReason, color: AppColors.green),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            BeginnerSummaryCard(analysis: _analysis),
            const SizedBox(height: 12),
            DecisionModelCard(decision: _analysis.decision),
            const SizedBox(height: 12),
            GridBattlePlanCard(plan: _analysis.battlePlan),
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
                  const Text('前十大重仓股', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  if (_analysis.holdingSourceText.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(_analysis.holdingSourceText, style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w800)),
                  ],
                  const SizedBox(height: 12),
                  if (_analysis.holdings.isEmpty)
                    const Text('暂时还没拿到最新的前十大重仓股，下拉刷新后会再试一次。', style: TextStyle(color: AppColors.muted, height: 1.45, fontWeight: FontWeight.w700))
                  else
                    ..._analysis.holdings.take(10).map((item) => StockHoldingRow(item: item)),
                  if (_analysis.announcements.isNotEmpty) ...[
                    const Divider(height: 28),
                    const Text('高影响公告', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 10),
                    ..._analysis.announcements.take(3).map((item) => AnnouncementTile(item: item)),
                  ],
                ],
              ),
            ),
            if (_analysis.yesterdayReview != null) ...[
              const SizedBox(height: 12),
              YesterdayReviewCard(review: _analysis.yesterdayReview!),
            ],
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
    Navigator.pop(
      context,
      PortfolioItem(
        code: code,
        amount: amount,
        untrackedAmount: widget.title == '持有持仓' ? amount : 0,
      ),
    );
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
        child: SingleChildScrollView(
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
      ),
    );
  }
}

class AddBuySheet extends StatefulWidget {
  const AddBuySheet({super.key});

  @override
  State<AddBuySheet> createState() => _AddBuySheetState();
}

class _AddBuySheetState extends State<AddBuySheet> {
  final TextEditingController _amountController = TextEditingController();
  late bool _beforeCutoff;

  @override
  void initState() {
    super.initState();
    _beforeCutoff = pendingOrderPlan(DateTime.now()).beforeCutoff;
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = double.tryParse(_amountController.text.trim()) ?? 0;
    if (amount <= 0) return;
    Navigator.pop(context, AddBuyDraft(amount: amount, beforeCutoff: _beforeCutoff));
  }

  @override
  Widget build(BuildContext context) {
    final order = pendingOrderPlan(DateTime.now(), beforeCutoffOverride: _beforeCutoff);
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
            const Text('加仓', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            const Text('买入时点', style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            CupertinoSlidingSegmentedControl<bool>(
              groupValue: _beforeCutoff,
              children: const {
                true: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text('15点前买入', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
                false: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text('15点后买入', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              },
              onValueChanged: (value) {
                if (value == null) return;
                setState(() => _beforeCutoff = value);
              },
            ),
            const SizedBox(height: 12),
            Text(order.note, style: const TextStyle(color: AppColors.muted, height: 1.45, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            CupertinoTextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              placeholder: '加仓金额',
              padding: const EdgeInsets.all(15),
              decoration: inputDecoration(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(CupertinoIcons.checkmark_circle),
                label: const Text('加入确认中'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PendingBuySummary extends StatelessWidget {
  const PendingBuySummary({super.key, required this.item});

  final PortfolioItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.softBlue,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD8E9FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('买入确认中：${money(item.pendingAmount)}', style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          ...item.pendingBuys.take(3).map(
                (order) => Text(
                  '${money(order.amount)} · ${order.beforeCutoff ? '15点前买入' : '15点后买入'} · ${order.confirmDate} 确认',
                  style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4, fontWeight: FontWeight.w700),
                ),
              ),
        ],
      ),
    );
  }
}

class FeeWindowSummaryCard extends StatelessWidget {
  const FeeWindowSummaryCard({super.key, required this.item, required this.latestNav});

  final PortfolioItem item;
  final double latestNav;

  @override
  Widget build(BuildContext context) {
    final snapshot = buildFeeWindowSnapshot(item, latestNav);
    if (snapshot.tone == 'warn' && item.untrackedAmount > 0) return const SizedBox.shrink();
    final tone = snapshot.tone;
    final icon = tone == 'good'
        ? CupertinoIcons.check_mark_circled_solid
        : tone == 'bad'
            ? CupertinoIcons.exclamationmark_triangle_fill
            : CupertinoIcons.info_circle;
    final textColor = tone == 'good'
        ? const Color(0xFF2EB45F)
        : tone == 'bad'
            ? AppColors.green
            : AppColors.muted;
    final detail = tone == 'warn' ? '' : snapshot.detail;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 14, color: textColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  snapshot.headline,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: tone == 'warn' ? FontWeight.w700 : FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              detail,
              style: const TextStyle(color: AppColors.muted, fontSize: 11, height: 1.4, fontWeight: FontWeight.w700),
            ),
          ],
        ],
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

class PredictionMetric extends StatelessWidget {
  const PredictionMetric({
    super.key,
    required this.label,
    required this.locked,
    required this.value,
    required this.color,
  });

  final String label;
  final bool locked;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final visual = forecastVisual(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(height: 5),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(visual.icon, size: 18, color: visual.color),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          value,
                          style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w900),
                        ),
                      ),
                      if (locked) ...[
                        const SizedBox(width: 5),
                        const Icon(CupertinoIcons.lock, size: 13, color: AppColors.muted),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    visual.subtitle,
                    style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w700, height: 1.3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class ReasonBox extends StatelessWidget {
  const ReasonBox({super.key, required this.title, required this.text, required this.color});

  final String title;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          Text(text, style: const TextStyle(color: AppColors.ink, height: 1.42, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class IntradayChartCard extends StatefulWidget {
  const IntradayChartCard({
    super.key,
    required this.points,
    required this.note,
    required this.fallbackPct,
  });

  final List<IntradayPoint> points;
  final String note;
  final double fallbackPct;

  @override
  State<IntradayChartCard> createState() => _IntradayChartCardState();
}

class _IntradayChartCardState extends State<IntradayChartCard> {
  IntradayPoint? _selected;

  void _select(Offset local, Size size) {
    if (widget.points.isEmpty) return;
    final plot = chartPlotRect(size);
    final targetMinute = (((local.dx - plot.left) / plot.width).clamp(0.0, 1.0) * 240).toDouble();
    IntradayPoint? best;
    var distance = double.infinity;
    for (final point in widget.points) {
      final diff = (tradingMinute(point.time).toDouble() - targetMinute).abs();
      if (diff < distance) {
        distance = diff;
        best = point;
      }
    }
    setState(() => _selected = best);
  }

  @override
  Widget build(BuildContext context) {
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('当日分时走势', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, 230);
              return GestureDetector(
                onLongPressStart: (details) => _select(details.localPosition, size),
                onLongPressMoveUpdate: (details) => _select(details.localPosition, size),
                onLongPressEnd: (_) => setState(() => _selected = null),
                child: SizedBox(
                  width: double.infinity,
                  height: size.height,
                  child: CustomPaint(
                    painter: IntradayChartPainter(
                      points: widget.points,
                      selected: _selected,
                      fallbackPct: widget.fallbackPct,
                    ),
                    size: size,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class IntradayChartPainter extends CustomPainter {
  IntradayChartPainter({required this.points, required this.selected, required this.fallbackPct});

  final List<IntradayPoint> points;
  final IntradayPoint? selected;
  final double fallbackPct;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = chartPlotRect(size);
    final axisMax = chartAxisMax(points, fallbackPct);
    final zeroY = plot.center.dy;
    final gridPaint = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1;
    final labelStyle = const TextStyle(color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w700);

    canvas.drawLine(Offset(plot.left, plot.top), Offset(plot.right, plot.top), gridPaint);
    canvas.drawLine(Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom), gridPaint);
    _drawDashedLine(canvas, Offset(plot.left, zeroY), Offset(plot.right, zeroY), Paint()..color = const Color(0xFFB8C0CC)..strokeWidth = 1);

    _drawLabel(canvas, pct(axisMax), Offset(0, plot.top - 7), labelStyle, TextAlign.left);
    _drawLabel(canvas, '0%', Offset(0, zeroY - 7), labelStyle, TextAlign.left);
    _drawLabel(canvas, pct(-axisMax), Offset(0, plot.bottom - 7), labelStyle, TextAlign.left);
    _drawLabel(canvas, '09:30', Offset(plot.left - 2, plot.bottom + 9), labelStyle, TextAlign.left);
    _drawLabel(canvas, '11:30/13:00', Offset(plot.center.dx - 34, plot.bottom + 9), labelStyle, TextAlign.left);
    _drawLabel(canvas, '15:00', Offset(plot.right - 28, plot.bottom + 9), labelStyle, TextAlign.left);

    if (points.isEmpty) return;

    final fillPath = Path();
    for (var i = 0; i < points.length; i += 1) {
      final point = points[i];
      final offset = Offset(chartX(point, plot), chartY(point.changePct, plot, axisMax));
      if (i == 0) {
        fillPath.moveTo(offset.dx, zeroY);
        fillPath.lineTo(offset.dx, offset.dy);
      } else {
        fillPath.lineTo(offset.dx, offset.dy);
      }
    }
    fillPath.lineTo(chartX(points.last, plot), zeroY);
    fillPath.close();

    final positive = points.last.changePct >= 0;
    final mainColor = positive ? const Color(0xFFF44336) : AppColors.green;
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [mainColor.withOpacity(0.22), mainColor.withOpacity(0.02)],
      ).createShader(plot);
    canvas.drawPath(fillPath, fillPaint);

    for (var i = 1; i < points.length; i += 1) {
      final previous = points[i - 1];
      final current = points[i];
      final color = current.changePct >= 0 ? const Color(0xFFF44336) : AppColors.green;
      canvas.drawLine(
        Offset(chartX(previous, plot), chartY(previous.changePct, plot, axisMax)),
        Offset(chartX(current, plot), chartY(current.changePct, plot, axisMax)),
        Paint()
          ..color = color
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.butt,
      );
    }

    final target = selected;
    if (target != null) {
      final x = chartX(target, plot);
      final y = chartY(target.changePct, plot, axisMax);
      final guide = Paint()
        ..color = AppColors.ink.withOpacity(0.18)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), guide);
      canvas.drawCircle(Offset(x, y), 5.5, Paint()..color = Colors.white);
      canvas.drawCircle(Offset(x, y), 4, Paint()..color = target.changePct >= 0 ? const Color(0xFFF44336) : AppColors.green);

      final tooltip = '${formatClock(target.time)}  ${target.estimatedNav.toStringAsFixed(4)}  ${pct(target.changePct)}';
      _drawTooltip(canvas, tooltip, Offset(x, max(plot.top + 8, y - 38)), plot);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dash = 6.0;
    const gap = 5.0;
    var x = start.dx;
    while (x < end.dx) {
      canvas.drawLine(Offset(x, start.dy), Offset(min(x + dash, end.dx), end.dy), paint);
      x += dash + gap;
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset offset, TextStyle style, TextAlign align) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout();
    painter.paint(canvas, offset);
  }

  void _drawTooltip(Canvas canvas, String text, Offset anchor, Rect plot) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900)),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width + 18;
    final left = (anchor.dx - width / 2).clamp(plot.left, plot.right - width);
    final rect = RRect.fromRectAndRadius(Rect.fromLTWH(left, anchor.dy, width, painter.height + 12), const Radius.circular(10));
    canvas.drawRRect(rect, Paint()..color = AppColors.ink.withOpacity(0.92));
    painter.paint(canvas, Offset(left + 9, anchor.dy + 6));
  }

  @override
  bool shouldRepaint(covariant IntradayChartPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.selected != selected || oldDelegate.fallbackPct != fallbackPct;
  }
}

class DecisionModelCard extends StatelessWidget {
  const DecisionModelCard({super.key, required this.decision});

  final DecisionModel decision;

  @override
  Widget build(BuildContext context) {
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('14:45 推演 · 14:50 决策', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
            ],
          ),
          const SizedBox(height: 4),
          Text(decision.confidence, style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          TrendThermometer(score: decision.temperatureScore, label: decision.temperatureLabel),
          const SizedBox(height: 10),
          Text(decision.summary, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, height: 1.35)),
          const SizedBox(height: 12),
          _DecisionRow(label: '大盘背景', value: compactDecisionText('外围背景', decision.macroState, decision.macroTone), tone: decision.macroTone),
          _DecisionRow(label: '板块资金', value: compactDecisionText('板块资金', decision.valuationState, decision.valuationTone), tone: decision.valuationTone),
          _DecisionRow(label: '尾盘动向', value: compactDecisionText('尾盘动向', decision.trendState, decision.trendTone), tone: decision.trendTone),
          _DecisionRow(label: '聪明资金', value: compactDecisionText('聪明资金', decision.smartMoneyState, decision.smartMoneyTone), tone: decision.smartMoneyTone),
          _DecisionRow(label: 'ETF折溢价', value: compactDecisionText('ETF折溢价', decision.etfPricingState, decision.etfPricingTone), tone: decision.etfPricingTone),
          _DecisionRow(label: '量价状态', value: compactDecisionText('量价状态', decision.costDeviationText, decision.deviationTone), tone: decision.deviationTone),
          _DecisionRow(label: '趋势位置', value: compactDecisionText('趋势共振', decision.resonanceState, decision.resonanceTone), tone: decision.resonanceTone),
          _DecisionRow(label: '后面几天', value: compactDecisionText('后面几天', decision.durationState, decision.durationTone), tone: decision.durationTone),
          _DecisionRow(label: 'T+7', value: compactDecisionText('T+7 安全垫', decision.holdingCycleState, decision.holdingCycleTone), tone: decision.holdingCycleTone),
        ],
      ),
    );
  }
}

class YesterdayReviewCard extends StatelessWidget {
  const YesterdayReviewCard({super.key, required this.review});

  final YesterdayReview review;

  @override
  Widget build(BuildContext context) {
    final color = review.success == null
        ? AppColors.blue
        : review.success!
            ? AppColors.green
            : AppColors.red;
    final icon = review.success == null
        ? CupertinoIcons.clock
        : review.success!
            ? CupertinoIcons.check_mark_circled_solid
            : CupertinoIcons.exclamationmark_triangle_fill;
    final reasonLabel = review.success == null
        ? '复盘状态'
        : review.success!
            ? '命中原因'
            : '失误原因';
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  review.headline,
                  style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            review.detail,
            style: const TextStyle(color: AppColors.ink, height: 1.45, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          _ReviewLine(label: reasonLabel, text: review.diagnosis),
          const SizedBox(height: 8),
          _ReviewLine(label: '学习改进', text: review.nextAdjustment),
        ],
      ),
    );
  }
}

class GuideBox extends StatelessWidget {
  const GuideBox({super.key, required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.softGrey,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(
            text,
            style: const TextStyle(color: AppColors.ink, height: 1.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class BeginnerSummaryCard extends StatelessWidget {
  const BeginnerSummaryCard({super.key, required this.analysis});

  final FundAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final actionText = beginnerActionText(analysis);
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('新手看这里', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _BeginnerPill(label: '今天', value: analysis.todayState, tone: toneFromDirectionText(analysis.todayState))),
              const SizedBox(width: 10),
              Expanded(child: _BeginnerPill(label: '明天', value: analysis.tomorrowTrend, tone: toneFromDirectionText(analysis.tomorrowTrend))),
              const SizedBox(width: 10),
              Expanded(child: _BeginnerPill(label: '风险', value: analysis.downsideRiskText, tone: analysis.downsideRiskText == '高' ? 'bad' : analysis.downsideRiskText == '低' ? 'good' : 'warn')),
            ],
          ),
          const SizedBox(height: 12),
          Text(actionText, style: const TextStyle(color: AppColors.ink, height: 1.5, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SignalBadge(label: 'ETF折溢价', tone: analysis.decision.etfPricingTone),
              _SignalBadge(label: '板块资金', tone: analysis.decision.valuationTone),
              _SignalBadge(label: '尾盘资金', tone: analysis.decision.trendTone),
              _SignalBadge(label: '公告事件', tone: analysis.decision.smartMoneyTone),
              _SignalBadge(label: 'T+7', tone: analysis.decision.holdingCycleTone),
            ],
          ),
        ],
      ),
    );
  }
}

class _BeginnerPill extends StatelessWidget {
  const _BeginnerPill({required this.label, required this.value, required this.tone});

  final String label;
  final String value;
  final String tone;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class _SignalBadge extends StatelessWidget {
  const _SignalBadge({required this.label, required this.tone});

  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(tone);
    final icon = toneIcon(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.softGrey,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(color: AppColors.ink, fontSize: 12, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class _ReviewLine extends StatelessWidget {
  const _ReviewLine({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w900)),
        ),
        Expanded(child: Text(text, style: const TextStyle(color: AppColors.ink, height: 1.42, fontWeight: FontWeight.w800))),
      ],
    );
  }
}

class GridBattlePlanCard extends StatelessWidget {
  const GridBattlePlanCard({super.key, required this.plan});

  final GridBattlePlan plan;

  @override
  Widget build(BuildContext context) {
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('持仓网格战区图', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          _BattleRow(icon: CupertinoIcons.arrow_up_circle_fill, color: AppColors.red, label: '向上压力位', value: plan.upperTrigger, note: plan.upperAction),
          const SizedBox(height: 10),
          _BattleRow(icon: CupertinoIcons.scope, color: AppColors.blue, label: '当前净值', value: plan.currentValue, note: plan.currentZone),
          const SizedBox(height: 10),
          _BattleRow(icon: CupertinoIcons.arrow_down_circle_fill, color: AppColors.green, label: '向下支撑位', value: plan.lowerTrigger, note: plan.lowerAction),
        ],
      ),
    );
  }
}

class _BattleRow extends StatelessWidget {
  const _BattleRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.note,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$label：$value', style: const TextStyle(fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text(note, style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ],
    );
  }
}

class TrendThermometer extends StatelessWidget {
  const TrendThermometer({super.key, required this.score, required this.label});

  final int score;
  final String label;

  @override
  Widget build(BuildContext context) {
    final normalized = ((score + 100) / 200).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('明天风险温度', style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w800)),
            ),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final knobLeft = max(0.0, min(constraints.maxWidth - 16, constraints.maxWidth * normalized - 8));
            return SizedBox(
              height: 20,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    height: 12,
                    margin: const EdgeInsets.only(top: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF3B82F6), Color(0xFFE5E7EB), Color(0xFFF44336)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: knobLeft,
                    top: 0,
                    child: Container(
                      width: 16,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppColors.ink, width: 1.2),
                        boxShadow: AppShadows.card,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _DecisionRow extends StatelessWidget {
  const _DecisionRow({required this.label, required this.value, required this.tone});

  final String label;
  final String value;
  final String tone;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(tone);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(label, style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w800)),
          ),
          Icon(toneIcon(tone), color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w900, height: 1.35))),
        ],
      ),
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
          Text('${item.stockName} · ${item.title}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, height: 1.35)),
          const SizedBox(height: 5),
          Text(item.reason, style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.45, fontWeight: FontWeight.w700)),
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
    final flow = item.mainFlow == null ? '资金等待' : flowDirectionText(item.mainFlow, item.mainFlowPct);
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
                const SizedBox(height: 3),
                Text(flow, style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w700)),
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

  Future<FundAnalysis> load(PortfolioItem item, {double totalCapital = 0}) async {
    final code = item.code;
    final fund = await _loadFundBase(code);
    final theme = inferTheme(fund.name);
    final overnightFuture = _loadOvernightSignal(theme);
    final marketBreadthFuture = _loadMarketBreadthSignal();
    final settledItem = settlePortfolioItem(item, fund);
    final realtime = await _loadRealtimeEstimate(code);
    final intraday = await _loadIntradayTrend(code, fund, theme, realtime, fund.points.last.value);
    final holdingCode = holdingsLookupCode(fund);
    final etfPricingFuture = _loadEtfPricingSignal(fund, holdingCode);
    final rawHoldings = await _loadHoldings(holdingCode);
    final holdingSourceText = holdingCode == code ? '' : '该基金为联接基金，此处展示底层目标 ETF $holdingCode 最近披露的核心重仓股。';
    final holdings = await _enrichHoldings(rawHoldings);
    final tailSignalsFuture = _loadStockTailSignals(holdings);
    final announcementsFuture = _loadAnnouncements(holdings.take(8).toList());
    final marketBaseFuture = _loadMarket(fund, theme, holdings);
    final smartMoneyFuture = _loadSmartMoneySignal(theme, holdings);
    final tailSignals = await tailSignalsFuture;
    final announcements = await announcementsFuture;
    final marketBase = await marketBaseFuture;
    final smartMoney = await smartMoneyFuture;
    final overnight = await overnightFuture;
    final etfPricing = await etfPricingFuture;
    final marketBreadth = await marketBreadthFuture;
    final market = MarketSnapshot(
      label: marketBase.label,
      averageChange: marketBase.averageChange,
      board: marketBase.board,
      etfPricing: etfPricing,
      overnight: overnight,
      marketBreadth: marketBreadth,
    );
    final draft = _analyze(
      fund,
      holdings,
      announcements,
      market,
      smartMoney,
      theme,
      realtime,
      intraday,
      tailSignals,
      settledItem,
      holdingSourceText,
      totalCapital,
    );
    final yesterdayReview = await _loadYesterdayReview(code, draft.todayPct);
    final live = yesterdayReview == null
        ? draft
        : _analyze(
            fund,
            holdings,
            announcements,
            market,
            smartMoney,
            theme,
            realtime,
            intraday,
            tailSignals,
            settledItem,
            holdingSourceText,
            totalCapital,
            yesterdayReview: yesterdayReview,
          );
    return _applyLocks(code, live.copyWith(yesterdayReview: yesterdayReview));
  }

  Future<FundBase> _loadFundBase(String code) async {
    final uri = Uri.parse('https://fund.eastmoney.com/pingzhongdata/$code.js?v=${DateTime.now().millisecondsSinceEpoch}');
    final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 18));
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

  Future<RealtimeEstimate?> _loadRealtimeEstimate(String code) async {
    final uri = Uri.parse('http://fundgz.1234567.com.cn/js/$code.js?rt=${DateTime.now().millisecondsSinceEpoch}');
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final raw = utf8.decode(response.bodyBytes, allowMalformed: true);
      final jsonText = RegExp(r'jsonpgz\((\{.*\})\);?', dotAll: true).firstMatch(raw)?.group(1);
      if (jsonText == null) return null;
      final payload = jsonDecode(jsonText) as Map<String, dynamic>;
      final estimatedNav = toDouble(payload['gsz']);
      if (estimatedNav <= 0) return null;
      return RealtimeEstimate(
        fundCode: (payload['fundcode'] ?? code).toString(),
        navDate: (payload['jzrq'] ?? '').toString(),
        officialNav: toDouble(payload['dwjz']),
        estimatedNav: estimatedNav,
        estimatePct: toDouble(payload['gszzl']),
        updateTime: (payload['gztime'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<IntradaySeries> _loadIntradayTrend(String code, FundBase fund, String theme, RealtimeEstimate? realtime, double fallbackNav) async {
    if (shouldUseProxyIntraday(fund)) {
      return await _loadProxyIntradayTrend(fund, theme, realtime, fallbackNav) ?? IntradaySeries(points: const [], note: '');
    }
    final endpoints = [
      Uri.https('fundcomapi.tiantianfunds.com', '/mm/fundTrade/FundValuationDetail', {
        'FCODE': code,
        'rt': DateTime.now().millisecondsSinceEpoch.toString(),
      }),
    ];
    for (final uri in endpoints) {
      try {
        final response = await _client.get(uri, headers: noCacheHeaders(const {'Referer': 'https://fund.eastmoney.com/'})).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) continue;
        final raw = utf8.decode(response.bodyBytes, allowMalformed: true);
        final jsonText = extractJsonLike(raw);
        if (jsonText == null) continue;
        final payload = decodeNestedFundPayload(jsonDecode(jsonText));
        final points = _parseIntradayPayload(payload, realtime, fallbackNav);
        final minimum = minimumMinutePointCount();
        if (points.length >= minimum || (points.length >= 30 && !isTradingTime())) {
          return IntradaySeries(points: points, note: '');
        }
      } catch (_) {
        continue;
      }
    }
    return await _loadProxyIntradayTrend(fund, theme, realtime, fallbackNav) ?? IntradaySeries(points: const [], note: '');
  }

  Future<IntradaySeries?> _loadProxyIntradayTrend(FundBase fund, String theme, RealtimeEstimate? realtime, double fallbackNav) async {
    final targets = intradayProxyTargets(fund);
    void addTarget(IntradayProxyTarget target) {
      if (!targets.any((item) => item.secid == target.secid)) targets.add(target);
    }

    try {
      final board = await _loadThemeBoard(theme);
      if (board != null && (board.code?.isNotEmpty ?? false)) {
        addTarget(IntradayProxyTarget(secid: '90.${board.code}', name: board.name));
      }
    } catch (_) {}

    for (final target in targets) {
      final uri = Uri.parse(
        'https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=${target.secid}&fields1=f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13&fields2=f51,f52,f53,f54,f55,f56,f57,f58&iscr=0&iscca=0&ndays=1&rt=${DateTime.now().millisecondsSinceEpoch}',
      );
      try {
        final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) continue;
        final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final points = _proxyIntradayPointsFromPayload(payload, realtime, fallbackNav);
        final minimum = minimumMinutePointCount();
        if (points.length >= minimum || (points.length >= 30 && !isTradingTime())) {
          return IntradaySeries(points: points, note: '使用${target.name}分钟走势做代理。');
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  List<IntradayPoint> _proxyIntradayPointsFromPayload(Map<String, dynamic> payload, RealtimeEstimate? realtime, double fallbackNav) {
    final data = payload['data'] as Map<String, dynamic>?;
    final prePrice = toDouble(data?['prePrice'] ?? data?['preClose']);
    if (prePrice <= 0) return const [];
    final byMinute = <int, IntradayPoint>{};
    for (final point in trendPointsFromPayload(payload)) {
      final minute = tradingMinute(point.time);
      final changePct = (point.close / prePrice - 1) * 100;
      final nav = navFromChange(changePct, realtime, fallbackNav);
      if (minute >= 0 && minute <= 240 && nav > 0) {
        byMinute[minute] = IntradayPoint(time: point.time, estimatedNav: nav, changePct: changePct);
      }
    }
    final result = byMinute.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return result.map((entry) => entry.value).toList();
  }

  List<IntradayPoint> _parseIntradayPayload(dynamic payload, RealtimeEstimate? realtime, double fallbackNav) {
    final rows = <IntradayPoint>[];
    void visit(dynamic node) {
      final point = _pointFromIntradayRow(node, realtime, fallbackNav);
      if (point != null) {
        rows.add(point);
        return;
      }
      if (node is Map) {
        for (final value in node.values) {
          visit(value);
        }
      } else if (node is List) {
        for (final value in node) {
          visit(value);
        }
      } else if (node is String && node.length > 8) {
        for (final part in node.split(RegExp(r'[;\n]'))) {
          final parsed = _pointFromIntradayString(part, realtime, fallbackNav);
          if (parsed != null) rows.add(parsed);
        }
      }
    }

    visit(payload);
    final byMinute = <int, IntradayPoint>{};
    for (final point in rows) {
      final minute = tradingMinute(point.time);
      if (minute >= 0 && minute <= 240 && point.estimatedNav > 0) byMinute[minute] = point;
    }
    final result = byMinute.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return result.map((entry) => entry.value).toList();
  }

  IntradayPoint? _pointFromIntradayRow(dynamic row, RealtimeEstimate? realtime, double fallbackNav) {
    if (row is List && row.length >= 3) {
      final time = parseIntradayTime(row[0]);
      final nav = toDouble(row[1]);
      final change = toNullableDouble(row[2]);
      if (time != null && nav > 0 && change != null) return IntradayPoint(time: time, estimatedNav: nav, changePct: change);
    }
    if (row is! Map) return null;
    final time = parseIntradayTime(firstValue(row, const ['time', 'TIME', 'gztime', 'GZTIME', 'jzrq', 'JZRQ', 'x', 't']));
    final change = firstNumber(row, const ['gszzl', 'GSZZL', 'zdf', 'ZDF', 'changePct', 'PCT', 'NAVCHGRT', 'equityReturn']);
    var nav = firstNumber(row, const ['gsz', 'GSZ', 'dwjz', 'DWJZ', 'nav', 'NAV', 'jz', 'JZ', 'y']);
    if (time == null || change == null) return null;
    if ((nav == null || nav <= 0) && realtime != null) {
      final base = realtime.officialNav > 0 ? realtime.officialNav : realtime.estimatedNav;
      nav = base * (1 + change / 100);
    }
    if ((nav == null || nav <= 0) && fallbackNav > 0) nav = fallbackNav * (1 + change / 100);
    if (nav == null || nav <= 0) return null;
    return IntradayPoint(time: time, estimatedNav: nav, changePct: change);
  }

  IntradayPoint? _pointFromIntradayString(String value, RealtimeEstimate? realtime, double fallbackNav) {
    final text = value.trim();
    if (text.isEmpty) return null;
    final pieces = text.split(RegExp(r'[,|，\s]+')).where((item) => item.isNotEmpty).toList();
    if (pieces.length < 3) return null;
    final indexedTime = parseIntradayTime(pieces[1]);
    final indexedChange = toNullableDouble(pieces[2]);
    if (indexedTime != null && indexedChange != null && RegExp(r'^\d+$').hasMatch(pieces[0])) {
      final nav = navFromChange(indexedChange, realtime, fallbackNav);
      if (nav <= 0) return null;
      return IntradayPoint(time: indexedTime, estimatedNav: nav, changePct: indexedChange);
    }
    final time = parseIntradayTime(pieces[0]);
    var nav = toDouble(pieces[1]);
    final change = toNullableDouble(pieces[2]);
    if (time == null || change == null) return null;
    if (nav <= 0) nav = navFromChange(change, realtime, fallbackNav);
    if (nav <= 0) return null;
    return IntradayPoint(time: time, estimatedNav: nav, changePct: change);
  }

  Future<List<StockHolding>> _loadHoldings(String code) async {
    final year = DateTime.now().year;
    for (final targetYear in [year, year - 1]) {
      final uri = Uri.parse(
        'https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=$code&topline=10&year=$targetYear&month=&rt=${DateTime.now().millisecondsSinceEpoch}',
      );
      try {
        final response = await _client.get(uri, headers: noCacheHeaders(const {'Referer': 'https://fundf10.eastmoney.com/'})).timeout(const Duration(seconds: 18));
        if (response.statusCode != 200) continue;
        final holdings = parseHoldingsHtml(utf8.decode(response.bodyBytes));
        if (holdings.isNotEmpty) return holdings;
      } catch (_) {
        continue;
      }
    }
    return [];
  }

  Future<List<StockHolding>> _enrichHoldings(List<StockHolding> holdings) async {
    if (holdings.isEmpty) return holdings;
    final secids = holdings.map((item) => '${marketFromCode(item.code)}.${item.code}').join(',');
    final uri = Uri.parse('https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=$secids&fields=f2,f3,f6,f8,f12,f14,f62,f66,f69,f72,f75,f100,f184&rt=${DateTime.now().millisecondsSinceEpoch}');
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final data = payload['data'] as Map<String, dynamic>?;
      final rows = (data?['diff'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();
      final quoteMap = {for (final row in rows) row['f12'].toString(): row};
      return holdings.map((holding) {
        final quote = quoteMap[holding.code];
        final change = quote == null ? null : toNullableDouble(quote['f3']);
        final price = quote == null ? null : toNullableDouble(quote['f2']);
        final amount = quote == null ? null : toNullableDouble(quote['f6']);
        final turnover = quote == null ? null : toNullableDouble(quote['f8']);
        final mainFlow = quote == null ? null : toNullableDouble(quote['f62']);
        final superLargeFlow = quote == null ? null : toNullableDouble(quote['f66']);
        final superLargeFlowPct = quote == null ? null : toNullableDouble(quote['f69']);
        final largeFlow = quote == null ? null : toNullableDouble(quote['f72']);
        final largeFlowPct = quote == null ? null : toNullableDouble(quote['f75']);
        final mainFlowPct = quote == null ? null : toNullableDouble(quote['f184']);
        final quoteIndustry = quote == null ? '' : (quote['f100'] ?? '').toString();
        final industry = quoteIndustry.isNotEmpty ? quoteIndustry : holding.industry;
        return holding.copyWith(
          industry: normalizeIndustry(industry, fallback: holding.industry),
          price: price,
          changePct: change,
          amount: amount,
          turnover: turnover,
          mainFlow: mainFlow,
          superLargeFlow: superLargeFlow,
          superLargeFlowPct: superLargeFlowPct,
          largeFlow: largeFlow,
          largeFlowPct: largeFlowPct,
          mainFlowPct: mainFlowPct,
          contributionPct: change == null ? null : holding.holdingPct * change / 100,
        );
      }).toList();
    } catch (_) {
      return holdings;
    }
  }

  Future<MarketSnapshot> _loadMarket(FundBase fund, String theme, List<StockHolding> holdings) async {
    final uri = Uri.parse('https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=1.000001,0.399001,0.399006,1.000300&fields=f2,f3,f12,f14&rt=${DateTime.now().millisecondsSinceEpoch}');
    var label = '大盘一般';
    var avg = 0.0;
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final data = payload['data'] as Map<String, dynamic>?;
      final rows = (data?['diff'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      final changes = rows.map((row) => toDouble(row['f3'])).toList();
      avg = changes.isEmpty ? 0.0 : changes.reduce((a, b) => a + b) / changes.length;
      label = avg > 0.4 ? '大盘偏暖' : avg < -0.4 ? '大盘偏冷' : '大盘一般';
    } catch (_) {
      final returns = recentReturns(fund.points, 10);
      avg = returns.isEmpty ? 0.0 : returns.reduce((a, b) => a + b) / returns.length;
      label = avg > 0 ? '基金风格偏暖' : '基金风格一般';
    }
    final realtimeBoard = await _loadThemeBoard(theme);
    final board = realtimeBoard ?? boardSignalFromHoldings(theme, holdings);
    return MarketSnapshot(label: label, averageChange: avg, board: board);
  }

  Future<MarketBreadthSignal?> _loadMarketBreadthSignal() async {
    final uri = Uri.parse(
      'https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=6000&po=1&np=1&fltt=2&fid=f3&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23&fields=f3&rt=${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final data = payload['data'] as Map<String, dynamic>?;
      final rows = (data?['diff'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      if (rows.isEmpty) return null;
      final risingCount = rows.where((row) => toDouble(row['f3']) > 0).length;
      final fallingCount = rows.where((row) => toDouble(row['f3']) < 0).length;
      final flatCount = rows.length - risingCount - fallingCount;
      final score = fallingCount >= 3500 && fallingCount > risingCount * 1.35
          ? -2
          : risingCount >= 3500 && risingCount > fallingCount * 1.35
              ? 1
              : 0;
      final summary = fallingCount >= 3500 && fallingCount > risingCount * 1.35
          ? '全市场下跌家数 $fallingCount 家，明显多于上涨家数 $risingCount 家，指数就算翻红也要防止虚假繁荣。'
          : risingCount >= 3500 && risingCount > fallingCount * 1.35
              ? '全市场上涨家数 $risingCount 家，明显多于下跌家数 $fallingCount 家，赚钱效应在回暖。'
              : '全市场上涨 $risingCount 家、下跌 $fallingCount 家，市场情绪还在拉扯。';
      return MarketBreadthSignal(
        risingCount: risingCount,
        fallingCount: fallingCount,
        flatCount: flatCount,
        summary: summary,
        score: score,
      );
    } catch (_) {
      return null;
    }
  }

  Future<EtfPricingSignal?> _loadEtfPricingSignal(FundBase fund, String holdingCode) async {
    final lookupCode = isLinkedFund(fund.name)
        ? holdingCode
        : fund.name.contains('ETF')
            ? fund.code
            : '';
    if (!RegExp(r'^\d{6}$').hasMatch(lookupCode)) return null;
    final uri = Uri.parse(
      'https://datacenter.eastmoney.com/stock/fundselector/api/data/get?type=RPTA_APP_FUNDSELECT&sty=ETF_TYPE_CODE,SECUCODE,SECURITY_CODE,CHANGE_RATE_1W,CHANGE_RATE_1M,CHANGE_RATE_3M,YTD_CHANGE_RATE,DEC_TOTALSHARE,DEC_NAV,SECURITY_NAME_ABBR,DERIVE_INDEX_CODE,INDEX_CODE,INDEX_NAME,NEW_PRICE,CHANGE_RATE,CHANGE,VOLUME,DEAL_AMOUNT,PREMIUM_DISCOUNT_RATIO,QUANTITY_RELATIVE_RATIO,HIGH_PRICE,LOW_PRICE,STOCK_ID,PRE_CLOSE_PRICE&extraCols=&source=FUND_SELECTOR&client=APP&sr=-1,-1,1&st=CHANGE_RATE,CHANGE,SECURITY_CODE&filter=(SECURITY_CODE%3D%22$lookupCode%22)&p=1&ps=10&isIndexFilter=1',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders(const {'Referer': 'https://datacenter.eastmoney.com/'})).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final rows = ((payload['result'] as Map<String, dynamic>?)?['data'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      final row = rows.firstOrNull;
      if (row == null) return null;
      final premiumDiscountRatio = toNullableDouble(row['PREMIUM_DISCOUNT_RATIO']);
      final changePct = toNullableDouble(row['CHANGE_RATE']);
      final volumeRatio = toNullableDouble(row['QUANTITY_RELATIVE_RATIO']);
      final dealAmount = toNullableDouble(row['DEAL_AMOUNT']);
      final totalShare = toNullableDouble(row['DEC_TOTALSHARE']);
      final name = (row['SECURITY_NAME_ABBR'] ?? '').toString();
      final indexName = (row['INDEX_NAME'] ?? '').toString();
      if (premiumDiscountRatio == null || changePct == null || name.isEmpty) return null;
      return EtfPricingSignal(
        code: lookupCode,
        name: name,
        indexName: indexName,
        changePct: changePct,
        premiumDiscountRatio: premiumDiscountRatio,
        volumeRatio: volumeRatio,
        dealAmount: dealAmount,
        totalShare: totalShare,
      );
    } catch (_) {
      return null;
    }
  }

  Future<YesterdayReview?> _loadYesterdayReview(String code, double todayPct) async {
    final yesterday = previousTradingDate(DateTime.now());
    final lock = await _loadLockState(code, dateText(yesterday));
    if (!lock.hasTomorrowLock || (lock.tomorrowTrend ?? '').isEmpty) return null;
    final predicted = lock.tomorrowTrend!;
    final predictedAction = lock.action ?? '';
    final predictedText = '$predicted $predictedAction';
    final predictedDirection = predictionDirectionFromText(predictedText);
    final actualDirection = actualDirectionFromPct(todayPct);
    final success = predictedDirection == actualDirection;
    final actualText = actualDirectionText(actualDirection);
    final scoreAdjustment = reviewScoreAdjustment(predictedDirection, actualDirection, success);
    return YesterdayReview(
      headline: success
          ? predictedDirection == 0
              ? '昨日观望命中'
              : '昨日预判命中'
          : predictedDirection == 0
              ? '昨日观望漏判'
              : '昨日预判未命中',
      detail: '昨天系统判断“${predictionPlainText(predictedText)}”，今天真实结果是 ${pct(todayPct)}，$actualText。',
      diagnosis: reviewDiagnosis(lock, predictedDirection, actualDirection, success),
      nextAdjustment: reviewNextAdjustment(predictedDirection, actualDirection, success, scoreAdjustment),
      success: success,
      predictedDirection: predictedDirection,
      actualDirection: actualDirection,
      scoreAdjustment: scoreAdjustment,
    );
  }

  Future<OvernightSignal> _loadOvernightSignal(String theme) async {
    final config = overnightConfig(theme);
    final futures = <Future<ExternalQuote?>>[
      _loadYahooQuote(config.$1, config.$2),
      _loadYahooQuote(config.$3, config.$4),
      _loadYahooQuote('CNH=X', '离岸人民币'),
    ];
    final results = await Future.wait(futures.map((task) => task.catchError((_) => null)));
    final primary = results[0];
    final secondary = results[1];
    final usdcnh = results[2];

    var score = 0;
    final weighted = ((primary?.changePct ?? 0) * 0.6) + ((secondary?.changePct ?? 0) * 0.4);
    if (weighted >= 1.2) {
      score += 2;
    } else if (weighted >= 0.35) {
      score += 1;
    } else if (weighted <= -1.2) {
      score -= 2;
    } else if (weighted <= -0.35) {
      score -= 1;
    }
    final cnhPct = usdcnh?.changePct ?? 0;
    if (cnhPct >= 0.20) score -= 1;
    if (cnhPct <= -0.20) score += 1;

    final text = [
      if (primary != null) '${primary.label}${pct(primary.changePct)}',
      if (secondary != null) '${secondary.label}${pct(secondary.changePct)}',
      if (usdcnh != null) '离岸人民币${pct(-cnhPct)}',
    ].join('；');
    final summary = text.isEmpty
        ? '隔夜外围等待刷新'
        : '$text。${score >= 2 ? '隔夜气氛偏暖' : score <= -2 ? '隔夜气氛偏冷' : '隔夜没有给出明显方向'}。';
    return OvernightSignal(primary: primary, secondary: secondary, usdcnh: usdcnh, summary: summary, score: score);
  }

  Future<ExternalQuote?> _loadYahooQuote(String symbol, String label) async {
    final uri = Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/${Uri.encodeComponent(symbol)}?interval=1d&range=5d');
    final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final result = ((payload['chart'] as Map<String, dynamic>?)?['result'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().firstOrNull;
    final quote = result?['indicators'] as Map<String, dynamic>?;
    final adjcloseGroup = (quote?['adjclose'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().firstOrNull;
    final closes = (adjcloseGroup?['adjclose'] as List<dynamic>? ?? []).map(toNullableDouble).whereType<double>().toList();
    if (closes.length < 2) return null;
    final last = closes.last;
    final previous = closes[closes.length - 2];
    if (previous <= 0) return null;
    return ExternalQuote(symbol: symbol, label: label, changePct: (last / previous - 1) * 100);
  }

  Future<FundAnalysis> _applyLocks(String code, FundAnalysis live) async {
    final now = DateTime.now();
    var lock = await _loadLockState(code, live.analysisDate);
    var changed = false;
    if (shouldLockTodayPrediction(now) && !lock.hasTodayLock) {
      lock = lock.captureToday(live, '09:45');
      changed = true;
    }
    if (shouldLockTomorrowPrediction(now) && !lock.hasTomorrowLock) {
      lock = lock.captureTomorrow(live, '14:45');
      changed = true;
    }
    if (changed) await _saveLockState(lock);
    return lock.applyTo(live);
  }

  Future<AnalysisLockState> _loadLockState(String code, String date) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(analysisLockStorageKey(code, date));
    if (raw == null || raw.isEmpty) return AnalysisLockState(code: code, date: date);
    try {
      return AnalysisLockState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AnalysisLockState(code: code, date: date);
    }
  }

  Future<void> _saveLockState(AnalysisLockState lock) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(analysisLockStorageKey(lock.code, lock.date), jsonEncode(lock.toJson()));
  }

  Future<BoardSignal?> _loadThemeBoard(String theme) async {
    final keywords = themeKeywords(theme);
    if (keywords.isEmpty) return null;
    final allRows = <String, Map<String, dynamic>>{};
    final candidates = <Map<String, dynamic>>[];
    for (final boardType in const ['2', '3']) {
      final uri = Uri.parse(
        'https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=1000&po=1&np=1&fltt=2&fid=f3&fs=m:90+t:$boardType&fields=f12,f14,f3,f62,f184,f6,f2,f8,f104,f105&rt=${DateTime.now().millisecondsSinceEpoch}',
      );
      try {
        final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) continue;
        final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final data = payload['data'] as Map<String, dynamic>?;
        final rows = (data?['diff'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
        for (final row in rows) {
          final code = (row['f12'] ?? '').toString();
          if (code.isNotEmpty) allRows[code] = row;
        }
        candidates.addAll(rows.where((row) => themeBoardScore((row['f14'] ?? '').toString(), keywords) > 0));
      } catch (_) {
        continue;
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final byName = themeBoardScore((b['f14'] ?? '').toString(), keywords).compareTo(themeBoardScore((a['f14'] ?? '').toString(), keywords));
      if (byName != 0) return byName;
      return toDouble(b['f6']).compareTo(toDouble(a['f6']));
    });
    final best = candidates.first;
    final boardCode = (best['f12'] ?? '').toString();
    final rankedRows = allRows.values.toList()..sort((a, b) => toDouble(b['f3']).compareTo(toDouble(a['f3'])));
    final marketRank = boardCode.isEmpty ? null : rankedRows.indexWhere((row) => (row['f12'] ?? '').toString() == boardCode) + 1;
    final marketCount = rankedRows.length;
    final rpsPercentile = marketRank == null || marketCount <= 1 ? null : (100 - ((marketRank - 1) * 100 / (marketCount - 1))).clamp(0, 100).toDouble();
    final trendFuture = boardCode.isEmpty ? Future<BoardTrendStats?>.value(null) : _loadBoardTrendStats('90.$boardCode');
    final dailyFuture = boardCode.isEmpty ? Future<BoardTrendStats?>.value(null) : _loadBoardDailyStats('90.$boardCode');
    final trendStats = await trendFuture;
    final dailyStats = await dailyFuture;
    return BoardSignal(
      name: (best['f14'] ?? '$theme板块').toString(),
      source: '板块实时行情',
      changePct: toDouble(best['f3']),
      code: boardCode,
      mainFlow: toNullableDouble(best['f62']),
      mainFlowPct: toNullableDouble(best['f184']),
      amount: toNullableDouble(best['f6']),
      turnover: toNullableDouble(best['f8']),
      volumeRatio: trendStats?.volumeRatio1440,
      openGapPct: trendStats?.openGapPct,
      first15ChangePct: trendStats?.first15ChangePct,
      first15VolumeRatio: trendStats?.first15VolumeRatio,
      tail20ChangePct: trendStats?.tail20ChangePct,
      marketRank: marketRank == 0 ? null : marketRank,
      marketCount: marketCount == 0 ? null : marketCount,
      rpsPercentile: rpsPercentile,
      recent3ChangePct: dailyStats?.recent3ChangePct,
      recent5ChangePct: dailyStats?.recent5ChangePct,
      risingCount: toNullableInt(best['f104']),
      fallingCount: toNullableInt(best['f105']),
    );
  }

  Future<BoardTrendStats?> _loadBoardTrendStats(String secid) async {
    final uri = Uri.parse(
      'https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=$secid&fields1=f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13&fields2=f51,f52,f53,f54,f55,f56,f57,f58&iscr=0&iscca=0&ndays=2&rt=${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return boardTrendStatsFromPayload(payload);
    } catch (_) {
      return null;
    }
  }

  Future<BoardTrendStats?> _loadBoardDailyStats(String secid) async {
    final uri = Uri.parse(
      'https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=$secid&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57,f58&klt=101&fqt=1&lmt=12&end=20500101&iscca=1&rt=${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return boardDailyStatsFromPayload(payload);
    } catch (_) {
      return null;
    }
  }

  Future<List<StockTailSignal>> _loadStockTailSignals(List<StockHolding> holdings) async {
    final top = List<StockHolding>.from(holdings)..sort((a, b) => b.holdingPct.compareTo(a.holdingPct));
    final tasks = top.take(3).map((holding) => _loadStockTailSignal(holding).catchError((_) {
          return StockTailSignal(code: holding.code, name: holding.name, ready: false);
        }));
    return Future.wait(tasks);
  }

  Future<StockTailSignal> _loadStockTailSignal(StockHolding holding) async {
    final secid = '${marketFromCode(holding.code)}.${holding.code}';
    final uri = Uri.parse(
      'https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=$secid&fields1=f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13&fields2=f51,f52,f53,f54,f55,f56,f57,f58&iscr=0&iscca=0&ndays=1&rt=${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 7));
      if (response.statusCode != 200) return StockTailSignal(code: holding.code, name: holding.name, ready: false);
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final points = trendPointsFromPayload(payload);
      final tail = tailChangeBetween(points, 14, 30, 14, 40);
      if (tail == null) return StockTailSignal(code: holding.code, name: holding.name, ready: false);
      return StockTailSignal(
        code: holding.code,
        name: holding.name,
        ready: true,
        changePct: tail.changePct,
        startTime: tail.startTime,
        endTime: tail.endTime,
      );
    } catch (_) {
      return StockTailSignal(code: holding.code, name: holding.name, ready: false);
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
      final uri = Uri.parse('https://np-anotice-stock.eastmoney.com/api/security/ann?$params&_=${DateTime.now().millisecondsSinceEpoch}');
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 12));
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

  Future<SmartMoneySignal> _loadSmartMoneySignal(String theme, List<StockHolding> holdings) async {
    final focus = List<StockHolding>.from(holdings)..sort((a, b) => b.holdingPct.compareTo(a.holdingPct));
    if (focus.isEmpty) {
      return SmartMoneySignal(
        summary: '暂时还没有拿到机构席位和事件层面的增量线索，先只看盘面承接。',
        detail: '暂时还没有拿到机构席位和事件层面的增量线索，判断重心先回到板块资金、尾盘承接和量价变化。',
        tone: 'warn',
        score: 0,
        evidenceCount: 0,
        eventScore: 0,
      );
    }

    final bigOrder = _buildBigOrderFactor(focus.take(3).toList());
    final dragonFuture = _loadDragonTigerFactor(focus.take(2).toList());
    final blockFuture = _loadBlockTradeFactor(focus.take(2).toList());
    final marginFuture = _loadMarginFactor(focus.take(3).toList());
    final eventFuture = _loadEventCalendarFactor(theme);

    final dragon = await dragonFuture;
    final block = await blockFuture;
    final margin = await marginFuture;
    final event = await eventFuture;

    final score = (dragon.score + block.score + margin.score + event.score + bigOrder.score).clamp(-3, 3).toInt();
    final evidenceCount = dragon.hitCount + block.hitCount + margin.hitCount + event.hitCount + bigOrder.hitCount;
    final summary = score >= 2
        ? '机构、大单和杠杆资金暂时站在偏多一边，明天没有看到明显的砸盘信号。'
        : score <= -2
            ? '机构、大单和杠杆资金都偏谨慎，先把风控摆在前面。'
            : '机构、大单和杠杆资金还没形成同一方向，明天先别太激进。';
    final detail = joinSentences([
      bigOrder.text,
      dragon.text,
      block.text,
      margin.text,
      event.text,
    ]);
    return SmartMoneySignal(
      summary: summary,
      detail: detail,
      tone: toneFromScore(score.toDouble()),
      score: score,
      evidenceCount: evidenceCount,
      eventScore: event.score,
    );
  }

  Future<TextFactorSignal> _loadDragonTigerFactor(List<StockHolding> holdings) async {
    final results = await Future.wait(holdings.map((holding) => _loadDragonTigerFactorForHolding(holding)));
    final hits = results.where((item) => item.hitCount > 0).toList();
    if (hits.isEmpty) {
      return TextFactorSignal(text: '最近未见核心重仓股出现新的龙虎榜席位异动。', score: 0, hitCount: 0);
    }
    final score = hits.fold<int>(0, (value, item) => value + item.score).clamp(-2, 2).toInt();
    return TextFactorSignal(
      text: hits.take(2).map((item) => item.text).join('；'),
      score: score,
      hitCount: hits.length,
    );
  }

  Future<TextFactorSignal> _loadDragonTigerFactorForHolding(StockHolding holding) async {
    final institution = await _loadInstitutionTradeFactorForHolding(holding);
    if (institution.hitCount > 0) return institution;
    return _loadBillboardFactorForHolding(holding);
  }

  Future<TextFactorSignal> _loadInstitutionTradeFactorForHolding(StockHolding holding) async {
    final uri = Uri.parse(
      'https://datacenter-web.eastmoney.com/api/data/v1/get?reportName=RPT_ORGANIZATION_TRADE_DETAILS&columns=ALL&filter=(SECURITY_CODE%3D%22${holding.code}%22)&pageNumber=1&pageSize=3&sortColumns=TRADE_DATE&sortTypes=-1&source=WEB&client=WEB',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return TextFactorSignal(text: '', score: 0);
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final rows = ((payload['result'] as Map<String, dynamic>?)?['data'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      Map<String, dynamic>? row;
      for (final item in rows) {
        final tradeDate = parseDateFromText((item['TRADE_DATE'] ?? '').toString());
        if (tradeDate != null && DateTime.now().difference(tradeDate).inDays <= 120) {
          row = item;
          break;
        }
      }
      if (row == null) return TextFactorSignal(text: '', score: 0);
      final buyTimes = max(toInt(row['BUY_TIMES']), toInt(row['BUY_COUNT']));
      final sellTimes = max(toInt(row['SELL_TIMES']), toInt(row['SELL_COUNT']));
      final netAmt = toNullableDouble(row['NET_BUY_AMT']) ?? 0;
      final d1 = toNullableDouble(row['D1_CLOSE_ADJCHRATE']) ?? 0;
      if (buyTimes + sellTimes <= 0 && netAmt.abs() < 50000000) {
        return TextFactorSignal(text: '', score: 0);
      }
      final date = parseDateFromText((row['TRADE_DATE'] ?? '').toString());
      final dateLabel = date == null ? '最近一次' : shortDateText(date);
      final seatLabel = '$dateLabel机构席位上榜时，买方机构 $buyTimes 家、卖方机构 $sellTimes 家';
      if (netAmt >= 50000000 || buyTimes >= sellTimes + 2) {
        final momentum = d1 >= 1.0 ? '，历史上次日也偏向继续走强' : '';
        return TextFactorSignal(
          text: '${holding.name}$seatLabel，净买入 ${cnAmount(netAmt.abs())}，说明机构回补意愿还在$momentum。',
          score: 1,
          hitCount: 1,
        );
      }
      if (netAmt <= -50000000 || sellTimes >= buyTimes + 2) {
        final pressure = d1 <= -1.0 ? '，历史上次日承压也更明显' : '';
        return TextFactorSignal(
          text: '${holding.name}$seatLabel，但净卖出 ${cnAmount(netAmt.abs())}，说明席位端仍偏撤退$pressure。',
          score: -1,
          hitCount: 1,
        );
      }
      return TextFactorSignal(text: '', score: 0);
    } catch (_) {
      return TextFactorSignal(text: '', score: 0);
    }
  }

  Future<TextFactorSignal> _loadBillboardFactorForHolding(StockHolding holding) async {
    final uri = Uri.parse(
      'https://datacenter-web.eastmoney.com/api/data/v1/get?reportName=RPT_DAILYBILLBOARD_DETAILSNEW&columns=ALL&filter=(SECURITY_CODE%3D%22${holding.code}%22)&pageNumber=1&pageSize=1&sortTypes=-1&sortColumns=TRADE_DATE&source=WEB&client=WEB',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return TextFactorSignal(text: '', score: 0);
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final data = ((payload['result'] as Map<String, dynamic>?)?['data'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      final row = data.firstOrNull;
      if (row == null) return TextFactorSignal(text: '', score: 0);
      final tradeDate = parseDateFromText((row['TRADE_DATE'] ?? '').toString());
      if (tradeDate == null || DateTime.now().difference(tradeDate).inDays > 60) return TextFactorSignal(text: '', score: 0);
      final netAmt = toNullableDouble(row['BILLBOARD_NET_AMT']) ?? toNullableDouble(row['NET_BS_AMT']) ?? 0;
      final explain = ((row['EXPLAIN'] ?? row['EXPLANATION'] ?? '').toString()).trim();
      if (netAmt.abs() < 30000000 && !containsAnyKeyword(explain, const ['机构', '买一', '卖一'])) {
        return TextFactorSignal(text: '', score: 0);
      }
      if (netAmt > 0 || containsAnyKeyword(explain, const ['机构买入', '买一主买'])) {
        return TextFactorSignal(
          text: '${holding.name}最近登上龙虎榜，席位净买入 ${cnAmount(netAmt.abs())}，说明机构还在回补。',
          score: 1,
          hitCount: 1,
        );
      }
      if (netAmt < 0 || containsAnyKeyword(explain, const ['机构卖出', '卖一主卖'])) {
        return TextFactorSignal(
          text: '${holding.name}最近登上龙虎榜，但席位净卖出 ${cnAmount(netAmt.abs())}，短线抛压还没散。',
          score: -1,
          hitCount: 1,
        );
      }
      return TextFactorSignal(text: '', score: 0);
    } catch (_) {
      return TextFactorSignal(text: '', score: 0);
    }
  }

  Future<TextFactorSignal> _loadBlockTradeFactor(List<StockHolding> holdings) async {
    final results = await Future.wait(holdings.map((holding) => _loadBlockTradeFactorForHolding(holding)));
    final hits = results.where((item) => item.hitCount > 0).toList();
    if (hits.isEmpty) {
      return TextFactorSignal(text: '最近没有看到核心重仓股出现明显折价的大宗交易。', score: 0, hitCount: 0);
    }
    final score = hits.fold<int>(0, (value, item) => value + item.score).clamp(-2, 2).toInt();
    return TextFactorSignal(
      text: hits.take(2).map((item) => item.text).join('；'),
      score: score,
      hitCount: hits.length,
    );
  }

  Future<TextFactorSignal> _loadBlockTradeFactorForHolding(StockHolding holding) async {
    final uri = Uri.parse(
      'https://datacenter-web.eastmoney.com/api/data/v1/get?reportName=RPT_DATA_BLOCKTRADE&columns=ALL&filter=(SECURITY_CODE%3D%22${holding.code}%22)&pageNumber=1&pageSize=1&sortColumns=TRADE_DATE&sortTypes=-1&source=WEB&client=WEB',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return TextFactorSignal(text: '', score: 0);
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final data = ((payload['result'] as Map<String, dynamic>?)?['data'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      final row = data.firstOrNull;
      if (row == null) return TextFactorSignal(text: '', score: 0);
      final tradeDate = parseDateFromText((row['TRADE_DATE'] ?? '').toString());
      if (tradeDate == null || DateTime.now().difference(tradeDate).inDays > 25) return TextFactorSignal(text: '', score: 0);
      final discount = toNullableDouble(row['DISCOUNT_RATIO']) ?? -toDouble(row['PREMIUM_RATIO']);
      final amount = toNullableDouble(row['DEAL_AMT']) ?? 0;
      if (amount <= 0) return TextFactorSignal(text: '', score: 0);
      if (discount <= -5) {
        return TextFactorSignal(
          text: '${holding.name}最近出现折价大宗交易 ${cnAmount(amount)}，说明高位仍有人先落袋。',
          score: -1,
          hitCount: 1,
        );
      }
      if (discount >= 1) {
        return TextFactorSignal(
          text: '${holding.name}最近大宗交易没有出现折价，筹码承接还算稳。',
          score: 1,
          hitCount: 1,
        );
      }
      return TextFactorSignal(text: '', score: 0);
    } catch (_) {
      return TextFactorSignal(text: '', score: 0);
    }
  }

  Future<TextFactorSignal> _loadMarginFactor(List<StockHolding> holdings) async {
    final results = await Future.wait(holdings.map((holding) => _loadMarginFactorForHolding(holding)));
    final rows = results.where((item) => item.hitCount > 0).toList();
    if (rows.isEmpty) {
      return TextFactorSignal(text: '融资盘暂时没有看到新的极端升温信号。', score: 0, hitCount: 0);
    }
    final hotNames = rows.where((item) => item.score < 0).map((item) => item.text).where((item) => item.isNotEmpty).take(2).join('、');
    final coolNames = rows.where((item) => item.score > 0).map((item) => item.text).where((item) => item.isNotEmpty).take(2).join('、');
    final hotCount = rows.where((item) => item.score < 0).length;
    final coolCount = rows.where((item) => item.score > 0).length;
    if (hotCount >= 2) {
      return TextFactorSignal(
        text: '${hotNames.isEmpty ? '几只核心重仓股' : hotNames}的融资余额最近抬得太快，追高杠杆偏热，一旦冲高失败更容易出现踩踏。',
        score: -1,
        hitCount: 1,
      );
    }
    if (coolCount >= 2) {
      return TextFactorSignal(
        text: '${coolNames.isEmpty ? '核心重仓股' : coolNames}的融资盘没有继续升温，杠杆追涨压力反而在降下来。',
        score: 1,
        hitCount: 1,
      );
    }
    return TextFactorSignal(
      text: hotCount == 1 ? '融资盘有升温苗头，但暂时还没到失控的程度。' : '融资盘整体中性，没有明显挤兑式杠杆风险。',
      score: hotCount == 1 ? -1 : 0,
      hitCount: 1,
    );
  }

  Future<TextFactorSignal> _loadMarginFactorForHolding(StockHolding holding) async {
    final uri = Uri.parse(
      'https://datacenter-web.eastmoney.com/api/data/v1/get?reportName=RPTA_WEB_RZRQ_GGMX&columns=ALL&filter=(SCODE%3D%22${holding.code}%22)&pageNumber=1&pageSize=5&sortColumns=DATE&sortTypes=-1&source=WEB&client=WEB',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return TextFactorSignal(text: '', score: 0);
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final rows = ((payload['result'] as Map<String, dynamic>?)?['data'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      if (rows.isEmpty) return TextFactorSignal(text: '', score: 0);
      final sample = rows.take(3).toList();
      final latest = sample.first;
      final finGrowth = toNullableDouble(latest['FIN_BALANCE_GR']) ?? 0;
      final rzjme5d = toNullableDouble(latest['RZJME5D']) ?? 0;
      final changePct = toNullableDouble(latest['ZDF']) ?? 0;
      final hotDays = sample.where((row) => (toNullableDouble(row['FIN_BALANCE_GR']) ?? 0) >= 1.2).length;
      final coolDays = sample.where((row) => (toNullableDouble(row['FIN_BALANCE_GR']) ?? 0) <= -0.8).length;
      final sidewaysDays = sample.where((row) => (toNullableDouble(row['ZDF']) ?? 0).abs() <= 1.0).length;
      final leverageBuild = (finGrowth >= 2.0 && rzjme5d > 0) || (hotDays >= 2 && sidewaysDays >= 1);
      final leverageCool = (finGrowth <= -1.0 && rzjme5d < 0) || coolDays >= 2;
      if (leverageBuild) {
        return TextFactorSignal(text: holding.name, score: -1, hitCount: 1);
      }
      if (leverageCool) {
        return TextFactorSignal(text: holding.name, score: 1, hitCount: 1);
      }
      if (rzjme5d > 0 && changePct > 0 && changePct < 1.5) {
        return TextFactorSignal(text: holding.name, score: -1, hitCount: 1);
      }
      return TextFactorSignal(text: '', score: 0, hitCount: 0);
    } catch (_) {
      return TextFactorSignal(text: '', score: 0);
    }
  }

  TextFactorSignal _buildBigOrderFactor(List<StockHolding> holdings) {
    final rows = holdings.where((item) => item.superLargeFlow != null || item.largeFlow != null).toList();
    if (rows.isEmpty) {
      return TextFactorSignal(text: '超大单和大单数据还在刷新，先不把这项当成硬判断。', score: 0, hitCount: 0);
    }
    double weightedFlow = 0;
    double weightedPct = 0;
    final bullish = <String>[];
    final bearish = <String>[];
    for (final item in rows) {
      final flow = (item.superLargeFlow ?? 0) + (item.largeFlow ?? 0);
      final pct = (item.superLargeFlowPct ?? 0) + (item.largeFlowPct ?? 0);
      weightedFlow += flow * item.holdingPct / 100;
      weightedPct += pct * item.holdingPct / 100;
      if (flow > 0 && pct > 0) bullish.add(item.name);
      if (flow < 0 && pct < 0) bearish.add(item.name);
    }
    if (weightedFlow.abs() < 10000000 && weightedPct.abs() < 0.15) {
      return TextFactorSignal(text: '超大单和大单暂时没有明显偏向，说明大资金还在边看边走。', score: 0, hitCount: 1);
    }
    if (weightedFlow > 0 && weightedPct > 0.2) {
      final names = bullish.take(2).join('、');
      return TextFactorSignal(
        text: '${names.isEmpty ? '几只核心重仓股' : names}的超大单仍在净流入，说明大资金还没有退。',
        score: weightedPct >= 0.5 ? 2 : 1,
        hitCount: 1,
      );
    }
    if (weightedFlow < 0 && weightedPct < -0.2) {
      final names = bearish.take(2).join('、');
      return TextFactorSignal(
        text: '${names.isEmpty ? '几只核心重仓股' : names}的超大单仍在净流出，说明大资金更偏向先撤。',
        score: weightedPct <= -0.5 ? -2 : -1,
        hitCount: 1,
      );
    }
    return TextFactorSignal(text: '大单方向还有分歧，说明机构并没有在尾盘给出统一态度。', score: 0, hitCount: 1);
  }

  Future<TextFactorSignal> _loadEventCalendarFactor(String theme) async {
    final start = dateText(DateTime.now());
    final uri = Uri.parse(
      'https://datacenter-web.eastmoney.com/api/data/v1/get?reportName=RPT_CPH_FECALENDAR&columns=ALL&filter=(START_DATE%3E%3D%27$start%27)&pageNumber=1&pageSize=40&sortTypes=1&sortColumns=START_DATE&source=WEB&client=WEB',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return TextFactorSignal(text: '未来一周暂未看到需要提前躲避的高影响事件。', score: 0, hitCount: 0);
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final rows = ((payload['result'] as Map<String, dynamic>?)?['data'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      final themeKeys = themeEventKeywords(theme);
      final macroKeys = macroEventKeywords();
      final relevant = <Map<String, dynamic>>[];
      for (final row in rows) {
        final title = ((row['FE_NAME'] ?? '').toString()).trim();
        final content = ((row['CONTENT'] ?? '').toString()).trim();
        final eventDate = parseDateFromText((row['START_DATE'] ?? '').toString());
        if (title.isEmpty || eventDate == null) continue;
        final days = DateTime(eventDate.year, eventDate.month, eventDate.day).difference(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)).inDays;
        if (days < 0 || days > 7) continue;
        if (containsAnyKeyword('$title $content', themeKeys) || containsAnyKeyword('$title $content', macroKeys)) {
          relevant.add(row);
        }
      }
      if (relevant.isEmpty) {
        return TextFactorSignal(text: '未来一周暂未看到会立刻打断节奏的高影响事件。', score: 0, hitCount: 0);
      }
      final top = relevant.take(2).toList();
      final titles = top.map((row) => (row['FE_NAME'] ?? '').toString().trim()).where((item) => item.isNotEmpty).join('、');
      final firstDate = parseDateFromText((top.first['START_DATE'] ?? '').toString());
      final whenText = describeEventWindow(firstDate);
      final macroHeavy = top.any((row) => containsAnyKeyword('${row['FE_NAME'] ?? ''} ${row['CONTENT'] ?? ''}', macroKeys));
      return TextFactorSignal(
        text: '$whenText有 $titles，事件落地前资金更容易先观望，别把仓位打得太满。',
        score: macroHeavy ? -2 : -1,
        hitCount: 1,
      );
    } catch (_) {
      return TextFactorSignal(text: '事件日历暂时没有给出新的强扰动线索。', score: 0, hitCount: 0);
    }
  }

  FundAnalysis _analyze(
    FundBase fund,
    List<StockHolding> holdings,
    List<Announcement> announcements,
    MarketSnapshot market,
    SmartMoneySignal smartMoney,
    String theme,
    RealtimeEstimate? realtime,
    IntradaySeries intraday,
    List<StockTailSignal> tailSignals,
    PortfolioItem item,
    String holdingSourceText,
    double totalCapital, {
    YesterdayReview? yesterdayReview,
  }) {
    final points = fund.points;
    final last = points.last;
    final returns = dailyReturns(points);
    final last20 = returns.takeLast(20).sum;
    final drawdown = maxDrawdown(points.takeLast(90)) * 100;
    final contribution = holdings.where((row) => row.contributionPct != null).map((row) => row.contributionPct!).sum;
    final hasStockRealtime = holdings.any((row) => row.changePct != null);
    final useOfficialValue = shouldUseOfficialNav(last, realtime);
    final hasFundRealtime = realtime != null && !useOfficialValue;
    final latestReturn = last.equityReturn ?? (returns.isEmpty ? 0 : returns.last);
    final todayPct = useOfficialValue
        ? latestReturn
        : hasFundRealtime
            ? realtime!.estimatePct
            : (hasStockRealtime ? contribution : latestReturn);
    final decisionNav = useOfficialValue
        ? last.value
        : hasFundRealtime
            ? realtime!.estimatedNav
            : last.value;
    final majorNegative = announcements.where((row) => row.sentiment == '负面' && row.severity >= 80).firstOrNull;
    final positiveCatalyst = announcements.any((row) => row.sentiment == '正面' && row.severity >= 80);
    final isLiquor = theme == '白酒';

    final todayTone = buildTodayToneSignal(overnight: market.overnight, board: market.board, market: market);
    final ma5 = movingAverage(points, 5);
    final ma20 = movingAverage(points, 20);
    final ma60 = movingAverage(points, 60);
    final ma120 = movingAverage(points, 120);
    final recentSupport = points.takeLast(min(20, points.length)).map((item) => item.value).reduce(min).toDouble();
    final recentResistance = points.takeLast(min(60, points.length)).map((item) => item.value).reduce(max).toDouble();
    final bias5 = biasFromAverage(decisionNav, ma5);
    final bias20 = biasFromAverage(decisionNav, ma20);
    final biasScoreValue = biasScore(bias5, bias20);
    final resonance = buildResonanceSignal(
      points: points,
      decisionNav: decisionNav,
      ma20: ma20,
      ma60: ma60,
      ma120: ma120,
      market: market,
    );

    var forward = buildForwardDecisionScore(board: market.board, tailSignals: tailSignals, todayPct: todayPct);
    if (majorNegative != null) {
      forward = ForwardDecisionScore(
        total: min(forward.total - 2, -3).toInt(),
        fundFlowScore: forward.fundFlowScore,
        tailScore: forward.tailScore,
        volumeScore: forward.volumeScore,
        fundFlowText: forward.fundFlowText,
        tailText: '${forward.tailText}；再叠加重大负面公告压制',
        volumeText: forward.volumeText,
        conclusion: '明天有低开低走风险',
        confidence: forward.confidence,
      );
    }

    final marketBackdropScore = market.averageChange >= 0.60
        ? 1
        : market.averageChange <= -0.60
            ? -1
            : 0;
    final marketBackdropText = market.averageChange >= 0.60
        ? '大盘今天整体在帮忙，板块如果同步走高，明天更容易延续。'
        : market.averageChange <= -0.60
            ? '大盘今天整体偏冷，局部热点就算有反抽，高度也容易被压住。'
            : '大盘没有明显站队，明天更多还是看板块和资金自己说话。';
    final breadthText = market.marketBreadth?.summary ?? '全市场涨跌家数还在刷新，先不把市场情绪看得太满。';
    final breadthScore = market.marketBreadth?.score ?? 0;


    final reviewAdjustment = yesterdayReview?.scoreAdjustment ?? 0;
    var totalScore = forward.total + breadthScore + biasScoreValue + marketBackdropScore + smartMoney.score + resonance.score + reviewAdjustment;
    final duration = buildDurationSignal(
      points: points,
      decisionNav: decisionNav,
      totalScore: totalScore,
      majorNegative: majorNegative,
      positiveCatalyst: positiveCatalyst,
    );
    if (duration.tone == 'good' && totalScore > 0) totalScore += 1;
    if (duration.tone == 'bad' && totalScore < 0) totalScore -= 1;

    final availableTomorrowSignals = [
      market.board?.mainFlow != null,
      market.board?.volumeRatio != null,
      tailSignals.where((row) => row.ready && row.changePct != null).length >= 2,
      market.marketBreadth != null,
      market.board?.rpsPercentile != null,
      market.board?.risingCount != null && market.board?.fallingCount != null,
      market.etfPricing != null,
      smartMoney.evidenceCount > 0,
      ma5 > 0 && ma20 > 0 && ma60 > 0,
      yesterdayReview != null,
    ].where((item) => item).length;
    var confidence = majorNegative != null
        ? '低'
        : availableTomorrowSignals >= 6
            ? '中'
            : availableTomorrowSignals >= 4
                ? '中低'
                : '低';
    final conflictCount = [
      forward.fundFlowScore != 0 && marketBackdropScore != 0 && forward.fundFlowScore.sign != marketBackdropScore.sign,
      breadthScore != 0 && forward.fundFlowScore != 0 && breadthScore.sign != forward.fundFlowScore.sign,
      duration.tone == 'bad' && totalScore > 0,
      duration.tone == 'good' && totalScore < 0,
      forward.volumeScore < 0 && (forward.fundFlowScore > 0 || forward.tailScore > 0),
      smartMoney.score != 0 && forward.fundFlowScore != 0 && smartMoney.score.sign != forward.fundFlowScore.sign,
      resonance.score != 0 && forward.total != 0 && resonance.score.sign != forward.total.sign,
      yesterdayReview?.success == false && reviewAdjustment != 0 && forward.total != 0 && reviewAdjustment.sign != forward.total.sign,
    ].where((item) => item).length;
    if (conflictCount >= 2) {
      confidence = '极低';
    } else if (yesterdayReview?.success == false && confidence == '中') {
      confidence = '中低';
    }

    final sectorState = forward.fundFlowText;
    final tailState = forward.tailText;
    final smartMoneyState = smartMoney.summary;
    final volumeState = joinSentences([forward.volumeText, breadthText]);
    final resonanceState = resonance.summary;
    final probabilityUp = (50 + totalScore * 6).clamp(10.0, 90.0).toDouble();
    var todayState = buildTodayDirectionText(todayPct: todayPct, totalScore: totalScore);
    var tomorrowTrend = buildTomorrowDirectionText(totalScore: totalScore, confidence: confidence);
    final valuationBackground = valuationText(drawdown: drawdown, last20: last20);
    final holdingRatio = totalCapital > 0 ? item.amount / totalCapital : null;
    final isHeavyPosition = holdingRatio != null ? holdingRatio > 0.5 : item.amount >= 30000;
    final holdingStatusTone = 'warn';
    final holdingStatusBadge = money(item.amount);
    final holdingStatusText = '当前持有 ${money(item.amount)}。';
    final atr14 = resonance.atr14;
    final rpsPercentile = market.board?.rpsPercentile;
    final buyCap = atr14 >= 2.6
        ? 0.05
        : atr14 >= 1.8
            ? 0.08
            : 0.10;
    final sellCap = atr14 >= 2.6
        ? 0.15
        : atr14 >= 1.8
            ? 0.12
            : 0.10;
    final durationUpperDays = durationUpperBoundDays(duration.summary);
    final oneMonthVolatility = std(returns.takeLast(20));
    final hasWeekEventRisk = smartMoney.eventScore < 0;
    final macroEventRisk = smartMoney.eventScore <= -2;
    final shortCycleTrade = durationUpperDays != null && durationUpperDays < 7;
    final feeWindowSnapshot = buildFeeWindowSnapshot(item, decisionNav);
    final etfPricing = market.etfPricing;
    final etfPremiumRatio = etfPricing?.premiumDiscountRatio;
    final etfPremiumHigh = etfPremiumRatio != null && etfPremiumRatio >= 1;
    final highVolatility = atr14 >= 2.6 || oneMonthVolatility >= 1.8;
    final etfPricingState = etfPricing == null
        ? '场内 ETF 的折溢价和成交活跃度暂时还没拿齐，今天先不把它当成硬拦截。'
        : etfPremiumRatio! >= 1
            ? '${etfPricing.name} 当前溢价 ${pct(etfPremiumRatio!)}，而且场内交易偏热，明天容易被套利资金压回去。'
            : etfPremiumRatio! <= -1
                ? '${etfPricing.name} 当前折价 ${pct(etfPremiumRatio!)}，场内情绪不算过热。'
                : joinSentences([
                    '${etfPricing.name} 当前折溢价 ${pct(etfPremiumRatio!)}，情绪没有明显失真。',
                    if (etfPricing.volumeRatio != null && etfPricing.volumeRatio! >= 1.4) '量比 ${etfPricing.volumeRatio!.toStringAsFixed(1)}，说明场内交易明显放大。',
                    if (etfPricing.dealAmount != null && etfPricing.dealAmount! > 0) '成交额 ${cnAmount(etfPricing.dealAmount!)}。',
                  ]);
    final etfPricingTone = etfPricing == null
        ? 'warn'
        : etfPremiumRatio! >= 1
            ? 'bad'
            : etfPremiumRatio! <= -1
                ? 'good'
                : 'warn';
    final t7Risk = shortCycleTrade && (atr14 >= 1.8 || oneMonthVolatility >= 1.6 || hasWeekEventRisk);
    final futureDaysText = futureDaysLabel(duration: duration, totalScore: totalScore);
    final volatilityText = volatilityLabel(atr14: atr14, oneMonthVolatility: oneMonthVolatility);
    final downsideRiskText = downsideRiskLabel(
      totalScore: totalScore,
      confidence: confidence,
      durationTone: duration.tone,
      majorNegative: majorNegative != null,
      etfPremiumHigh: etfPremiumHigh,
      highVolatility: highVolatility,
    );
    final holdingCycleState = t7Risk
        ? hasWeekEventRisk
            ? '虽然明天可能有反弹，但未来一周还有事件扰动，场外基金现在买进去并不划算。'
            : '这轮更像短线波动，持有未满 7 天就卖出会被手续费吃掉，不适合做短线博弈。'
        : feeWindowSnapshot.headline;
    final holdingCycleTone = t7Risk ? 'bad' : feeWindowSnapshot.tone;
    var strongBuyTrigger = 5;
    var probeBuyTrigger = 2;
    var watchTrigger = -2;
    var reduceTrigger = -5;
    if (rpsPercentile != null && rpsPercentile >= 90) {
      strongBuyTrigger -= 1;
      probeBuyTrigger -= 1;
    } else if (rpsPercentile != null && rpsPercentile < 50) {
      watchTrigger += 1;
      reduceTrigger += 1;
    }
    if (atr14 >= 2.6) {
      strongBuyTrigger += 1;
      probeBuyTrigger += 1;
    } else if (atr14 <= 1.2) {
      strongBuyTrigger -= 1;
    }

    var buyRatio = 0.0;
    var sellRatio = 0.0;
    var action = shouldLockTomorrowPrediction(DateTime.now()) ? '不动，等确认' : '等待14:45确认';
    if (totalScore <= reduceTrigger || duration.tone == 'bad' && (bias20 > 5 || majorNegative != null || resonance.score < 0)) {
      action = isHeavyPosition ? '今天先减一点' : '今天先降一点仓位';
      sellRatio = item.amount >= 10000 ? 0.10 : 0.06;
    } else if (totalScore >= strongBuyTrigger && duration.tone != 'bad' && resonance.score >= 0) {
      action = '今天可小额买入';
      buyRatio = confidence.startsWith('中') ? 0.10 : 0.06;
    } else if (totalScore <= watchTrigger) {
      if (isHeavyPosition) {
        action = '仓位偏重，先降一点';
        sellRatio = 0.05;
      } else {
        action = '观望，防回落';
      }
    } else if (totalScore >= probeBuyTrigger && duration.tone == 'good' && smartMoney.score >= 0) {
      action = '先小额试试';
      buyRatio = confidence.startsWith('中') ? 0.04 : 0.02;
    }
    if (buyRatio > 0 && t7Risk) {
      buyRatio = 0.0;
      action = '观望，防回落';
    }
    if (buyRatio > 0 && macroEventRisk) {
      buyRatio = 0.0;
      action = '重大事件前先观望';
    }
    if (buyRatio > 0 && etfPremiumRatio != null && etfPremiumRatio >= 1) {
      buyRatio = 0.0;
      sellRatio = max(sellRatio, isHeavyPosition ? 0.08 : 0.04);
      action = 'ETF溢价过高，先降一点';
    }
    if (buyRatio > 0 && downsideRiskText == '高') {
      buyRatio = 0.0;
      action = '风险偏高，先不买';
    }
    if (forward.volumeScore <= -2 && todayPct > 0.15) {
      buyRatio = 0.0;
      sellRatio = max(sellRatio, isHeavyPosition ? 0.10 : 0.06);
      action = '缩量上涨，先锁利润';
    }
    if (confidence == '低' && totalScore.abs() < 4) {
      buyRatio = 0.0;
      sellRatio = 0.0;
      action = '不动，等实时数据';
    }
    if (confidence == '极低') {
      buyRatio = 0.0;
      sellRatio = 0.0;
      tomorrowTrend = '明天震荡';
      action = '风险不可控，今日观望';
    }
    if (isHeavyPosition && totalScore < 0) {
      sellRatio = max(sellRatio, 0.05);
      buyRatio = min(buyRatio, 0.03);
      if (sellRatio > 0) action = '仓位重可小幅减';
    }
    if (sellRatio == 0 && downsideRiskText == '高' && (duration.tone == 'bad' || etfPremiumHigh || majorNegative != null)) {
      buyRatio = 0.0;
      sellRatio = item.amount >= 10000 ? 0.08 : 0.05;
      action = '后面几天偏弱，先减一点';
    }
    if (smartMoney.score < 0) buyRatio = min(buyRatio, 0.04);
    if (resonance.score < 0) buyRatio = min(buyRatio, 0.03);
    if (duration.tone == 'bad') buyRatio = min(buyRatio, 0.04);
    if (isLiquor && confidence == '低') buyRatio = min(buyRatio, 0.03);
    buyRatio = buyRatio.clamp(0.0, buyCap).toDouble();
    sellRatio = sellRatio.clamp(0.0, sellCap).toDouble();
    if (sellRatio > 0 && buyRatio == 0 && confidence != '极低') {
      tomorrowTrend = '明天偏跌';
    } else if (buyRatio > 0 && sellRatio == 0 && totalScore < 2) {
      tomorrowTrend = '明天偏涨';
    }

    if (sellRatio > 0 && buyRatio == 0) {
      todayState = '今天偏跌';
    } else if (buyRatio > 0 && sellRatio == 0) {
      todayState = todayPct < -0.15 ? '今天小跌' : '今天偏涨';
      tomorrowTrend = '明天偏涨';
    } else {
      todayState = buildTodayDirectionText(todayPct: todayPct, totalScore: totalScore);
    }

    final macroScore = ((market.overnight?.score ?? 0) + marketBackdropScore + breadthScore).toDouble();
    final sectorTone = toneFromScore(forward.fundFlowScore.toDouble());
    final coreTone = toneFromScore((forward.tailScore + biasScoreValue).toDouble());
    final volumeTone = toneFromScore(forward.volumeScore.toDouble());
    final smartMoneyTone = smartMoney.tone;
    final resonanceTone = resonance.tone;
    final temperatureScore = (totalScore * 14).clamp(-100, 100).round();
    final temperatureLabel = confidence == '极低'
        ? '方向不明'
        : temperatureScore >= 55
            ? '明显转暖'
            : temperatureScore >= 18
                ? '慢慢转暖'
                : temperatureScore <= -55
                    ? '风险升高'
                    : temperatureScore <= -18
                        ? '明显转冷'
                        : '不冷不热';
    final decisionSummary = buyRatio == 0 && sellRatio == 0
        ? t7Risk
            ? '就算明天可能反弹，这里也不值得为了短线波动去承担 7 天手续费约束。'
            : macroEventRisk
            ? '明天前后有高影响事件，宁愿少赚一点，也先别在今晚把仓位抬太高。'
            : confidence == '极低'
            ? '当前多空分歧太大，今天先观望，不要硬做判断。'
            : '今天先观望，等更明确的止跌或放量信号。'
        : buyRatio > 0 && sellRatio == 0
            ? '今天更适合小额试探，不适合一把追进去。'
        : sellRatio > 0 && buyRatio == 0
            ? '今天更适合先降一小部分仓位，把回撤风险压住。'
            : '今天以控仓为主，买卖都只做小幅调整。';
    final amountRule = buyRatio == 0 && sellRatio == 0
        ? '当前持有 ${money(item.amount)}，今天先观望，不给具体买卖金额。'
        : buyRatio > 0 && sellRatio == 0
            ? '当前持有 ${money(item.amount)}，若按模型执行，可分批买入 ${money(item.amount * buyRatio)}。'
            : sellRatio > 0 && buyRatio == 0
                ? '当前持有 ${money(item.amount)}，若按模型执行，可分批卖出 ${money(item.amount * sellRatio)}。'
                : '当前持有 ${money(item.amount)}，若按模型执行，可小幅买入 ${money(item.amount * buyRatio)}，并同步卖出 ${money(item.amount * sellRatio)}。';
    final decision = DecisionModel(
      confidence: confidence == '中'
          ? '置信度：中'
          : confidence == '中低'
              ? '置信度：中低'
              : confidence == '极低'
                  ? '置信度：极低'
                  : '置信度：低',
      temperatureScore: temperatureScore,
      temperatureLabel: temperatureLabel,
      macroState: joinSentences([market.overnight?.summary ?? '隔夜外围消息偏平。', marketBackdropText]),
      macroTone: toneFromScore(macroScore),
      valuationState: sectorState,
      valuationTone: sectorTone,
      trendState: tailState,
      trendTone: coreTone,
      smartMoneyState: smartMoneyState,
      smartMoneyTone: smartMoneyTone,
      etfPricingState: etfPricingState,
      etfPricingTone: etfPricingTone,
      costDeviationText: volumeState,
      deviationTone: volumeTone,
      resonanceState: resonanceState,
      resonanceTone: resonanceTone,
      durationState: '${duration.summary}。${duration.reason}',
      durationTone: duration.tone,
      holdingCycleState: holdingCycleState,
      holdingCycleTone: holdingCycleTone,
      gridTrigger: amountRule,
      summary: decisionSummary,
      reason: '',
    );

    final todayReason =
        '${todayTone.reason}${useOfficialValue ? ' 晚上已切换为实际净值 ${last.value.toStringAsFixed(4)}。' : hasFundRealtime ? ' 当前盘中估值 ${pct(todayPct)}，更新时间 ${realtime!.updateTime}。' : ' 当前盘中估值暂缺，所以今天只按已经拿到的真实净值、持仓和公告来判断。'}';
    final plainTrendText = '$todayState，$tomorrowTrend；$futureDaysText，波动$volatilityText，下跌风险$downsideRiskText。';
    final todaySimpleText = sellRatio > 0
        ? '今天盘面偏防守：板块资金、尾盘承接或高影响事件里有风险信号，继续追容易被回撤打到。'
        : buyRatio > 0
            ? '今天盘面有修复信号：资金和趋势没有继续恶化，可以只用小金额试探。'
            : '今天盘面还没有给出清楚方向：资金、量能和尾盘表现没有站到同一边。';
    final tomorrowSimpleText = sellRatio > 0
        ? '明天更要防回落；如果后面几天继续偏弱，先保住本金比多赚一点更重要。'
        : buyRatio > 0
            ? '明天有继续反弹机会，但仍按分批来，不适合一次买满。'
            : '明天先看资金会不会继续流入；没有确认前，少动比乱动更稳。';
    final actionText = confidence == '极低'
        ? '新手建议：多空分歧太大，今天不硬猜，先观望。'
        : etfPremiumRatio != null && etfPremiumRatio >= 1 && buyRatio == 0
            ? '新手建议：ETF 溢价偏高，今天不追。'
        : macroEventRisk && buyRatio == 0
            ? '新手建议：明天前后有重要事件，今晚更适合观望。'
        : downsideRiskText == '高' && buyRatio == 0
            ? '新手建议：后面几天下跌风险偏高，不追涨；已经持有的话可以先降一点。'
        : buyRatio > 0
            ? t7Risk
                ? '新手建议：短线反弹不够划算，场外基金有 7 天手续费约束，今天不追。'
                : '新手建议：可以小额分批买入，只试探，不一次性追价。'
            : sellRatio > 0
                ? '新手建议：先卖出一小部分，把回撤风险压住；不是清仓，是先防守。'
                : '新手建议：今天先不动，等更明确的止跌或放量确认。';
    final actionReason = '$plainTrendText\n\n$todaySimpleText\n\n$tomorrowSimpleText\n\n$actionText';
    final upperTriggerValue = recentResistance > decisionNav ? recentResistance : decisionNav * (1 + max(0.02, atr14 / 100));
    final lowerTriggerValue = recentSupport < decisionNav ? recentSupport : decisionNav * (1 - max(0.025, atr14 / 100));
    final battlePlan = GridBattlePlan(
      upperTrigger: upperTriggerValue.toStringAsFixed(4),
      upperAction: sellRatio > 0 ? '触及后优先减仓 ${ratioText(max(sellRatio, 0.05))}，先把利润和仓位风险一起锁住。' : '触及后更适合分批止盈 5%，不追着高位继续加。',
      currentValue: decisionNav.toStringAsFixed(4),
      currentZone: buyRatio > 0
          ? '当前处在可试探区域，适合小额跟随，不适合一把冲进去。'
          : sellRatio > 0
              ? '当前更像高位整理区，重点是先防回落，不是继续追涨。'
              : '当前处在震荡观察区，先等资金把方向说清楚。',
      lowerTrigger: lowerTriggerValue.toStringAsFixed(4),
      lowerAction: buyRatio > 0 ? '触及后优先加仓 ${ratioText(max(buyRatio, 0.05))}，按计划低吸，不抢反弹。' : '触及后可考虑低吸 10%，前提是资金没有继续恶化。',
    );

    final buyReason = buyRatio > 0
        ? [
            '明天和后面几天仍有上涨机会，先用小金额试探更稳。',
            forward.fundFlowText,
            t7Risk ? '只是这波更像短线反弹，所以买入金额要压小。' : '$futureDaysText，$volatilityText，风险没有压过机会。',
          ].join('\n')
        : [
            '现在不是舒服的买点，先别急着冲进去。',
            t7Risk ? '哪怕明天有反弹，7 天免手续费也会让这次短线博弈不划算。' : '$tomorrowTrend，$futureDaysText，下跌风险$downsideRiskText。',
            '等更明确的止跌和放量，再出手会更稳。',
          ].join('\n');
    final sellReason = sellRatio > 0
        ? [
            majorNegative != null ? '${majorNegative.stockName}的负面消息还在压情绪，短线先别硬扛。' : (duration.tone == 'bad' ? '$futureDaysText，短线回调压力已经变大。' : '$tomorrowTrend，$downsideRiskText风险，先别把仓位压得太重。'),
            forward.volumeScore <= -1 ? '今天虽然还在涨，但成交量没跟上，新资金接力偏弱。' : '尾盘没有看到很强的抢筹，买盘接力还不够坚决。',
            '如果你已经有浮盈，先卖出 ${ratioText(sellRatio)} 左右更稳，先把利润装进口袋。',
          ].join('\n')
        : [
            '现在还没到必须卖的时候。',
            isHeavyPosition ? '只是仓位已经不轻，明天若继续转弱，再优先考虑先降一点。' : '如果你仓位不重，先观察明天资金有没有重新回流。',
            '等出现更明确的放量转弱，再减仓也不晚。',
          ].join('\n');

    return FundAnalysis(
      code: fund.code,
      name: fund.name,
      theme: theme.isEmpty ? '主题待确认' : theme,
      analysisDate: todayDateString(),
      latestDate: last.date,
      latestValue: decisionNav,
      todayPct: todayPct,
      todayState: todayState,
      tomorrowTrend: tomorrowTrend,
      probabilityUp: probabilityUp,
      action: action,
      buyRatio: buyRatio,
      sellRatio: sellRatio,
      confidence: confidence,
      todayConfidence: todayTone.confidence,
      todayReason: todayReason,
      actionReason: actionReason,
      buyReason: buyReason,
      sellReason: sellReason,
      durationText: duration.summary,
      durationReason: duration.reason,
      futureDaysText: futureDaysText,
      volatilityText: volatilityText,
      downsideRiskText: downsideRiskText,
      summaryLine: '$todayState · $tomorrowTrend · $futureDaysText · $action',
      realtimeAvailable: hasFundRealtime || useOfficialValue,
      realtimeNavText: decisionNav.toStringAsFixed(4),
      realtimeTimeText: useOfficialValue
          ? '实际净值'
          : hasFundRealtime
              ? shortRealtimeTime(realtime!.updateTime)
              : '等待刷新',
      realtimeStatus: useOfficialValue
          ? '实际净值 ${last.date}'
          : hasFundRealtime
              ? '估值 ${shortRealtimeTime(realtime!.updateTime)}'
              : '净值日 ${last.date}',
      intradayPoints: intraday.points,
      intradayNote: intraday.note,
      decision: decision,
      holdings: holdings,
      announcements: announcements,
      liquorSpecial: isLiquor
          ? '估值位置：$valuationBackground；龙头业绩：${majorNegative == null ? '关注茅台、五粮液、泸州老窖经营数据' : '五粮液管理层公告偏负面'}；消费情绪：${last20 > 0 ? '中性修复' : '偏弱'}；节假日效应：${holidayEffect()}；机构拥挤度：${std(returns.takeLast(30)) > 1.4 ? '中高' : '中'}。'
          : null,
      battlePlan: battlePlan,
      settledItem: item,
      holdingSourceText: holdingSourceText,
      holdingStatusText: holdingStatusText,
      holdingStatusBadge: holdingStatusBadge,
      holdingStatusTone: holdingStatusTone,
      todayLockedAt: '',
      tomorrowLockedAt: '',
    );
  }
}

class PendingBuy {
  PendingBuy({
    required this.amount,
    required this.orderDate,
    required this.confirmDate,
    required this.beforeCutoff,
    required this.note,
  });

  final double amount;
  final String orderDate;
  final String confirmDate;
  final bool beforeCutoff;
  final String note;

  factory PendingBuy.fromJson(Map<String, dynamic> json) => PendingBuy(
        amount: toDouble(json['amount']),
        orderDate: (json['orderDate'] ?? '').toString(),
        confirmDate: (json['confirmDate'] ?? '').toString(),
        beforeCutoff: json['beforeCutoff'] == true,
        note: (json['note'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'amount': amount,
        'orderDate': orderDate,
        'confirmDate': confirmDate,
        'beforeCutoff': beforeCutoff,
        'note': note,
      };
}

class HoldingLot {
  HoldingLot({
    required this.amount,
    required this.shares,
    required this.confirmDate,
    required this.feeFreeDate,
  });

  final double amount;
  final double shares;
  final String confirmDate;
  final String feeFreeDate;

  HoldingLot copyWith({
    double? amount,
    double? shares,
    String? confirmDate,
    String? feeFreeDate,
  }) {
    return HoldingLot(
      amount: amount ?? this.amount,
      shares: shares ?? this.shares,
      confirmDate: confirmDate ?? this.confirmDate,
      feeFreeDate: feeFreeDate ?? this.feeFreeDate,
    );
  }

  factory HoldingLot.fromJson(Map<String, dynamic> json) => HoldingLot(
        amount: toDouble(json['amount']),
        shares: toDouble(json['shares']),
        confirmDate: (json['confirmDate'] ?? '').toString(),
        feeFreeDate: (json['feeFreeDate'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'amount': amount,
        'shares': shares,
        'confirmDate': confirmDate,
        'feeFreeDate': feeFreeDate,
      };
}

class AddBuyDraft {
  const AddBuyDraft({required this.amount, required this.beforeCutoff});

  final double amount;
  final bool beforeCutoff;
}

class PendingOrderPlan {
  PendingOrderPlan({
    required this.confirmDate,
    required this.beforeCutoff,
    required this.label,
    required this.note,
  });

  final String confirmDate;
  final bool beforeCutoff;
  final String label;
  final String note;
}

class FeeWindowSnapshot {
  FeeWindowSnapshot({
    required this.headline,
    required this.detail,
    required this.tone,
    this.progress,
  });

  final String headline;
  final String detail;
  final String tone;
  final double? progress;
}

class PortfolioItem {
  PortfolioItem({
    required this.code,
    required this.amount,
    this.shares,
    this.lastSettledDate = '',
    this.lastSettledNav = 0,
    this.untrackedAmount = 0,
    List<PendingBuy>? pendingBuys,
    List<HoldingLot>? holdingLots,
  })  : pendingBuys = pendingBuys ?? const [],
        holdingLots = holdingLots ?? const [];

  final String code;
  final double amount;
  final double? shares;
  final String lastSettledDate;
  final double lastSettledNav;
  final double untrackedAmount;
  final List<PendingBuy> pendingBuys;
  final List<HoldingLot> holdingLots;

  double get pendingAmount => pendingBuys.map((item) => item.amount).sum;
  factory PortfolioItem.fromJson(Map<String, dynamic> json) {
    final pendingBuys = (json['pendingBuys'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PendingBuy.fromJson)
        .toList();
    final holdingLots = (json['holdingLots'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(HoldingLot.fromJson)
        .toList();
    final amount = toDouble(json['amount']);
    final storedUntracked = toNullableDouble(json['untrackedAmount']);
    final inferredUntracked = storedUntracked ?? ((holdingLots.isEmpty && amount > 0) ? amount : 0);
    return PortfolioItem(
      code: json['code'].toString(),
      amount: amount,
      shares: toNullableDouble(json['shares']),
      lastSettledDate: (json['lastSettledDate'] ?? '').toString(),
      lastSettledNav: toDouble(json['lastSettledNav']),
      untrackedAmount: inferredUntracked,
      pendingBuys: pendingBuys,
      holdingLots: holdingLots,
    );
  }

  PortfolioItem copyWith({
    double? amount,
    double? shares,
    String? lastSettledDate,
    double? lastSettledNav,
    double? untrackedAmount,
    List<PendingBuy>? pendingBuys,
    List<HoldingLot>? holdingLots,
  }) {
    return PortfolioItem(
      code: code,
      amount: amount ?? this.amount,
      shares: shares ?? this.shares,
      lastSettledDate: lastSettledDate ?? this.lastSettledDate,
      lastSettledNav: lastSettledNav ?? this.lastSettledNav,
      untrackedAmount: untrackedAmount ?? this.untrackedAmount,
      pendingBuys: pendingBuys ?? this.pendingBuys,
      holdingLots: holdingLots ?? this.holdingLots,
    );
  }

  PortfolioItem addPendingBuy(double value, {bool? beforeCutoff}) {
    final plan = pendingOrderPlan(DateTime.now(), beforeCutoffOverride: beforeCutoff);
    return copyWith(
      pendingBuys: [
        ...pendingBuys,
        PendingBuy(
          amount: value,
          orderDate: todayDateString(),
          confirmDate: plan.confirmDate,
          beforeCutoff: plan.beforeCutoff,
          note: plan.note,
        ),
      ],
    );
  }

  PortfolioItem recordSell(double value, {double latestNav = 0}) {
    if (value <= 0 || amount <= 0) return this;
    final sellValue = min(value, amount);
    var remaining = sellValue;
    var nextUntracked = untrackedAmount;
    var nextLots = <HoldingLot>[];

    if (nextUntracked > 0) {
      final used = min(nextUntracked, remaining);
      nextUntracked -= used;
      remaining -= used;
    }

    final sortedLots = List<HoldingLot>.from(holdingLots)
      ..sort((a, b) => compareDateText(a.confirmDate, b.confirmDate));
    for (final lot in sortedLots) {
      final lotValue = latestNav > 0 && lot.shares > 0 ? lot.shares * latestNav : lot.amount;
      if (remaining <= 0 || lotValue <= 0) {
        nextLots.add(lot);
        continue;
      }
      if (remaining >= lotValue - 0.01) {
        remaining -= lotValue;
        continue;
      }
      final keepRatio = ((lotValue - remaining) / lotValue).clamp(0.0, 1.0);
      nextLots.add(
        lot.copyWith(
          amount: lot.amount * keepRatio,
          shares: lot.shares * keepRatio,
        ),
      );
      remaining = 0;
    }

    final nextAmount = max(0.0, amount - sellValue);
    final ratio = amount <= 0 ? 0.0 : (nextAmount / amount).clamp(0.0, 1.0);
    return copyWith(
      amount: nextAmount,
      shares: shares == null ? null : shares! * ratio,
      untrackedAmount: max(0.0, nextUntracked),
      holdingLots: nextLots,
    );
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'amount': amount,
        'shares': shares,
        'lastSettledDate': lastSettledDate,
        'lastSettledNav': lastSettledNav,
        'untrackedAmount': untrackedAmount,
        'pendingBuys': pendingBuys.map((item) => item.toJson()).toList(),
        'holdingLots': holdingLots.map((item) => item.toJson()).toList(),
      };
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

class RealtimeEstimate {
  RealtimeEstimate({
    required this.fundCode,
    required this.navDate,
    required this.officialNav,
    required this.estimatedNav,
    required this.estimatePct,
    required this.updateTime,
  });

  final String fundCode;
  final String navDate;
  final double officialNav;
  final double estimatedNav;
  final double estimatePct;
  final String updateTime;
}

class IntradaySeries {
  IntradaySeries({required this.points, required this.note});

  final List<IntradayPoint> points;
  final String note;
}

class IntradayProxyTarget {
  const IntradayProxyTarget({required this.secid, required this.name});

  final String secid;
  final String name;
}

class IntradayPoint {
  IntradayPoint({required this.time, required this.estimatedNav, required this.changePct});

  final DateTime time;
  final double estimatedNav;
  final double changePct;
}

class TrendPoint {
  TrendPoint({required this.time, required this.open, required this.close, required this.amount});

  final DateTime time;
  final double open;
  final double close;
  final double amount;
}

class StockTailSignal {
  StockTailSignal({
    required this.code,
    required this.name,
    required this.ready,
    this.changePct,
    this.startTime,
    this.endTime,
  });

  final String code;
  final String name;
  final bool ready;
  final double? changePct;
  final DateTime? startTime;
  final DateTime? endTime;
}

class TailChange {
  TailChange({required this.changePct, required this.startTime, required this.endTime});

  final double changePct;
  final DateTime startTime;
  final DateTime endTime;
}

class BoardTrendStats {
  BoardTrendStats({
    this.openGapPct,
    this.first15ChangePct,
    this.first15VolumeRatio,
    this.tail20ChangePct,
    this.volumeRatio1440,
    this.recent3ChangePct,
    this.recent5ChangePct,
  });

  final double? openGapPct;
  final double? first15ChangePct;
  final double? first15VolumeRatio;
  final double? tail20ChangePct;
  final double? volumeRatio1440;
  final double? recent3ChangePct;
  final double? recent5ChangePct;
}

class ExternalQuote {
  ExternalQuote({required this.symbol, required this.label, required this.changePct});

  final String symbol;
  final String label;
  final double changePct;
}

class OvernightSignal {
  OvernightSignal({
    required this.primary,
    required this.secondary,
    required this.usdcnh,
    required this.summary,
    required this.score,
  });

  final ExternalQuote? primary;
  final ExternalQuote? secondary;
  final ExternalQuote? usdcnh;
  final String summary;
  final int score;
}

class TodayToneSignal {
  TodayToneSignal({
    required this.state,
    required this.confidence,
    required this.reason,
    required this.score,
  });

  final String state;
  final String confidence;
  final String reason;
  final int score;
}

class MacdSnapshot {
  MacdSnapshot({
    required this.score,
    required this.summary,
  });

  final int score;
  final String summary;
}

class DurationSignal {
  DurationSignal({
    required this.summary,
    required this.reason,
    required this.tone,
    required this.rsi14,
    required this.kdjJ,
    required this.bias5,
    required this.bias20,
    required this.supportGapPct,
    required this.resistanceGapPct,
  });

  final String summary;
  final String reason;
  final String tone;
  final double rsi14;
  final double kdjJ;
  final double bias5;
  final double bias20;
  final double supportGapPct;
  final double resistanceGapPct;
}

class TextFactorSignal {
  TextFactorSignal({
    required this.text,
    required this.score,
    this.hitCount = 0,
  });

  final String text;
  final int score;
  final int hitCount;
}

class SmartMoneySignal {
  SmartMoneySignal({
    required this.summary,
    required this.detail,
    required this.tone,
    required this.score,
    required this.evidenceCount,
    required this.eventScore,
  });

  final String summary;
  final String detail;
  final String tone;
  final int score;
  final int evidenceCount;
  final int eventScore;
}

class ResonanceSignal {
  ResonanceSignal({
    required this.summary,
    required this.detail,
    required this.tone,
    required this.score,
    required this.atr14,
  });

  final String summary;
  final String detail;
  final String tone;
  final int score;
  final double atr14;
}

class StockHolding {
  StockHolding({
    required this.code,
    required this.name,
    required this.industry,
    required this.holdingPct,
    this.price,
    this.changePct,
    this.amount,
    this.turnover,
    this.mainFlow,
    this.superLargeFlow,
    this.superLargeFlowPct,
    this.largeFlow,
    this.largeFlowPct,
    this.mainFlowPct,
    this.contributionPct,
  });

  final String code;
  final String name;
  final String industry;
  final double holdingPct;
  final double? price;
  final double? changePct;
  final double? amount;
  final double? turnover;
  final double? mainFlow;
  final double? superLargeFlow;
  final double? superLargeFlowPct;
  final double? largeFlow;
  final double? largeFlowPct;
  final double? mainFlowPct;
  final double? contributionPct;

  StockHolding copyWith({
    String? industry,
    double? price,
    double? changePct,
    double? amount,
    double? turnover,
    double? mainFlow,
    double? superLargeFlow,
    double? superLargeFlowPct,
    double? largeFlow,
    double? largeFlowPct,
    double? mainFlowPct,
    double? contributionPct,
  }) {
    return StockHolding(
      code: code,
      name: name,
      industry: industry ?? this.industry,
      holdingPct: holdingPct,
      price: price ?? this.price,
      changePct: changePct ?? this.changePct,
      amount: amount ?? this.amount,
      turnover: turnover ?? this.turnover,
      mainFlow: mainFlow ?? this.mainFlow,
      superLargeFlow: superLargeFlow ?? this.superLargeFlow,
      superLargeFlowPct: superLargeFlowPct ?? this.superLargeFlowPct,
      largeFlow: largeFlow ?? this.largeFlow,
      largeFlowPct: largeFlowPct ?? this.largeFlowPct,
      mainFlowPct: mainFlowPct ?? this.mainFlowPct,
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

class BoardSignal {
  BoardSignal({
    required this.name,
    required this.source,
    required this.changePct,
    this.code,
    this.mainFlow,
    this.mainFlowPct,
    this.amount,
    this.turnover,
    this.volumeRatio,
    this.openGapPct,
    this.first15ChangePct,
    this.first15VolumeRatio,
    this.tail20ChangePct,
    this.marketRank,
    this.marketCount,
    this.rpsPercentile,
    this.recent3ChangePct,
    this.recent5ChangePct,
    this.risingCount,
    this.fallingCount,
  });

  final String name;
  final String source;
  final double changePct;
  final String? code;
  final double? mainFlow;
  final double? mainFlowPct;
  final double? amount;
  final double? turnover;
  final double? volumeRatio;
  final double? openGapPct;
  final double? first15ChangePct;
  final double? first15VolumeRatio;
  final double? tail20ChangePct;
  final int? marketRank;
  final int? marketCount;
  final double? rpsPercentile;
  final double? recent3ChangePct;
  final double? recent5ChangePct;
  final int? risingCount;
  final int? fallingCount;
}

class EtfPricingSignal {
  EtfPricingSignal({
    required this.code,
    required this.name,
    required this.indexName,
    required this.changePct,
    required this.premiumDiscountRatio,
    this.volumeRatio,
    this.dealAmount,
    this.totalShare,
  });

  final String code;
  final String name;
  final String indexName;
  final double changePct;
  final double premiumDiscountRatio;
  final double? volumeRatio;
  final double? dealAmount;
  final double? totalShare;
}

class YesterdayReview {
  YesterdayReview({
    required this.headline,
    required this.detail,
    required this.diagnosis,
    required this.nextAdjustment,
    this.success,
    this.predictedDirection = 0,
    this.actualDirection = 0,
    this.scoreAdjustment = 0,
  });

  final String headline;
  final String detail;
  final String diagnosis;
  final String nextAdjustment;
  final bool? success;
  final int predictedDirection;
  final int actualDirection;
  final int scoreAdjustment;
}

class GridBattlePlan {
  GridBattlePlan({
    required this.upperTrigger,
    required this.upperAction,
    required this.currentValue,
    required this.currentZone,
    required this.lowerTrigger,
    required this.lowerAction,
  });

  final String upperTrigger;
  final String upperAction;
  final String currentValue;
  final String currentZone;
  final String lowerTrigger;
  final String lowerAction;
}

class MarketBreadthSignal {
  MarketBreadthSignal({
    required this.risingCount,
    required this.fallingCount,
    required this.flatCount,
    required this.summary,
    required this.score,
  });

  final int risingCount;
  final int fallingCount;
  final int flatCount;
  final String summary;
  final int score;
}

class MarketSnapshot {
  MarketSnapshot({
    required this.label,
    required this.averageChange,
    this.board,
    this.etfPricing,
    this.overnight,
    this.marketBreadth,
  });

  final String label;
  final double averageChange;
  final BoardSignal? board;
  final EtfPricingSignal? etfPricing;
  final OvernightSignal? overnight;
  final MarketBreadthSignal? marketBreadth;
}

class ForwardDecisionScore {
  ForwardDecisionScore({
    required this.total,
    required this.fundFlowScore,
    required this.tailScore,
    required this.volumeScore,
    required this.fundFlowText,
    required this.tailText,
    required this.volumeText,
    required this.conclusion,
    required this.confidence,
  });

  final int total;
  final int fundFlowScore;
  final int tailScore;
  final int volumeScore;
  final String fundFlowText;
  final String tailText;
  final String volumeText;
  final String conclusion;
  final String confidence;
}

class DecisionModel {
  DecisionModel({
    required this.confidence,
    required this.temperatureScore,
    required this.temperatureLabel,
    required this.macroState,
    required this.macroTone,
    required this.valuationState,
    required this.valuationTone,
    required this.trendState,
    required this.trendTone,
    required this.smartMoneyState,
    required this.smartMoneyTone,
    required this.etfPricingState,
    required this.etfPricingTone,
    required this.costDeviationText,
    required this.deviationTone,
    required this.resonanceState,
    required this.resonanceTone,
    required this.durationState,
    required this.durationTone,
    required this.holdingCycleState,
    required this.holdingCycleTone,
    required this.gridTrigger,
    required this.summary,
    required this.reason,
  });

  final String confidence;
  final int temperatureScore;
  final String temperatureLabel;
  final String macroState;
  final String macroTone;
  final String valuationState;
  final String valuationTone;
  final String trendState;
  final String trendTone;
  final String smartMoneyState;
  final String smartMoneyTone;
  final String etfPricingState;
  final String etfPricingTone;
  final String costDeviationText;
  final String deviationTone;
  final String resonanceState;
  final String resonanceTone;
  final String durationState;
  final String durationTone;
  final String holdingCycleState;
  final String holdingCycleTone;
  final String gridTrigger;
  final String summary;
  final String reason;

  Map<String, dynamic> toJson() => {
        'confidence': confidence,
        'temperatureScore': temperatureScore,
        'temperatureLabel': temperatureLabel,
        'macroState': macroState,
        'macroTone': macroTone,
        'valuationState': valuationState,
        'valuationTone': valuationTone,
        'trendState': trendState,
        'trendTone': trendTone,
        'smartMoneyState': smartMoneyState,
        'smartMoneyTone': smartMoneyTone,
        'etfPricingState': etfPricingState,
        'etfPricingTone': etfPricingTone,
        'costDeviationText': costDeviationText,
        'deviationTone': deviationTone,
        'resonanceState': resonanceState,
        'resonanceTone': resonanceTone,
        'durationState': durationState,
        'durationTone': durationTone,
        'holdingCycleState': holdingCycleState,
        'holdingCycleTone': holdingCycleTone,
        'gridTrigger': gridTrigger,
        'summary': summary,
        'reason': reason,
      };

  factory DecisionModel.fromJson(Map<String, dynamic> json) => DecisionModel(
        confidence: (json['confidence'] ?? '').toString(),
        temperatureScore: toInt(json['temperatureScore']),
        temperatureLabel: (json['temperatureLabel'] ?? '方向待确认').toString(),
        macroState: (json['macroState'] ?? '').toString(),
        macroTone: (json['macroTone'] ?? 'warn').toString(),
        valuationState: (json['valuationState'] ?? '').toString(),
        valuationTone: (json['valuationTone'] ?? 'warn').toString(),
        trendState: (json['trendState'] ?? '').toString(),
        trendTone: (json['trendTone'] ?? 'warn').toString(),
        smartMoneyState: (json['smartMoneyState'] ?? '').toString(),
        smartMoneyTone: (json['smartMoneyTone'] ?? 'warn').toString(),
        etfPricingState: (json['etfPricingState'] ?? '').toString(),
        etfPricingTone: (json['etfPricingTone'] ?? 'warn').toString(),
        costDeviationText: (json['costDeviationText'] ?? '').toString(),
        deviationTone: (json['deviationTone'] ?? 'warn').toString(),
        resonanceState: (json['resonanceState'] ?? '').toString(),
        resonanceTone: (json['resonanceTone'] ?? 'warn').toString(),
        durationState: (json['durationState'] ?? '').toString(),
        durationTone: (json['durationTone'] ?? 'warn').toString(),
        holdingCycleState: (json['holdingCycleState'] ?? '持有周期数据等待刷新。').toString(),
        holdingCycleTone: (json['holdingCycleTone'] ?? 'warn').toString(),
        gridTrigger: (json['gridTrigger'] ?? '').toString(),
        summary: (json['summary'] ?? '').toString(),
        reason: (json['reason'] ?? '').toString(),
      );

  DecisionModel copyWith({
    String? confidence,
    int? temperatureScore,
    String? temperatureLabel,
    String? macroState,
    String? macroTone,
    String? valuationState,
    String? valuationTone,
    String? trendState,
    String? trendTone,
    String? smartMoneyState,
    String? smartMoneyTone,
    String? etfPricingState,
    String? etfPricingTone,
    String? costDeviationText,
    String? deviationTone,
    String? resonanceState,
    String? resonanceTone,
    String? durationState,
    String? durationTone,
    String? holdingCycleState,
    String? holdingCycleTone,
    String? gridTrigger,
    String? summary,
    String? reason,
  }) {
    return DecisionModel(
      confidence: confidence ?? this.confidence,
      temperatureScore: temperatureScore ?? this.temperatureScore,
      temperatureLabel: temperatureLabel ?? this.temperatureLabel,
      macroState: macroState ?? this.macroState,
      macroTone: macroTone ?? this.macroTone,
      valuationState: valuationState ?? this.valuationState,
      valuationTone: valuationTone ?? this.valuationTone,
      trendState: trendState ?? this.trendState,
      trendTone: trendTone ?? this.trendTone,
      smartMoneyState: smartMoneyState ?? this.smartMoneyState,
      smartMoneyTone: smartMoneyTone ?? this.smartMoneyTone,
      etfPricingState: etfPricingState ?? this.etfPricingState,
      etfPricingTone: etfPricingTone ?? this.etfPricingTone,
      costDeviationText: costDeviationText ?? this.costDeviationText,
      deviationTone: deviationTone ?? this.deviationTone,
      resonanceState: resonanceState ?? this.resonanceState,
      resonanceTone: resonanceTone ?? this.resonanceTone,
      durationState: durationState ?? this.durationState,
      durationTone: durationTone ?? this.durationTone,
      holdingCycleState: holdingCycleState ?? this.holdingCycleState,
      holdingCycleTone: holdingCycleTone ?? this.holdingCycleTone,
      gridTrigger: gridTrigger ?? this.gridTrigger,
      summary: summary ?? this.summary,
      reason: reason ?? this.reason,
    );
  }
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
    required this.todayConfidence,
    required this.todayReason,
    required this.actionReason,
    required this.buyReason,
    required this.sellReason,
    required this.durationText,
    required this.durationReason,
    required this.futureDaysText,
    required this.volatilityText,
    required this.downsideRiskText,
    required this.summaryLine,
    required this.realtimeAvailable,
    required this.realtimeNavText,
    required this.realtimeTimeText,
    required this.realtimeStatus,
    required this.intradayPoints,
    required this.intradayNote,
    required this.decision,
    required this.holdings,
    required this.announcements,
    required this.liquorSpecial,
    required this.battlePlan,
    required this.settledItem,
    required this.holdingSourceText,
    required this.holdingStatusText,
    required this.holdingStatusBadge,
    required this.holdingStatusTone,
    this.yesterdayReview,
    this.todayLockedAt = '',
    this.tomorrowLockedAt = '',
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
  final String todayConfidence;
  final String todayReason;
  final String actionReason;
  final String buyReason;
  final String sellReason;
  final String durationText;
  final String durationReason;
  final String futureDaysText;
  final String volatilityText;
  final String downsideRiskText;
  final String summaryLine;
  final bool realtimeAvailable;
  final String realtimeNavText;
  final String realtimeTimeText;
  final String realtimeStatus;
  final List<IntradayPoint> intradayPoints;
  final String intradayNote;
  final DecisionModel decision;
  final List<StockHolding> holdings;
  final List<Announcement> announcements;
  final String? liquorSpecial;
  final GridBattlePlan battlePlan;
  final PortfolioItem settledItem;
  final String holdingSourceText;
  final String holdingStatusText;
  final String holdingStatusBadge;
  final String holdingStatusTone;
  final YesterdayReview? yesterdayReview;
  final String todayLockedAt;
  final String tomorrowLockedAt;

  String get todayLockText => todayLockedAt.isEmpty ? '09:45 前预判' : '09:45 已锁定';
  String get tomorrowLockText => tomorrowLockedAt.isEmpty ? '14:45 前推演' : '14:45 已锁定';
  String get lockHintText => tomorrowLockedAt.isNotEmpty ? '大盘定调和明日推演已锁定' : '大盘定调已锁定';
  bool get officialNavUpdated => realtimeStatus.contains('实际净值');
  String get updateMetricLabel => officialNavUpdated ? '更新状态' : '更新时间';
  String get updateMetricValue {
    if (officialNavUpdated) return '已更新官方净值';
    if (realtimeTimeText == '等待刷新') return realtimeTimeText;
    return realtimeTimeText.contains(':') ? '$realtimeTimeText 估算' : realtimeTimeText;
  }

  FundAnalysis copyWith({
    String? todayState,
    String? tomorrowTrend,
    double? probabilityUp,
    String? action,
    double? buyRatio,
    double? sellRatio,
    String? confidence,
    String? todayConfidence,
    String? todayReason,
    String? actionReason,
    String? buyReason,
    String? sellReason,
    String? durationText,
    String? durationReason,
    String? futureDaysText,
    String? volatilityText,
    String? downsideRiskText,
    String? summaryLine,
    DecisionModel? decision,
    GridBattlePlan? battlePlan,
    YesterdayReview? yesterdayReview,
    String? todayLockedAt,
    String? tomorrowLockedAt,
  }) {
    return FundAnalysis(
      code: code,
      name: name,
      theme: theme,
      analysisDate: analysisDate,
      latestDate: latestDate,
      latestValue: latestValue,
      todayPct: todayPct,
      todayState: todayState ?? this.todayState,
      tomorrowTrend: tomorrowTrend ?? this.tomorrowTrend,
      probabilityUp: probabilityUp ?? this.probabilityUp,
      action: action ?? this.action,
      buyRatio: buyRatio ?? this.buyRatio,
      sellRatio: sellRatio ?? this.sellRatio,
      confidence: confidence ?? this.confidence,
      todayConfidence: todayConfidence ?? this.todayConfidence,
      todayReason: todayReason ?? this.todayReason,
      actionReason: actionReason ?? this.actionReason,
      buyReason: buyReason ?? this.buyReason,
      sellReason: sellReason ?? this.sellReason,
      durationText: durationText ?? this.durationText,
      durationReason: durationReason ?? this.durationReason,
      futureDaysText: futureDaysText ?? this.futureDaysText,
      volatilityText: volatilityText ?? this.volatilityText,
      downsideRiskText: downsideRiskText ?? this.downsideRiskText,
      summaryLine: summaryLine ?? this.summaryLine,
      realtimeAvailable: realtimeAvailable,
      realtimeNavText: realtimeNavText,
      realtimeTimeText: realtimeTimeText,
      realtimeStatus: realtimeStatus,
      intradayPoints: intradayPoints,
      intradayNote: intradayNote,
      decision: decision ?? this.decision,
      holdings: holdings,
      announcements: announcements,
      liquorSpecial: liquorSpecial,
      battlePlan: battlePlan ?? this.battlePlan,
      settledItem: settledItem,
      holdingSourceText: holdingSourceText,
      holdingStatusText: holdingStatusText,
      holdingStatusBadge: holdingStatusBadge,
      holdingStatusTone: holdingStatusTone,
      yesterdayReview: yesterdayReview ?? this.yesterdayReview,
      todayLockedAt: todayLockedAt ?? this.todayLockedAt,
      tomorrowLockedAt: tomorrowLockedAt ?? this.tomorrowLockedAt,
    );
  }
}

class AnalysisLockState {
  AnalysisLockState({
    required this.code,
    required this.date,
    this.todayLockedAt = '',
    this.todayState,
    this.todayConfidence,
    this.todayReason,
    this.tomorrowLockedAt = '',
    this.tomorrowTrend,
    this.probabilityUp,
    this.action,
    this.buyRatio,
    this.sellRatio,
    this.confidence,
    this.actionReason,
    this.buyReason,
    this.sellReason,
    this.durationText,
    this.durationReason,
    this.futureDaysText,
    this.volatilityText,
    this.downsideRiskText,
    this.summaryLine,
    this.decision,
  });

  final String code;
  final String date;
  final String todayLockedAt;
  final String? todayState;
  final String? todayConfidence;
  final String? todayReason;
  final String tomorrowLockedAt;
  final String? tomorrowTrend;
  final double? probabilityUp;
  final String? action;
  final double? buyRatio;
  final double? sellRatio;
  final String? confidence;
  final String? actionReason;
  final String? buyReason;
  final String? sellReason;
  final String? durationText;
  final String? durationReason;
  final String? futureDaysText;
  final String? volatilityText;
  final String? downsideRiskText;
  final String? summaryLine;
  final DecisionModel? decision;

  bool get hasTodayLock => todayLockedAt.isNotEmpty && todayState != null && todayReason != null;
  bool get hasTomorrowLock => tomorrowLockedAt.isNotEmpty && tomorrowTrend != null && action != null && decision != null;

  AnalysisLockState copyWith({
    String? todayLockedAt,
    String? todayState,
    String? todayConfidence,
    String? todayReason,
    String? tomorrowLockedAt,
    String? tomorrowTrend,
    double? probabilityUp,
    String? action,
    double? buyRatio,
    double? sellRatio,
    String? confidence,
    String? actionReason,
    String? buyReason,
    String? sellReason,
    String? durationText,
    String? durationReason,
    String? futureDaysText,
    String? volatilityText,
    String? downsideRiskText,
    String? summaryLine,
    DecisionModel? decision,
  }) {
    return AnalysisLockState(
      code: code,
      date: date,
      todayLockedAt: todayLockedAt ?? this.todayLockedAt,
      todayState: todayState ?? this.todayState,
      todayConfidence: todayConfidence ?? this.todayConfidence,
      todayReason: todayReason ?? this.todayReason,
      tomorrowLockedAt: tomorrowLockedAt ?? this.tomorrowLockedAt,
      tomorrowTrend: tomorrowTrend ?? this.tomorrowTrend,
      probabilityUp: probabilityUp ?? this.probabilityUp,
      action: action ?? this.action,
      buyRatio: buyRatio ?? this.buyRatio,
      sellRatio: sellRatio ?? this.sellRatio,
      confidence: confidence ?? this.confidence,
      actionReason: actionReason ?? this.actionReason,
      buyReason: buyReason ?? this.buyReason,
      sellReason: sellReason ?? this.sellReason,
      durationText: durationText ?? this.durationText,
      durationReason: durationReason ?? this.durationReason,
      futureDaysText: futureDaysText ?? this.futureDaysText,
      volatilityText: volatilityText ?? this.volatilityText,
      downsideRiskText: downsideRiskText ?? this.downsideRiskText,
      summaryLine: summaryLine ?? this.summaryLine,
      decision: decision ?? this.decision,
    );
  }

  AnalysisLockState captureToday(FundAnalysis analysis, String lockedAt) {
    return copyWith(
      todayLockedAt: lockedAt,
      todayState: analysis.todayState,
      todayConfidence: analysis.todayConfidence,
      todayReason: analysis.todayReason,
    );
  }

  AnalysisLockState captureTomorrow(FundAnalysis analysis, String lockedAt) {
    return copyWith(
      tomorrowLockedAt: lockedAt,
      tomorrowTrend: analysis.tomorrowTrend,
      probabilityUp: analysis.probabilityUp,
      action: analysis.action,
      buyRatio: analysis.buyRatio,
      sellRatio: analysis.sellRatio,
      confidence: analysis.confidence,
      actionReason: analysis.actionReason,
      buyReason: analysis.buyReason,
      sellReason: analysis.sellReason,
      durationText: analysis.durationText,
      durationReason: analysis.durationReason,
      futureDaysText: analysis.futureDaysText,
      volatilityText: analysis.volatilityText,
      downsideRiskText: analysis.downsideRiskText,
      summaryLine: analysis.summaryLine,
      decision: analysis.decision,
    );
  }

  FundAnalysis applyTo(FundAnalysis analysis) {
    final lockedDecision = hasTomorrowLock && decision != null
        ? decision!.copyWith(
            gridTrigger: analysis.decision.gridTrigger,
            holdingCycleState: analysis.decision.holdingCycleState,
            holdingCycleTone: analysis.decision.holdingCycleTone,
            etfPricingState: analysis.decision.etfPricingState,
            etfPricingTone: analysis.decision.etfPricingTone,
          )
        : null;
    final resolvedTodayState = hasTodayLock ? lockedDirectionOrLive(todayState, analysis.todayState, today: true) : null;
    final resolvedTomorrowTrend = hasTomorrowLock ? lockedDirectionOrLive(tomorrowTrend, analysis.tomorrowTrend, today: false) : null;
    return analysis.copyWith(
      todayState: resolvedTodayState,
      todayConfidence: hasTodayLock ? todayConfidence : null,
      todayReason: hasTodayLock ? todayReason : null,
      todayLockedAt: hasTodayLock ? todayLockedAt : analysis.todayLockedAt,
      tomorrowTrend: resolvedTomorrowTrend,
      probabilityUp: hasTomorrowLock ? probabilityUp : null,
      action: hasTomorrowLock ? action : null,
      buyRatio: hasTomorrowLock ? buyRatio : null,
      sellRatio: hasTomorrowLock ? sellRatio : null,
      confidence: hasTomorrowLock ? confidence : null,
      actionReason: hasTomorrowLock ? actionReason : null,
      buyReason: hasTomorrowLock ? buyReason : null,
      sellReason: hasTomorrowLock ? sellReason : null,
      durationText: hasTomorrowLock ? durationText : null,
      durationReason: hasTomorrowLock ? durationReason : null,
      futureDaysText: hasTomorrowLock ? futureDaysText : null,
      volatilityText: hasTomorrowLock ? volatilityText : null,
      downsideRiskText: hasTomorrowLock ? downsideRiskText : null,
      summaryLine: hasTomorrowLock ? summaryLine : null,
      decision: lockedDecision,
      tomorrowLockedAt: hasTomorrowLock ? tomorrowLockedAt : analysis.tomorrowLockedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'date': date,
        'todayLockedAt': todayLockedAt,
        'todayState': todayState,
        'todayConfidence': todayConfidence,
        'todayReason': todayReason,
        'tomorrowLockedAt': tomorrowLockedAt,
        'tomorrowTrend': tomorrowTrend,
        'probabilityUp': probabilityUp,
        'action': action,
        'buyRatio': buyRatio,
        'sellRatio': sellRatio,
        'confidence': confidence,
        'actionReason': actionReason,
        'buyReason': buyReason,
        'sellReason': sellReason,
        'durationText': durationText,
        'durationReason': durationReason,
        'futureDaysText': futureDaysText,
        'volatilityText': volatilityText,
        'downsideRiskText': downsideRiskText,
        'summaryLine': summaryLine,
        'decision': decision?.toJson(),
      };

  factory AnalysisLockState.fromJson(Map<String, dynamic> json) => AnalysisLockState(
        code: (json['code'] ?? '').toString(),
        date: (json['date'] ?? '').toString(),
        todayLockedAt: (json['todayLockedAt'] ?? '').toString(),
        todayState: json['todayState']?.toString(),
        todayConfidence: json['todayConfidence']?.toString(),
        todayReason: json['todayReason']?.toString(),
        tomorrowLockedAt: (json['tomorrowLockedAt'] ?? '').toString(),
        tomorrowTrend: json['tomorrowTrend']?.toString(),
        probabilityUp: toNullableDouble(json['probabilityUp']),
        action: json['action']?.toString(),
        buyRatio: toNullableDouble(json['buyRatio']),
        sellRatio: toNullableDouble(json['sellRatio']),
        confidence: json['confidence']?.toString(),
        actionReason: json['actionReason']?.toString(),
        buyReason: json['buyReason']?.toString(),
        sellReason: json['sellReason']?.toString(),
        durationText: json['durationText']?.toString(),
        durationReason: json['durationReason']?.toString(),
        futureDaysText: json['futureDaysText']?.toString(),
        volatilityText: json['volatilityText']?.toString(),
        downsideRiskText: json['downsideRiskText']?.toString(),
        summaryLine: json['summaryLine']?.toString(),
        decision: json['decision'] is Map ? DecisionModel.fromJson((json['decision'] as Map).cast<String, dynamic>()) : null,
      );
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

String? extractJsonLike(String raw) {
  final trimmed = raw.trim();
  final objectStart = trimmed.indexOf('{');
  final arrayStart = trimmed.indexOf('[');
  final starts = [objectStart, arrayStart].where((index) => index >= 0).toList()..sort();
  if (starts.isEmpty) return null;
  final start = starts.first;
  final end = trimmed[start] == '{' ? trimmed.lastIndexOf('}') : trimmed.lastIndexOf(']');
  if (end <= start) return null;
  return trimmed.substring(start, end + 1);
}

Map<String, String> noCacheHeaders([Map<String, String> extra = const {}]) {
  return {
    'User-Agent': 'Mozilla/5.0',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
    ...extra,
  };
}

List<StockHolding> parseHoldingsHtml(String raw) {
  var content = RegExp(r'content:"(.*?)",arryear', dotAll: true).firstMatch(raw)?.group(1) ?? raw;
  content = content.replaceAll(r'\"', '"').replaceAll(r'\/', '/');
  final rows = RegExp(r'<tr>(.*?)</tr>', dotAll: true).allMatches(content);
  final holdings = <StockHolding>[];
  for (final row in rows) {
    final cells = RegExp(r'<td.*?>(.*?)</td>', dotAll: true).allMatches(row.group(1)!).map((cell) => stripTags(cell.group(1)!)).toList();
    if (cells.length < 7) continue;
    final stockCode = RegExp(r'\d{6}').firstMatch(cells[1])?.group(0);
    if (stockCode == null) continue;
    final name = cells.length > 2 ? cells[2] : '股票$stockCode';
    final pctCell = cells.reversed.firstWhere((cell) => cell.contains('%'), orElse: () => '0');
    final holdingPct = toDouble(pctCell.replaceAll('%', '').replaceAll(',', ''));
    holdings.add(
      StockHolding(
        code: stockCode,
        name: name,
        industry: '行业暂缺',
        holdingPct: holdingPct,
      ),
    );
    if (holdings.length >= 10) break;
  }
  return holdings;
}

dynamic decodeNestedFundPayload(dynamic payload) {
  if (payload is Map && payload['data'] is String) {
    final text = (payload['data'] as String).trim();
    if (text.isNotEmpty) {
      try {
        return jsonDecode(text);
      } catch (_) {
        return payload;
      }
    }
  }
  return payload;
}

dynamic firstValue(Map<dynamic, dynamic> row, List<String> keys) {
  for (final key in keys) {
    if (row.containsKey(key)) return row[key];
    final lower = key.toLowerCase();
    for (final entry in row.entries) {
      if (entry.key.toString().toLowerCase() == lower) return entry.value;
    }
  }
  return null;
}

double? firstNumber(Map<dynamic, dynamic> row, List<String> keys) {
  final value = firstValue(row, keys);
  if (value == null) return null;
  return toNullableDouble(value);
}

int toInt(dynamic value) {
  if (value == null) return 0;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? 0;
}

double navFromChange(double change, RealtimeEstimate? realtime, double fallbackNav) {
  final base = realtime == null
      ? fallbackNav
      : realtime.officialNav > 0
          ? realtime.officialNav
          : realtime.estimatedNav / (1 + realtime.estimatePct / 100);
  if (base <= 0) return 0;
  return base * (1 + change / 100);
}

int minimumMinutePointCount() {
  final now = DateTime.now();
  final elapsed = tradingMinute(now);
  if (elapsed <= 0) return 8;
  return min(132, max(8, (elapsed * 0.55).round()));
}

DateTime? parseIntradayTime(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final raw = value.toInt();
    if (raw > 1000000000000) return DateTime.fromMillisecondsSinceEpoch(raw);
    if (raw > 1000000000) return DateTime.fromMillisecondsSinceEpoch(raw * 1000);
  }
  var text = value.toString().trim();
  if (text.isEmpty || text == '-') return null;
  final dateMillis = RegExp(r'\d{10,13}').firstMatch(text)?.group(0);
  if (dateMillis != null && text.contains('Date')) return parseIntradayTime(int.tryParse(dateMillis));
  text = text.replaceAll('/', '-');
  final full = RegExp(r'(\d{4}-\d{1,2}-\d{1,2})\s+(\d{1,2}:\d{2}(?::\d{2})?)').firstMatch(text);
  if (full != null) return DateTime.tryParse('${full.group(1)}T${full.group(2)}');
  final clock = RegExp(r'(\d{1,2}):(\d{2})(?::\d{2})?').firstMatch(text);
  if (clock != null) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, int.parse(clock.group(1)!), int.parse(clock.group(2)!));
  }
  final compact = RegExp(r'^\d{3,4}$').firstMatch(text);
  if (compact != null) {
    final now = DateTime.now();
    final padded = text.padLeft(4, '0');
    return DateTime(now.year, now.month, now.day, int.parse(padded.substring(0, 2)), int.parse(padded.substring(2)));
  }
  return DateTime.tryParse(text);
}

Rect chartPlotRect(Size size) => Rect.fromLTWH(42, 10, max(1, size.width - 54), max(1, size.height - 46));

double chartAxisMax(List<IntradayPoint> points, double fallbackPct) {
  var maxAbs = fallbackPct.abs();
  for (final point in points) {
    maxAbs = max(maxAbs, point.changePct.abs());
  }
  return max(0.6, maxAbs);
}

double chartX(IntradayPoint point, Rect plot) => plot.left + (tradingMinute(point.time).clamp(0, 240).toDouble() / 240) * plot.width;
double chartY(double pctValue, Rect plot, double axisMax) => plot.center.dy - (pctValue / axisMax) * (plot.height / 2);

int tradingMinute(DateTime time) {
  final minute = time.hour * 60 + time.minute;
  if (minute <= 9 * 60 + 30) return 0;
  if (minute <= 11 * 60 + 30) return minute - (9 * 60 + 30);
  if (minute < 13 * 60) return 120;
  if (minute <= 15 * 60) return 120 + minute - 13 * 60;
  return 240;
}

String formatClock(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

bool isDirectionLabel(String? text, {required bool today}) {
  if (text == null) return false;
  final prefix = today ? '今天' : '明天';
  return RegExp('^$prefix(偏涨|小涨|震荡|小跌|偏跌)\$').hasMatch(text.trim());
}

String lockedDirectionOrLive(String? locked, String live, {required bool today}) {
  final value = locked?.trim();
  if (isDirectionLabel(value, today: today)) return value!;
  return live;
}

String compactDecisionText(String label, String value, String tone) {
  final clean = value
      .replaceAll(RegExp(r'得分\s*[+-]?\d+'), '')
      .replaceAll(RegExp(r'MA\d+\s*[+-]?\d+(\.\d+)?%?'), '')
      .replaceAll(RegExp(r'RSI\d*\s*\d+(\.\d+)?'), '')
      .replaceAll(RegExp(r'Bias\d*\s*[+-]?\d+(\.\d+)?%?'), '')
      .replaceAll('当前按低权重处理', '')
      .replaceAll('北向收盘后接口经常归零', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final flowMatch = RegExp(r'主力净(流入|流出)\s*([0-9.]+亿)').firstMatch(clean);
  final premiumMatch = RegExp(r'折溢价\s*([+-]?[0-9.]+%)').firstMatch(clean);

  switch (label) {
    case '外围背景':
      if (tone == 'good') return '外围和大盘环境偏暖，明天更容易顺风。';
      if (tone == 'bad') return '外围或大盘情绪偏弱，明天先防回落。';
      return '外围和大盘没有明显站队，主要看板块资金。';
    case '板块资金':
      if (flowMatch != null) {
        final direction = flowMatch.group(1)!;
        final amount = flowMatch.group(2)!;
        return direction == '流入' ? '主力净流入 $amount，资金仍在买入。' : '主力净流出 $amount，抛压偏重。';
      }
      if (tone == 'good') return '板块资金偏流入，有资金支撑。';
      if (tone == 'bad') return '板块资金偏流出，追涨风险更高。';
      return '板块资金方向不够清楚，先不做强判断。';
    case '尾盘动向':
      if (clean.contains('合力抢筹') || clean.contains('分化')) return '核心重仓股尾盘分化，未见合力抢筹。';
      if (clean.contains('走强') || clean.contains('抢筹')) return '核心重仓股尾盘走强，有资金抢筹迹象。';
      if (clean.contains('走弱') || clean.contains('卖压')) return '核心重仓股尾盘走弱，卖压还没散。';
      return tone == 'good' ? '尾盘承接偏强。' : tone == 'bad' ? '尾盘承接偏弱。' : '尾盘没有给出强方向。';
    case '聪明资金':
      if (tone == 'good') return '机构、大单和杠杆资金偏积极。';
      if (tone == 'bad') return '机构、大单和杠杆资金偏谨慎。';
      return '机构、大单和杠杆资金分歧，暂不支持激进操作。';
    case 'ETF折溢价':
      if (premiumMatch != null) {
        final premium = premiumMatch.group(1)!;
        return tone == 'bad' ? 'ETF 折溢价 $premium，警惕溢价回落。' : 'ETF 折溢价 $premium，情绪没有明显失真。';
      }
      return 'ETF 折溢价等待刷新，暂不作为硬判断。';
    case '量价状态':
      if (clean.contains('量价背离') || clean.contains('量能没有跟上')) return '上涨缺少量能配合，追价意愿偏弱。';
      if (clean.contains('上涨时量能')) return '上涨时量能还能配合，承接不差。';
      if (clean.contains('上涨') && clean.contains('下跌')) return '市场广度已纳入判断，指数没有单边确认。';
      return tone == 'good' ? '量价配合偏好。' : tone == 'bad' ? '量价配合偏弱。' : '量能还不够清楚，先看承接。';
    case '趋势共振':
      if (tone == 'good') return '大盘、板块和均线方向偏顺。';
      if (tone == 'bad') return '当前位置接近压力位，短线缺少上行动能。';
      return '趋势还没完全站稳，明天先看资金能否继续跟。';
    case '后面几天':
      if (clean.contains('回调')) return '短期可能回调 1-2 天，先防守。';
      if (clean.contains('上涨') || clean.contains('修复')) return '短期仍有修复空间，但要看量能。';
      return '后面几天更像震荡，别把一天波动看太重。';
    case 'T+7 安全垫':
      if (clean.contains('免除') || clean.contains('满 7 天')) return '持有份额已满足 7 天，卖出不触发惩罚手续费。';
      if (clean.contains('未满') || clean.contains('锁定')) return '部分份额仍受 7 天手续费约束，卖出前要谨慎。';
      return '持有周期还在核对，先按保守规则处理。';
  }
  return clean.isEmpty ? '等待真实数据刷新。' : clean;
}

Color toneColor(String tone) {
  if (tone == 'good') return AppColors.red;
  if (tone == 'bad') return AppColors.green;
  return AppColors.muted;
}

IconData toneIcon(String tone) {
  if (tone == 'good') return CupertinoIcons.arrow_up_circle_fill;
  if (tone == 'bad') return CupertinoIcons.arrow_down_circle_fill;
  return CupertinoIcons.minus_circle_fill;
}

String actionReasonSide(String action, double buyRatio, double sellRatio) {
  if (RegExp(r'观望|不动|等待|风险不可控|方向不明|实时数据').hasMatch(action)) return 'hold';
  final buyText = RegExp(r'买入|试探|加仓|低吸').hasMatch(action);
  final sellText = RegExp(r'卖出|减仓|降一点|小幅减|锁利润|止盈').hasMatch(action);
  if (buyText && !sellText) return 'buy';
  if (sellText && !buyText) return 'sell';
  if (buyRatio > 0 && sellRatio <= 0) return 'buy';
  if (sellRatio > 0 && buyRatio <= 0) return 'sell';
  if (buyRatio > 0 && sellRatio > 0) return buyRatio >= sellRatio ? 'buy' : 'sell';
  return 'hold';
}

String buildTodayDirectionText({required double todayPct, required int totalScore}) {
  if (todayPct >= 0.45 || totalScore >= 4) return '今天偏涨';
  if (todayPct <= -0.45 || totalScore <= -4) return '今天偏跌';
  if (todayPct >= 0.15 || totalScore >= 2) return '今天小涨';
  if (todayPct <= -0.15 || totalScore <= -2) return '今天小跌';
  return '今天震荡';
}

String buildTomorrowDirectionText({required int totalScore, required String confidence}) {
  if (confidence == '极低') return '明天震荡';
  if (totalScore >= 5) return '明天偏涨';
  if (totalScore <= -5) return '明天偏跌';
  if (totalScore >= 2) return '明天小涨';
  if (totalScore <= -2) return '明天小跌';
  return '明天震荡';
}

String futureDaysLabel({required DurationSignal duration, required int totalScore}) {
  final days = RegExp(r'\d+(?:-\d+)?\s*天').firstMatch(duration.summary)?.group(0)?.replaceAll(' ', '');
  final dayText = days ?? (duration.tone == 'good' ? '2-3天' : duration.tone == 'bad' ? '1-2天' : '1-2天');
  if (duration.tone == 'good' || totalScore >= 4) return '可能涨$dayText';
  if (duration.tone == 'bad' || totalScore <= -4) return '可能跌$dayText';
  return '震荡$dayText';
}

String volatilityLabel({required double atr14, required double oneMonthVolatility}) {
  final value = max(atr14, oneMonthVolatility);
  if (value >= 2.6) return '波动大';
  if (value >= 1.4) return '波动中';
  return '波动小';
}

String downsideRiskLabel({
  required int totalScore,
  required String confidence,
  required String durationTone,
  required bool majorNegative,
  required bool etfPremiumHigh,
  required bool highVolatility,
}) {
  if (confidence == '极低' || majorNegative || etfPremiumHigh) return '高';
  if (totalScore <= -4 || durationTone == 'bad') return '高';
  if (totalScore <= -2 || highVolatility) return '中';
  return '低';
}

String toneFromDirectionText(String text) {
  if (text.contains('偏涨') || text.contains('小涨')) return 'good';
  if (text.contains('偏跌') || text.contains('小跌')) return 'bad';
  return 'warn';
}

String beginnerActionText(FundAnalysis analysis) {
  if (analysis.buyRatio > 0 && analysis.sellRatio == 0) {
    return '这不是让你满仓追进去，而是说明上涨机会大于风险。可以按建议金额小额分批买，买完也要看后面几天是否继续放量。';
  }
  if (analysis.sellRatio > 0 && analysis.buyRatio == 0) {
    return '卖出不是清仓逃跑，而是先把一小部分风险降下来。后面几天偏弱、波动变大或下跌风险偏高时，先减一点会更稳。';
  }
  if (analysis.downsideRiskText == '高') {
    return '现在最重要的是别追。即使今天有反弹，后面几天也可能回落，等风险降下来再买更舒服。';
  }
  return '现在还没有强买点，也没有强卖点。新手最适合先不动，等明天方向、成交量和资金流再确认。';
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

List<TrendPoint> trendPointsFromPayload(Map<String, dynamic> payload) {
  final data = payload['data'] as Map<String, dynamic>?;
  final rows = (data?['trends'] as List<dynamic>? ?? []).map((item) => item.toString());
  final points = <TrendPoint>[];
  for (final row in rows) {
    final pieces = row.split(',');
    if (pieces.length < 7) continue;
    final time = DateTime.tryParse(pieces[0].trim().replaceFirst(' ', 'T'));
    final open = toDouble(pieces[1]);
    final close = toDouble(pieces[2]);
    final amount = toDouble(pieces[6]);
    if (time != null && open > 0 && close > 0) {
      points.add(TrendPoint(time: time, open: open, close: close, amount: amount));
    }
  }
  points.sort((a, b) => a.time.compareTo(b.time));
  return points;
}

BoardTrendStats? boardTrendStatsFromPayload(Map<String, dynamic> payload) {
  final data = payload['data'] as Map<String, dynamic>?;
  final prePrice = toDouble(data?['prePrice']);
  final points = trendPointsFromPayload(payload);
  if (points.length < 10) return null;
  final openGapPct = prePrice > 0 ? (points.first.open / prePrice - 1) * 100 : null;
  return BoardTrendStats(
    openGapPct: openGapPct,
    first15ChangePct: intervalChangeBetween(points, 9, 30, 9, 45),
    first15VolumeRatio: sameMinuteAmountRatioAt(points, 9, 45),
    tail20ChangePct: intervalChangeBetween(points, 14, 40, 15, 0),
    volumeRatio1440: sameMinuteAmountRatioAt(points, 14, 40),
  );
}

BoardTrendStats? boardDailyStatsFromPayload(Map<String, dynamic> payload) {
  final data = payload['data'] as Map<String, dynamic>?;
  final klines = (data?['klines'] as List<dynamic>? ?? []).whereType<String>().toList();
  if (klines.length < 3) return null;
  final closes = <double>[];
  for (final row in klines) {
    final parts = row.split(',');
    if (parts.length < 3) continue;
    final close = toNullableDouble(parts[2]);
    if (close != null && close > 0) closes.add(close);
  }
  if (closes.length < 3) return null;
  double? trailingChange(int days) {
    if (closes.length <= days) return null;
    final base = closes[closes.length - days - 1];
    final latest = closes.last;
    if (base <= 0) return null;
    return (latest / base - 1) * 100;
  }

  return BoardTrendStats(
    recent3ChangePct: trailingChange(3),
    recent5ChangePct: trailingChange(5),
  );
}

TailChange? tailChangeBetween(List<TrendPoint> points, int startHour, int startMinuteValue, int endHour, int endMinuteValue) {
  if (points.length < 2) return null;
  final latestDate = points.map((item) => dateKey(item.time)).reduce((a, b) => a.compareTo(b) > 0 ? a : b);
  final today = points.where((item) => dateKey(item.time) == latestDate).toList();
  if (today.length < 2) return null;
  final now = DateTime.now();
  final startTarget = tradingMinute(DateTime(now.year, now.month, now.day, startHour, startMinuteValue));
  final endTarget = tradingMinute(DateTime(now.year, now.month, now.day, endHour, endMinuteValue));
  TrendPoint? start;
  TrendPoint? end;
  for (final point in today) {
    final minute = tradingMinute(point.time);
    if (minute <= startTarget) start = point;
    if (minute <= endTarget) end = point;
  }
  end ??= today.last;
  start ??= today.first;
  if (end.time.isBefore(start.time) || start.close <= 0) return null;
  return TailChange(changePct: (end.close / start.close - 1) * 100, startTime: start.time, endTime: end.time);
}

double? sameMinuteAmountRatio(List<TrendPoint> points) {
  return sameMinuteAmountRatioAt(points, 14, 40);
}

double? sameMinuteAmountRatioAt(List<TrendPoint> points, int hour, int minute) {
  if (points.length < 60) return null;
  final dates = points.map((item) => dateKey(item.time)).toSet().toList()..sort();
  if (dates.length < 2) return null;
  final previousDate = dates[dates.length - 2];
  final latestDate = dates.last;
  final today = points.where((item) => dateKey(item.time) == latestDate).toList();
  final previous = points.where((item) => dateKey(item.time) == previousDate).toList();
  if (today.isEmpty || previous.isEmpty) return null;
  final now = DateTime.now();
  final decisionMinute = tradingMinute(DateTime(now.year, now.month, now.day, hour, minute));
  var latestMinute = 0;
  for (final point in today) {
    latestMinute = max(latestMinute, tradingMinute(point.time));
  }
  final referenceMinute = min(decisionMinute, latestMinute).toInt();
  final todayAmount = today.where((item) => tradingMinute(item.time) <= referenceMinute).map((item) => item.amount).sum;
  final previousAmount = previous.where((item) => tradingMinute(item.time) <= referenceMinute).map((item) => item.amount).sum;
  if (todayAmount <= 0 || previousAmount <= 0) return null;
  return todayAmount / previousAmount;
}

double? intervalChangeBetween(List<TrendPoint> points, int startHour, int startMinuteValue, int endHour, int endMinuteValue) {
  final tail = tailChangeBetween(points, startHour, startMinuteValue, endHour, endMinuteValue);
  return tail?.changePct;
}

String dateKey(DateTime time) => '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';

FeeWindowSnapshot buildFeeWindowSnapshot(PortfolioItem item, double latestNav) {
  final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  final trackedLots = item.holdingLots.where((lot) => lot.feeFreeDate.isNotEmpty).toList();
  double freeAmount = 0;
  double frozenAmount = 0;
  double progressWeight = 0;
  double progressTotal = 0;
  int? nearestDays;
  for (final lot in trackedLots) {
    final feeFreeDate = DateTime.tryParse(lot.feeFreeDate);
    final confirmDate = DateTime.tryParse(lot.confirmDate);
    if (feeFreeDate == null || confirmDate == null) continue;
    final currentValue = latestNav > 0 && lot.shares > 0 ? lot.shares * latestNav : lot.amount;
    final remainingDays = max(0, DateTime(feeFreeDate.year, feeFreeDate.month, feeFreeDate.day).difference(today).inDays);
    if (remainingDays > 0) {
      frozenAmount += currentValue;
      nearestDays = nearestDays == null ? remainingDays : min(nearestDays!, remainingDays);
    } else {
      freeAmount += currentValue;
    }
    final progressDays = (today.difference(DateTime(confirmDate.year, confirmDate.month, confirmDate.day)).inDays).clamp(0, 7).toDouble();
    progressWeight += currentValue;
    progressTotal += currentValue * (progressDays / 7);
  }
  final progress = progressWeight > 0 ? (progressTotal / progressWeight).clamp(0.0, 1.0) : null;
  final unknownText = item.untrackedAmount > 0 ? ' 另有历史持仓 ${money(item.untrackedAmount)} 缺少买入日记录，这部分今天先不乱猜是否已满 7 天。' : '';
  if (freeAmount > 0 && frozenAmount > 0) {
    return FeeWindowSnapshot(
      headline: '部分份额受限：已有 ${money(freeAmount)} 可免手续费卖出，另有 ${money(frozenAmount)} 还需再等 ${nearestDays ?? 0} 天。',
      detail: '今天若只想减仓，优先把卖出金额控制在 ${money(freeAmount)} 以内，会更稳。$unknownText',
      tone: 'warn',
      progress: progress,
    );
  }
  if (frozenAmount > 0) {
    return FeeWindowSnapshot(
      headline: '手续费锁定期：当前已记录份额里，还有 ${money(frozenAmount)} 需要再等 ${nearestDays ?? 0} 天。',
      detail: '如果今天强行卖出，这部分仍可能被 1.5% 惩罚性手续费咬掉利润。更适合先熬过解冻期再动。$unknownText',
      tone: 'bad',
      progress: progress,
    );
  }
  if (trackedLots.isNotEmpty) {
    return FeeWindowSnapshot(
      headline: '交易无限制：当前已记录份额均已满 7 天，今天卖出可免 1.5% 惩罚性手续费。',
      detail: item.untrackedAmount > 0 ? '已记录的这部分份额今天可以放心操作。$unknownText' : '这部分份额今天可以放心卖出，不再受 7 天免手续费门槛限制。',
      tone: 'good',
      progress: 1,
    );
  }
  if (item.untrackedAmount > 0) {
    return FeeWindowSnapshot(
      headline: '免手续费额度暂时还不能精确测算。',
      detail: '老持仓没有完整的买入日期记录；从现在开始新增的买入，系统会自动跟踪确认日和解冻进度。',
      tone: 'warn',
      progress: null,
    );
  }
  return FeeWindowSnapshot(
    headline: '当前还没有已确认的分笔持仓记录',
    detail: item.pendingAmount > 0 ? '等确认中资金在晚间折算成份额后，这里会开始显示 7 天免手续费进度。' : '后续新增买入一旦确认，这里会自动开始计算解冻进度。',
    tone: 'warn',
    progress: null,
  );
}

int? durationUpperBoundDays(String summary) {
  final match = RegExp(r'(\d+)\s*-\s*(\d+)\s*天').firstMatch(summary);
  if (match != null) return int.tryParse(match.group(2)!);
  final single = RegExp(r'(\d+)\s*天').firstMatch(summary);
  if (single != null) return int.tryParse(single.group(1)!);
  return null;
}

BoardSignal? boardSignalFromHoldings(String theme, List<StockHolding> holdings) {
  final quoted = holdings.where((item) => item.changePct != null).toList();
  if (quoted.isEmpty) return null;
  final totalWeight = quoted.map((item) => item.holdingPct).sum;
  final weightedChange = totalWeight <= 0
      ? quoted.map((item) => item.changePct!).averageOrZero
      : quoted.map((item) => item.changePct! * item.holdingPct).sum / totalWeight;
  final flow = weightedHoldingFlow(holdings);
  final amountRows = holdings.where((item) => item.amount != null).toList();
  final mappedAmount = amountRows.isEmpty ? null : amountRows.map((item) => item.amount! * item.holdingPct / 100).sum;
  final risingCount = quoted.where((item) => (item.changePct ?? 0) > 0).length;
  final fallingCount = quoted.where((item) => (item.changePct ?? 0) < 0).length;
  return BoardSignal(
    name: theme.isEmpty ? '重仓股测算' : '$theme重仓股测算',
    source: '前十大重仓股实时测算',
    changePct: weightedChange,
    mainFlow: flow,
    mainFlowPct: averageHoldingFlowPct(holdings),
    amount: mappedAmount,
    risingCount: risingCount,
    fallingCount: fallingCount,
  );
}

List<String> themeKeywords(String theme) {
  if (theme.contains('电池')) return const ['动力电池', '锂电池', '刀片电池', '电池化学品', '电池', '储能'];
  if (theme.contains('新能源')) return const ['新能源车', '电池', '储能', '光伏设备', '光伏'];
  if (theme.contains('白酒')) return const ['白酒', '酿酒'];
  if (theme.contains('医药')) return const ['医药', '医疗', '生物医药'];
  if (theme.contains('半导体')) return const ['半导体', '芯片', '半导体材料', '半导体设备'];
  if (theme.contains('军工')) return const ['军工', '航天', '航空'];
  return const [];
}

List<String> themeEventKeywords(String theme) {
  if (theme.contains('电池')) return const ['电池', '锂', '储能', '新能源车', '车展', '碳酸锂', '比亚迪', '宁德时代'];
  if (theme.contains('新能源')) return const ['新能源', '光伏', '储能', '车展', '锂', '硅料'];
  if (theme.contains('半导体')) return const ['半导体', '芯片', '晶圆', '台积电', '苹果发布会', '英伟达'];
  if (theme.contains('白酒')) return const ['白酒', '消费', '食品饮料', '中秋', '国庆'];
  if (theme.contains('医药')) return const ['医药', '创新药', '医保', '集采', '医疗器械'];
  return const [];
}

List<String> macroEventKeywords() => const [
      'PMI',
      '非农',
      'CPI',
      'PPI',
      '社融',
      '利率',
      '议息',
      '美联储',
      '央行',
      '国常会',
      '财报',
      '就业',
      '关税',
      '汇率',
    ];

bool containsAnyKeyword(String text, List<String> keywords) {
  if (text.isEmpty || keywords.isEmpty) return false;
  final upper = text.toUpperCase();
  return keywords.any((keyword) => text.contains(keyword) || upper.contains(keyword.toUpperCase()));
}

String describeEventWindow(DateTime? date) {
  if (date == null) return '近期';
  final now = DateTime.now();
  final delta = DateTime(date.year, date.month, date.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (delta <= 0) return '今天';
  if (delta == 1) return '明天';
  if (delta <= 3) return '未来三天';
  return '未来一周';
}

String joinSentences(List<String?> parts) {
  final cleaned = parts
      .whereType<String>()
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .map((item) => item.endsWith('。') || item.endsWith('！') || item.endsWith('？') ? item : '$item。')
      .toList();
  return cleaned.join(' ');
}

int themeBoardScore(String name, List<String> keywords) {
  var score = 0;
  for (final keyword in keywords) {
    if (name == keyword) score = max(score, 120 + keyword.length);
    if (name.contains(keyword)) score = max(score, 70 + keyword.length);
  }
  return score;
}

String sectorStateText(String theme, BoardSignal? board, MarketSnapshot market) {
  final label = board?.name ?? (theme.isEmpty ? '对应板块' : '$theme板块');
  if (board == null) return '$label资金等待交易时段刷新，大盘${market.label} ${pct(market.averageChange)}';
  return '$label ${pct(board.changePct)}，${flowDirectionText(board.mainFlow, board.mainFlowPct)}';
}

double sectorScore(BoardSignal? board, MarketSnapshot market) {
  if (board == null) return (market.averageChange / 2).clamp(-0.3, 0.3).toDouble();
  final pricePart = (board.changePct / 3.5).clamp(-0.45, 0.45).toDouble();
  final flowPart = flowStrengthScore(board.mainFlow, board.mainFlowPct) * 0.65;
  return (pricePart + flowPart).clamp(-1.0, 1.0).toDouble();
}

String coreHoldingStateText(List<StockHolding> holdings) {
  final quoted = holdings.where((item) => item.changePct != null).toList();
  if (quoted.isEmpty) return '核心重仓股等待实时行情，暂不做强判断';
  final top = List<StockHolding>.from(quoted)..sort((a, b) => b.holdingPct.compareTo(a.holdingPct));
  final leaders = top.take(3).map((item) => '${item.name}${pct(item.changePct!)}').join('、');
  final weightedChange = weightedHoldingChange(holdings);
  final flow = weightedHoldingFlow(holdings);
  final flowText = flowDirectionText(flow, averageHoldingFlowPct(holdings));
  if (weightedChange > 0.6 && (flow ?? 0) > 0) return '核心重仓股 $leaders，$flowText，形成支撑';
  if (weightedChange < -0.6 && (flow ?? 0) < 0) return '核心重仓股 $leaders，$flowText，抛压偏重';
  return '核心重仓股 $leaders，$flowText，方向仍在拉扯';
}

double coreHoldingScore(List<StockHolding> holdings) {
  final changePart = (weightedHoldingChange(holdings) / 3).clamp(-0.45, 0.45).toDouble();
  final flowPart = flowStrengthScore(weightedHoldingFlow(holdings), averageHoldingFlowPct(holdings)) * 0.55;
  return (changePart + flowPart).clamp(-1.0, 1.0).toDouble();
}

String volumeStateText(BoardSignal? board, double todayPct) {
  if (board == null) return '量价等待板块行情刷新，先看分时尾盘确认';
  final amountText = board.amount == null ? '' : '，成交额 ${cnAmount(board.amount!)}';
  final flow = board.mainFlow ?? 0;
  if (todayPct > 0.2 && flow > 0) return '放量上涨倾向：上涨同时有资金承接$amountText';
  if (todayPct > 0.2 && flow < 0) return '缩量/背离上涨：净值上涨但资金流出$amountText';
  if (todayPct < -0.2 && flow < 0) return '放量下跌倾向：下跌叠加资金流出$amountText';
  if (todayPct < -0.2 && flow > 0) return '下跌有承接：净值回落但资金回流$amountText';
  return '量价中性：价格波动不大，资金强弱还不明显$amountText';
}

double volumeScore(BoardSignal? board, double todayPct) {
  if (board == null) return 0;
  final flow = flowStrengthScore(board.mainFlow, board.mainFlowPct);
  if (todayPct > 0.2 && flow > 0) return min(0.9, 0.25 + flow * 0.75);
  if (todayPct > 0.2 && flow < 0) return max(-0.8, flow * 0.8);
  if (todayPct < -0.2 && flow < 0) return max(-0.9, -0.25 + flow * 0.75);
  if (todayPct < -0.2 && flow > 0) return min(0.65, flow * 0.6);
  return flow * 0.45;
}

ForwardDecisionScore buildForwardDecisionScore({
  required BoardSignal? board,
  required List<StockTailSignal> tailSignals,
  required double todayPct,
}) {
  final flow = board?.mainFlow;
  var fundFlowScore = 0;
  if (flow != null && flow > 1000000000) fundFlowScore = 2;
  if (flow != null && flow < -1000000000) fundFlowScore = -2;
  final boardSourceHint = board?.source == '前十大重仓股实时测算' ? '按前十大重仓股实时表现测算，' : '';
  final risingCount = board?.risingCount;
  final fallingCount = board?.fallingCount;
  final breadthText = risingCount == null || fallingCount == null
      ? ''
      : risingCount > fallingCount
          ? '板块里上涨家数更多，赚钱效应还在。'
          : fallingCount > risingCount
              ? '板块里下跌家数更多，别被指数表面的翻红带偏。'
              : '板块里涨跌家数差不多，说明资金还在拉扯。';
  if (risingCount != null && fallingCount != null) {
    if ((board?.changePct ?? 0) > 0 && fallingCount > risingCount) fundFlowScore -= 1;
    if ((board?.changePct ?? 0) < 0 && risingCount > fallingCount) fundFlowScore += 1;
  }

  final fundFlowText = board == null
      ? '板块主力资金还在刷新，先不做强判断。'
      : flow == null
          ? joinSentences(['$boardSourceHint${board.name}${pct(board.changePct)}，板块在动，但主力方向还不够清晰。', breadthText])
          : flow >= 0
              ? joinSentences(['$boardSourceHint主力净流入 ${cnAmount(flow.abs())}，${board.name}${pct(board.changePct)}，资金仍在买入。', breadthText])
              : joinSentences(['$boardSourceHint主力净流出 ${cnAmount(flow.abs())}，${board.name}${pct(board.changePct)}，抛压偏重。', breadthText]);

  final readyTails = tailSignals.where((item) => item.ready && item.changePct != null).toList();
  final tailUpCount = readyTails.where((item) => item.changePct! > 1).length;
  final tailDownCount = readyTails.where((item) => item.changePct! < -1).length;
  final boardTailLift = board?.tail20ChangePct;
  var tailScore = 0;
  if (tailUpCount >= 2) tailScore = 2;
  if (tailDownCount >= 2) tailScore = -2;
  if (boardTailLift != null && boardTailLift >= 0.45) tailScore += 1;
  if (boardTailLift != null && boardTailLift <= -0.45) tailScore -= 1;
  final tailNames = readyTails.map((item) => item.name).take(2).join('、');
  final stockTailText = readyTails.isEmpty
      ? '核心重仓股尾盘还没有拿到足够的分时确认。'
      : tailUpCount >= 2
          ? '$tailNames尾盘同步走强，出现了抢筹过夜的味道。'
          : tailDownCount >= 2
              ? '$tailNames尾盘走弱，卖压没有明显松开。'
              : '$tailNames尾盘走势分化，未见合力抢筹。';
  final boardTailText = boardTailLift == null
      ? ''
      : boardTailLift >= 0.45
          ? '板块最后 20 分钟继续抬升，尾盘资金没有退。'
          : boardTailLift <= -0.45
              ? '板块最后 20 分钟回落明显，尾盘更像在撤。'
              : '板块最后 20 分钟变化不大，尾盘没有给出额外加分。';
  final tailText = joinSentences([stockTailText, boardTailText]);

  final ratio = board?.volumeRatio;
  var volumeScoreValue = 0;
  if (ratio != null && todayPct > 0.15 && ratio >= 1.10) volumeScoreValue = 1;
  if (ratio != null && todayPct > 0.15 && ratio < 0.72) volumeScoreValue = -2;
  if (ratio != null && todayPct > 0.15 && ratio >= 0.72 && ratio < 0.95) volumeScoreValue = -1;
  if (ratio != null && todayPct < -0.15 && ratio >= 1.10) volumeScoreValue = -1;
  if (ratio != null && todayPct < -0.15 && ratio < 0.90) volumeScoreValue = 1;
  final volumeLabel = ratio == null
      ? '量能还在刷新，先看盘中承接。'
      : todayPct > 0.15
          ? ratio < 0.72
              ? '净值继续上行，但成交量明显掉下来，量价背离偏重。'
              : ratio < 0.95
                  ? '上涨但量能没有跟上，追价意愿偏弱。'
                  : '上涨时量能还能配合，资金承接不算差。'
          : todayPct < -0.15
              ? ratio >= 1.10
                  ? '回落时量能放大，抛压释放得更彻底。'
                  : ratio < 0.90
                      ? '回落但量能没有失控，下方承接还在试探。'
                      : '回落时量能中性，情绪偏谨慎。'
              : '量能和昨天同段差不多，方向还不够明确。';

  final total = fundFlowScore + tailScore + volumeScoreValue;
  final conclusion = total >= 3
      ? '明天更像偏强开局'
      : total <= -3
          ? '明天更像低开承压'
          : '明天更像上下拉扯';
  final readyCount = [board != null && flow != null, readyTails.length >= 2, ratio != null].where((item) => item).length;
  final confidence = readyCount >= 3
      ? '中等置信度'
      : readyCount == 2
          ? '低到中置信度'
          : '低置信度';

  return ForwardDecisionScore(
    total: total,
    fundFlowScore: fundFlowScore,
    tailScore: tailScore,
    volumeScore: volumeScoreValue,
    fundFlowText: fundFlowText,
    tailText: tailText,
    volumeText: volumeLabel,
    conclusion: conclusion,
    confidence: confidence,
  );
}

String scoreText(int value) {
  if (value > 0) return '+$value';
  return value.toString();
}

double? intradayDeltaSinceClock(List<IntradayPoint> points, int hour, int minute) {
  if (points.length < 2) return null;
  final now = DateTime.now();
  final target = tradingMinute(DateTime(now.year, now.month, now.day, hour, minute));
  final lastMinute = tradingMinute(points.last.time);
  final startMinute = lastMinute >= target ? target : max(0, lastMinute - 30);
  IntradayPoint? base;
  for (final point in points) {
    if (tradingMinute(point.time) <= startMinute) base = point;
  }
  base ??= points.first;
  return points.last.changePct - base.changePct;
}

String tailStateText(double? delta) {
  if (delta == null) return '尾盘信号等待分钟估值更新';
  if (delta > 0.28) return '14:30附近以来估值抬升 ${pct(delta)}，有尾盘抢筹迹象';
  if (delta < -0.28) return '14:30附近以来估值回落 ${pct(delta)}，尾盘抛压偏重';
  return '14:30附近以来变化 ${pct(delta)}，尾盘暂未给出强方向';
}

double tailScore(double? delta) {
  if (delta == null) return 0;
  return (delta / 0.9).clamp(-1.0, 1.0).toDouble();
}

String flowDirectionText(double? flow, double? flowPct) {
  if (flow == null) return '资金方向还在等待确认';
  final direction = flow >= 0 ? '主力净流入' : '主力净流出';
  final absFlow = flow.abs();
  final strength = absFlow >= 1000000000
      ? '大幅'
      : absFlow >= 300000000
          ? '明显'
          : absFlow >= 50000000
              ? '小幅'
              : '轻微';
  final pctText = flowPct == null ? '' : '，资金强度 ${pct(flowPct)}';
  return '$strength$direction ${cnAmount(absFlow)}$pctText';
}

double flowStrengthScore(double? flow, double? flowPct) {
  if (flow == null) return 0;
  final absFlow = flow.abs();
  var score = absFlow >= 1000000000
      ? 1.0
      : absFlow >= 300000000
          ? 0.72
          : absFlow >= 50000000
              ? 0.42
              : 0.18;
  if (flowPct != null) score = max(score, (flowPct.abs() / 6).clamp(0.0, 1.0).toDouble());
  return flow >= 0 ? score : -score;
}

double weightedHoldingChange(List<StockHolding> holdings) {
  final quoted = holdings.where((item) => item.changePct != null).toList();
  if (quoted.isEmpty) return 0;
  final totalWeight = quoted.map((item) => item.holdingPct).sum;
  if (totalWeight <= 0) return quoted.map((item) => item.changePct!).averageOrZero;
  return quoted.map((item) => item.changePct! * item.holdingPct).sum / totalWeight;
}

double? weightedHoldingFlow(List<StockHolding> holdings) {
  final rows = holdings.where((item) => item.mainFlow != null).toList();
  if (rows.isEmpty) return null;
  return rows.map((item) => item.mainFlow! * item.holdingPct / 100).sum;
}

double? averageHoldingFlowPct(List<StockHolding> holdings) {
  final rows = holdings.where((item) => item.mainFlowPct != null).toList();
  if (rows.isEmpty) return null;
  return rows.map((item) => item.mainFlowPct!).averageOrZero;
}

String toneFromScore(double score) {
  if (score > 0.18) return 'good';
  if (score < -0.18) return 'bad';
  return 'warn';
}

const linkedFundTargetCodes = <String, String>{
  '012862': '159796',
  '012863': '159796',
};

const directIntradayProxyTargets = <String, List<IntradayProxyTarget>>{
  '025686': [
    IntradayProxyTarget(secid: '90.BK1326', name: '半导体设备指数'),
    IntradayProxyTarget(secid: '0.159516', name: '半导体设备ETF国泰'),
  ],
  '025687': [
    IntradayProxyTarget(secid: '90.BK1326', name: '半导体设备指数'),
    IntradayProxyTarget(secid: '0.159516', name: '半导体设备ETF国泰'),
  ],
};

String? linkedTargetCode(String code) => linkedFundTargetCodes[code];

String holdingsLookupCode(FundBase fund) {
  if (!isLinkedFund(fund.name)) return fund.code;
  return linkedTargetCode(fund.code) ?? fund.code;
}

bool isLinkedFund(String name) => RegExp(r'联接|ETF联接').hasMatch(name);

bool shouldUseProxyIntraday(FundBase fund) {
  if (isLinkedFund(fund.name)) return true;
  final looksExchangeTraded = RegExp(r'^(159|16|5)').hasMatch(fund.code) && RegExp(r'ETF|LOF').hasMatch(fund.name);
  return !looksExchangeTraded;
}

List<IntradayProxyTarget> intradayProxyTargets(FundBase fund) {
  final targets = <IntradayProxyTarget>[];
  void addTarget(IntradayProxyTarget target) {
    if (!targets.any((item) => item.secid == target.secid)) targets.add(target);
  }

  final direct = directIntradayProxyTargets[fund.code] ?? const [];
  for (final target in direct) {
    addTarget(target);
  }

  final linkedCode = linkedTargetCode(fund.code);
  if (linkedCode != null) {
    addTarget(IntradayProxyTarget(secid: '${marketFromCode(linkedCode)}.$linkedCode', name: '目标ETF $linkedCode'));
  }

  return targets;
}

String inferTheme(String name) {
  if (RegExp(r'白酒|酒').hasMatch(name)) return '白酒';
  if (RegExp(r'医药|医疗|生物').hasMatch(name)) return '医药';
  if (RegExp(r'半导体|芯片').hasMatch(name)) return '半导体';
  if (RegExp(r'电池|锂|储能').hasMatch(name)) return '电池';
  if (RegExp(r'新能源|光伏|电力设备').hasMatch(name)) return '新能源';
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

int? toNullableInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().replaceAll(',', ''));
}

String dateFromMillis(int millis) {
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String todayDateString() {
  final date = DateTime.now();
  return dateText(date);
}

String dateText(DateTime date) {
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String shortDateText(DateTime date) => '${date.month}月${date.day}日';

String feeFreeDateFromConfirmText(String confirmDate) {
  final date = DateTime.tryParse(confirmDate);
  if (date == null) return '';
  return dateText(date.add(const Duration(days: 7)));
}

PortfolioItem settlePortfolioItem(PortfolioItem item, FundBase fund) {
  final last = fund.points.last;
  if (last.value <= 0) return item;
  var shares = item.shares;
  var amount = item.amount;
  var settledDate = item.lastSettledDate;
  var settledNav = item.lastSettledNav;
  var pending = List<PendingBuy>.from(item.pendingBuys);
  var holdingLots = List<HoldingLot>.from(item.holdingLots);

  shares ??= amount > 0 ? amount / last.value : 0;
  if (settledDate.isEmpty) {
    settledDate = last.date;
    settledNav = last.value;
  }

  if (last.equityReturn != null) {
    final remaining = <PendingBuy>[];
    for (final order in pending) {
      if (compareDateText(order.confirmDate, last.date) <= 0) {
        final confirmedShares = order.amount / last.value;
        shares = (shares ?? 0) + confirmedShares;
        holdingLots.add(
          HoldingLot(
            amount: order.amount,
            shares: confirmedShares,
            confirmDate: last.date,
            feeFreeDate: feeFreeDateFromConfirmText(last.date),
          ),
        );
      } else {
        remaining.add(order);
      }
    }
    final hasNewNav = compareDateText(last.date, settledDate) > 0;
    final confirmedOrder = remaining.length != pending.length;
    if (hasNewNav || confirmedOrder) {
    amount = (shares ?? 0) * last.value;
    settledDate = last.date;
    settledNav = last.value;
  }
  pending = remaining;
  }

  return item.copyWith(
    amount: amount,
    shares: shares,
    lastSettledDate: settledDate,
    lastSettledNav: settledNav,
    pendingBuys: pending,
    holdingLots: holdingLots,
  );
}

PendingOrderPlan pendingOrderPlan(DateTime now, {bool? beforeCutoffOverride}) {
  final autoBeforeCutoff = isFundTradingDay(now) && (now.hour * 60 + now.minute) < 15 * 60;
  final beforeCutoff = beforeCutoffOverride ?? autoBeforeCutoff;
  final confirm = beforeCutoff
      ? (isFundTradingDay(now) ? now : nextTradingDate(now))
      : nextTradingDate(now);
  final confirmText = dateText(confirm);
  return PendingOrderPlan(
    confirmDate: confirmText,
    beforeCutoff: beforeCutoff,
    label: beforeCutoff ? '15点前买入' : '15点后买入',
    note: beforeCutoff
        ? '按 $confirmText 晚间净值确认份额，适合记录今天 15:00 前已经提交的买入。'
        : '按 $confirmText 的净值确认份额，适合记录今天 15:00 后或下一交易日生效的买入。',
  );
}
DateTime nextTradingDate(DateTime value) {
  var date = DateTime(value.year, value.month, value.day).add(const Duration(days: 1));
  while (!isFundTradingDay(date)) {
    date = date.add(const Duration(days: 1));
  }
  return date;
}

DateTime previousTradingDate(DateTime value) {
  var date = DateTime(value.year, value.month, value.day).subtract(const Duration(days: 1));
  while (!isFundTradingDay(date)) {
    date = date.subtract(const Duration(days: 1));
  }
  return date;
}

bool isFundTradingDay(DateTime value) {
  return value.weekday != DateTime.saturday && value.weekday != DateTime.sunday;
}

int compareDateText(String a, String b) {
  final da = DateTime.tryParse(a);
  final db = DateTime.tryParse(b);
  if (da == null && db == null) return 0;
  if (da == null) return -1;
  if (db == null) return 1;
  return da.compareTo(db);
}

bool shouldUseOfficialNav(NavPoint last, RealtimeEstimate? realtime) {
  if (last.equityReturn == null) return false;
  final officialDate = DateTime.tryParse(last.date);
  final realtimeDate = realtime == null ? null : parseDateFromText(realtime.updateTime);
  if (officialDate != null && realtimeDate != null && officialDate.isAfter(realtimeDate)) return true;
  if (isTradingTime()) return false;
  final now = DateTime.now();
  final minute = now.hour * 60 + now.minute;
  final afterOfficialWindow = minute >= 20 * 60 || minute < 9 * 60 + 30;
  if (!afterOfficialWindow) return false;
  if (officialDate == null) return true;
  if (realtimeDate == null) return true;
  return !officialDate.isBefore(realtimeDate);
}

DateTime? parseDateFromText(String value) {
  final match = RegExp(r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(value);
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

bool isTradingTime() {
  final now = DateTime.now();
  if (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday) return false;
  final minute = now.hour * 60 + now.minute;
  return (minute >= 9 * 60 + 30 && minute <= 11 * 60 + 30) || (minute >= 13 * 60 && minute <= 15 * 60);
}

bool shouldAutoRefreshData() {
  final now = DateTime.now();
  if (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday) return false;
  final minute = now.hour * 60 + now.minute;
  final tradingWindow = (minute >= 9 * 60 + 25 && minute <= 11 * 60 + 35) || (minute >= 12 * 60 + 55 && minute <= 15 * 60 + 5);
  final eveningNetValueWindow = minute >= 18 * 60 && minute <= 23 * 60 + 30;
  return tradingWindow || eveningNetValueWindow;
}

String shortRealtimeTime(String value) {
  if (value.isEmpty) return '未接入';
  final parts = value.split(' ');
  return parts.length == 2 ? parts[1] : value;
}

double movingAverage(List<NavPoint> points, int days) {
  if (points.length < days) return 0;
  final values = points.takeLast(days).map((item) => item.value);
  return values.averageOrZero;
}

MacdSnapshot computeMacdSnapshot(List<NavPoint> points) {
  if (points.length < 35) {
    return MacdSnapshot(score: 0, summary: 'MACD 样本还不够长，先少看这一项。');
  }
  final closes = points.map((item) => item.value).toList();
  final ema12 = emaSeries(closes, 12);
  final ema26 = emaSeries(closes, 26);
  if (ema12.length != closes.length || ema26.length != closes.length) {
    return MacdSnapshot(score: 0, summary: 'MACD 还没形成稳定信号。');
  }
  final difs = <double>[];
  for (var i = 0; i < closes.length; i += 1) {
    difs.add(ema12[i] - ema26[i]);
  }
  final deas = emaSeries(difs, 9);
  if (deas.length != difs.length || difs.length < 2) {
    return MacdSnapshot(score: 0, summary: 'MACD 还没形成稳定信号。');
  }
  final prevDif = difs[difs.length - 2];
  final latestDif = difs.last;
  final prevDea = deas[deas.length - 2];
  final latestDea = deas.last;
  final hist = (latestDif - latestDea) * 2;
  if (prevDif <= prevDea && latestDif > latestDea) {
    return MacdSnapshot(score: 2, summary: '日线 MACD 刚出现金叉，中期修复意愿在抬头。');
  }
  if (prevDif >= prevDea && latestDif < latestDea) {
    return MacdSnapshot(score: -2, summary: '日线 MACD 刚出现死叉，明天更要防转弱。');
  }
  if (latestDif > latestDea && hist > 0) {
    return MacdSnapshot(score: 1, summary: 'MACD 仍在零轴上方，趋势修复还没完全走坏。');
  }
  if (latestDif < latestDea && hist < 0) {
    return MacdSnapshot(score: -1, summary: 'MACD 还在空头一侧，反弹持续性先别看太满。');
  }
  return MacdSnapshot(score: 0, summary: 'MACD 没有给出新的方向确认。');
}

List<double> emaSeries(List<double> values, int period) {
  if (values.isEmpty) return const [];
  final alpha = 2 / (period + 1);
  final result = <double>[values.first];
  for (var i = 1; i < values.length; i += 1) {
    result.add(values[i] * alpha + result.last * (1 - alpha));
  }
  return result;
}

String valuationText({required double drawdown, required double last20}) {
  if (drawdown <= -18) return '偏低（90日回撤 ${pct(drawdown)}，安全垫较厚）';
  if (drawdown <= -10) return '中偏低（90日仍有 ${pct(drawdown)} 回撤）';
  if (drawdown >= -5 && last20 > 6) return '偏高（回撤修复且近20日涨幅 ${pct(last20)}）';
  if (last20 > 8) return '中偏高（短线涨幅偏大）';
  return '中性（位置不极端，等趋势确认）';
}

String trendText({
  required double decisionNav,
  required double ma20,
  required double ma120,
  required double ma250,
  required MarketSnapshot market,
}) {
  if (ma20 <= 0) return '样本不足，暂按震荡处理';
  final above20 = decisionNav >= ma20;
  final above120 = ma120 > 0 && decisionNav >= ma120;
  final above250 = ma250 > 0 && decisionNav >= ma250;
  if (above20 && market.averageChange >= 0.2) return '短线向上，站上MA20，市场偏强';
  if (above20 && (above120 || above250)) return '站上MA20，中期趋势有支撑';
  if (above20) return '站上MA20，但市场确认不强';
  if (!above20 && ma120 > 0 && decisionNav < ma120) return '跌破MA20/MA120，短线偏弱';
  return '跌破MA20，先观察';
}

String analysisLockStorageKey(String code, String date) => 'analysis_lock_${code}_$date';

bool shouldLockTodayPrediction(DateTime now) {
  if (!isFundTradingDay(now)) return false;
  return now.hour * 60 + now.minute >= 9 * 60 + 45;
}

bool shouldLockTomorrowPrediction(DateTime now) {
  if (!isFundTradingDay(now)) return false;
  return now.hour * 60 + now.minute >= 14 * 60 + 45;
}

(String, String, String, String) overnightConfig(String theme) {
  if (theme == '半导体') return ('^SOX', '费城半导体', '^IXIC', '纳斯达克');
  if (theme == '电池' || theme == '新能源') return ('LIT', '海外电池链', '^IXIC', '纳斯达克');
  if (theme == '白酒') return ('^GSPC', '标普500', '^IXIC', '纳斯达克');
  return ('^IXIC', '纳斯达克', '^GSPC', '标普500');
}

double biasFromAverage(double value, double average) {
  if (average <= 0) return 0;
  return (value / average - 1) * 100;
}

int biasScore(double bias5, double bias20) {
  if (bias20 >= 6 || bias5 >= 3.5) return -1;
  if (bias20 <= -6 || bias5 <= -3.5) return 1;
  return 0;
}

String biasStateText(double bias5, double bias20) {
  if (bias20 >= 6 || bias5 >= 3.5) return '当前位置偏热，离均线有点远，追高后更容易回落';
  if (bias20 <= -6 || bias5 <= -3.5) return '当前位置偏低，更接近修复区，若资金回流更容易反弹';
  return '当前位置中性，没有明显超买或超卖';
}

TodayToneSignal buildTodayToneSignal({
  required OvernightSignal? overnight,
  required BoardSignal? board,
  required MarketSnapshot market,
}) {
  var score = overnight?.score ?? 0;
  var inputs = overnight == null ? 0 : 1;
  if (board?.openGapPct != null) {
    inputs += 1;
    if (board!.openGapPct! >= 0.45) score += 1;
    if (board.openGapPct! <= -0.45) score -= 1;
  }
  if (board?.first15ChangePct != null) {
    inputs += 1;
    if (board!.first15ChangePct! >= 0.45) score += 1;
    if (board.first15ChangePct! <= -0.45) score -= 1;
  }
  if (board?.first15VolumeRatio != null) {
    inputs += 1;
    final ratio = board!.first15VolumeRatio!;
    final change = board.first15ChangePct ?? 0;
    if (change > 0.15 && ratio >= 1.05) score += 1;
    if (change > 0.15 && ratio < 0.95) score -= 1;
    if (change < -0.15 && ratio >= 1.05) score -= 1;
  }
  if (market.averageChange >= 0.60) {
    score += 1;
    inputs += 1;
  } else if (market.averageChange <= -0.60) {
    score -= 1;
    inputs += 1;
  }

  final state = score >= 3
      ? '盘面偏强'
      : score >= 1
          ? '盘面转暖'
          : score <= -3
              ? '盘面转弱'
              : score <= -1
                  ? '盘面偏弱'
                  : '震荡不明';
  final confidence = inputs >= 4
      ? '中高'
      : inputs >= 3
          ? '中'
          : '低';
  final boardText = board == null
      ? '集合竞价和早盘量能等待板块分钟数据。'
      : [
          if (board.openGapPct != null) '开盘缺口 ${pct(board.openGapPct!)}',
          if (board.first15ChangePct != null) '09:30-09:45 变化 ${pct(board.first15ChangePct!)}',
          if (board.first15VolumeRatio != null) '早盘量能为昨日同段 ${(board.first15VolumeRatio! * 100).toStringAsFixed(0)}%',
        ].join('；');
  final reason = '09:45 口径：${overnight?.summary ?? '隔夜外围等待刷新。'}${boardText.isEmpty ? '' : '$boardText。'}大盘背景 ${market.label}。结论 ${forecastBrief(state)}，置信度 $confidence。';
  return TodayToneSignal(state: state, confidence: confidence, reason: reason, score: score);
}

ResonanceSignal buildResonanceSignal({
  required List<NavPoint> points,
  required double decisionNav,
  required double ma20,
  required double ma60,
  required double ma120,
  required MarketSnapshot market,
}) {
  final board = market.board;
  final atr14 = atrProxy(points, 14);
  final macd = computeMacdSnapshot(points);
  var score = 0;
  final notes = <String>[];

  final boardStrength = board?.rpsPercentile;
  final board3d = board?.recent3ChangePct;
  final board5d = board?.recent5ChangePct;
  if (boardStrength != null) {
    if (boardStrength >= 90) {
      score += 2;
      notes.add('${board!.name}当前强度位于全市场前 10%，仍然算主线方向');
    } else if (boardStrength >= 75) {
      score += 1;
      notes.add('${board!.name}当前强度位于全市场前四分之一，延续性还可以');
    } else if (boardStrength < 50) {
      score -= 1;
      notes.add('${board!.name}当前强度落在市场后半区，反弹持续性一般');
    }
  }

  if (boardStrength != null && board3d != null) {
    if (boardStrength >= 85 && board3d >= 2.0) {
      score += 1;
      notes.add('${board!.name}最近 3 个交易日还在延续走强，主线惯性没有断。');
    } else if (boardStrength < 50 && board3d <= 0) {
      score -= 1;
      notes.add('${board!.name}短线强度和近几天惯性都偏弱，反弹更容易走成一日游。');
    }
  } else if (board5d != null) {
    if (board5d >= 4.0) {
      notes.add('最近 5 个交易日板块修复幅度不小，后面要防止追高。');
    } else if (board5d <= -4.0) {
      notes.add('最近 5 个交易日仍在低位反复，只有资金回流时才更像修复窗口。');
    }
  }

  if (market.averageChange >= 0.60 && (board?.changePct ?? 0) > 0.2) {
    score += 1;
    notes.add('大盘和板块方向一致，顺风时更容易把反弹做出来');
  } else if (market.averageChange <= -0.60 && (board?.changePct ?? 0) > 0.1) {
    score -= 1;
    notes.add('板块虽然局部活跃，但大盘偏弱，会压住明天的反弹高度');
  } else if (market.averageChange <= -0.60) {
    score -= 1;
    notes.add('大盘环境偏弱，任何反弹都要先防冲高回落');
  }

  final gapTo60 = ma60 > 0 ? (ma60 / decisionNav - 1) * 100 : 99.0;
  final gapTo120 = ma120 > 0 ? (ma120 / decisionNav - 1) * 100 : 99.0;
  if (ma60 > 0 && decisionNav < ma60 && gapTo60 <= 1.2) {
    score -= 1;
    notes.add('当前位置已经贴近 60 日线压力，明天更容易先遇到抛压');
  } else if (ma120 > 0 && decisionNav < ma120 && gapTo120 <= 1.5) {
    score -= 1;
    notes.add('半年线附近还有一层阻力，向上空间不宜看太满');
  } else if (ma20 > 0 && ma60 > 0 && decisionNav > ma20 && decisionNav > ma60 && (ma120 <= 0 || decisionNav > ma120)) {
    score += 1;
    notes.add('已经重新站上中期均线，趋势修复更完整');
  }

  score += macd.score;
  notes.add(macd.summary);

  if (atr14 >= 2.6) {
    notes.add('最近波动偏大，单次仓位要压小');
  } else if (atr14 <= 1.2) {
    notes.add('最近波动温和，分批操作的容错会更高');
  } else {
    notes.add('最近波动中等，继续小步分批更稳');
  }

  final summary = score >= 2
      ? '大盘与板块趋势向好，均线也在配合。'
      : score <= -2
          ? '大盘和板块配合度不够，明天更要防回落。'
          : '趋势还没完全站稳，明天先看资金会不会继续跟。';
  return ResonanceSignal(
    summary: summary,
    detail: joinSentences(notes),
    tone: toneFromScore(score.toDouble()),
    score: score,
    atr14: atr14,
  );
}

DurationSignal buildDurationSignal({
  required List<NavPoint> points,
  required double decisionNav,
  required int totalScore,
  required Announcement? majorNegative,
  required bool positiveCatalyst,
}) {
  final rsi14 = computeRsi(points, 14);
  final kdjJ = computeKdjJ(points, 9);
  final ma5 = movingAverage(points, 5);
  final ma20 = movingAverage(points, 20);
  final bias5 = biasFromAverage(decisionNav, ma5);
  final bias20 = biasFromAverage(decisionNav, ma20);
  final support = points.takeLast(20).map((item) => item.value).reduce(min).toDouble();
  final resistance = points.takeLast(60).map((item) => item.value).reduce(max).toDouble();
  final supportGapPct = (support > 0 ? (decisionNav / support - 1) * 100 : 0.0).toDouble();
  final resistanceGapPct = (decisionNav > 0 ? (resistance / decisionNav - 1) * 100 : 0.0).toDouble();

  String summary;
  String tone;
  if (majorNegative != null) {
    summary = '回调压力 1-2 天';
    tone = 'bad';
  } else if (rsi14 >= 80 || bias20 >= 6 || kdjJ >= 90) {
    summary = '过热回调 1-2 天';
    tone = 'bad';
  } else if (rsi14 <= 32 && resistanceGapPct >= 4) {
    summary = positiveCatalyst ? '修复窗口 3-5 天' : '修复窗口 2-4 天';
    tone = 'good';
  } else if (totalScore >= 4 && resistanceGapPct >= 3) {
    summary = positiveCatalyst ? '反弹惯性 3-4 天' : '反弹惯性 2-3 天';
    tone = 'good';
  } else if (totalScore <= -4) {
    summary = '容易反复走弱 1-2 天';
    tone = 'bad';
  } else if (resistanceGapPct <= 2) {
    summary = '接近压力位，持续 1 天左右';
    tone = 'warn';
  } else {
    summary = '上下拉扯 1-2 天';
    tone = 'warn';
  }

  final momentumText = rsi14 >= 80
      ? '短线情绪已经偏热'
      : rsi14 <= 32
          ? '短线处在低位修复区'
          : '短线情绪暂时中性';
  final pressureText = resistanceGapPct <= 2 ? '上方压力位很近' : '离上方压力位还有一定空间';
  final supportText = supportGapPct <= 2 ? '下方支撑已经比较近' : '下方还有支撑缓冲';
  final reason = '$momentumText，$pressureText，$supportText。';
  return DurationSignal(
    summary: summary,
    reason: reason,
    tone: tone,
    rsi14: rsi14,
    kdjJ: kdjJ,
    bias5: bias5,
    bias20: bias20,
    supportGapPct: supportGapPct,
    resistanceGapPct: resistanceGapPct,
  );
}

double computeRsi(List<NavPoint> points, int period) {
  final changes = dailyReturns(points);
  if (changes.length < period) return 50;
  final sample = changes.takeLast(period);
  var gains = 0.0;
  var losses = 0.0;
  for (final change in sample) {
    if (change >= 0) gains += change;
    if (change < 0) losses += change.abs();
  }
  final avgGain = gains / period;
  final avgLoss = losses / period;
  if (avgLoss == 0) return 100;
  final rs = avgGain / avgLoss;
  return (100 - (100 / (1 + rs))).clamp(0.0, 100.0).toDouble();
}

double computeKdjJ(List<NavPoint> points, int period) {
  if (points.length < period) return 50;
  var k = 50.0;
  var d = 50.0;
  for (var i = period - 1; i < points.length; i += 1) {
    final window = points.sublist(i - period + 1, i + 1);
    final low = window.map((item) => item.value).reduce(min);
    final high = window.map((item) => item.value).reduce(max);
    final close = points[i].value;
    final rsv = high <= low ? 50.0 : ((close - low) / (high - low) * 100).clamp(0.0, 100.0).toDouble();
    k = k * 2 / 3 + rsv / 3;
    d = d * 2 / 3 + k / 3;
  }
  return (3 * k - 2 * d).clamp(0.0, 100.0).toDouble();
}

String ratioText(double value) => '${(value * 100).toStringAsFixed(0)}%';

List<double> dailyReturns(List<NavPoint> points) {
  final rows = <double>[];
  for (var i = 1; i < points.length; i += 1) {
    final prev = points[i - 1].value;
    if (prev > 0) rows.add((points[i].value / prev - 1) * 100);
  }
  return rows;
}

List<double> recentReturns(List<NavPoint> points, int days) => dailyReturns(points).takeLast(days);

double atrProxy(List<NavPoint> points, int period) {
  final sample = dailyReturns(points).takeLast(period).map((item) => item.abs()).toList();
  if (sample.isEmpty) return 0;
  return sample.averageOrZero;
}

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

class ForecastVisual {
  ForecastVisual({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
}

ForecastVisual forecastVisual(String text) {
  final lower = text.trim();
  final storm = containsAnyKeyword(lower, const ['回落风险很大', '风险不可控', '低开低走', '大跌', '主跌', '盘面转弱', '过热', '先保护本金', '今天要防回落', '涨得有点快', '偏跌']);
  final weak = containsAnyKeyword(lower, const ['偏弱', '小跌', '回落', '走弱', '缩量上涨', '方向不明', '震荡不明', '看不清', '分歧', '观望', '先别着急', '今天先别急']);
  final strong = containsAnyKeyword(lower, const ['把握更大', '高开高走', '主升', '大涨', '明显转暖', '盘面偏强', '大概率还会走强', '继续慢慢走强']);
  final warm = containsAnyKeyword(lower, const ['偏涨', '小涨', '转强', '走高', '反弹', '企稳', '偏暖', '小幅走高', '盘面转暖', '有一点转强', '可以看多一点', '继续小涨']);
  if (storm) {
    return ForecastVisual(
      title: '偏跌',
      subtitle: '回落风险偏大，今天先防守',
      icon: CupertinoIcons.exclamationmark_triangle_fill,
      color: AppColors.green,
    );
  }
  if (strong) {
    return ForecastVisual(
      title: '偏涨',
      subtitle: '资金还在跟，适合继续拿着',
      icon: CupertinoIcons.arrow_up_circle_fill,
      color: AppColors.red,
    );
  }
  if (warm) {
    return ForecastVisual(
      title: '小涨',
      subtitle: '资金在回流，可以小步试试',
      icon: CupertinoIcons.chart_bar_circle_fill,
      color: AppColors.red,
    );
  }
  if (weak) {
    return ForecastVisual(
      title: '小跌',
      subtitle: '盘面偏弱，建议多看少动',
      icon: CupertinoIcons.cloud_fill,
      color: AppColors.green,
    );
  }
  return ForecastVisual(
    title: '震荡',
    subtitle: '方向还不够清楚，先别急着下手',
    icon: CupertinoIcons.minus_circle_fill,
    color: AppColors.ink,
  );
}

String forecastBrief(String text) {
  final visual = forecastVisual(text);
  return '${visual.title}，${visual.subtitle}';
}

String forecastCompact(String text) => forecastVisual(text).title;

Color signalColor(String text) {
  return forecastVisual(text).color;
}

int predictionDirectionFromText(String text) {
  if (containsAnyKeyword(text, const ['把握更大', '走高机会', '偏涨', '小涨', '偏强', '转强', '修复', '买入', '加仓', '低吸', '试探', '走强', '继续小涨', '看多一点'])) return 1;
  if (containsAnyKeyword(text, const ['回落风险', '偏跌', '小跌', '偏弱', '低开承压', '走弱', '回调', '冲高回落', '先回落', '减仓', '小幅减', '锁利润', '低开低走', '面临回落', '今天要防回落', '涨得有点快'])) return -1;
  return 0;
}

int actualDirectionFromPct(double value) {
  if (value >= 0.15) return 1;
  if (value <= -0.15) return -1;
  return 0;
}

String predictionPlainText(String text) {
  final direction = predictionDirectionFromText(text);
  if (direction > 0) return '明天偏强';
  if (direction < 0) return '明天偏弱';
  return '明天方向不明';
}

String directionName(int direction) {
  if (direction > 0) return '偏强';
  if (direction < 0) return '偏弱';
  return '震荡';
}

String actualDirectionText(int direction) {
  if (direction > 0) return '今天确实走强';
  if (direction < 0) return '今天确实转弱';
  return '今天走成横盘整理';
}

String scoreAdjustmentText(int value) {
  if (value > 0) return '偏多校准';
  if (value < 0) return '偏空校准';
  return '保持观望纪律';
}

int reviewScoreAdjustment(int predictedDirection, int actualDirection, bool success) {
  if (actualDirection == 0) {
    if (predictedDirection == 0) return 0;
    return -predictedDirection;
  }
  if (success) return actualDirection;
  return actualDirection;
}

String reviewDiagnosis(AnalysisLockState lock, int predictedDirection, int actualDirection, bool success) {
  final expectedFactors = decisionFactorsByDirection(lock.decision, predictedDirection);
  final actualFactors = decisionFactorsByDirection(lock.decision, actualDirection);
  final expectedText = expectedFactors.isEmpty ? '总分和动作规则' : expectedFactors.join('、');
  final actualText = actualFactors.isEmpty ? '盘中真实走势' : actualFactors.join('、');
  final confidenceText = (lock.confidence ?? '').isEmpty ? '置信度未知' : '置信度${lock.confidence}';

  if (success) {
    if (predictedDirection == 0) {
      return '昨天没有强行给方向，今天也确实没有走出有效单边，说明当时把互相打架的信号压住是对的；真正支撑这次命中的主要原因，是没有把零碎异动误判成买卖信号。';
    }
    return '昨天看${directionName(predictedDirection)}的核心依据是$expectedText，今天方向兑现，说明这些因子这次确实抓到了主线；$confidenceText。真正命中的关键，不是某一个孤立指标，而是这些真实信号在同一时间站到了同一边。';
  }

  if (predictedDirection == 0) {
    return '昨天把信号按观望处理，但今天实际${directionName(actualDirection)}，属于观望漏判；说明昨天临近收盘时，$actualText 这些真实信号已经开始朝同一方向收敛，只是模型当时没有给到足够权重。';
  }
  if (actualDirection == 0) {
    return '昨天看${directionName(predictedDirection)}，但今天没有走出方向，说明$expectedText的延续性不足；这些信号当时看起来够强，但缺少后续量能、广度或尾盘承接确认，所以被高估了。';
  }
  return '昨天看${directionName(predictedDirection)}主要依赖$expectedText，但今天实际${directionName(actualDirection)}；这说明昨天真正更该重视的，其实是$actualText这些反向约束项。模型没有提前识别到它们的压制或修复力度，所以方向被看反了。';
}

String reviewNextAdjustment(int predictedDirection, int actualDirection, bool success, int scoreAdjustment) {
  final adjustment = scoreAdjustmentText(scoreAdjustment);
  if (success) {
    if (scoreAdjustment == 0) {
      return '这次学习结果是继续保留观望纪律：没有真实突破或破位时，不把零碎信号硬翻译成买卖动作；下次再遇到信号分裂，仍以少动为先。';
    }
    return '这次学习结果是把$adjustment写回下一轮模型；同类信号再次出现时，方向权重会保留，但依然要求尾盘承接、量能配合和广度确认至少再过一道关。';
  }
  if (predictedDirection == 0) {
    return '这次学习结果是把$adjustment写回下一轮模型；下次如果观望状态下又出现真实单边结果，就把代理指数分时、市场广度和尾盘主力斜率抬成补充触发器，不再只盯总分。';
  }
  if (actualDirection == 0) {
    return '这次学习结果是把$adjustment写回下一轮模型；以后同类方向判断如果缺少量能确认、广度确认或 ETF 折溢价约束，就先把强结论降成观望。';
  }
  return '这次学习结果是把$adjustment写回下一轮模型；以后如果反向信号已经在板块资金、市场广度、ETF 折溢价或尾盘承接里同时出现两项以上，就直接下调置信度，并取消激进买卖动作。';
}

List<String> decisionFactorsByDirection(DecisionModel? decision, int direction) {
  if (decision == null || direction == 0) return const [];
  final targetTone = direction > 0 ? 'good' : 'bad';
  final factors = <String>[];
  if (decision.macroTone == targetTone) factors.add('外围背景');
  if (decision.valuationTone == targetTone) factors.add('板块资金');
  if (decision.trendTone == targetTone) factors.add('尾盘动向');
  if (decision.smartMoneyTone == targetTone) factors.add('聪明资金');
  if (decision.etfPricingTone == targetTone) factors.add('ETF折溢价');
  if (decision.deviationTone == targetTone) factors.add('量价状态');
  if (decision.resonanceTone == targetTone) factors.add('趋势共振');
  if (decision.durationTone == targetTone) factors.add('持续判断');
  if (decision.holdingCycleTone == targetTone) factors.add('T+7安全垫');
  return factors;
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

String cnAmount(double value) {
  final absValue = value.abs();
  if (absValue >= 100000000) return '${(absValue / 100000000).toStringAsFixed(absValue >= 1000000000 ? 1 : 2)}亿';
  if (absValue >= 10000) return '${(absValue / 10000).toStringAsFixed(absValue >= 1000000 ? 1 : 2)}万';
  return '${absValue.toStringAsFixed(0)}元';
}

double positionValue(PortfolioItem item) {
  return item.amount;
}

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
