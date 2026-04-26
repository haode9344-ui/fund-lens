const form = document.querySelector("#fundForm");
const input = document.querySelector("#fundCode");
const summary = document.querySelector("#summary");
const metrics = document.querySelector("#metrics");
const holdingsPanel = document.querySelector("#holdingsPanel");
const holdingsList = document.querySelector("#holdingsList");
const impactBadge = document.querySelector("#impactBadge");
const buyView = document.querySelector("#buyView");
const chartPanel = document.querySelector("#chartPanel");
const chart = document.querySelector("#chart");
const latestDate = document.querySelector("#latestDate");
const notes = document.querySelector("#notes");
const sourceBadge = document.querySelector("#sourceBadge");

const pct = (number) => `${number > 0 ? "+" : ""}${number}%`;

function setLoading() {
  summary.innerHTML = `<div class="muted-state"><p>正在抓取公开净值数据并计算短期区间...</p></div>`;
  metrics.hidden = true;
  holdingsPanel.hidden = true;
  chartPanel.hidden = true;
  notes.hidden = true;
  sourceBadge.textContent = "分析中";
}

function setError(message) {
  summary.innerHTML = `<div class="muted-state"><p>${message}</p></div>`;
  metrics.hidden = true;
  holdingsPanel.hidden = true;
  chartPanel.hidden = true;
  notes.hidden = true;
  sourceBadge.textContent = "需要重试";
}

function metric(label, value) {
  return `<article class="metric"><span>${label}</span><strong>${value}</strong></article>`;
}

function render(data) {
  const forecast = data.forecast;
  const isUp = forecast.direction === "up";
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
          未来约 ${forecast.horizonDays} 个交易日上涨概率 ${forecast.probabilityUp}%。
          预估变化 ${pct(forecast.expectedPct)}，常见波动区间 ${pct(forecast.rangePct[0])} 至 ${pct(forecast.rangePct[1])}。
        </p>
      </div>
      <aside class="forecast-box">
        <p class="eyebrow">Estimated NAV</p>
        <div class="big">${forecast.expectedValue}</div>
        <p class="sub">
          估算净值区间 ${forecast.rangeValue[0]} 至 ${forecast.rangeValue[1]}。
          这是统计模型，不是承诺收益。
        </p>
      </aside>
    </div>
  `;

  metrics.hidden = false;
  metrics.innerHTML = [
    metric("近 5 日", pct(forecast.lastReturnsPct["5d"])),
    metric("近 10 日", pct(forecast.lastReturnsPct["10d"])),
    metric("近 20 日", pct(forecast.lastReturnsPct["20d"])),
    metric("30 日波动", `${forecast.volatilityPct}%`),
    metric("90 日最大回撤", `${forecast.maxDrawdownPct}%`),
    metric("更新时间", data.updatedAt.slice(5, 16)),
    metric("最新日期", data.latest.date.slice(5)),
    metric("预测天数", `${forecast.horizonDays} 天`),
  ].join("");

  holdingsPanel.hidden = false;
  impactBadge.textContent = `${data.impact.label} · ${pct(data.impact.todayContributionPct)}`;
  const industryText = data.impact.topIndustries
    .map((item) => `${item.name} ${item.holdingPct}%`)
    .join(" / ");
  buyView.innerHTML = `
    <strong>${data.buyView.stance}</strong>
    <span>${data.buyView.reason}</span>
    <small>风险：${data.buyView.riskLevel} · 前十大持仓占净值 ${data.impact.topHoldingExposurePct}% · ${industryText}</small>
  `;
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
    const response = await fetch(`/api/fund/${code}`);
    const payload = await response.json();
    if (!payload.ok) throw new Error(payload.error || "抓取失败");
    render(payload.data);
  } catch (error) {
    setError(error.message);
  }
});

window.addEventListener("resize", () => {
  if (!chartPanel.hidden && window.lastHistory) drawChart(window.lastHistory);
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/static/sw.js").catch(() => {});
}
