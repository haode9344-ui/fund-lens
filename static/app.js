const form = document.querySelector("#fundForm");
const input = document.querySelector("#fundCode");
const summary = document.querySelector("#summary");
const metrics = document.querySelector("#metrics");
const analysisPanel = document.querySelector("#analysisPanel");
const tomorrowBadge = document.querySelector("#tomorrowBadge");
const tomorrowCard = document.querySelector("#tomorrowCard");
const detailGrid = document.querySelector("#detailGrid");
const reviewList = document.querySelector("#reviewList");
const holdingsPanel = document.querySelector("#holdingsPanel");
const holdingsList = document.querySelector("#holdingsList");
const impactBadge = document.querySelector("#impactBadge");
const buyViewEl = document.querySelector("#buyView");
const explainGrid = document.querySelector("#explainGrid");
const chartPanel = document.querySelector("#chartPanel");
const chart = document.querySelector("#chart");
const latestDate = document.querySelector("#latestDate");
const notes = document.querySelector("#notes");
const sourceBadge = document.querySelector("#sourceBadge");

const pct = (number) => `${Number(number) > 0 ? "+" : ""}${Number(number).toFixed(2)}%`;
const jsonpPrefix = "fundLensJsonp";

function setLoading() {
  summary.innerHTML = `<div class="muted-state"><p>正在抓取公开净值、重仓持仓和行情数据...</p></div>`;
  metrics.hidden = true;
  analysisPanel.hidden = true;
  holdingsPanel.hidden = true;
  chartPanel.hidden = true;
  notes.hidden = true;
  sourceBadge.textContent = "分析中";
}

function setError(message) {
  summary.innerHTML = `<div class="muted-state"><p>${message}</p></div>`;
  metrics.hidden = true;
  analysisPanel.hidden = true;
  holdingsPanel.hidden = true;
  chartPanel.hidden = true;
  notes.hidden = true;
  sourceBadge.textContent = "需要重试";
}

function metric(label, value) {
  return `<article class="metric"><span>${label}</span><strong>${value}</strong></article>`;
}

function scriptLoad(url, timeout = 15000) {
  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    const timer = window.setTimeout(() => {
      script.remove();
      reject(new Error("数据源响应超时"));
    }, timeout);
    script.src = url;
    script.async = true;
    script.onload = () => {
      window.clearTimeout(timer);
      script.remove();
      resolve();
    };
    script.onerror = () => {
      window.clearTimeout(timer);
      script.remove();
      reject(new Error("数据源加载失败"));
    };
    document.head.appendChild(script);
  });
}

function jsonp(url) {
  const callbackName = `${jsonpPrefix}${Date.now()}${Math.round(Math.random() * 100000)}`;
  const separator = url.includes("?") ? "&" : "?";
  return new Promise((resolve, reject) => {
    window[callbackName] = (payload) => {
      delete window[callbackName];
      resolve(payload);
    };
    scriptLoad(`${url}${separator}cb=${callbackName}`).catch((error) => {
      delete window[callbackName];
      reject(error);
    });
  });
}

function dateFromTimestamp(value) {
  const date = new Date(value);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function dailyReturns(points) {
  const returns = [];
  for (let i = 1; i < points.length; i += 1) {
    const previous = points[i - 1].value;
    const current = points[i].value;
    if (previous > 0) returns.push(current / previous - 1);
  }
  return returns;
}

function mean(values) {
  if (!values.length) return 0;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function std(values) {
  if (values.length < 2) return 0;
  const avg = mean(values);
  return Math.sqrt(mean(values.map((value) => (value - avg) ** 2)));
}

function maxDrawdown(points) {
  let peak = 0;
  let worst = 0;
  points.forEach((point) => {
    peak = Math.max(peak, point.value);
    if (peak) worst = Math.min(worst, point.value / peak - 1);
  });
  return worst;
}

function returnDetails(points, days) {
  const start = Math.max(1, points.length - days);
  const details = [];
  for (let i = start; i < points.length; i += 1) {
    const previous = points[i - 1];
    const current = points[i];
    const changePct = previous.value > 0 ? (current.value / previous.value - 1) * 100 : 0;
    details.push({
      date: current.date,
      value: current.value,
      changePct: Math.round(changePct * 100) / 100,
    });
  }
  return details;
}

function movingAverageValue(points, days) {
  const values = points.slice(-days).map((item) => item.value);
  return values.length ? mean(values) : 0;
}

function recentReview(points, impact, market) {
  const details = returnDetails(points, 5);
  const industry = impact.topIndustries?.[0]?.name || "当前重仓行业";
  return details.map((item) => {
    const direction = item.changePct >= 0 ? "上涨" : "下跌";
    const baseReason =
      item.changePct >= 0
        ? `净值抬升，说明当日底层持仓整体贡献偏正。`
        : `净值回落，说明当日底层持仓整体承压。`;
    const marketReason =
      market.averageChange > 0.4
        ? "大盘环境偏强，对基金有托底。"
        : market.averageChange < -0.4
          ? "大盘环境偏弱，容易放大回撤。"
          : "大盘震荡，主要看重仓行业和个股表现。";
    return {
      ...item,
      title: `${item.date} ${direction} ${pct(item.changePct)}`,
      reason: `${baseReason}${marketReason}重点观察 ${industry}、资金流向和龙头股公告。`,
    };
  }).reverse();
}

function todayAndAfterAnalysis(forecastData, impact, market, holdings) {
  const leaders = holdings
    .filter((item) => typeof item.changePct === "number")
    .sort((a, b) => Math.abs(b.estimatedContributionPct || 0) - Math.abs(a.estimatedContributionPct || 0))
    .slice(0, 3);
  const leaderText = leaders.length
    ? leaders
        .map((item) => `${item.name}${pct(item.changePct || 0)}，贡献${pct(item.estimatedContributionPct || 0)}`)
        .join("；")
    : "重仓股实时数据暂缺，先按基金净值动量和市场风格判断";

  const todayDirection =
    impact.todayContributionPct > 0.25 || market.averageChange > 0.5
      ? "今天偏正面"
      : impact.todayContributionPct < -0.25 || market.averageChange < -0.5
        ? "今天偏负面"
        : "今天偏震荡";

  const todayReason = `${todayDirection}：市场/风格为${market.label}，前十大持仓估算影响 ${pct(
    impact.todayContributionPct || 0
  )}。${leaderText}。`;

  const afterDirection = forecastData.expectedPct >= 0 ? "今天过后偏涨" : "今天过后偏跌";
  const afterReason =
    forecastData.expectedPct >= 0
      ? `后市看涨依据：5 日和 10 日动量合计 ${
          forecastData.lastReturnsPct["5d"] + forecastData.lastReturnsPct["10d"] >= 0 ? "为正" : "接近修复"
        }，若明天重仓股继续不拖累，净值更容易延续反弹。`
      : `后市看跌依据：短期动量偏弱或波动区间下沿较大，若明天重仓股继续走弱，净值容易继续回撤。`;

  const buyReason =
    forecastData.expectedPct >= 0 && market.averageChange > -0.6
      ? "买进原因：不是因为一定会涨，而是短线趋势没有破坏，可用小额分批换取反弹机会。"
      : "暂缓买进原因：今天信号不够强，等明天确认重仓股止跌或指数转强更稳。";

  return [
    { title: "今天怎么看", reason: todayReason },
    { title: "今天以后怎么看", reason: `${afterDirection}：${afterReason}` },
    { title: "买进原因", reason: buyReason },
  ];
}

function forecast(points, horizonDays = 5) {
  const returns = dailyReturns(points);
  const recent = returns.slice(-30);
  const last5 = returns.slice(-5);
  const last10 = returns.slice(-10);
  const last20 = returns.slice(-20);
  if (recent.length < 8) throw new Error("历史净值太少，暂时无法生成可靠区间。");

  const momentum = 0.5 * mean(last5) + 0.3 * mean(last10) + 0.2 * mean(last20);
  const drift = mean(recent);
  const volatility = std(recent);
  const dailyExpected = 0.65 * momentum + 0.35 * drift;
  const expectedChange = dailyExpected * horizonDays;
  const interval = 1.15 * volatility * Math.sqrt(horizonDays);
  const probabilityUp = 1 / (1 + Math.exp(-(expectedChange / Math.max(interval / 2, 0.0001))));
  const lastValue = points.at(-1).value;
  const tomorrowExpected = dailyExpected;
  const tomorrowInterval = 0.95 * volatility;

  return {
    horizonDays,
    direction: expectedChange >= 0 ? "up" : "down",
    probabilityUp: Math.round(probabilityUp * 1000) / 10,
    expectedPct: Math.round(expectedChange * 10000) / 100,
    rangePct: [
      Math.round((expectedChange - interval) * 10000) / 100,
      Math.round((expectedChange + interval) * 10000) / 100,
    ],
    expectedValue: Math.round(lastValue * (1 + expectedChange) * 10000) / 10000,
    rangeValue: [
      Math.round(lastValue * (1 + expectedChange - interval) * 10000) / 10000,
      Math.round(lastValue * (1 + expectedChange + interval) * 10000) / 10000,
    ],
    volatilityPct: Math.round(volatility * 10000) / 100,
    maxDrawdownPct: Math.round(maxDrawdown(points.slice(-90)) * 10000) / 100,
    lastReturnsPct: {
      "5d": Math.round(last5.reduce((sum, value) => sum + value, 0) * 10000) / 100,
      "10d": Math.round(last10.reduce((sum, value) => sum + value, 0) * 10000) / 100,
      "20d": Math.round(last20.reduce((sum, value) => sum + value, 0) * 10000) / 100,
    },
    movingAverage: {
      ma5: Math.round(movingAverageValue(points, 5) * 10000) / 10000,
      ma10: Math.round(movingAverageValue(points, 10) * 10000) / 10000,
      ma20: Math.round(movingAverageValue(points, 20) * 10000) / 10000,
    },
    detailReturns: {
      "5d": returnDetails(points, 5),
      "10d": returnDetails(points, 10),
      "20d": returnDetails(points, 20),
    },
    tomorrow: {
      expectedPct: Math.round(tomorrowExpected * 10000) / 100,
      rangePct: [
        Math.round((tomorrowExpected - tomorrowInterval) * 10000) / 100,
        Math.round((tomorrowExpected + tomorrowInterval) * 10000) / 100,
      ],
      probabilityUp: Math.round((1 / (1 + Math.exp(-(tomorrowExpected / Math.max(tomorrowInterval / 2, 0.0001))))) * 1000) / 10,
    },
  };
}

function stripTags(html) {
  const element = document.createElement("div");
  element.innerHTML = html;
  return element.textContent.replace(/\s+/g, " ").trim();
}

function marketFromCode(code) {
  return /^[569]/.test(code) ? "1" : "0";
}

async function loadFundScript(code) {
  delete window.Data_netWorthTrend;
  delete window.fS_name;
  delete window.fS_code;
  await scriptLoad(`https://fund.eastmoney.com/pingzhongdata/${code}.js?v=${Date.now()}`);
  if (!Array.isArray(window.Data_netWorthTrend)) {
    throw new Error("没有抓到净值走势，可能基金代码不存在或数据源临时不可用。");
  }
  const history = window.Data_netWorthTrend
    .filter((item) => item && item.x && item.y !== undefined)
    .map((item) => ({
      date: dateFromTimestamp(item.x),
      value: Number(item.y),
      equityReturn: item.equityReturn,
    }));
  return {
    code: window.fS_code || code,
    name: window.fS_name || `基金 ${code}`,
    history,
  };
}

async function loadHoldings(code) {
  delete window.apidata;
  const year = new Date().getFullYear();
  await scriptLoad(
    `https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=${code}&topline=10&year=${year}&month=`
  );
  const content = window.apidata?.content || "";
  const doc = new DOMParser().parseFromString(content, "text/html");
  return [...doc.querySelectorAll("tbody tr")]
    .map((row) => {
      const cells = [...row.querySelectorAll("td")];
      if (cells.length < 9) return null;
      const stockCode = stripTags(cells[1].innerHTML);
      if (!/^\d{6}$/.test(stockCode)) return null;
      return {
        code: stockCode,
        secid: `${marketFromCode(stockCode)}.${stockCode}`,
        name: stripTags(cells[2].innerHTML),
        holdingPct: Number(stripTags(cells[6].innerHTML).replace("%", "")) || 0,
      };
    })
    .filter(Boolean)
    .slice(0, 10);
}

async function enrichHoldings(holdings) {
  if (!holdings.length) return [];
  const secids = holdings.map((item) => item.secid).join(",");
  const url = `https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=${secids}&fields=f2,f3,f12,f14,f62,f100,f184`;
  const payload = await jsonp(url);
  const quoteMap = new Map((payload?.data?.diff || []).map((item) => [item.f12, item]));
  return holdings.map((holding) => {
    const quote = quoteMap.get(holding.code) || {};
    const changePct = typeof quote.f3 === "number" ? quote.f3 : null;
    const contribution =
      changePct === null ? null : Math.round((holding.holdingPct / 100) * changePct * 1000) / 1000;
    return {
      ...holding,
      price: quote.f2,
      changePct,
      industry: quote.f100 || "未知",
      mainInflow: quote.f62,
      mainInflowPct: quote.f184,
      estimatedContributionPct: contribution,
    };
  });
}

async function loadMarket() {
  const url = "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=1.000001,0.399001,0.399006,1.000300&fields=f2,f3,f12,f14";
  try {
    const payload = await jsonp(url);
    const items = payload?.data?.diff || [];
    const averageChange = items.length ? mean(items.map((item) => Number(item.f3) || 0)) : 0;
    let label = "市场偏震荡";
    if (averageChange > 0.4) label = "市场偏强";
    if (averageChange < -0.4) label = "市场偏弱";
    return {
      label,
      averageChange: Math.round(averageChange * 100) / 100,
      indices: items.map((item) => ({
        name: item.f14,
        code: item.f12,
        changePct: item.f3,
        price: item.f2,
      })),
    };
  } catch {
    return { label: "市场数据暂缺", averageChange: 0, indices: [] };
  }
}

function relatedImpact(holdings) {
  const valid = holdings.filter((item) => typeof item.changePct === "number");
  const todayContributionPct =
    Math.round(valid.reduce((sum, item) => sum + (item.estimatedContributionPct || 0), 0) * 1000) / 1000;
  const topHoldingExposurePct =
    Math.round(holdings.reduce((sum, item) => sum + (item.holdingPct || 0), 0) * 100) / 100;
  const industryMap = new Map();
  holdings.forEach((item) => {
    industryMap.set(item.industry, (industryMap.get(item.industry) || 0) + (item.holdingPct || 0));
  });
  const topIndustries = [...industryMap.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([name, holdingPct]) => ({ name, holdingPct: Math.round(holdingPct * 100) / 100 }));

  let label = "关联持仓影响偏中性";
  if (todayContributionPct > 0.25) label = "关联持仓正在推动净值";
  if (todayContributionPct < -0.25) label = "关联持仓正在拖累净值";
  return { label, topHoldingExposurePct, todayContributionPct, topIndustries };
}

function eventHints(impact) {
  const names = impact.topIndustries.map((item) => item.name).join("、");
  if (/白酒|饮料|食品|消费/.test(names)) {
    return ["消费复苏强弱", "白酒批价变化", "节假日消费预期", "龙头公司财报"];
  }
  if (/半导体|芯片|电子|通信|计算机|软件|人工智能/.test(names)) {
    return ["科技政策", "AI 订单变化", "芯片景气度", "美股科技股波动"];
  }
  if (/医药|医疗|生物/.test(names)) {
    return ["医保政策", "创新药审批", "药企财报", "集采预期"];
  }
  if (/新能源|电池|光伏|电力设备/.test(names)) {
    return ["锂价变化", "装机需求", "海外关税", "龙头订单"];
  }
  if (/银行|证券|保险|金融/.test(names)) {
    return ["利率变化", "成交量", "政策预期", "地产信用"];
  }
  return ["大盘风险偏好", "行业政策", "重仓股财报", "资金流向"];
}

function explainMove(forecastData, impact, market) {
  const direction = forecastData.direction === "up" ? "涨" : "跌";
  const marketText = `${market.label}${market.averageChange ? `（主要指数均值 ${pct(market.averageChange)}）` : ""}`;
  const holdingText =
    impact.todayContributionPct > 0.25
      ? `重仓股今天贡献约 ${pct(impact.todayContributionPct)}`
      : impact.todayContributionPct < -0.25
        ? `重仓股今天拖累约 ${pct(impact.todayContributionPct)}`
        : "重仓股影响不强";
  const reason =
    forecastData.direction === "up"
      ? `近 5/10/20 日动量偏正，${holdingText}。`
      : `短期动量或市场环境偏弱，${holdingText}。`;
  return {
    market: marketText,
    move: `偏${direction}：${reason}`,
    events: eventHints(impact).join("、"),
  };
}

function tomorrowDeepDive(forecastData, impact, market, holdings) {
  const tomorrow = forecastData.tomorrow || {
    expectedPct: forecastData.expectedPct / Math.max(forecastData.horizonDays, 1),
    rangePct: [forecastData.rangePct[0] / Math.max(forecastData.horizonDays, 1), forecastData.rangePct[1] / Math.max(forecastData.horizonDays, 1)],
    probabilityUp: forecastData.probabilityUp,
  };
  const direction = tomorrow.expectedPct >= 0 ? "偏涨" : "偏跌";
  const topHolding = holdings.find((item) => typeof item.changePct === "number");
  const industry = impact.topIndustries?.[0]?.name || "重仓行业";
  const bullish = [];
  const bearish = [];

  if (forecastData.lastReturnsPct["5d"] > 0) bullish.push(`近 5 日累计 ${pct(forecastData.lastReturnsPct["5d"])}，短线动量还在。`);
  else bearish.push(`近 5 日累计 ${pct(forecastData.lastReturnsPct["5d"])}，短线动量偏弱。`);

  if (market.averageChange > 0.4) bullish.push(`大盘/风格偏强，指数均值 ${pct(market.averageChange)}。`);
  else if (market.averageChange < -0.4) bearish.push(`大盘/风格偏弱，指数均值 ${pct(market.averageChange)}。`);
  else bullish.push("大盘没有明显拖累，明天主要看重仓股表现。");

  if (impact.todayContributionPct > 0.25) bullish.push(`前十大持仓估算贡献 ${pct(impact.todayContributionPct)}。`);
  else if (impact.todayContributionPct < -0.25) bearish.push(`前十大持仓估算拖累 ${pct(impact.todayContributionPct)}。`);
  else bearish.push("重仓股今天没有形成强推动，明天需要确认延续性。");

  if (topHolding) {
    const line = `${topHolding.name} 今日 ${pct(topHolding.changePct || 0)}，它对 ${industry} 情绪影响较大。`;
    if ((topHolding.changePct || 0) >= 0) bullish.push(line);
    else bearish.push(line);
  }

  const conclusion =
    direction === "偏涨"
      ? "明天更像小幅偏涨或震荡上行，不适合追高重仓，适合小额分批观察。"
      : "明天更像偏弱或震荡回撤，先等重仓股止跌和市场情绪改善。";

  return {
    direction,
    probabilityUp: tomorrow.probabilityUp,
    expectedPct: tomorrow.expectedPct,
    rangePct: tomorrow.rangePct,
    bullish,
    bearish,
    conclusion,
  };
}

function marketFromTrend(forecastData) {
  const shortTrend = forecastData.lastReturnsPct["5d"] + forecastData.lastReturnsPct["10d"];
  let label = "市场/基金风格偏震荡";
  if (shortTrend > 1.2) label = "市场/基金风格偏强";
  if (shortTrend < -1.2) label = "市场/基金风格偏弱";
  return {
    label,
    averageChange: Math.round((shortTrend / 2) * 100) / 100,
    indices: [],
  };
}

function makeBuyView(forecastData, impact, market) {
  const expected = forecastData.expectedPct;
  const probability = forecastData.probabilityUp;
  const contribution = impact.todayContributionPct || 0;
  const marketOk = market.averageChange > -0.6;
  let stance = "观望或定投式少量";
  let reason = "信号不够单边，若你本来长期看好，可以只按计划小额定投，不建议冲动补仓。";
  if (expected > 0.8 && probability >= 60 && contribution >= 0 && marketOk) {
    stance = "可以考虑小额分批";
    reason = "买进理由：短期趋势偏正、市场不弱、重仓持仓没有明显拖累；但仍建议分批。";
  } else if (expected < -0.5 || probability < 45 || contribution < -0.4) {
    stance = "先别急着加仓";
    reason = "不急买理由：短期估算偏弱或持仓拖累明显，等连续两三个交易日改善再看。";
  } else {
    reason = "少量买进理由：没有明显单边信号，适合按计划小额定投，不适合一次性重仓。";
  }

  let riskLevel = "高波动";
  if (forecastData.volatilityPct < 0.8 && forecastData.maxDrawdownPct > -8) riskLevel = "中低波动";
  else if (forecastData.volatilityPct < 1.5 && forecastData.maxDrawdownPct > -18) riskLevel = "中等波动";
  return { stance, reason, riskLevel };
}

async function loadStaticFund(code) {
  const fund = await loadFundScript(code);
  let market = await loadMarket();
  let holdings = [];
  try {
    holdings = await enrichHoldings(await loadHoldings(code));
  } catch {
    holdings = [];
  }
  const forecastData = forecast(fund.history.slice(-180));
  if (market.label === "市场数据暂缺") market = marketFromTrend(forecastData);
  const impact = relatedImpact(holdings);
  const explanation = explainMove(forecastData, impact, market);
  return {
    code: fund.code,
    name: fund.name,
    source: "东方财富/天天基金公开页面数据（GitHub Pages 纯前端）",
    updatedAt: new Date().toLocaleString("zh-CN", { hour12: false }),
    latest: fund.history.at(-1),
    history: fund.history.slice(-90),
    forecast: forecastData,
    holdings,
    impact,
    market,
    explanation,
    tomorrowDetail: tomorrowDeepDive(forecastData, impact, market, holdings),
    review: todayAndAfterAnalysis(forecastData, impact, market, holdings),
    buyView: makeBuyView(forecastData, impact, market),
    disclaimer: "模型只基于历史净值、持仓和行情做统计估算，不能保证未来收益，也不构成投资建议。",
  };
}

async function loadFund(code) {
  const forceStatic = new URLSearchParams(location.search).has("static");
  if (!forceStatic && !location.hostname.endsWith("github.io")) {
    try {
      const response = await fetch(`/api/fund/${code}`);
      if (response.ok) {
        const payload = await response.json();
        if (payload.ok) return payload.data;
      }
    } catch {
      // Fall through to the GitHub Pages compatible loader.
    }
  }
  return loadStaticFund(code);
}

function render(data) {
  const forecastData = data.forecast;
  if (!forecastData.detailReturns) {
    forecastData.detailReturns = {
      "5d": returnDetails(data.history, 5),
      "10d": returnDetails(data.history, 10),
      "20d": returnDetails(data.history, 20),
    };
  }
  if (!forecastData.tomorrow) {
    forecastData.tomorrow = {
      expectedPct: forecastData.expectedPct / Math.max(forecastData.horizonDays, 1),
      rangePct: [
        forecastData.rangePct[0] / Math.max(forecastData.horizonDays, 1),
        forecastData.rangePct[1] / Math.max(forecastData.horizonDays, 1),
      ],
      probabilityUp: forecastData.probabilityUp,
    };
  }
  const marketData = data.market || marketFromTrend(forecastData);
  const tomorrowDetail = data.tomorrowDetail || tomorrowDeepDive(forecastData, data.impact, marketData, data.holdings || []);
  const review = data.review || todayAndAfterAnalysis(forecastData, data.impact, marketData, data.holdings || []);
  const isUp = forecastData.direction === "up";
  const directionText = isUp ? "偏涨" : "偏跌";
  const actionColor = isUp ? "up" : "down";

  sourceBadge.textContent = data.source;
  summary.innerHTML = `
    <div class="result-layout">
      <div>
        <p class="eyebrow">${data.code} · 最新净值 ${data.latest.value}</p>
        <h2 class="fund-name">${data.name}</h2>
        <div class="direction ${actionColor}">${directionText}</div>
        <p class="confidence">
          未来约 ${forecastData.horizonDays} 个交易日上涨概率 ${forecastData.probabilityUp}%。
          预估变化 ${pct(forecastData.expectedPct)}，常见波动区间 ${pct(forecastData.rangePct[0])} 至 ${pct(forecastData.rangePct[1])}。
        </p>
      </div>
      <aside class="forecast-box">
        <p class="eyebrow">估算净值</p>
        <div class="big">${forecastData.expectedValue}</div>
        <p class="sub">
          估算净值区间 ${forecastData.rangeValue[0]} 至 ${forecastData.rangeValue[1]}。
          这是统计模型，不是承诺收益。
        </p>
      </aside>
    </div>
  `;

  metrics.hidden = false;
  metrics.innerHTML = [
    metric("近 5 日", pct(forecastData.lastReturnsPct["5d"])),
    metric("近 10 日", pct(forecastData.lastReturnsPct["10d"])),
    metric("近 20 日", pct(forecastData.lastReturnsPct["20d"])),
    metric("30 日波动", `${forecastData.volatilityPct}%`),
    metric("90 日最大回撤", `${forecastData.maxDrawdownPct}%`),
    metric("更新时间", data.updatedAt.slice(5, 16)),
    metric("最新日期", data.latest.date.slice(5)),
    metric("预测天数", `${forecastData.horizonDays} 天`),
  ].join("");

  analysisPanel.hidden = false;
  tomorrowBadge.textContent = `${tomorrowDetail.direction} · 上涨概率 ${tomorrowDetail.probabilityUp}%`;
  tomorrowCard.innerHTML = `
    <strong>明天判断：${tomorrowDetail.direction}，预估 ${pct(tomorrowDetail.expectedPct)}</strong>
    <p>这是今天以后最近一个交易日的判断。常见波动区间 ${pct(tomorrowDetail.rangePct[0])} 至 ${pct(tomorrowDetail.rangePct[1])}。${tomorrowDetail.conclusion}</p>
    <div class="factor-row">
      <div class="factor"><span>看涨因素</span><b>${tomorrowDetail.bullish.slice(0, 3).join(" ") || "暂无明显看涨因素。"}</b></div>
      <div class="factor"><span>看跌风险</span><b>${tomorrowDetail.bearish.slice(0, 3).join(" ") || "暂无明显看跌因素。"}</b></div>
    </div>
  `;
  detailGrid.innerHTML = [
    { key: "5d", label: "近 5 日", total: forecastData.lastReturnsPct["5d"] },
    { key: "10d", label: "近 10 日", total: forecastData.lastReturnsPct["10d"] },
    { key: "20d", label: "近 20 日", total: forecastData.lastReturnsPct["20d"] },
  ]
    .map((group) => `
      <details>
        <summary>${group.label} ${pct(group.total)}</summary>
        ${(forecastData.detailReturns[group.key] || [])
          .map((item) => `<div class="date-return"><span>${item.date}</span><b class="${item.changePct >= 0 ? "hot" : "cold"}">${pct(item.changePct)}</b></div>`)
          .join("")}
      </details>
    `)
    .join("");
  reviewList.innerHTML = review
    .map((item) => `
      <article class="review-item">
        <strong>${item.title}</strong>
        <span>${item.reason}</span>
      </article>
    `)
    .join("");

  holdingsPanel.hidden = false;
  impactBadge.textContent = `${data.impact.label} · ${pct(data.impact.todayContributionPct)}`;
  const industryText = data.impact.topIndustries.map((item) => `${item.name} ${item.holdingPct}%`).join(" / ");
  buyViewEl.innerHTML = `
    <strong>${data.buyView.stance}</strong>
    <span>${data.buyView.reason}</span>
    <small>风险：${data.buyView.riskLevel} · 前十大持仓占净值 ${data.impact.topHoldingExposurePct}% · ${industryText}</small>
  `;
  explainGrid.innerHTML = [
    { label: "市场环境", value: data.explanation?.market || "市场数据暂缺" },
    { label: "今天以后原因", value: data.explanation?.move || "短期信号不足" },
    { label: "影响事件", value: data.explanation?.events || "资金流向、行业政策、重仓股财报" },
  ]
    .map((item) => `<article class="explain"><span>${item.label}</span><strong>${item.value}</strong></article>`)
    .join("");
  holdingsList.innerHTML = data.holdings
    .map((item) => {
      const direction = (item.changePct || 0) >= 0 ? "hot" : "cold";
      return `
        <article class="holding">
          <div>
            <strong>${item.name}</strong>
            <span>${item.code} · ${item.industry}</span>
          </div>
          <div class="holding-numbers">
            <b class="${direction}">${pct(item.changePct ?? 0)}</b>
            <span>占 ${item.holdingPct}% · 贡献 ${pct(item.estimatedContributionPct ?? 0)}</span>
          </div>
        </article>
      `;
    })
    .join("");

  latestDate.textContent = data.latest.date;
  chartPanel.hidden = false;
  drawChart(data.history);

  notes.hidden = false;
  notes.textContent = data.disclaimer;
}

function drawChart(history) {
  window.lastHistory = history;
  const ratio = window.devicePixelRatio || 1;
  const rect = chart.getBoundingClientRect();
  const width = Math.max(320, Math.floor(rect.width));
  const height = 220;
  chart.width = width * ratio;
  chart.height = height * ratio;
  const ctx = chart.getContext("2d");
  ctx.scale(ratio, ratio);
  ctx.clearRect(0, 0, width, height);

  const padding = { top: 16, right: 16, bottom: 30, left: 48 };
  const values = history.map((item) => item.value);
  const min = Math.min(...values);
  const max = Math.max(...values);
  const spread = max - min || 1;
  const innerW = width - padding.left - padding.right;
  const innerH = height - padding.top - padding.bottom;

  ctx.strokeStyle = "#dfe3eb";
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let i = 0; i < 4; i += 1) {
    const y = padding.top + (innerH / 3) * i;
    ctx.moveTo(padding.left, y);
    ctx.lineTo(width - padding.right, y);
  }
  ctx.stroke();

  ctx.strokeStyle = "#0a84ff";
  ctx.lineWidth = 3;
  ctx.lineJoin = "round";
  ctx.lineCap = "round";
  ctx.beginPath();
  history.forEach((item, index) => {
    const x = padding.left + (innerW * index) / Math.max(history.length - 1, 1);
    const y = padding.top + innerH - ((item.value - min) / spread) * innerH;
    if (index === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  });
  ctx.stroke();

  ctx.fillStyle = "#6d7280";
  ctx.font = "12px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.fillText(max.toFixed(4), 4, padding.top + 4);
  ctx.fillText(min.toFixed(4), 4, padding.top + innerH);
  ctx.fillText(history[0].date.slice(5), padding.left, height - 8);
  ctx.fillText(history.at(-1).date.slice(5), width - padding.right - 36, height - 8);
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const code = input.value.trim();
  if (!/^\d{6}$/.test(code)) {
    setError("请输入 6 位基金代码。");
    return;
  }

  setLoading();
  try {
    render(await loadFund(code));
  } catch (error) {
    setError(error.message || "分析失败，请稍后重试。");
  }
});

window.addEventListener("resize", () => {
  if (!chartPanel.hidden && window.lastHistory) drawChart(window.lastHistory);
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").catch(() => {});
}
