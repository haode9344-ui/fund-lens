const form = document.querySelector("#fundForm");
const input = document.querySelector("#fundCode");
const summary = document.querySelector("#summary");
const metrics = document.querySelector("#metrics");
const analysisPanel = document.querySelector("#analysisPanel");
const tomorrowBadge = document.querySelector("#tomorrowBadge");
const tomorrowCard = document.querySelector("#tomorrowCard");
const detailGrid = document.querySelector("#detailGrid");
const reviewList = document.querySelector("#reviewList");
const monitorPanel = document.querySelector("#monitorPanel");
const monitorBadge = document.querySelector("#monitorBadge");
const monitorNote = document.querySelector("#monitorNote");
const alertList = document.querySelector("#alertList");
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
const backendStatus = document.querySelector("#backendStatus");

const pct = (number) => `${Number(number) > 0 ? "+" : ""}${Number(number).toFixed(2)}%`;
const jsonpPrefix = "fundLensJsonp";
const pageParams = new URLSearchParams(location.search);

function setBackendStatus(message, state = "") {
  if (!backendStatus) return;
  backendStatus.textContent = message;
  backendStatus.className = `backend-status ${state}`.trim();
}

async function fetchJson(url, timeout = 18000) {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), timeout);
  try {
    const response = await fetch(url, { signal: controller.signal, mode: "cors" });
    return response;
  } finally {
    window.clearTimeout(timer);
  }
}

setBackendStatus("纯前端模式：不连接后端，公告由浏览器直接抓取。", "ready");

function setLoading() {
  summary.innerHTML = `<div class="muted-state"><p>正在抓取公开净值、重仓持仓和行情数据...</p></div>`;
  metrics.hidden = true;
  analysisPanel.hidden = true;
  monitorPanel.hidden = true;
  holdingsPanel.hidden = true;
  chartPanel.hidden = true;
  notes.hidden = true;
  sourceBadge.textContent = "分析中";
}

function setError(message) {
  summary.innerHTML = `<div class="muted-state"><p>${message}</p></div>`;
  metrics.hidden = true;
  analysisPanel.hidden = true;
  monitorPanel.hidden = true;
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

function inferThemeFromName(name) {
  if (/白酒|酒/.test(name)) return "白酒";
  if (/医药|医疗|生物/.test(name)) return "医药";
  if (/半导体|芯片/.test(name)) return "半导体";
  if (/新能源|电池|光伏|电力设备/.test(name)) return "新能源";
  if (/军工/.test(name)) return "军工";
  if (/银行|证券|保险|金融/.test(name)) return "金融";
  return "";
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
  return [...doc.querySelectorAll("tr")]
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

function applyThemeFallback(holdings, theme) {
  if (!theme) return holdings;
  return holdings.map((item) => {
    const industry = item.industry || "";
    if (!industry || industry === "未知" || industry === "undefined") return { ...item, industry: theme };
    return item;
  });
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

function classifyTomorrow(forecastData, impact, market) {
  const tomorrow = forecastData.tomorrow || {
    expectedPct: forecastData.expectedPct / Math.max(forecastData.horizonDays, 1),
    probabilityUp: forecastData.probabilityUp,
  };
  let score = 0;
  if (tomorrow.expectedPct > 0.25) score += 1;
  if (tomorrow.expectedPct < -0.25) score -= 1;
  if (tomorrow.probabilityUp > 58) score += 1;
  if (tomorrow.probabilityUp < 42) score -= 1;
  if ((market.averageChange || 0) > 0.5) score += 1;
  if ((market.averageChange || 0) < -0.5) score -= 1;
  if ((impact.todayContributionPct || 0) > 0.25) score += 1;
  if ((impact.todayContributionPct || 0) < -0.25) score -= 1;

  let direction = "震荡";
  if (score >= 2) direction = "偏涨";
  else if (score === 1) direction = "震荡偏涨";
  else if (score === -1) direction = "震荡偏弱";
  else if (score <= -2) direction = "偏跌";

  let confidence = "中";
  if (forecastData.volatilityPct > 1.5 || Math.abs(tomorrow.expectedPct) < forecastData.volatilityPct * 0.35) {
    confidence = "低";
  }
  if (Math.abs(score) >= 3 && forecastData.volatilityPct <= 1.2) confidence = "较高";
  return { direction, confidence, score };
}

function tomorrowDeepDive(forecastData, impact, market, holdings) {
  const tomorrow = forecastData.tomorrow || {
    expectedPct: forecastData.expectedPct / Math.max(forecastData.horizonDays, 1),
    rangePct: [forecastData.rangePct[0] / Math.max(forecastData.horizonDays, 1), forecastData.rangePct[1] / Math.max(forecastData.horizonDays, 1)],
    probabilityUp: forecastData.probabilityUp,
  };
  const signal = classifyTomorrow(forecastData, impact, market);
  const direction = signal.direction;
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

  let conclusion = "明天不确定性较高，更适合等盘中重仓股和指数方向确认。";
  if (direction === "偏涨") conclusion = "明天更像小幅偏涨或震荡上行，不适合追高重仓，适合小额分批观察。";
  if (direction === "震荡偏涨") conclusion = "明天有反弹倾向，但信号不强，适合观察或很小额分批。";
  if (direction === "震荡偏弱") conclusion = "明天偏弱震荡，先别急着加仓，等重仓股止跌更稳。";
  if (direction === "偏跌") conclusion = "明天更像偏弱或震荡回撤，先等重仓股止跌和市场情绪改善。";

  return {
    direction,
    confidence: signal.confidence,
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

function classifyAnnouncement(row, holding) {
  const title = row.title_ch || row.title || "";
  const matched = [holding?.name, holding?.code].filter(Boolean);
  const isMajorNegative = /留置|被留置|纪律审查|监察调查|立案|被查|处罚|刑事|失联|违规|风险提示|退市|违约/.test(title);
  const isManagerRisk = /(董事长|总经理|实控人|控股股东|核心管理层|高管).*(留置|调查|被查|处罚)|(?:留置|调查|被查|处罚).*(董事长|总经理|实控人|控股股东|高管)/.test(title);
  const isReport = /季度报告|年度报告|半年度报告|经营数据|业绩|财务|利润|营收/.test(title);
  const isInvestor = /投资者关系活动记录表|调研活动|业绩说明会/.test(title);
  const isGovernance = /董事|监事|高管|股东|换届|辞职|选举|聘任|变更/.test(title);
  const isRoutine = /独立董事述职|信息披露制度|关联交易预计|日常关联交易|内部控制|募集资金|董事会决议|监事会决议|股东大会|章程|审计委员会/.test(title);
  const isPositive = /增长|预增|回购|增持|分红|超预期|创新高|提价|盈利/.test(title);

  let sentiment = "中性";
  let severity = 48;
  let category = "普通公告";
  let sortRank = 6;
  let action = "相关公告，等待行情验证。";

  if (isMajorNegative || isManagerRisk) {
    sentiment = "负面";
    severity = isManagerRisk ? 93 : 86;
    category = "重大负面";
    sortRank = 1;
    action = "核心管理层或公司治理重大风险事件，可能压制短期情绪和估值。";
  } else if (isPositive) {
    sentiment = "正面";
    severity = 82;
    category = "重大正面";
    sortRank = 2;
    action = "可能改善短期情绪，但仍要看股价是否已提前反映。";
  } else if (isReport) {
    sentiment = "经营数据";
    severity = 68;
    category = "财报/经营数据";
    sortRank = 3;
    action = "直接影响龙头业绩预期，是白酒基金的重要验证数据。";
  } else if (isGovernance) {
    sentiment = "治理";
    severity = 55;
    category = "股东/高管变化";
    sortRank = 4;
    action = "影响治理预期，重要性取决于职位和变动原因。";
  } else if (isInvestor) {
    sentiment = "中性";
    severity = 46;
    category = "调研/投资者关系";
    sortRank = 5;
    action = "可作为经营口径和机构关注度参考，通常不是强预警。";
  } else if (isRoutine) {
    sentiment = "例行";
    severity = 28;
    category = "例行公告";
    sortRank = 9;
    action = "例行披露，通常不直接改变基金短期判断。";
  }

  if (holding?.holdingPct && !isRoutine) {
    severity = Math.min(98, Math.round(severity + Math.min(8, holding.holdingPct / 3)));
  }
  if (isRoutine) severity = Math.min(40, severity);

  return {
    id: `notice-${row.art_code || title}`,
    source: "东方财富公告",
    relevance: "强相关",
    sentiment,
    severity,
    category,
    sortRank,
    time: row.display_time || row.notice_date || "",
    title,
    summary: title,
    action,
    matched,
    url: row.art_code && holding?.code ? `https://data.eastmoney.com/notices/detail/${holding.code}/${row.art_code}.html` : "https://data.eastmoney.com/notices/",
  };
}

async function loadStockAnnouncements(holding, perStock = 8) {
  const params = new URLSearchParams({
    sr: "-1",
    page_size: String(perStock),
    page_index: "1",
    ann_type: "A",
    client_source: "web",
    stock_list: holding.code,
  });
  const response = await fetchJson(`https://np-anotice-stock.eastmoney.com/api/security/ann?${params}`, 15000);
  if (!response.ok) return [];
  const payload = await response.json();
  return (payload?.data?.list || []).map((row) => classifyAnnouncement(row, holding));
}

async function loadStaticMonitor(fundData) {
  const jobs = (fundData.holdings || []).slice(0, 5).map((holding) => loadStockAnnouncements(holding));
  const results = await Promise.allSettled(jobs);
  const seen = new Set();
  const alerts = results
    .flatMap((result) => (result.status === "fulfilled" ? result.value : []))
    .filter((item) => {
      if (!item.title || seen.has(item.id)) return false;
      seen.add(item.id);
      return true;
    })
    .sort((a, b) => {
      if (a.sortRank !== b.sortRank) return a.sortRank - b.sortRank;
      if (b.severity !== a.severity) return b.severity - a.severity;
      return String(b.time).localeCompare(String(a.time));
    });
  const majorNegative = alerts.find((item) => item.sentiment === "负面" && item.severity >= 80);
  const status = majorNegative ? "出现重大负面公告" : alerts.some((item) => item.severity >= 65) ? "有高影响公告" : "暂无强预警";
  return {
    code: fundData.code,
    name: fundData.name,
    updatedAt: new Date().toLocaleString("zh-CN", { hour12: false }),
    status,
    alerts,
    note: "纯前端公告监控：直接读取东方财富公开公告，并按重大负面、经营数据、调研、例行公告分级。主面板只展示前 3 条高影响事件，其余折叠。",
  };
}

async function loadStaticFund(code) {
  const fund = await loadFundScript(code);
  let market = await loadMarket();
  let holdings = [];
  try {
    holdings = await loadHoldings(code);
  } catch {
    holdings = [];
  }
  if (holdings.length) {
    try {
      holdings = await enrichHoldings(holdings);
    } catch {
      // Keep the quarterly holdings even when realtime quotes are unavailable.
    }
  }
  const theme = inferThemeFromName(fund.name);
  holdings = applyThemeFallback(holdings, theme);
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
  setBackendStatus("纯前端模式：正在抓取公开净值、持仓和公告。", "ready");
  return loadStaticFund(code);
}

async function loadMonitor(code, fundData) {
  try {
    return await loadStaticMonitor(fundData);
  } catch {
    return null;
  }
}

function renderMonitor(data) {
  if (!data) {
    monitorPanel.hidden = false;
    monitorBadge.textContent = "公告暂缺";
    monitorNote.textContent = "这次没有抓到公开公告，基金分析仍按净值、持仓和市场数据生成。";
    alertList.innerHTML = "";
    return;
  }
  monitorPanel.hidden = false;
  monitorBadge.textContent = `${data.status} · ${data.updatedAt.slice(11, 16)}`;
  monitorNote.textContent = data.note;
  if (!data.alerts.length) {
    alertList.innerHTML = `<article class="alert-item"><strong>暂无匹配预警</strong><span>当前没有抓到与基金、重仓股或行业强相关的快讯/公告。</span></article>`;
    return;
  }
  const topAlerts = data.alerts.slice(0, 3);
  const otherAlerts = data.alerts.slice(3);
  const renderAlert = (item) => {
    const sentimentClass = item.sentiment === "正面" ? "positive" : item.sentiment === "负面" ? "negative" : item.sentiment === "例行" ? "routine" : "";
    return `
      <article class="alert-item ${item.severity >= 80 ? "major" : ""}">
        <div class="alert-meta">
          <span class="tag">${item.source}</span>
          <span class="tag">${item.relevance || "强相关"}</span>
          <span class="tag ${sentimentClass}">${item.sentiment}</span>
          <span class="tag">${item.category || "公告"}</span>
          <span class="tag">强度 ${item.severity}</span>
        </div>
        <strong>${item.title}</strong>
        <span>${item.action}</span>
        <span>关联：${(item.matched || []).join("、") || "重仓股"}</span>
      </article>
    `;
  };
  alertList.innerHTML =
    topAlerts.map(renderAlert).join("") +
    (otherAlerts.length
      ? `
        <details class="folded-alerts">
          <summary>其他 ${otherAlerts.length} 条低影响或例行公告</summary>
          ${otherAlerts.map(renderAlert).join("")}
        </details>
      `
      : "");
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
  const directionText = tomorrowDetail.direction;
  const isDown = directionText.includes("跌") || directionText.includes("弱");
  const isFlat = directionText.includes("震荡");
  const actionColor = isFlat ? "flat" : isDown ? "down" : "up";

  sourceBadge.textContent = data.source;
  summary.innerHTML = `
    <div class="result-layout">
      <div>
        <p class="eyebrow">${data.code} · 最新净值 ${data.latest.value}</p>
        <h2 class="fund-name">${data.name}</h2>
        <div class="direction ${actionColor}">${directionText}</div>
        <p class="confidence">
          模型置信度：${tomorrowDetail.confidence || "中"}。未来约 ${forecastData.horizonDays} 个交易日倾向变化 ${pct(forecastData.expectedPct)}，
          风险区间 ${pct(forecastData.rangePct[0])} 至 ${pct(forecastData.rangePct[1])}。
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
  tomorrowBadge.textContent = `${tomorrowDetail.direction} · 置信度 ${tomorrowDetail.confidence || "中"}`;
  tomorrowCard.innerHTML = `
    <strong>明天情景：${tomorrowDetail.direction}，中心估计 ${pct(tomorrowDetail.expectedPct)}</strong>
    <p>这是今天以后最近一个交易日的情景判断，不是确定预测。常见波动区间 ${pct(tomorrowDetail.rangePct[0])} 至 ${pct(tomorrowDetail.rangePct[1])}。${tomorrowDetail.conclusion}</p>
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

function formatDisplayDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function addTradingDays(fromDate, days) {
  const date = new Date(fromDate);
  let left = days;
  while (left > 0) {
    date.setDate(date.getDate() + 1);
    const weekday = date.getDay();
    if (weekday !== 0 && weekday !== 6) left -= 1;
  }
  return date;
}

function signalClass(text) {
  if (text.includes("跌") || text.includes("弱")) return "down";
  if (text.includes("震荡")) return "flat";
  return "up";
}

function clampNumber(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function hasRealtimeHoldingData(data) {
  return (data.holdings || []).some((item) => typeof item.changePct === "number");
}

function hasIndustryData(data) {
  return (data.impact?.topIndustries || []).some((item) => {
    const name = item.name || "";
    return name && name !== "未知" && name !== "undefined";
  });
}

function holdingImpactText(data) {
  if (!hasRealtimeHoldingData(data)) return "不可计算";
  return pct(data.impact?.todayContributionPct || 0);
}

function majorNegativeEvent(data) {
  return (data.monitor?.alerts || []).find((item) => item.sentiment === "负面" && item.severity >= 80);
}

function liquorSpecial(data) {
  const name = data.name || "";
  const industry = data.impact?.topIndustries?.[0]?.name || "";
  if (!/白酒|酒/.test(`${name}${industry}`)) return null;
  const f = data.forecast;
  const event = majorNegativeEvent(data);
  const valuation =
    f.maxDrawdownPct < -15 ? "中偏低" : f.lastReturnsPct?.["20d"] > 8 ? "偏高" : "中";
  const leader = event ? `偏弱：${event.title}` : "待确认：重点看茅台、五粮液、泸州老窖经营数据";
  const consumption = f.lastReturnsPct?.["20d"] > 3 ? "中性偏强" : f.maxDrawdownPct < -12 ? "中性偏弱" : "中性";
  const month = new Date().getMonth() + 1;
  const holiday = [1, 2, 9, 10].includes(month) ? "节假日前后，催化较强" : "非春节/中秋/国庆窗口，催化偏弱";
  const crowding = f.volatilityPct > 1.5 ? "中高" : "中";
  return {
    text: `估值位置：${valuation}；龙头业绩：${leader}；消费情绪：${consumption}；节假日效应：${holiday}；机构拥挤度：${crowding}。`,
    majorRisk: event ? `${event.matched?.[0] || "重仓股"}重大负面公告` : "",
  };
}

function missingDataReasons(data) {
  const missing = [];
  if (!hasRealtimeHoldingData(data)) missing.push("重仓股实时贡献");
  if (!hasIndustryData(data)) missing.push("行业/主题资金流");
  if (!data.market?.indices?.length) missing.push("主要指数实时行情");
  return missing;
}

function softenDirection(direction, realtimeReady) {
  if (realtimeReady) return direction;
  if (direction === "可能上涨" || direction === "偏涨" || direction === "震荡偏涨") return "偏震荡，略偏强";
  if (direction === "可能下跌" || direction === "偏跌" || direction === "震荡偏弱") return "偏震荡，略偏弱";
  return "震荡";
}

function buildTodaySignal(forecastData, impact, marketData, holdings, realtimeReady) {
  let score = 0;
  if ((marketData.averageChange || 0) > 0.45) score += 1;
  if ((marketData.averageChange || 0) < -0.45) score -= 1;
  if (realtimeReady && (impact.todayContributionPct || 0) > 0.2) score += 1;
  if (realtimeReady && (impact.todayContributionPct || 0) < -0.2) score -= 1;
  if ((forecastData.lastReturnsPct?.["5d"] || 0) > 1) score += 1;
  if ((forecastData.lastReturnsPct?.["5d"] || 0) < -1) score -= 1;

  let direction = "震荡";
  if (score >= 2) direction = "可能上涨";
  else if (score === 1) direction = "震荡偏强";
  else if (score === -1) direction = "震荡偏弱";
  else if (score <= -2) direction = "可能下跌";
  direction = softenDirection(direction, realtimeReady);

  const activeHolding = holdings.find((item) => typeof item.changePct === "number");
  const holdingReason = activeHolding
    ? `${activeHolding.name} 今日 ${pct(activeHolding.changePct || 0)}，前十大持仓估算贡献 ${pct(impact.todayContributionPct || 0)}。`
    : `重仓股实时行情暂缺，不能把 0.00% 当成没有影响，只能先用短期动量和市场基准。`;
  const reason = `市场基准：${marketData.label}${marketData.averageChange ? `（${pct(marketData.averageChange)}）` : ""}。${holdingReason}短期动量：近5日 ${pct(forecastData.lastReturnsPct?.["5d"] || 0)}。`;
  return { direction, reason, score };
}

function buildTomorrowSignal(tomorrowDetail, forecastData, impact, marketData, realtimeReady) {
  const direction = softenDirection(tomorrowDetail.direction, realtimeReady);
  const holdingText = realtimeReady ? `重仓贡献 ${pct(impact.todayContributionPct || 0)}` : "重仓贡献暂无实时数据";
  const confidence = realtimeReady ? tomorrowDetail.confidence : "低";
  const conclusion = realtimeReady
    ? tomorrowDetail.conclusion
    : "关键数据缺失，明天只适合看作低置信度情景，等对应行业指数和重仓股盘中方向确认。";
  const reason = `上涨概率 ${Math.round(tomorrowDetail.probabilityUp || 50)}%，置信度 ${confidence}。中心估计 ${pct(tomorrowDetail.expectedPct)}，常见波动 ${pct(tomorrowDetail.rangePct[0])} 到 ${pct(tomorrowDetail.rangePct[1])}。依据：近5日动量 ${pct(forecastData.lastReturnsPct?.["5d"] || 0)}、市场基准 ${marketData.label}、${holdingText}。${conclusion}`;
  return { direction, reason, confidence };
}

function classifyFundProfile(data) {
  const name = data.name || "";
  let type = "主动股票/混合基金";
  let method = "持仓披露有滞后，只能用前十大持仓、行业风格和净值动量近似。";
  let tracking = "无明确跟踪指数";
  if (/债|纯债|短债|中短债|信用债/.test(name)) {
    type = "债券基金";
    method = "重点看利率、债券指数、信用风险和股债跷跷板。";
    tracking = "债券市场/利率环境";
  } else if (/QDII|全球|海外|纳斯达克|标普|恒生|港股|美元|美国/.test(name)) {
    type = "QDII/海外基金";
    method = "重点看海外市场、汇率和时差，支付宝当日估值可能滞后。";
    tracking = /纳斯达克/.test(name) ? "纳斯达克" : /恒生|港股/.test(name) ? "港股/恒生相关指数" : "海外市场";
  } else if (/指数|ETF|联接|LOF|增强/.test(name)) {
    type = "指数基金/ETF联接";
    method = "重点看对应指数、行业指数、成交量、均线和估值位置。";
    const match = name.match(/中证[^()（）A-Z]+|沪深300|中证500|创业板|科创|恒生科技|纳斯达克|白酒|医药|半导体|新能源|军工/);
    tracking = match ? match[0] : "对应指数/行业指数";
  }
  let industry = data.impact?.topIndustries?.[0]?.name || "行业暂缺";
  if (industry === "未知" || industry === "undefined") {
    if (/白酒/.test(name)) industry = "白酒";
    else if (/医药|医疗/.test(name)) industry = "医药";
    else if (/半导体|芯片/.test(name)) industry = "半导体";
    else if (/新能源|电池|光伏/.test(name)) industry = "新能源";
    else if (/军工/.test(name)) industry = "军工";
  }
  const risk =
    data.forecast.volatilityPct > 1.8 || data.forecast.maxDrawdownPct < -25
      ? "高"
      : data.forecast.volatilityPct > 1 || data.forecast.maxDrawdownPct < -12
        ? "中"
        : "中低";
  return { type, tracking, industry, risk, method };
}

function buyScore(data, todaySignal, tomorrowDetail, realtimeReady) {
  const f = data.forecast;
  let score = 50;
  const reasons = [];
  if ((f.lastReturnsPct?.["20d"] || 0) > 0) {
    score += 10;
    reasons.push("20日趋势修复");
  } else {
    score -= 6;
    reasons.push("20日趋势未修复");
  }
  if ((f.lastReturnsPct?.["5d"] || 0) > 0) {
    score += 8;
    reasons.push("短线动量为正");
  } else {
    score -= 8;
    reasons.push("短线动量偏弱");
  }
  if (f.maxDrawdownPct < -18 && (f.lastReturnsPct?.["5d"] || 0) > 0) {
    score += 10;
    reasons.push("回撤较深后有修复迹象");
  } else if (f.maxDrawdownPct < -25) {
    score -= 8;
    reasons.push("回撤过深，风险仍高");
  }
  if (f.volatilityPct > 1.8) {
    score -= 12;
    reasons.push("波动偏大");
  } else if (f.volatilityPct < 0.9) {
    score += 5;
    reasons.push("波动可控");
  }
  if (!realtimeReady) {
    score -= 8;
    reasons.push("缺少重仓股实时贡献确认");
  } else if ((data.impact?.todayContributionPct || 0) > 0.25) {
    score += 8;
    reasons.push("重仓股今天有贡献");
  } else if ((data.impact?.todayContributionPct || 0) < -0.25) {
    score -= 10;
    reasons.push("重仓股今天拖累");
  }
  if (todaySignal.direction.includes("涨") || todaySignal.direction.includes("强")) score += 6;
  if (todaySignal.direction.includes("跌") || todaySignal.direction.includes("弱")) score -= 6;
  if (tomorrowDetail.confidence === "低" || !realtimeReady) {
    score -= 6;
    reasons.push("明日判断置信度低");
  }
  const event = majorNegativeEvent(data);
  if (event) {
    score -= 8;
    reasons.push("重仓股出现重大负面公告");
  }
  score = Math.max(0, Math.min(100, Math.round(score)));
  let action = "观望";
  if (score >= 80) action = "可分批买入";
  else if (score >= 60) action = "小额定投";
  else if (score >= 40) action = "观望";
  else if (score >= 20) action = "等待回调";
  else action = "风险偏高，不追";
  return { score, action, reasons: reasons.slice(0, 5) };
}

function positionAdvice(data, todaySignal, tomorrowSignal, tomorrowDetail, score, profile) {
  const f = data.forecast;
  const fiveDay = f.lastReturnsPct?.["5d"] || 0;
  const realtimeReady = hasRealtimeHoldingData(data);
  const missing = missingDataReasons(data);
  const confidence = !realtimeReady || tomorrowDetail.confidence === "低" ? "低" : tomorrowDetail.confidence || "中";
  const liquor = liquorSpecial(data);
  const event = majorNegativeEvent(data);

  let buyAdvice = score.action;
  let buyRange = "0%";
  if (score.score >= 80) {
    buyRange = "10%-30%";
  } else if (score.score >= 60) {
    buyAdvice = "小额定投";
    buyRange = "0%-10%";
  } else if (score.score >= 40) {
    buyAdvice = "观望为主";
    buyRange = "0%-10%";
  } else {
    buyAdvice = "不追";
    buyRange = "0%";
  }
  if (confidence === "低" && score.score < 65) {
    buyAdvice = "观望为主";
    buyRange = "0%-10%";
  }
  if (liquor && confidence === "低") {
    buyAdvice = "观望，不追涨";
    buyRange = "计划新增仓位的 0%-5%";
  }

  let sellPct = 0;
  if (tomorrowSignal.direction.includes("弱") || tomorrowSignal.direction.includes("跌")) sellPct += 10;
  if ((tomorrowDetail.expectedPct || 0) > 2.5) sellPct += 10;
  if (fiveDay > 5) sellPct += 10;
  if ((f.maxDrawdownPct || 0) > -5) sellPct += 10;
  if (score.score < 40) sellPct += 20;
  if (tomorrowSignal.direction.includes("强") || tomorrowSignal.direction.includes("涨")) sellPct -= 10;
  if ((f.maxDrawdownPct || 0) < -10) sellPct -= 10;
  sellPct = clampNumber(Math.round(sellPct), 0, 60);

  let sellAdvice = "不卖";
  let sellRange = "当前该基金持仓的 0%-10%";
  if (sellPct > 35) {
    sellAdvice = "分批降低仓位";
    sellRange = `当前该基金持仓的 ${Math.max(20, sellPct - 10)}%-${sellPct}%`;
  } else if (sellPct > 15) {
    sellAdvice = "可小幅减仓";
    sellRange = `当前该基金持仓的 ${Math.max(10, sellPct - 10)}%-${sellPct}%`;
  } else if (sellPct > 0 || confidence === "低") {
    sellAdvice = "不卖或小幅减仓";
    sellRange = "当前该基金持仓的 0%-15%";
  }
  if (liquor && confidence === "低") {
    sellAdvice = "不急卖，仓位偏重者小幅降仓";
    sellRange = event ? "当前持仓的 0%-10%，若五粮液明显拖累可提高到15%" : "当前该基金持仓的 0%-10%";
  }

  const holdingAdvice = liquor ? "保持中低仓位" : profile.risk === "高" ? "保持轻仓/中低仓位" : profile.risk === "中" ? "保持中低仓位" : "按计划定投仓位";
  const reasons = [];
  if (fiveDay > 0) reasons.push(`近5日 ${pct(fiveDay)}，短期动量偏正`);
  else reasons.push(`近5日 ${pct(fiveDay)}，短期动量偏弱`);
  reasons.push(`30日波动 ${f.volatilityPct}%，90日回撤 ${f.maxDrawdownPct}%`);
  if (missing.length) reasons.push(`缺少${missing.join("、")}，所以置信度降为低`);
  if (profile.risk === "高") reasons.push("行业主题基金波动大，不适合追涨重仓");
  if (event) reasons.push(`${event.matched?.[0] || "重仓股"}存在重大负面公告`);
  if (liquor) reasons.push("白酒板块仍处修复波动期");

  return {
    buyAdvice,
    buyRange: buyRange.includes("仓位") ? buyRange : `计划新增仓位的 ${buyRange}`,
    sellAdvice,
    sellRange,
    holdingAdvice,
    confidence,
    reasons,
  };
}

function compactMetric(label, value) {
  return `<article class="metric"><span>${label}</span><strong>${value}</strong></article>`;
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
  const realtimeReady = hasRealtimeHoldingData(data);
  const missing = missingDataReasons(data);
  const tomorrowDetail = data.tomorrowDetail || tomorrowDeepDive(forecastData, data.impact, marketData, data.holdings || []);
  const todayDate = new Date();
  const tomorrowDate = addTradingDays(todayDate, 1);
  const todaySignal = buildTodaySignal(forecastData, data.impact, marketData, data.holdings || [], realtimeReady);
  const tomorrowSignal = buildTomorrowSignal(tomorrowDetail, forecastData, data.impact, marketData, realtimeReady);
  const profile = classifyFundProfile(data);
  const score = buyScore(data, todaySignal, tomorrowDetail, realtimeReady);
  const advice = positionAdvice(data, todaySignal, tomorrowSignal, tomorrowDetail, score, profile);
  const liquor = liquorSpecial(data);

  sourceBadge.textContent = data.source;
  summary.innerHTML = `
    <div class="fund-overview">
      <p class="eyebrow">${data.code} · 最新净值 ${data.latest.value} · 净值日 ${data.latest.date}</p>
      <h2 class="fund-name">${data.name}</h2>
      <div class="profile-strip">
        <span>类型：${profile.type}</span>
        <span>跟踪/参考：${profile.tracking}</span>
        <span>行业：${profile.industry}</span>
        <span>风险：${profile.risk}</span>
      </div>
      <div class="day-cards">
        <article class="day-card ${signalClass(todaySignal.direction)}">
          <span>今天 ${formatDisplayDate(todayDate)}</span>
          <strong>${todaySignal.direction}</strong>
          <p>${todaySignal.reason}</p>
        </article>
        <article class="day-card ${signalClass(tomorrowSignal.direction)}">
          <span>明天 ${formatDisplayDate(tomorrowDate)}</span>
          <strong>${tomorrowSignal.direction}</strong>
          <p>${tomorrowSignal.reason}</p>
        </article>
      </div>
    </div>
  `;

  metrics.hidden = false;
  metrics.innerHTML = [
    compactMetric("买入建议", advice.buyAdvice),
    compactMetric("可买比例", advice.buyRange),
    compactMetric("卖出建议", advice.sellAdvice),
    compactMetric("可卖比例", advice.sellRange),
    compactMetric("持仓建议", advice.holdingAdvice),
    compactMetric("置信度", advice.confidence),
    compactMetric("买入评分", `${score.score}/100`),
    compactMetric("重仓行情", realtimeReady ? "已接入" : "未接入"),
    compactMetric("重仓贡献", holdingImpactText(data)),
  ].join("");

  analysisPanel.hidden = false;
  tomorrowBadge.textContent = `仓位建议 · 置信度 ${advice.confidence}`;
  tomorrowCard.innerHTML = `
    <strong>今天 ${formatDisplayDate(todayDate)}：${todaySignal.direction}</strong>
    <p>${todaySignal.reason}</p>
    <strong>明天 ${formatDisplayDate(tomorrowDate)}：${tomorrowSignal.direction}</strong>
    <p>${tomorrowSignal.reason}</p>
    <div class="position-summary">
      <span>买入：${advice.buyAdvice}，${advice.buyRange}</span>
      <span>卖出：${advice.sellAdvice}，${advice.sellRange}</span>
      <span>仓位：${advice.holdingAdvice}</span>
    </div>
  `;
  detailGrid.innerHTML = [
    { label: "数据依据", value: `最新净值日 ${data.latest.date}，30日波动 ${forecastData.volatilityPct}%，90日最大回撤 ${forecastData.maxDrawdownPct}%。` },
    { label: "基金类型", value: `${profile.type}。${profile.method}` },
    { label: "关键数据", value: missing.length ? `暂缺：${missing.join("、")}。判断会自动降级。` : `重仓股、行业和市场基准均有实时参考。` },
    ...(liquor ? [{ label: "白酒专项", value: liquor.text }] : []),
    { label: "上涨条件", value: `对应指数转强、重仓股贡献转正、近5日动量继续保持正值，且成交量不要过热。` },
    { label: "下跌风险", value: `行业指数走弱、龙头股公告利空、资金流出或连续上涨后回撤。` },
    { label: "可能错的原因", value: `持仓披露滞后、基金经理调仓、净值晚上更新、15:00申购规则、外部新闻和估值误差。` },
  ]
    .map((item) => `<article class="explain"><span>${item.label}</span><strong>${item.value}</strong></article>`)
    .join("");
  reviewList.innerHTML = [
    { title: "为什么今天可能涨/跌", reason: todaySignal.reason },
    { title: "为什么明天可能涨/跌", reason: tomorrowSignal.reason },
    { title: "买入/卖出怎么判断", reason: `当前评分 ${score.score}/100。买入建议：${advice.buyAdvice}，可买 ${advice.buyRange}；卖出建议：${advice.sellAdvice}，可卖 ${advice.sellRange}。原因：${advice.reasons.join("；")}。` },
  ]
    .map((item) => `<article class="review-item"><strong>${item.title}</strong><span>${item.reason}</span></article>`)
    .join("");

  holdingsPanel.hidden = false;
  impactBadge.textContent = realtimeReady ? `${data.impact.label} · 重仓贡献 ${holdingImpactText(data)}` : "重仓行情未接入 · 重仓贡献不可计算";
  const industryText = data.impact.topIndustries.map((item) => `${item.name} ${item.holdingPct}%`).join(" / ");
  buyViewEl.innerHTML = `
    <strong>${advice.holdingAdvice}</strong>
    <span>买入建议：${advice.buyAdvice}，可买比例：${advice.buyRange}。卖出建议：${advice.sellAdvice}，可卖比例：${advice.sellRange}。</span>
    <span>原因：${advice.reasons.join("；")}。</span>
    <small>可买比例指计划新增仓位，可卖比例指当前该基金持仓。若当前盈利超过 8% 或该基金占总投资超过 20%，可更偏向卖出上限；若亏损较深且仓位不高，不建议因一天波动割肉。</small>
  `;
  explainGrid.innerHTML = [
    { label: "市场环境", value: data.explanation?.market || marketData.label },
    { label: "今天以后原因", value: tomorrowSignal.reason },
    ...(liquor ? [{ label: "白酒专项", value: liquor.text }] : []),
    { label: "影响事件", value: data.explanation?.events || "资金流向、行业政策、重仓股公告" },
  ]
    .map((item) => `<article class="explain"><span>${item.label}</span><strong>${item.value}</strong></article>`)
    .join("");
  holdingsList.innerHTML = (data.holdings || [])
    .map((item) => {
      const hasQuote = typeof item.changePct === "number";
      const direction = !hasQuote ? "neutral" : item.changePct >= 0 ? "hot" : "cold";
      return `
        <article class="holding">
          <div>
            <strong>${item.name}</strong>
            <span>${item.code} · ${item.industry || "行业暂缺"}</span>
          </div>
          <div class="holding-numbers">
            <b class="${direction}">${typeof item.changePct === "number" ? pct(item.changePct) : "暂无"}</b>
            <span>占 ${item.holdingPct}% · 贡献 ${typeof item.estimatedContributionPct === "number" ? pct(item.estimatedContributionPct) : "暂无"}</span>
          </div>
        </article>
      `;
    })
    .join("");

  latestDate.textContent = data.latest.date;
  chartPanel.hidden = false;
  drawChart(data.history);
  notes.hidden = false;
  notes.textContent = "这是基于公开净值、市场基准、波动率、均线和重仓股影响的情景分析，不是确定预测，也不构成投资建议。";
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
    const fundData = await loadFund(code);
    render(fundData);
    const monitorData = await loadMonitor(code, fundData);
    fundData.monitor = monitorData;
    if (monitorData) render(fundData);
    renderMonitor(monitorData);
  } catch (error) {
    setError(error.message || "分析失败，请稍后重试。");
  }
});

const initialCode = new URLSearchParams(location.search).get("fundCode");
if (/^\d{6}$/.test(initialCode || "")) {
  input.value = initialCode;
  window.setTimeout(() => form.requestSubmit(), 150);
}

window.addEventListener("resize", () => {
  if (!chartPanel.hidden && window.lastHistory) drawChart(window.lastHistory);
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").catch(() => {});
}
