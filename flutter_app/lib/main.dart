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
    _loadPortfolios();
    _autoRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (isTradingTime()) _refreshCurrent();
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
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
    if (_refreshing) return;
    _refreshing = true;
    try {
      for (final item in items) {
        try {
          final analysis = await _service.load(item);
          if (!mounted) return;
          setState(() => _cache[item.code] = analysis);
        } catch (_) {
          // Keep the previous analysis visible when one data source is temporarily slow.
        }
      }
    } finally {
      _refreshing = false;
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

  Future<FundAnalysis> _updateFund(PortfolioItem updated) async {
    final target = _tab == 0 ? _owned : _simulated;
    final index = target.indexWhere((item) => item.code == updated.code);
    if (index >= 0) {
      setState(() => target[index] = updated);
      await _saveCurrent();
    }
    final fresh = await _service.load(updated);
    if (mounted) setState(() => _cache[updated.code] = fresh);
    return fresh;
  }

  PortfolioSummary _summary() {
    double amount = 0;
    double income = 0;
    for (final item in _currentItems) {
      final analysis = _cache[item.code];
      final value = positionValue(item, analysis);
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
    final data = analysis;
    final currentValue = positionValue(item, data);
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
                  Expanded(child: _Metric(label: item.shares > 0 ? '估算市值' : '持有金额', value: money(currentValue))),
                  Expanded(
                    child: _Metric(
                      label: '实时估算',
                      value: data == null ? '分析中' : '${pct(data.todayPct)} / ${signedMoney(todayIncome)}',
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
    if (mounted) setState(() => _analysis = fresh);
  }

  Future<void> _editPosition() async {
    final result = await showModalBottomSheet<PortfolioItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AddFundSheet(title: '持仓信息', initialItem: _item),
    );
    if (result == null) return;
    setState(() => _item = result);
    final fresh = await widget.onUpdateItem(result);
    if (mounted) setState(() => _analysis = fresh);
  }

  @override
  Widget build(BuildContext context) {
    final currentValue = positionValue(_item, _analysis);
    final buyAmount = currentValue * _analysis.buyRatio;
    final sellAmount = currentValue * _analysis.sellRatio;
    final hasOperation = buyAmount > 0.01 || sellAmount > 0.01;
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
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(child: _Metric(label: '实时估值', value: _analysis.realtimeNavText)),
                      Expanded(child: _Metric(label: '更新时间', value: _analysis.realtimeTimeText)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            IntradayChartCard(
              points: _analysis.intradayPoints,
              note: _analysis.intradayNote,
              fallbackPct: _analysis.todayPct,
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
                  if (hasOperation)
                    Row(
                      children: [
                        if (buyAmount > 0.01) Expanded(child: _Metric(label: '建议买入', value: money(buyAmount), color: AppColors.red)),
                        if (buyAmount > 0.01 && sellAmount > 0.01) const SizedBox(width: 12),
                        if (sellAmount > 0.01) Expanded(child: _Metric(label: '建议卖出', value: money(sellAmount), color: AppColors.green)),
                      ],
                    )
                  else
                    const Text('今日无网格触发点，建议观望。', style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w800)),
                  if (!_item.hasCostBasis) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _editPosition,
                        icon: const Icon(CupertinoIcons.slider_horizontal_3),
                        label: const Text('点击设置持仓成本与份额'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(_analysis.actionReason, style: const TextStyle(color: AppColors.muted, height: 1.45, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            DecisionModelCard(decision: _analysis.decision, needsCostBasis: !_item.hasCostBasis, onEditPosition: _editPosition),
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
  const AddFundSheet({super.key, required this.title, this.initialItem});

  final String title;
  final PortfolioItem? initialItem;

  @override
  State<AddFundSheet> createState() => _AddFundSheetState();
}

class _AddFundSheetState extends State<AddFundSheet> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _costController = TextEditingController();
  final TextEditingController _sharesController = TextEditingController();
  final TextEditingController _gridController = TextEditingController(text: '2');

  @override
  void initState() {
    super.initState();
    final item = widget.initialItem;
    if (item == null) return;
    _codeController.text = item.code;
    _amountController.text = trimNumber(item.amount);
    if (item.costNav > 0) _costController.text = trimNumber(item.costNav);
    if (item.shares > 0) _sharesController.text = trimNumber(item.shares);
    _gridController.text = trimNumber(item.gridStepPct);
  }

  @override
  void dispose() {
    _codeController.dispose();
    _amountController.dispose();
    _costController.dispose();
    _sharesController.dispose();
    _gridController.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _codeController.text.trim();
    var amount = double.tryParse(_amountController.text.trim()) ?? 0;
    final costNav = double.tryParse(_costController.text.trim()) ?? 0;
    final shares = double.tryParse(_sharesController.text.trim()) ?? 0;
    final gridStep = double.tryParse(_gridController.text.trim()) ?? 2.0;
    if (amount <= 0 && costNav > 0 && shares > 0) amount = costNav * shares;
    if (!RegExp(r'^\d{6}$').hasMatch(code)) return;
    if (amount <= 0) return;
    Navigator.pop(
      context,
      PortfolioItem(
        code: code,
        amount: amount,
        costNav: costNav,
        shares: shares,
        gridStepPct: gridStep <= 0 ? 2.0 : gridStep,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final editing = widget.initialItem != null;
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
              Text(editing ? '设置持仓成本与份额' : '添加到${widget.title}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
              const SizedBox(height: 14),
              CupertinoTextField(
                controller: _codeController,
                enabled: !editing,
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
                placeholder: editing ? '当前该基金持仓金额' : (widget.title == '持有持仓' ? '我持有的金额' : '模拟金额'),
                padding: const EdgeInsets.all(15),
                decoration: inputDecoration(),
              ),
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: _costController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                placeholder: '持仓成本价，可不填',
                padding: const EdgeInsets.all(15),
                decoration: inputDecoration(),
              ),
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: _sharesController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                placeholder: '持有份额，可不填',
                padding: const EdgeInsets.all(15),
                decoration: inputDecoration(),
              ),
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: _gridController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                placeholder: '网格步长%，默认 2',
                padding: const EdgeInsets.all(15),
                decoration: inputDecoration(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _submit,
                  icon: Icon(editing ? CupertinoIcons.checkmark_alt : CupertinoIcons.add),
                  label: Text(editing ? '保存并重新分析' : '添加并分析'),
                ),
              ),
            ],
          ),
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
          Row(
            children: [
              const Expanded(child: Text('当日分时走势', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
              Pill(text: widget.points.length > 4 ? '分钟估值' : '等待更新'),
            ],
          ),
          const SizedBox(height: 6),
          Text(widget.note, style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700)),
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

    if (points.isEmpty) {
      _drawLabel(
        canvas,
        '交易时段下拉刷新后显示分钟线',
        Offset(plot.left + 12, plot.center.dy - 10),
        const TextStyle(color: AppColors.muted, fontSize: 14, fontWeight: FontWeight.w800),
        TextAlign.left,
      );
      return;
    }

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
          ..strokeCap = StrokeCap.round,
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
  const DecisionModelCard({super.key, required this.decision, required this.needsCostBasis, required this.onEditPosition});

  final DecisionModel decision;
  final bool needsCostBasis;
  final VoidCallback onEditPosition;

  @override
  Widget build(BuildContext context) {
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('14:50 决策模型', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
              Pill(text: decision.confidence),
            ],
          ),
          const SizedBox(height: 10),
          Text(decision.summary, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, height: 1.35)),
          const SizedBox(height: 12),
          _DecisionRow(label: '估值位置', value: decision.valuationState, tone: decision.valuationTone),
          _DecisionRow(label: '均线趋势', value: decision.trendState, tone: decision.trendTone),
          _DecisionRow(label: '偏离度', value: decision.costDeviationText, tone: decision.deviationTone),
          _DecisionRow(label: '网格动作', value: decision.gridTrigger, tone: decision.deviationTone),
          if (needsCostBasis) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onEditPosition,
                icon: const Icon(CupertinoIcons.slider_horizontal_3),
                label: const Text('补全成本与份额'),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(decision.reason, style: const TextStyle(color: AppColors.muted, height: 1.45, fontWeight: FontWeight.w700)),
        ],
      ),
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
            width: 74,
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

  Future<FundAnalysis> load(PortfolioItem item) async {
    final code = item.code;
    final fund = await _loadFundBase(code);
    final realtime = await _loadRealtimeEstimate(code);
    final intraday = await _loadIntradayTrend(code, realtime);
    final rawHoldings = await _loadHoldings(code);
    final theme = inferTheme(fund.name);
    final holdings = await _enrichHoldings(applyThemeFallback(rawHoldings, theme));
    final announcements = await _loadAnnouncements(holdings.take(5).toList());
    final market = await _loadMarket(fund);
    return _analyze(fund, holdings, announcements, market, theme, realtime, intraday, item);
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

  Future<RealtimeEstimate?> _loadRealtimeEstimate(String code) async {
    final uri = Uri.parse('http://fundgz.1234567.com.cn/js/$code.js?rt=${DateTime.now().millisecondsSinceEpoch}');
    try {
      final response = await _client.get(uri).timeout(const Duration(seconds: 8));
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

  Future<IntradaySeries> _loadIntradayTrend(String code, RealtimeEstimate? realtime) async {
    final endpoints = [
      Uri.https('fundmobapi.eastmoney.com', '/FundMApi/FundVarietieValuationDetail', {
        'FCODE': code,
        'RANGE': 'y',
        'deviceid': 'xiaoyou',
        'plat': 'Iphone',
        'product': 'EFund',
        'version': '7.0.0',
      }),
    ];
    for (final uri in endpoints) {
      try {
        final response = await _client.get(uri).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) continue;
        final raw = utf8.decode(response.bodyBytes, allowMalformed: true);
        final jsonText = extractJsonLike(raw);
        if (jsonText == null) continue;
        final payload = jsonDecode(jsonText);
        final points = _parseIntradayPayload(payload, realtime);
        if (points.length >= 3) {
          return IntradaySeries(points: points, note: '按 A 股交易时间展示，长按可查看每分钟估值。');
        }
      } catch (_) {
        continue;
      }
    }
    final fallback = buildSyntheticIntraday(realtime);
    return IntradaySeries(
      points: fallback,
      note: fallback.isEmpty ? '交易时段下拉刷新后显示当天分钟走势。' : '实时估值已更新，分时线会随下拉刷新继续校准。',
    );
  }

  List<IntradayPoint> _parseIntradayPayload(dynamic payload, RealtimeEstimate? realtime) {
    final rows = <IntradayPoint>[];
    void visit(dynamic node) {
      final point = _pointFromIntradayRow(node, realtime);
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
          final parsed = _pointFromIntradayString(part, realtime);
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

  IntradayPoint? _pointFromIntradayRow(dynamic row, RealtimeEstimate? realtime) {
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
    if (nav == null || nav <= 0) return null;
    return IntradayPoint(time: time, estimatedNav: nav, changePct: change);
  }

  IntradayPoint? _pointFromIntradayString(String value, RealtimeEstimate? realtime) {
    final text = value.trim();
    if (text.isEmpty) return null;
    final pieces = text.split(RegExp(r'[,|，\s]+')).where((item) => item.isNotEmpty).toList();
    if (pieces.length < 3) return null;
    final time = parseIntradayTime(pieces[0]);
    var nav = toDouble(pieces[1]);
    final change = toNullableDouble(pieces[2]);
    if (time == null || change == null) return null;
    if (nav <= 0 && realtime != null) {
      final base = realtime.officialNav > 0 ? realtime.officialNav : realtime.estimatedNav;
      nav = base * (1 + change / 100);
    }
    if (nav <= 0) return null;
    return IntradayPoint(time: time, estimatedNav: nav, changePct: change);
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

  FundAnalysis _analyze(
    FundBase fund,
    List<StockHolding> holdings,
    List<Announcement> announcements,
    MarketSnapshot market,
    String theme,
    RealtimeEstimate? realtime,
    IntradaySeries intraday,
    PortfolioItem item,
  ) {
    final points = fund.points;
    final last = points.last;
    final returns = dailyReturns(points);
    final last5 = returns.takeLast(5).sum;
    final last20 = returns.takeLast(20).sum;
    final volatility = std(returns.takeLast(30));
    final drawdown = maxDrawdown(points.takeLast(90)) * 100;
    final contribution = holdings.where((item) => item.contributionPct != null).map((item) => item.contributionPct!).sum;
    final hasStockRealtime = holdings.any((item) => item.changePct != null);
    final hasFundRealtime = realtime != null;
    final latestReturn = last.equityReturn ?? (returns.isEmpty ? 0 : returns.last);
    final todayPct = hasFundRealtime ? realtime!.estimatePct : (hasStockRealtime ? contribution : latestReturn);
    final decisionNav = hasFundRealtime ? realtime!.estimatedNav : last.value;
    final ma20 = movingAverage(points, 20);
    final ma120 = movingAverage(points, 120);
    final ma250 = movingAverage(points, 250);
    final majorNegative = announcements.where((item) => item.sentiment == '负面' && item.severity >= 80).firstOrNull;
    final isLiquor = theme == '白酒';
    var expected = 0.42 * returns.takeLast(5).averageOrZero +
        0.22 * returns.takeLast(10).averageOrZero +
        0.18 * market.averageChange +
        0.18 * todayPct;
    if (ma20 > 0 && decisionNav < ma20) expected -= 0.18;
    if (majorNegative != null) expected -= 0.35;
    final probabilityUp = (100 / (1 + exp(-(expected / max(volatility, 0.35))))).clamp(5.0, 95.0).toDouble();
    final confidence = hasFundRealtime && hasStockRealtime && volatility < 1.15 && majorNegative == null ? '中' : '低';
    final todayState = todayPct > 0.35 ? '偏涨' : todayPct < -0.35 ? '偏跌' : '震荡';
    final tomorrowTrend = probabilityUp > 60 && confidence != '低'
        ? '偏强'
        : probabilityUp >= 53
            ? '震荡，略偏强'
            : probabilityUp < 42
                ? '偏弱'
                : '震荡';
    final valuationState = valuationText(drawdown: drawdown, last20: last20);
    final trendState = trendText(decisionNav: decisionNav, ma20: ma20, ma120: ma120, ma250: ma250, market: market);
    final step = max(item.gridStepPct, 0.5);
    final costDeviation = item.costNav > 0 ? (decisionNav / item.costNav - 1) * 100 : null;
    final costDeviationText = costDeviation == null ? '等待设置成本与份额' : '${pct(costDeviation)}（成本 ${item.costNav.toStringAsFixed(4)}）';
    var gridTrigger = '未触发';
    var gridBuyRatio = 0.0;
    var gridSellRatio = 0.0;
    if (costDeviation == null) {
      gridTrigger = '设置后自动计算买卖金额';
    } else if (costDeviation <= -step * 2) {
      gridTrigger = '触发二档买入，偏离超过 -${(step * 2).toStringAsFixed(1)}%';
      gridBuyRatio = 0.12;
    } else if (costDeviation <= -step) {
      gridTrigger = '触发一档买入，偏离超过 -${step.toStringAsFixed(1)}%';
      gridBuyRatio = 0.06;
    } else if (costDeviation >= max(5, step * 2.5)) {
      gridTrigger = '触发分批止盈，偏离超过 +${max(5, step * 2.5).toStringAsFixed(1)}%';
      gridSellRatio = 0.20;
    }

    var buyRatio = 0.0;
    var sellRatio = 0.0;
    var action = '不动，等确认';
    if (valuationState.startsWith('偏低') && trendState.contains('向上')) {
      action = '小额分批买';
      buyRatio = 0.08;
    } else if (valuationState.startsWith('偏低')) {
      action = '小额定投';
      buyRatio = 0.05;
    } else if (valuationState.startsWith('偏高')) {
      action = '不急买，仓位重可减';
      sellRatio = 0.10;
    } else if (probabilityUp >= 57 && majorNegative == null) {
      action = confidence == '低' ? '观望，不追涨' : '小额试探';
      buyRatio = confidence == '低' ? 0.03 : 0.06;
    } else if (probabilityUp < 43 || majorNegative != null) {
      action = '不急买，仓位重可减';
      sellRatio = 0.10;
    }
    if (majorNegative != null) {
      action = '不急买，仓位重可减';
      buyRatio = 0.0;
      sellRatio = max(sellRatio, 0.10);
    }
    if (isLiquor && confidence == '低' && gridBuyRatio == 0) {
      buyRatio = min(buyRatio, 0.05);
      if (buyRatio == 0) action = '观望，不追涨';
    }
    if (gridBuyRatio > 0) {
      action = '网格触发，小额加仓';
      buyRatio = max(buyRatio, gridBuyRatio);
      sellRatio = 0.0;
    }
    if (gridSellRatio > 0) {
      action = '达到止盈线，分批卖出';
      sellRatio = max(sellRatio, gridSellRatio);
      buyRatio = 0.0;
    }
    buyRatio = buyRatio.clamp(0.0, 0.30).toDouble();
    sellRatio = sellRatio.clamp(0.0, 0.40).toDouble();

    final valuationTone = valuationState.startsWith('偏低') || valuationState.startsWith('中偏低')
        ? 'good'
        : valuationState.startsWith('偏高') || valuationState.startsWith('中偏高')
            ? 'bad'
            : 'warn';
    final trendTone = trendState.contains('向上') || trendState.contains('站上')
        ? 'good'
        : trendState.contains('跌破') || trendState.contains('偏弱')
            ? 'bad'
            : 'warn';
    final deviationTone = costDeviation == null
        ? 'warn'
        : gridBuyRatio > 0 || gridSellRatio > 0
            ? 'good'
            : 'warn';
    final decisionSummary = buyRatio == 0 && sellRatio == 0
        ? '观望为主，等待确认。'
        : '$action；可买 ${ratioText(buyRatio)}，可卖 ${ratioText(sellRatio)}。';
    final decision = DecisionModel(
      confidence: confidence == '低' ? '信号不足' : '信号中等',
      valuationState: valuationState,
      valuationTone: valuationTone,
      trendState: trendState,
      trendTone: trendTone,
      costDeviationText: costDeviationText,
      deviationTone: deviationTone,
      gridTrigger: gridTrigger,
      summary: decisionSummary,
      reason: '14:50 先看估值位置，再看均线风向，最后看你的成本偏离。最终净值以基金公司晚间公布为准。',
    );

    final todayReason = [
      '今天是 ${todayDateString()}，最新正式净值公布到 ${last.date}。',
      hasFundRealtime
          ? '天天基金盘中估值 ${pct(todayPct)}，估算净值 ${realtime!.estimatedNav.toStringAsFixed(4)}，更新时间 ${realtime!.updateTime}。'
          : '盘中估值暂缺，用最新净值和重仓行情近似。',
      '市场状态：${market.label}，主要指数均值 ${pct(market.averageChange)}。',
      hasStockRealtime ? '重仓股估算贡献 ${pct(contribution)}。' : '重仓贡献不可计算。',
      '近5日 ${pct(last5)}，90日回撤 ${pct(drawdown)}。',
      if (majorNegative != null) '${majorNegative.stockName} 有重大负面公告：${majorNegative.title}。',
    ].join('');

    final actionReason = [
      '买入按计划新增仓位计算，卖出按当前该基金持仓计算。',
      confidence == '低' ? '当前市场震荡，明日趋势暂不明朗。' : '明日更偏$tomorrowTrend，但仍要等盘中量价确认。',
      costDeviation == null ? '设置成本与份额后，会自动算出 14:50 是否触发网格。' : '成本偏离：$costDeviationText，网格：$gridTrigger。',
      if (isLiquor) '白酒处在修复波动期，重点看消费情绪、估值和龙头公告。',
      if (majorNegative != null) '重大负面公告出现后，短期情绪可能被压制。',
    ].join('');

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
      todayReason: todayReason,
      actionReason: actionReason,
      summaryLine: '$todayState · 明天$tomorrowTrend · $action',
      realtimeAvailable: hasFundRealtime,
      realtimeNavText: hasFundRealtime ? realtime!.estimatedNav.toStringAsFixed(4) : last.value.toStringAsFixed(4),
      realtimeTimeText: hasFundRealtime ? shortRealtimeTime(realtime!.updateTime) : '等待刷新',
      realtimeStatus: hasFundRealtime ? '估值 ${shortRealtimeTime(realtime!.updateTime)}' : '净值日 ${last.date}',
      intradayPoints: intraday.points,
      intradayNote: intraday.note,
      decision: decision,
      holdings: holdings,
      announcements: announcements,
      liquorSpecial: isLiquor
          ? '估值位置：$valuationState；龙头业绩：${majorNegative == null ? '关注茅台、五粮液、泸州老窖经营数据' : '五粮液管理层公告偏负面'}；消费情绪：${last20 > 0 ? '中性修复' : '偏弱'}；节假日效应：${holidayEffect()}；机构拥挤度：${volatility > 1.4 ? '中高' : '中'}。'
          : null,
    );
  }
}

class PortfolioItem {
  PortfolioItem({required this.code, required this.amount, this.costNav = 0, this.shares = 0, this.gridStepPct = 2.0});

  final String code;
  final double amount;
  final double costNav;
  final double shares;
  final double gridStepPct;
  bool get hasCostBasis => costNav > 0;

  factory PortfolioItem.fromJson(Map<String, dynamic> json) => PortfolioItem(
        code: json['code'].toString(),
        amount: toDouble(json['amount']),
        costNav: toDouble(json['costNav']),
        shares: toDouble(json['shares']),
        gridStepPct: toDouble(json['gridStepPct']) <= 0 ? 2.0 : toDouble(json['gridStepPct']),
      );

  Map<String, dynamic> toJson() => {'code': code, 'amount': amount, 'costNav': costNav, 'shares': shares, 'gridStepPct': gridStepPct};
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

class IntradayPoint {
  IntradayPoint({required this.time, required this.estimatedNav, required this.changePct});

  final DateTime time;
  final double estimatedNav;
  final double changePct;
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

class DecisionModel {
  DecisionModel({
    required this.confidence,
    required this.valuationState,
    required this.valuationTone,
    required this.trendState,
    required this.trendTone,
    required this.costDeviationText,
    required this.deviationTone,
    required this.gridTrigger,
    required this.summary,
    required this.reason,
  });

  final String confidence;
  final String valuationState;
  final String valuationTone;
  final String trendState;
  final String trendTone;
  final String costDeviationText;
  final String deviationTone;
  final String gridTrigger;
  final String summary;
  final String reason;
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

List<IntradayPoint> buildSyntheticIntraday(RealtimeEstimate? realtime) {
  if (realtime == null || realtime.estimatedNav <= 0) return [];
  final update = parseIntradayTime(realtime.updateTime) ?? DateTime.now();
  var endMinute = tradingMinute(update).clamp(0, 240);
  if (endMinute <= 0) endMinute = 240;
  final base = realtime.officialNav > 0 ? realtime.officialNav : realtime.estimatedNav / (1 + realtime.estimatePct / 100);
  final points = <IntradayPoint>[];
  for (var minute = 0; minute <= endMinute; minute += 5) {
    final ratio = endMinute == 0 ? 1.0 : minute / endMinute;
    final wave = sin(ratio * pi * 2) * min(realtime.estimatePct.abs() * 0.16, 0.18);
    final change = realtime.estimatePct * ratio + wave * (1 - ratio * 0.25);
    points.add(IntradayPoint(time: timeFromTradingMinute(minute), estimatedNav: base * (1 + change / 100), changePct: change));
  }
  final last = IntradayPoint(time: update, estimatedNav: realtime.estimatedNav, changePct: realtime.estimatePct);
  if (points.isEmpty || tradingMinute(points.last.time) != tradingMinute(last.time)) points.add(last);
  return points;
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

DateTime timeFromTradingMinute(int tradingMinute) {
  final now = DateTime.now();
  if (tradingMinute <= 120) {
    final minute = 9 * 60 + 30 + tradingMinute;
    return DateTime(now.year, now.month, now.day, minute ~/ 60, minute % 60);
  }
  final minute = 13 * 60 + (tradingMinute - 120);
  return DateTime(now.year, now.month, now.day, minute ~/ 60, minute % 60);
}

String formatClock(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String trimNumber(double value) {
  var text = value.toStringAsFixed(value.abs() >= 100 ? 2 : 4);
  text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return text;
}

Color toneColor(String tone) {
  if (tone == 'good') return AppColors.red;
  if (tone == 'bad') return AppColors.green;
  return const Color(0xFFB7791F);
}

IconData toneIcon(String tone) {
  if (tone == 'good') return CupertinoIcons.checkmark_circle_fill;
  if (tone == 'bad') return CupertinoIcons.xmark_circle_fill;
  return CupertinoIcons.minus_circle_fill;
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

bool isTradingTime() {
  final now = DateTime.now();
  if (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday) return false;
  final minute = now.hour * 60 + now.minute;
  return (minute >= 9 * 60 + 30 && minute <= 11 * 60 + 30) || (minute >= 13 * 60 && minute <= 15 * 60);
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

double positionValue(PortfolioItem item, FundAnalysis? analysis) {
  if (analysis != null && item.shares > 0 && analysis.latestValue > 0) {
    return item.shares * analysis.latestValue;
  }
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
