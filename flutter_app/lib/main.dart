import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  runApp(const FundLensApp());
}

class FundLensApp extends StatelessWidget {
  const FundLensApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '基金雷达',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF)),
        fontFamily: '.SF Pro Text',
        useMaterial3: true,
      ),
      home: const FundLensHome(),
    );
  }
}

class FundLensHome extends StatefulWidget {
  const FundLensHome({super.key});

  @override
  State<FundLensHome> createState() => _FundLensHomeState();
}

class _FundLensHomeState extends State<FundLensHome> {
  static const String dashboardBase = 'https://haode9344-ui.github.io/fund-lens/';

  final TextEditingController _codeController = TextEditingController(text: '161725');
  late final WebViewController _webViewController;
  int _progress = 0;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF6F7FB))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) => setState(() => _progress = progress),
          onPageStarted: (_) => setState(() => _hasError = false),
          onWebResourceError: (_) => setState(() => _hasError = true),
        ),
      )
      ..loadRequest(_dashboardUri(_codeController.text));
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Uri _dashboardUri(String code) {
    return Uri.parse(dashboardBase).replace(
      queryParameters: {
        'fundCode': code,
        'static': '1',
        'app': 'ios',
      },
    );
  }

  void _analyze() {
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      _showMessage('请输入 6 位基金代码');
      return;
    }
    FocusScope.of(context).unfocus();
    _webViewController.loadRequest(_dashboardUri(code));
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      navigationBar: CupertinoNavigationBar(
        middle: const Text('基金雷达'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => _webViewController.reload(),
          child: const Icon(CupertinoIcons.refresh, size: 22),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _SearchPanel(
              controller: _codeController,
              onSubmitted: _analyze,
            ),
            if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
            if (_hasError)
              Container(
                width: double.infinity,
                color: const Color(0xFFFFF4E5),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: const Text(
                  '页面加载失败，请检查网络后点右上角刷新。',
                  style: TextStyle(color: Color(0xFF9A5B00), fontWeight: FontWeight.w700),
                ),
              ),
            Expanded(
              child: ClipRect(
                child: WebViewWidget(controller: _webViewController),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchPanel extends StatelessWidget {
  const _SearchPanel({
    required this.controller,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xE6FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDFE3EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x141C2333),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: CupertinoTextField(
              controller: controller,
              keyboardType: TextInputType.number,
              maxLength: 6,
              placeholder: '基金代码，例如 161725',
              clearButtonMode: OverlayVisibilityMode.editing,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFDFE3EB)),
              ),
              onSubmitted: (_) => onSubmitted(),
            ),
          ),
          const SizedBox(width: 10),
          CupertinoButton.filled(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            onPressed: onSubmitted,
            child: const Text('分析', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}
