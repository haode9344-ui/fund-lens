import 'dart:math';

class MomentumInput {
  const MomentumInput({
    required this.code,
    required this.name,
    required this.rank,
    required this.weightPct,
    required this.priceSlopePct,
    required this.volumeSpikeRatio,
  });

  final String code;
  final String name;
  final int rank;
  final double weightPct;
  final double priceSlopePct;
  final double volumeSpikeRatio;
}

class MomentumFactor {
  const MomentumFactor({
    required this.code,
    required this.name,
    required this.rank,
    required this.weightPct,
    required this.priceSlope,
    required this.volumeSpikeRatio,
    required this.momentumScore,
    required this.isBullishSpike,
    required this.isBearishSpike,
  });

  final String code;
  final String name;
  final int rank;
  final double weightPct;
  final double priceSlope;
  final double volumeSpikeRatio;
  final double momentumScore;
  final bool isBullishSpike;
  final bool isBearishSpike;
}

class PortfolioMomentumSignal {
  const PortfolioMomentumSignal({
    required this.signalType,
    required this.totalMomentum,
    required this.bullishTopCount,
    required this.bearishTopCount,
    required this.validCount,
    required this.confidence,
    required this.reasons,
    required this.factors,
  });

  final String signalType;
  final double totalMomentum;
  final int bullishTopCount;
  final int bearishTopCount;
  final int validCount;
  final String confidence;
  final List<String> reasons;
  final List<MomentumFactor> factors;
}

class MomentumEngine {
  const MomentumEngine({
    this.topHoldingsCount = 10,
    this.coreHoldingsCount = 3,
    this.priceSlopePositiveThreshold = 0.0,
    this.priceSlopeNegativeThreshold = 0.0,
    this.volumeSpikeThreshold = 1.50,
    this.strongConfidenceMomentum = 0.0008,
  });

  final int topHoldingsCount;
  final int coreHoldingsCount;
  final double priceSlopePositiveThreshold;
  final double priceSlopeNegativeThreshold;
  final double volumeSpikeThreshold;
  final double strongConfidenceMomentum;

  MomentumFactor calculateFactor(MomentumInput input) {
    final priceSlope = input.priceSlopePct / 100.0;
    final volumeSpike = input.volumeSpikeRatio.isFinite && input.volumeSpikeRatio > 0 ? input.volumeSpikeRatio : 0.0;
    final effectiveVolumeSpike = volumeSpike >= volumeSpikeThreshold ? volumeSpike : 0.0;
    final weight = input.weightPct / 100.0;
    final score = priceSlope * effectiveVolumeSpike * weight;
    return MomentumFactor(
      code: input.code,
      name: input.name,
      rank: input.rank,
      weightPct: input.weightPct,
      priceSlope: priceSlope,
      volumeSpikeRatio: volumeSpike,
      momentumScore: score,
      isBullishSpike: priceSlope > priceSlopePositiveThreshold && volumeSpike >= volumeSpikeThreshold,
      isBearishSpike: priceSlope < -priceSlopeNegativeThreshold.abs() && volumeSpike >= volumeSpikeThreshold,
    );
  }

  PortfolioMomentumSignal decide(List<MomentumInput> inputs) {
    final sorted = [...inputs]..sort((a, b) => b.weightPct.compareTo(a.weightPct));
    final factors = sorted.take(max(1, topHoldingsCount)).map(calculateFactor).toList();
    final valid = factors.where((item) => item.volumeSpikeRatio >= volumeSpikeThreshold && item.weightPct > 0).toList();
    if (valid.isEmpty) {
      return const PortfolioMomentumSignal(
        signalType: 'WAIT',
        totalMomentum: 0,
        bullishTopCount: 0,
        bearishTopCount: 0,
        validCount: 0,
        confidence: '低',
        reasons: ['14:50-15:00 没有出现有效放量，尾盘不参与判断'],
        factors: [],
      );
    }

    final core = factors.take(max(1, coreHoldingsCount)).toList();
    final totalMomentum = valid.fold<double>(0, (sum, item) => sum + item.momentumScore);
    final bullishTopCount = core.where((item) => item.isBullishSpike).length;
    final bearishTopCount = core.where((item) => item.isBearishSpike).length;
    final positiveWeight = valid.where((item) => item.priceSlope > 0).fold<double>(0, (sum, item) => sum + item.weightPct);
    final negativeWeight = valid.where((item) => item.priceSlope < 0).fold<double>(0, (sum, item) => sum + item.weightPct);

    var signalType = 'WAIT';
    final reasons = <String>[
      '14:50-15:00 已按持仓占比汇总放量方向，净方向 ${(totalMomentum * 100).toStringAsFixed(3)}',
      '前三大持仓股放量上涨 $bullishTopCount 只，放量下跌 $bearishTopCount 只',
    ];
    if (totalMomentum > 0 && bullishTopCount >= 2) {
      signalType = 'BUY';
      reasons.add('最后 10 分钟放量上涨，核心持仓出现收盘前建仓信号');
    } else if (totalMomentum < 0 && bearishTopCount >= 2) {
      signalType = 'SELL';
      reasons.add('最后 10 分钟放量下跌，核心持仓出现收盘前出货信号');
    } else {
      reasons.add('放量方向不够一致，尾盘信号先按无效处理');
    }
    if (positiveWeight > negativeWeight) {
      reasons.add('放量上涨持仓权重 ${positiveWeight.toStringAsFixed(2)}% 高于放量下跌权重 ${negativeWeight.toStringAsFixed(2)}%');
    } else if (negativeWeight > positiveWeight) {
      reasons.add('放量下跌持仓权重 ${negativeWeight.toStringAsFixed(2)}% 高于放量上涨权重 ${positiveWeight.toStringAsFixed(2)}%');
    } else {
      reasons.add('放量上涨和放量下跌权重接近');
    }

    final confidence = _confidence(signalType, totalMomentum, bullishTopCount, bearishTopCount);
    return PortfolioMomentumSignal(
      signalType: signalType,
      totalMomentum: totalMomentum,
      bullishTopCount: bullishTopCount,
      bearishTopCount: bearishTopCount,
      validCount: valid.length,
      confidence: confidence,
      reasons: reasons,
      factors: valid,
    );
  }

  String _confidence(String signalType, double totalMomentum, int bullishTopCount, int bearishTopCount) {
    if (signalType == 'BUY') {
      return bullishTopCount >= 3 || totalMomentum >= strongConfidenceMomentum ? '中高' : '中';
    }
    if (signalType == 'SELL') {
      return bearishTopCount >= 3 || totalMomentum.abs() >= strongConfidenceMomentum ? '中高' : '中';
    }
    return totalMomentum.abs() < strongConfidenceMomentum / 4 ? '低' : '中低';
  }
}

class NavErrorRecord {
  const NavErrorRecord({
    required this.tradeDate,
    required this.actualNav,
    required this.estimatedNav,
    this.industryReturn,
    this.factorReturns = const {},
  });

  final String tradeDate;
  final double actualNav;
  final double estimatedNav;
  final double? industryReturn;
  final Map<String, double> factorReturns;

  double get error => actualNav - estimatedNav;

  factory NavErrorRecord.fromJson(Map<String, dynamic> json) {
    final factors = <String, double>{};
    final rawFactors = json['factorReturns'] ?? json['factor_returns'];
    if (rawFactors is Map) {
      rawFactors.forEach((key, value) {
        final parsed = _toFiniteDouble(value);
        if (parsed != null) factors[key.toString()] = parsed;
      });
    }
    final industry = _toFiniteDouble(json['industryReturn'] ?? json['industry_return']);
    if (industry != null) factors.putIfAbsent('industry_return', () => industry);
    return NavErrorRecord(
      tradeDate: (json['tradeDate'] ?? json['trade_date'] ?? json['date'] ?? '').toString(),
      actualNav: _toFiniteDouble(json['actualNav'] ?? json['actual_nav']) ?? 0,
      estimatedNav: _toFiniteDouble(json['estimatedNav'] ?? json['estimated_nav'] ?? json['est_nav']) ?? 0,
      industryReturn: industry,
      factorReturns: factors,
    );
  }

  Map<String, dynamic> toJson() => {
        'tradeDate': tradeDate,
        'actualNav': actualNav,
        'estimatedNav': estimatedNav,
        'industryReturn': industryReturn,
        'factorReturns': factorReturns,
      };
}

class NavCorrectionResult {
  const NavCorrectionResult({
    required this.algorithm,
    required this.rawEstNav,
    required this.correction,
    required this.correctedNav,
    required this.sampleSize,
    required this.detail,
  });

  final String algorithm;
  final double rawEstNav;
  final double correction;
  final double correctedNav;
  final int sampleSize;
  final String detail;

  bool get available => sampleSize > 0 && correctedNav > 0;
}

class ErrorCorrection {
  ErrorCorrection(this.records);

  final List<NavErrorRecord> records;

  NavCorrectionResult getCorrection(
    double rawEstNav, {
    String algorithm = 'SMA',
    double? currentIndustryReturn,
    Map<String, double> currentFactorReturns = const {},
  }) {
    if (rawEstNav <= 0) {
      throw StateError('rawEstNav must be positive');
    }
    final usable = records.where((item) => item.actualNav > 0 && item.estimatedNav > 0).toList()
      ..sort((a, b) => a.tradeDate.compareTo(b.tradeDate));
    if (usable.isEmpty) {
      throw StateError('no confirmed NAV error records');
    }
    final normalized = algorithm.trim().toUpperCase();
    if (normalized == 'KALMAN' || normalized == 'KF') {
      return _kalman(rawEstNav, usable);
    }
    if (normalized == 'REGRESSION' || normalized == 'REG' || normalized == 'INDUSTRY_REGRESSION') {
      return _regression(rawEstNav, usable, currentIndustryReturn, currentFactorReturns);
    }
    return _sma(rawEstNav, usable);
  }

  NavCorrectionResult bestAvailable(
    double rawEstNav, {
    double? currentIndustryReturn,
    Map<String, double> currentFactorReturns = const {},
  }) {
    final attempts = <String>['KALMAN', 'REGRESSION', 'SMA'];
    Object? lastError;
    for (final algorithm in attempts) {
      try {
        return getCorrection(
          rawEstNav,
          algorithm: algorithm,
          currentIndustryReturn: currentIndustryReturn,
          currentFactorReturns: currentFactorReturns,
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('NAV correction unavailable: $lastError');
  }

  NavCorrectionResult _sma(double rawEstNav, List<NavErrorRecord> usable, {int window = 5}) {
    final sample = usable.skip(max(0, usable.length - window)).toList();
    final correction = sample.fold<double>(0, (sum, item) => sum + item.error) / sample.length;
    return NavCorrectionResult(
      algorithm: 'SMA',
      rawEstNav: rawEstNav,
      correction: correction,
      correctedNav: rawEstNav + correction,
      sampleSize: sample.length,
      detail: '用最近 ${sample.length} 个真实误差做滑动平均修正',
    );
  }

  NavCorrectionResult _regression(
    double rawEstNav,
    List<NavErrorRecord> usable,
    double? currentIndustryReturn,
    Map<String, double> currentFactorReturns,
  ) {
    final rows = <List<double>>[];
    final targets = <double>[];
    final factorNames = <String>{};
    for (final item in usable) {
      factorNames.addAll(item.factorReturns.keys);
    }
    if (factorNames.isEmpty && usable.any((item) => item.industryReturn != null)) {
      factorNames.add('industry_return');
    }
    final factors = factorNames.toList()..sort();
    if (factors.isEmpty) {
      throw StateError('no factor columns for regression');
    }
    for (final item in usable) {
      final rowFactors = <String, double>{...item.factorReturns};
      if (item.industryReturn != null) rowFactors.putIfAbsent('industry_return', () => item.industryReturn!);
      if (!factors.every(rowFactors.containsKey)) continue;
      rows.add(factors.map((name) => rowFactors[name]!).toList());
      targets.add(item.error);
    }
    final minRequired = factors.length + 1;
    if (rows.length < minRequired) {
      throw StateError('not enough aligned regression rows');
    }
    final coeffs = _linearRegression(rows, targets);
    final current = <String, double>{...currentFactorReturns};
    if (currentIndustryReturn != null) current.putIfAbsent('industry_return', () => currentIndustryReturn);
    if (!factors.every(current.containsKey)) {
      throw StateError('missing current regression factors');
    }
    var correction = coeffs.first;
    for (var i = 0; i < factors.length; i += 1) {
      correction += coeffs[i + 1] * current[factors[i]]!;
    }
    return NavCorrectionResult(
      algorithm: 'REGRESSION',
      rawEstNav: rawEstNav,
      correction: correction,
      correctedNav: rawEstNav + correction,
      sampleSize: rows.length,
      detail: '用 ${rows.length} 个真实误差和 ${factors.join("、")} 做行业拟合修正',
    );
  }

  NavCorrectionResult _kalman(
    double rawEstNav,
    List<NavErrorRecord> usable, {
    double processNoise = 1e-6,
    double observationNoise = 1e-5,
    double initialStateCovariance = 1e-4,
    bool adaptive = true,
  }) {
    var state = usable.first.error;
    var covariance = initialStateCovariance;
    final errors = usable.map((item) => item.error).toList();
    final avg = errors.fold<double>(0, (sum, value) => sum + value) / errors.length;
    final std = errors.length <= 1 ? 0.0 : sqrt(errors.fold<double>(0, (sum, value) => sum + pow(value - avg, 2)) / errors.length);
    var lastGain = 0.0;
    for (final observed in errors) {
      var effectiveQ = processNoise;
      var predictedState = state;
      var predictedCovariance = covariance + effectiveQ;
      final innovation = observed - predictedState;
      if (adaptive && std > 0 && innovation.abs() > std * 3) {
        effectiveQ = processNoise * 8;
        predictedCovariance = covariance + effectiveQ;
      }
      final innovationCovariance = predictedCovariance + observationNoise;
      final gain = predictedCovariance / innovationCovariance;
      state = predictedState + gain * innovation;
      covariance = (1 - gain) * predictedCovariance;
      lastGain = gain;
    }
    return NavCorrectionResult(
      algorithm: 'KALMAN',
      rawEstNav: rawEstNav,
      correction: state,
      correctedNav: rawEstNav + state,
      sampleSize: usable.length,
      detail: '用 ${usable.length} 个真实误差做卡尔曼自适应修正，最近增益 ${lastGain.toStringAsFixed(2)}',
    );
  }

  List<double> _linearRegression(List<List<double>> rows, List<double> targets) {
    final featureCount = rows.first.length;
    final dimension = featureCount + 1;
    final xtx = List.generate(dimension, (_) => List<double>.filled(dimension, 0));
    final xty = List<double>.filled(dimension, 0);
    for (var r = 0; r < rows.length; r += 1) {
      final row = <double>[1, ...rows[r]];
      final y = targets[r];
      for (var i = 0; i < dimension; i += 1) {
        xty[i] += row[i] * y;
        for (var j = 0; j < dimension; j += 1) {
          xtx[i][j] += row[i] * row[j];
        }
      }
    }
    return _solveLinearSystem(xtx, xty);
  }

  List<double> _solveLinearSystem(List<List<double>> matrix, List<double> vector) {
    final n = vector.length;
    final aug = List.generate(n, (i) => [...matrix[i], vector[i]]);
    const eps = 1e-12;
    for (var pivot = 0; pivot < n; pivot += 1) {
      var best = pivot;
      for (var row = pivot + 1; row < n; row += 1) {
        if (aug[row][pivot].abs() > aug[best][pivot].abs()) best = row;
      }
      if (aug[best][pivot].abs() < eps) {
        throw StateError('singular regression matrix');
      }
      if (best != pivot) {
        final tmp = aug[pivot];
        aug[pivot] = aug[best];
        aug[best] = tmp;
      }
      final div = aug[pivot][pivot];
      for (var col = pivot; col <= n; col += 1) {
        aug[pivot][col] /= div;
      }
      for (var row = 0; row < n; row += 1) {
        if (row == pivot) continue;
        final factor = aug[row][pivot];
        if (factor.abs() < eps) continue;
        for (var col = pivot; col <= n; col += 1) {
          aug[row][col] -= factor * aug[pivot][col];
        }
      }
    }
    return List.generate(n, (i) => aug[i][n]);
  }
}

double? _toFiniteDouble(dynamic value) {
  if (value == null) return null;
  final number = value is num ? value.toDouble() : double.tryParse(value.toString());
  if (number == null || !number.isFinite) return null;
  return number;
}
