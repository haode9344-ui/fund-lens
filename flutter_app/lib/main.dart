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

  Future<void> _addPendingBuy() async {
    final amount = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const AddBuySheet(),
    );
    if (amount == null || amount <= 0) return;
    final updated = _item.addPendingBuy(amount);
    final fresh = await widget.onUpdateItem(updated);
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
    final pending = _item.pendingAmount;
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
                      Expanded(child: _Metric(label: '净值/估值', value: _analysis.realtimeNavText)),
                      Expanded(child: _Metric(label: '更新时间', value: _analysis.realtimeTimeText)),
                    ],
                  ),
                  if (pending > 0) ...[
                    const SizedBox(height: 12),
                    PendingBuySummary(item: _item),
                  ],
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
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _addPendingBuy,
                      icon: const Icon(CupertinoIcons.plus_circle),
                      label: const Text('加仓'),
                    ),
                  ),
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
                    const Text('今日没有买卖触发点，建议观望。', style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  Text(_analysis.actionReason, style: const TextStyle(color: AppColors.muted, height: 1.45, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  ReasonBox(title: '买入原因', text: _analysis.buyReason, color: AppColors.red),
                  const SizedBox(height: 10),
                  ReasonBox(title: '卖出原因', text: _analysis.sellReason, color: AppColors.green),
                ],
              ),
            ),
            const SizedBox(height: 12),
            DecisionModelCard(decision: _analysis.decision),
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
                    const Text('暂未抓到前十大重仓股。下拉刷新会重新请求季报持仓接口。', style: TextStyle(color: AppColors.muted, height: 1.45, fontWeight: FontWeight.w700))
                  else
                    ..._analysis.holdings.take(10).map((item) => StockHoldingRow(item: item)),
                  if (_analysis.announcements.isNotEmpty) ...[
                    const Divider(height: 28),
                    const Text('高影响公告', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 10),
                    ..._analysis.announcements.take(5).map((item) => AnnouncementTile(item: item)),
                  ],
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
    Navigator.pop(
      context,
      PortfolioItem(
        code: code,
        amount: amount,
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

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = double.tryParse(_amountController.text.trim()) ?? 0;
    if (amount <= 0) return;
    Navigator.pop(context, amount);
  }

  @override
  Widget build(BuildContext context) {
    final order = pendingOrderPlan(DateTime.now());
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
                  '${money(order.amount)} · ${order.note}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4, fontWeight: FontWeight.w700),
                ),
              ),
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
          Row(
            children: [
              const Expanded(child: Text('当日分时走势', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
              Pill(text: widget.points.length >= 120 ? '${widget.points.length}个分钟点' : '等待分钟数据'),
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
              Pill(text: decision.confidence),
            ],
          ),
          const SizedBox(height: 10),
          Text(decision.summary, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, height: 1.35)),
          const SizedBox(height: 12),
          _DecisionRow(label: '板块资金', value: decision.valuationState, tone: decision.valuationTone),
          _DecisionRow(label: '重仓尾盘', value: decision.trendState, tone: decision.trendTone),
          _DecisionRow(label: '量价配合', value: decision.costDeviationText, tone: decision.deviationTone),
          _DecisionRow(label: '持仓动作', value: decision.gridTrigger, tone: decision.deviationTone),
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

  Future<FundAnalysis> load(PortfolioItem item) async {
    final code = item.code;
    final fund = await _loadFundBase(code);
    final theme = inferTheme(fund.name);
    final settledItem = settlePortfolioItem(item, fund);
    final realtime = await _loadRealtimeEstimate(code);
    final intraday = await _loadIntradayTrend(code, fund, theme, realtime, fund.points.last.value);
    final holdingCode = holdingsLookupCode(fund);
    final rawHoldings = await _loadHoldings(holdingCode);
    final holdingSourceText = holdingCode == code ? '' : '联接基金持仓已切换为目标 ETF $holdingCode 的前十大股票。';
    final holdings = await _enrichHoldings(applyThemeFallback(rawHoldings, theme));
    final tailSignals = await _loadStockTailSignals(holdings);
    final announcements = await _loadAnnouncements(holdings.take(5).toList());
    final market = await _loadMarket(fund, theme, holdings);
    return _analyze(fund, holdings, announcements, market, theme, realtime, intraday, tailSignals, settledItem, holdingSourceText);
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
          return IntradaySeries(points: points, note: '已接入当日分钟估值，共 ${points.length} 个点；硬折线连接，不做平滑。');
        }
      } catch (_) {
        continue;
      }
    }
    final proxy = intradayProxyForFund(fund, theme);
    if (proxy != null) {
      final proxySeries = await _loadProxyIntradayTrend(proxy, realtime?.estimatePct ?? fund.points.last.equityReturn ?? 0, fallbackNav);
      if (proxySeries.points.isNotEmpty) return proxySeries;
    }
    return IntradaySeries(
      points: const [],
      note: '暂未拿到足够的分钟级数据。已强制刷新分时接口；如果基金平台还没生成当日分钟估值，下拉刷新会继续重试。',
    );
  }

  Future<IntradaySeries> _loadProxyIntradayTrend(IntradayProxy proxy, double anchorPct, double fallbackNav) async {
    final uri = Uri.parse(
      'https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=${proxy.secid}&fields1=f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13&fields2=f51,f52,f53,f54,f55,f56,f57,f58&iscr=0&iscca=0&ndays=1&rt=${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return IntradaySeries(points: const [], note: '');
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final points = proxyIntradayPointsFromPayload(payload, anchorPct, fallbackNav);
      if (points.length < 20) return IntradaySeries(points: const [], note: '');
      return IntradaySeries(
        points: points,
        note: '场外基金没有真实分钟成交价，已使用${proxy.name}分时走势，并把收盘端点锚定到基金当日估值/实际涨跌。',
      );
    } catch (_) {
      return IntradaySeries(points: const [], note: '');
    }
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
    final uri = Uri.parse('https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=$secids&fields=f2,f3,f6,f8,f12,f14,f62,f100,f184&rt=${DateTime.now().millisecondsSinceEpoch}');
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
    var label = '市场震荡';
    var avg = 0.0;
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final data = payload['data'] as Map<String, dynamic>?;
      final rows = (data?['diff'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
      final changes = rows.map((row) => toDouble(row['f3'])).toList();
      avg = changes.isEmpty ? 0.0 : changes.reduce((a, b) => a + b) / changes.length;
      label = avg > 0.4 ? '市场偏强' : avg < -0.4 ? '市场偏弱' : '市场震荡';
    } catch (_) {
      final returns = recentReturns(fund.points, 10);
      avg = returns.isEmpty ? 0.0 : returns.reduce((a, b) => a + b) / returns.length;
      label = avg > 0 ? '基金风格偏强' : '基金风格震荡';
    }
    final realtimeBoard = await _loadThemeBoard(theme);
    final board = realtimeBoard ?? boardSignalFromHoldings(theme, holdings);
    return MarketSnapshot(label: label, averageChange: avg, board: board);
  }

  Future<BoardSignal?> _loadThemeBoard(String theme) async {
    final keywords = themeKeywords(theme);
    if (keywords.isEmpty) return null;
    final candidates = <Map<String, dynamic>>[];
    for (final boardType in const ['2', '3']) {
      final uri = Uri.parse(
        'https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=1000&po=1&np=1&fltt=2&fid=f3&fs=m:90+t:$boardType&fields=f12,f14,f3,f62,f184,f6,f2,f8&rt=${DateTime.now().millisecondsSinceEpoch}',
      );
      try {
        final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) continue;
        final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final data = payload['data'] as Map<String, dynamic>?;
        final rows = (data?['diff'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();
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
    final volumeRatio = boardCode.isEmpty ? null : await _loadTrendVolumeRatio('90.$boardCode');
    return BoardSignal(
      name: (best['f14'] ?? '$theme板块').toString(),
      source: '板块实时行情',
      changePct: toDouble(best['f3']),
      code: boardCode,
      mainFlow: toNullableDouble(best['f62']),
      mainFlowPct: toNullableDouble(best['f184']),
      amount: toNullableDouble(best['f6']),
      turnover: toNullableDouble(best['f8']),
      volumeRatio: volumeRatio,
    );
  }

  Future<double?> _loadTrendVolumeRatio(String secid) async {
    final uri = Uri.parse(
      'https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=$secid&fields1=f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13&fields2=f51,f52,f53,f54,f55,f56,f57,f58&iscr=0&iscca=0&ndays=2&rt=${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      final response = await _client.get(uri, headers: noCacheHeaders()).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final points = trendPointsFromPayload(payload);
      if (points.length < 60) return null;
      return sameMinuteAmountRatio(points);
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

  FundAnalysis _analyze(
    FundBase fund,
    List<StockHolding> holdings,
    List<Announcement> announcements,
    MarketSnapshot market,
    String theme,
    RealtimeEstimate? realtime,
    IntradaySeries intraday,
    List<StockTailSignal> tailSignals,
    PortfolioItem item,
    String holdingSourceText,
  ) {
    final points = fund.points;
    final last = points.last;
    final returns = dailyReturns(points);
    final last20 = returns.takeLast(20).sum;
    final drawdown = maxDrawdown(points.takeLast(90)) * 100;
    final contribution = holdings.where((item) => item.contributionPct != null).map((item) => item.contributionPct!).sum;
    final hasStockRealtime = holdings.any((item) => item.changePct != null);
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
    final majorNegative = announcements.where((item) => item.sentiment == '负面' && item.severity >= 80).firstOrNull;
    final isLiquor = theme == '白酒';
    var forward = buildForwardDecisionScore(board: market.board, tailSignals: tailSignals, todayPct: todayPct);
    if (majorNegative != null) {
      forward = ForwardDecisionScore(
        total: min(forward.total - 2, -3).toInt(),
        fundFlowScore: forward.fundFlowScore,
        tailScore: forward.tailScore,
        volumeScore: forward.volumeScore,
        fundFlowText: forward.fundFlowText,
        tailText: '${forward.tailText}；重大负面公告额外扣分',
        volumeText: forward.volumeText,
        conclusion: '明天有低开低走风险',
        confidence: forward.confidence,
      );
    }
    final sectorState = forward.fundFlowText;
    final coreState = coreHoldingStateText(holdings);
    final tailState = forward.tailText;
    final volumeState = forward.volumeText;
    final confidence = forward.confidence.contains('中') && majorNegative == null ? '中' : '低';
    final probabilityUp = (50 + forward.total * 10).clamp(10.0, 90.0).toDouble();
    final todayState = todayPct > 0.35 ? '偏涨' : todayPct < -0.35 ? '偏跌' : '震荡';
    final tomorrowTrend = forward.total >= 3
        ? '大概率高开高走'
        : forward.total <= -3
            ? '低开低走风险高'
            : '震荡观察';
    final valuationBackground = valuationText(drawdown: drawdown, last20: last20);
    final amountLevel = item.amount >= 30000
        ? '仓位偏重'
        : item.amount >= 10000
            ? '中等仓位'
            : '轻仓';

    var buyRatio = 0.0;
    var sellRatio = 0.0;
    var action = '不动，等14:45确认';
    if (forward.total <= -3) {
      action = amountLevel == '仓位偏重' ? '减仓避险' : '观望，不加仓';
      sellRatio = item.amount >= 10000 ? 0.08 : 0.05;
    } else if (forward.total >= 3) {
      action = '14:50小额买入';
      buyRatio = confidence == '中' ? 0.10 : 0.06;
    } else if (forward.total <= -2) {
      action = '观望，防回落';
      if (amountLevel == '仓位偏重') sellRatio = 0.05;
    } else if (forward.total >= 2) {
      action = '轻仓可试探';
      buyRatio = confidence == '中' ? 0.04 : 0.02;
    }
    if (forward.confidence == '低置信度') {
      buyRatio = 0.0;
      sellRatio = 0.0;
      action = '不动，等实时数据';
    }
    if (amountLevel == '仓位偏重' && forward.total < 0) {
      sellRatio = max(sellRatio, 0.05);
      buyRatio = min(buyRatio, 0.03);
      if (sellRatio > 0) action = '仓位重可小幅减';
    }
    if (isLiquor && confidence == '低') buyRatio = min(buyRatio, 0.03);
    buyRatio = buyRatio.clamp(0.0, 0.20).toDouble();
    sellRatio = sellRatio.clamp(0.0, 0.30).toDouble();

    final sectorTone = toneFromScore(forward.fundFlowScore.toDouble());
    final coreTone = toneFromScore(forward.tailScore.toDouble());
    final volumeTone = toneFromScore(forward.volumeScore.toDouble());
    final decisionSummary = buyRatio == 0 && sellRatio == 0
        ? '总分 ${scoreText(forward.total)}：$action，今日没有买卖金额。'
        : '总分 ${scoreText(forward.total)}：$action，买 ${ratioText(buyRatio)}，卖 ${ratioText(sellRatio)}。';
    final amountRule = buyRatio == 0 && sellRatio == 0
        ? '$amountLevel ${money(item.amount)}，今日无买卖触发。'
        : '$amountLevel ${money(item.amount)}，买入 ${money(item.amount * buyRatio)}，卖出 ${money(item.amount * sellRatio)}';
    final decision = DecisionModel(
      confidence: confidence == '低' ? '低置信度' : '中等置信度',
      valuationState: sectorState,
      valuationTone: sectorTone,
      trendState: '$coreState；$tailState',
      trendTone: coreTone,
      costDeviationText: volumeState,
      deviationTone: volumeTone,
      gridTrigger: amountRule,
      summary: decisionSummary,
      reason: '规则：主力净流入/流出10亿给±2分；前三大重仓股14:30-14:40有2只尾盘涨跌超1%给±2分；量价配合给±1分。14:45汇总，14:50前只按你的持有金额换算买卖金额。',
    );

    final todayReason = [
      '今天是 ${todayDateString()}，最新正式净值公布到 ${last.date}。',
      useOfficialValue
          ? '已切换为盘后实际净值 ${last.value.toStringAsFixed(4)}，实际涨跌 ${pct(todayPct)}。'
          : hasFundRealtime
          ? '天天基金盘中估值 ${pct(todayPct)}，估算净值 ${realtime!.estimatedNav.toStringAsFixed(4)}，更新时间 ${realtime!.updateTime}。'
          : '盘中估值暂缺，用最新净值和重仓行情近似。',
      '板块：$sectorState。',
      '重仓：$coreState。',
      '尾盘：$tailState。',
      '量价：$volumeState。',
      '市场背景：${market.label}，主要指数均值 ${pct(market.averageChange)}。',
      if (majorNegative != null) '${majorNegative.stockName} 有重大负面公告：${majorNegative.title}。',
    ].join('');

    final moduleA = useOfficialValue
        ? '今日实际净值已更新，涨跌为 ${pct(todayPct)}，${forward.volumeText.replaceFirst('量价关系：', '')}。'
        : todayPct >= 0
            ? '今日盘中估值上涨 ${pct(todayPct)}，${forward.volumeText.replaceFirst('量价关系：', '')}。'
            : '今日盘中出现 ${pct(todayPct)} 的回撤，${forward.volumeText.replaceFirst('量价关系：', '')}。';
    final moduleB = forward.total >= 3
        ? '虽然大盘可能仍有震荡，但${forward.fundFlowText.replaceFirst('板块资金：', '')}；${forward.tailText.replaceFirst('前三大重仓股尾盘：', '')}。'
        : forward.total <= -3
            ? '${forward.fundFlowText.replaceFirst('板块资金：', '')}；${forward.tailText.replaceFirst('前三大重仓股尾盘：', '')}，短线抛压需要优先防守。'
            : '${forward.fundFlowText.replaceFirst('板块资金：', '')}；${forward.tailText.replaceFirst('前三大重仓股尾盘：', '')}，信号没有形成强共振。';
    final moduleC = buyRatio > 0
        ? '预计$tomorrowTrend，建议 14:50 执行【买入】，金额 ${money(item.amount * buyRatio)}。'
        : sellRatio > 0
            ? '预计$tomorrowTrend，建议 14:50 执行【卖出】，金额 ${money(item.amount * sellRatio)}；如果你实际已经深亏，这个卖出只作为防守参考，不建议因为一天信号直接割肉。'
            : '预计$tomorrowTrend，建议【不动，等确认】；买卖都按你填的持有金额 ${money(item.amount)} 计算，不需要成本价和份额。';
    final actionReason = '$moduleA$moduleB$moduleC${isLiquor ? '白酒还要额外看消费情绪、估值和龙头公告。' : ''}${majorNegative != null ? '重大负面公告出现后，短期情绪可能被压制。' : ''}';

    final buyReason = buyRatio > 0
        ? '$action。买入理由：总分 ${scoreText(forward.total)}，主力资金、尾盘重仓和量价关系偏正；按持有金额执行 ${ratioText(buyRatio)}，约 ${money(item.amount * buyRatio)}，只做小比例加仓。'
        : '暂不买。买入理由不足：总分 ${scoreText(forward.total)}，$sectorState；$tailState；$volumeState，没有达到强烈看涨阈值。';
    final sellReason = sellRatio > 0
        ? '建议小幅卖出 ${ratioText(sellRatio)}，约 ${money(item.amount * sellRatio)}。卖出理由：总分 ${scoreText(forward.total)}，${majorNegative != null ? '出现重大负面公告；' : ''}$sectorState；$tailState；$volumeState。先降一小部分风险，不做一次性清仓。'
        : '暂不卖。卖出理由不足：总分 ${scoreText(forward.total)}，还没有达到强烈看跌阈值；若持有金额不重，短线波动不适合直接卖出。';

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
      buyReason: buyReason,
      sellReason: sellReason,
      summaryLine: '$todayState · 明天$tomorrowTrend · $action',
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
      settledItem: item,
      holdingSourceText: holdingSourceText,
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

class PendingOrderPlan {
  PendingOrderPlan({required this.confirmDate, required this.beforeCutoff, required this.note});

  final String confirmDate;
  final bool beforeCutoff;
  final String note;
}

class PortfolioItem {
  PortfolioItem({
    required this.code,
    required this.amount,
    this.shares,
    this.lastSettledDate = '',
    this.lastSettledNav = 0,
    List<PendingBuy>? pendingBuys,
  }) : pendingBuys = pendingBuys ?? const [];

  final String code;
  final double amount;
  final double? shares;
  final String lastSettledDate;
  final double lastSettledNav;
  final List<PendingBuy> pendingBuys;

  double get pendingAmount => pendingBuys.map((item) => item.amount).sum;

  factory PortfolioItem.fromJson(Map<String, dynamic> json) => PortfolioItem(
        code: json['code'].toString(),
        amount: toDouble(json['amount']),
        shares: toNullableDouble(json['shares']),
        lastSettledDate: (json['lastSettledDate'] ?? '').toString(),
        lastSettledNav: toDouble(json['lastSettledNav']),
        pendingBuys: (json['pendingBuys'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(PendingBuy.fromJson)
            .toList(),
      );

  PortfolioItem copyWith({
    double? amount,
    double? shares,
    String? lastSettledDate,
    double? lastSettledNav,
    List<PendingBuy>? pendingBuys,
  }) {
    return PortfolioItem(
      code: code,
      amount: amount ?? this.amount,
      shares: shares ?? this.shares,
      lastSettledDate: lastSettledDate ?? this.lastSettledDate,
      lastSettledNav: lastSettledNav ?? this.lastSettledNav,
      pendingBuys: pendingBuys ?? this.pendingBuys,
    );
  }

  PortfolioItem addPendingBuy(double value) {
    final plan = pendingOrderPlan(DateTime.now());
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

  Map<String, dynamic> toJson() => {
        'code': code,
        'amount': amount,
        'shares': shares,
        'lastSettledDate': lastSettledDate,
        'lastSettledNav': lastSettledNav,
        'pendingBuys': pendingBuys.map((item) => item.toJson()).toList(),
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

class IntradayProxy {
  const IntradayProxy({required this.secid, required this.name});

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
  TrendPoint({required this.time, required this.close, required this.amount});

  final DateTime time;
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
  final double? mainFlowPct;
  final double? contributionPct;

  StockHolding copyWith({
    String? industry,
    double? price,
    double? changePct,
    double? amount,
    double? turnover,
    double? mainFlow,
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
}

class MarketSnapshot {
  MarketSnapshot({required this.label, required this.averageChange, this.board});

  final String label;
  final double averageChange;
  final BoardSignal? board;
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
    required this.buyReason,
    required this.sellReason,
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
    required this.settledItem,
    required this.holdingSourceText,
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
  final String buyReason;
  final String sellReason;
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
  final PortfolioItem settledItem;
  final String holdingSourceText;
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

List<TrendPoint> trendPointsFromPayload(Map<String, dynamic> payload) {
  final data = payload['data'] as Map<String, dynamic>?;
  final rows = (data?['trends'] as List<dynamic>? ?? []).map((item) => item.toString());
  final points = <TrendPoint>[];
  for (final row in rows) {
    final pieces = row.split(',');
    if (pieces.length < 7) continue;
    final time = DateTime.tryParse(pieces[0].trim().replaceFirst(' ', 'T'));
    final close = toDouble(pieces[2]);
    final amount = toDouble(pieces[6]);
    if (time != null && close > 0) points.add(TrendPoint(time: time, close: close, amount: amount));
  }
  points.sort((a, b) => a.time.compareTo(b.time));
  return points;
}

List<IntradayPoint> proxyIntradayPointsFromPayload(Map<String, dynamic> payload, double anchorPct, double fallbackNav) {
  final data = payload['data'] as Map<String, dynamic>?;
  final prePrice = toDouble(data?['prePrice']);
  if (prePrice <= 0) return const [];
  final trend = trendPointsFromPayload(payload);
  if (trend.length < 2) return const [];
  final raw = trend
      .map((point) => IntradayPoint(
            time: point.time,
            estimatedNav: fallbackNav * (point.close / prePrice),
            changePct: (point.close / prePrice - 1) * 100,
          ))
      .toList();
  final finalRaw = raw.last.changePct;
  double scale;
  if (finalRaw.abs() < 0.05) {
    scale = 0;
  } else {
    scale = anchorPct / finalRaw;
    scale = scale.clamp(-3.0, 3.0).toDouble();
  }
  return raw.map((point) {
    final minuteRatio = tradingMinute(point.time).clamp(0, 240).toDouble() / 240;
    final adjustedPct = scale == 0 ? anchorPct * minuteRatio : point.changePct * scale;
    return IntradayPoint(
      time: point.time,
      estimatedNav: fallbackNav * (1 + adjustedPct / 100),
      changePct: adjustedPct,
    );
  }).toList();
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
  if (points.length < 60) return null;
  final dates = points.map((item) => dateKey(item.time)).toSet().toList()..sort();
  if (dates.length < 2) return null;
  final previousDate = dates[dates.length - 2];
  final latestDate = dates.last;
  final today = points.where((item) => dateKey(item.time) == latestDate).toList();
  final previous = points.where((item) => dateKey(item.time) == previousDate).toList();
  if (today.isEmpty || previous.isEmpty) return null;
  final now = DateTime.now();
  final decisionMinute = tradingMinute(DateTime(now.year, now.month, now.day, 14, 40));
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

String dateKey(DateTime time) => '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';

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
  return BoardSignal(
    name: theme.isEmpty ? '重仓映射' : '$theme重仓映射',
    source: '重仓股实时映射',
    changePct: weightedChange,
    mainFlow: flow,
    mainFlowPct: averageHoldingFlowPct(holdings),
    amount: mappedAmount,
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

  final fundFlowText = board == null
      ? '板块资金：等待实时板块行情'
      : flow == null
          ? '板块资金：${board.name} ${pct(board.changePct)}，主力净流向等待确认'
          : '板块资金：${board.name} ${pct(board.changePct)}，${flow >= 0 ? '主力净流入' : '主力净流出'} ${cnAmount(flow.abs())}，得分 ${scoreText(fundFlowScore)}';

  final readyTails = tailSignals.where((item) => item.ready && item.changePct != null).toList();
  final tailUpCount = readyTails.where((item) => item.changePct! > 1).length;
  final tailDownCount = readyTails.where((item) => item.changePct! < -1).length;
  var tailScore = 0;
  if (tailUpCount >= 2) tailScore = 2;
  if (tailDownCount >= 2) tailScore = -2;
  final tailSummary = readyTails.isEmpty
      ? '前三大重仓股尾盘：分钟数据等待刷新'
      : readyTails.map((item) => '${item.name}${pct(item.changePct!)}').join('、');
  final tailText = readyTails.isEmpty
      ? tailSummary
      : '前三大重仓股尾盘：$tailSummary，${tailUpCount >= 2 ? '抢筹明显' : tailDownCount >= 2 ? '跳水偏弱' : '没有形成一致方向'}，得分 ${scoreText(tailScore)}';

  final ratio = board?.volumeRatio;
  var volumeScoreValue = 0;
  if (ratio != null && todayPct > 0.15 && ratio >= 1.05) volumeScoreValue = 1;
  if (ratio != null && todayPct > 0.15 && ratio < 0.95) volumeScoreValue = -1;
  if (ratio != null && todayPct < -0.15 && ratio >= 1.05) volumeScoreValue = -1;
  if (ratio != null && todayPct < -0.15 && ratio < 0.95) volumeScoreValue = 1;
  final volumeLabel = ratio == null
      ? '量价关系：成交额同段对比等待刷新'
      : '量价关系：今日成交额约为昨日同段 ${(ratio * 100).toStringAsFixed(0)}%，${ratio >= 1.05 ? '放量' : ratio < 0.95 ? '缩量' : '量能接近'}，得分 ${scoreText(volumeScoreValue)}';

  final total = fundFlowScore + tailScore + volumeScoreValue;
  final conclusion = total >= 3
      ? '明天大概率高开高走'
      : total <= -3
          ? '明天大概率低开低走'
          : '明天更偏震荡';
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

String holdingsLookupCode(FundBase fund) {
  const linkedTargets = {
    '012862': '159796',
    '012863': '159796',
  };
  if (!isLinkedFund(fund.name)) return fund.code;
  return linkedTargets[fund.code] ?? fund.code;
}

bool isLinkedFund(String name) => RegExp(r'联接|ETF联接').hasMatch(name);

IntradayProxy? intradayProxyForFund(FundBase fund, String theme) {
  const byCode = {
    '025687': IntradayProxy(secid: '90.BK1326', name: '半导体设备指数'),
    '012862': IntradayProxy(secid: '0.159796', name: '汇添富中证电池主题ETF'),
    '012863': IntradayProxy(secid: '0.159796', name: '汇添富中证电池主题ETF'),
  };
  final direct = byCode[fund.code];
  if (direct != null) return direct;
  if (isLinkedFund(fund.name) && holdingsLookupCode(fund) != fund.code) {
    return IntradayProxy(secid: '0.${holdingsLookupCode(fund)}', name: '目标ETF ${holdingsLookupCode(fund)}');
  }
  if (theme == '半导体') return IntradayProxy(secid: '90.BK1326', name: '半导体设备指数');
  if (theme == '电池' || theme == '新能源') return IntradayProxy(secid: '90.BK0951', name: '电池主题指数');
  return null;
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

PortfolioItem settlePortfolioItem(PortfolioItem item, FundBase fund) {
  final last = fund.points.last;
  if (last.value <= 0) return item;
  var shares = item.shares;
  var amount = item.amount;
  var settledDate = item.lastSettledDate;
  var settledNav = item.lastSettledNav;
  var pending = List<PendingBuy>.from(item.pendingBuys);

  shares ??= amount > 0 ? amount / last.value : 0;
  if (settledDate.isEmpty) {
    settledDate = last.date;
    settledNav = last.value;
  }

  if (last.equityReturn != null) {
    final remaining = <PendingBuy>[];
    for (final order in pending) {
      if (compareDateText(order.confirmDate, last.date) <= 0) {
        shares = (shares ?? 0) + order.amount / last.value;
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
  );
}

PendingOrderPlan pendingOrderPlan(DateTime now) {
  final beforeCutoff = isFundTradingDay(now) && (now.hour * 60 + now.minute) < 15 * 60;
  final confirm = beforeCutoff ? now : nextTradingDate(now);
  final confirmText = dateText(confirm);
  return PendingOrderPlan(
    confirmDate: confirmText,
    beforeCutoff: beforeCutoff,
    note: beforeCutoff ? '15:00前买入，按今日夜间公布净值确认份额' : '已过15:00或非交易日，按下一交易日净值确认',
  );
}

DateTime nextTradingDate(DateTime value) {
  var date = DateTime(value.year, value.month, value.day).add(const Duration(days: 1));
  while (!isFundTradingDay(date)) {
    date = date.add(const Duration(days: 1));
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
