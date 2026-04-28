import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fund_lens/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('boots Xiaoyou app shell', (tester) async {
    await tester.pumpWidget(const XiaoyouApp());
    await tester.pump();

    expect(find.byType(XiaoyouApp), findsOneWidget);
    expect(find.byType(PortfolioHome), findsOneWidget);
  });
}
