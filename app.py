from __future__ import annotations

import json
import math
import os
import re
import statistics
import time
import urllib.error
import urllib.request
from datetime import datetime
from html import unescape
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
FUND_CODE_RE = re.compile(r"^\d{6}$")


def fetch_text(url: str) -> str:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"
            ),
            "Referer": "https://fund.eastmoney.com/",
        },
    )
    with urllib.request.urlopen(request, timeout=12) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        return response.read().decode(charset, errors="replace")


def js_var(raw: str, name: str, default: Any = None) -> Any:
    pattern = rf"var\s+{re.escape(name)}\s*=\s*(.*?);"
    match = re.search(pattern, raw, re.S)
    if not match:
        return default
    value = match.group(1).strip()
    if value.startswith("'") or value.startswith('"'):
        return value.strip("'\"")
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return default


def daily_returns(points: list[dict[str, Any]]) -> list[float]:
    returns: list[float] = []
    for previous, current in zip(points, points[1:]):
        prev_value = float(previous["y"])
        curr_value = float(current["y"])
        if prev_value > 0:
            returns.append((curr_value / prev_value) - 1)
    return returns


def moving_average(values: list[float], window: int) -> float | None:
    if len(values) < window:
        return None
    return statistics.fmean(values[-window:])


def max_drawdown(points: list[dict[str, Any]]) -> float:
    peak = 0.0
    worst = 0.0
    for point in points:
        value = float(point["y"])
        peak = max(peak, value)
        if peak:
            worst = min(worst, value / peak - 1)
    return worst


def strip_tags(value: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<.*?>", "", unescape(value))).strip()


def market_from_code(code: str) -> str:
    return "1" if code.startswith(("5", "6", "9")) else "0"


def load_holdings(code: str) -> list[dict[str, Any]]:
    year = datetime.now().year
    url = (
        "https://fundf10.eastmoney.com/FundArchivesDatas.aspx"
        f"?type=jjcc&code={code}&topline=10&year={year}&month="
    )
    raw = fetch_text(url)
    content_match = re.search(r'content:"(.*?)",arryear', raw, re.S)
    content = content_match.group(1) if content_match else raw
    rows = re.findall(r"<tr>(.*?)</tr>", content, re.S)
    holdings: list[dict[str, Any]] = []

    for row in rows:
        cells = re.findall(r"<td.*?>(.*?)</td>", row, re.S)
        if len(cells) < 9:
            continue
        stock_code = strip_tags(cells[1])
        name = strip_tags(cells[2])
        ratio_text = strip_tags(cells[6]).replace("%", "")
        if not re.match(r"^\d{6}$", stock_code):
            continue
        try:
            ratio = float(ratio_text)
        except ValueError:
            ratio = 0.0
        holdings.append(
            {
                "code": stock_code,
                "secid": f"{market_from_code(stock_code)}.{stock_code}",
                "name": name,
                "holdingPct": ratio,
            }
        )

    return holdings[:10]


def enrich_holdings(holdings: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not holdings:
        return []
    secids = ",".join(item["secid"] for item in holdings)
    fields = "f2,f3,f12,f14,f62,f100,f184"
    url = f"https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids={secids}&fields={fields}"
    try:
        payload = json.loads(fetch_text(url))
    except Exception:
        return holdings

    quote_map = {item.get("f12"): item for item in payload.get("data", {}).get("diff", [])}
    enriched: list[dict[str, Any]] = []
    for holding in holdings:
        quote = quote_map.get(holding["code"], {})
        change_pct = quote.get("f3")
        holding_pct = holding.get("holdingPct") or 0
        contribution = (holding_pct / 100) * change_pct if isinstance(change_pct, (int, float)) else None
        enriched.append(
            {
                **holding,
                "price": quote.get("f2"),
                "changePct": change_pct,
                "industry": quote.get("f100") or "未知",
                "mainInflow": quote.get("f62"),
                "mainInflowPct": quote.get("f184"),
                "estimatedContributionPct": round(contribution, 3) if contribution is not None else None,
            }
        )
    return enriched


def related_impact(holdings: list[dict[str, Any]]) -> dict[str, Any]:
    valid = [item for item in holdings if isinstance(item.get("changePct"), (int, float))]
    contribution = sum(item.get("estimatedContributionPct") or 0 for item in valid)
    exposure = sum(item.get("holdingPct") or 0 for item in holdings)
    industries: dict[str, float] = {}
    for item in holdings:
        industry = item.get("industry") or "未知"
        industries[industry] = industries.get(industry, 0) + (item.get("holdingPct") or 0)
    top_industries = [
        {"name": name, "holdingPct": round(value, 2)}
        for name, value in sorted(industries.items(), key=lambda pair: pair[1], reverse=True)[:3]
    ]

    if contribution > 0.25:
        label = "关联持仓正在推动净值"
    elif contribution < -0.25:
        label = "关联持仓正在拖累净值"
    else:
        label = "关联持仓影响偏中性"

    return {
        "label": label,
        "topHoldingExposurePct": round(exposure, 2),
        "todayContributionPct": round(contribution, 3),
        "topIndustries": top_industries,
    }


def buy_view(forecast_data: dict[str, Any], impact: dict[str, Any]) -> dict[str, Any]:
    expected = forecast_data["expectedPct"]
    probability = forecast_data["probabilityUp"]
    drawdown = forecast_data["maxDrawdownPct"]
    contribution = impact.get("todayContributionPct") or 0

    if expected > 0.8 and probability >= 60 and contribution >= 0:
        stance = "可以考虑小额分批"
        reason = "短期动量和关联持仓偏正，但仍建议分批，避免一次买在波动高点。"
    elif expected < -0.5 or probability < 45 or contribution < -0.4:
        stance = "先别急着加仓"
        reason = "短期估算或重仓关联资产偏弱，等回撤企稳、连续两三个交易日改善再看更稳。"
    else:
        stance = "观望或定投式少量"
        reason = "信号不够单边，若你本来长期看好，可以只按计划小额定投，不建议冲动补仓。"

    risk = "高波动"
    if forecast_data["volatilityPct"] < 0.8 and drawdown > -8:
        risk = "中低波动"
    elif forecast_data["volatilityPct"] < 1.5 and drawdown > -18:
        risk = "中等波动"

    return {"stance": stance, "reason": reason, "riskLevel": risk}


def forecast(points: list[dict[str, Any]], horizon: int = 5) -> dict[str, Any]:
    returns = daily_returns(points)
    recent = returns[-30:]
    last_5 = returns[-5:]
    last_10 = returns[-10:]
    last_20 = returns[-20:]

    if len(recent) < 8:
        raise ValueError("历史净值太少，暂时无法生成可靠区间。")

    momentum = (
        0.5 * (statistics.fmean(last_5) if last_5 else 0)
        + 0.3 * (statistics.fmean(last_10) if last_10 else 0)
        + 0.2 * (statistics.fmean(last_20) if last_20 else 0)
    )
    drift = statistics.fmean(recent)
    volatility = statistics.pstdev(recent) if len(recent) > 1 else 0
    daily_expected = 0.65 * momentum + 0.35 * drift
    expected_change = daily_expected * horizon
    interval = 1.15 * volatility * math.sqrt(horizon)
    prob_up = 1 / (1 + math.exp(-(expected_change / max(interval / 2, 0.0001))))

    last_value = float(points[-1]["y"])
    expected_value = last_value * (1 + expected_change)
    lower_value = last_value * (1 + expected_change - interval)
    upper_value = last_value * (1 + expected_change + interval)

    return {
        "horizonDays": horizon,
        "direction": "up" if expected_change >= 0 else "down",
        "probabilityUp": round(prob_up * 100, 1),
        "expectedPct": round(expected_change * 100, 2),
        "rangePct": [
            round((expected_change - interval) * 100, 2),
            round((expected_change + interval) * 100, 2),
        ],
        "expectedValue": round(expected_value, 4),
        "rangeValue": [round(lower_value, 4), round(upper_value, 4)],
        "volatilityPct": round(volatility * 100, 2),
        "maxDrawdownPct": round(max_drawdown(points[-90:]) * 100, 2),
        "lastReturnsPct": {
            "5d": round(sum(last_5) * 100, 2),
            "10d": round(sum(last_10) * 100, 2),
            "20d": round(sum(last_20) * 100, 2),
        },
    }


def load_fund(code: str) -> dict[str, Any]:
    if not FUND_CODE_RE.match(code):
        raise ValueError("请输入支付宝基金详情页里的 6 位基金代码。")

    timestamp = int(time.time() * 1000)
    url = f"https://fund.eastmoney.com/pingzhongdata/{code}.js?v={timestamp}"
    raw = fetch_text(url)
    points = js_var(raw, "Data_netWorthTrend", [])
    name = js_var(raw, "fS_name", "")
    fund_code = js_var(raw, "fS_code", code)

    if not points:
        raise ValueError("没有抓到净值走势，可能基金代码不存在或数据源临时不可用。")

    clean_points = [
        {
            "date": datetime.fromtimestamp(item["x"] / 1000).strftime("%Y-%m-%d"),
            "value": float(item["y"]),
            "equityReturn": item.get("equityReturn"),
        }
        for item in points
        if item.get("y") is not None and item.get("x") is not None
    ]
    forecast_points = [{"x": p["date"], "y": p["value"]} for p in clean_points[-180:]]

    forecast_data = forecast(forecast_points)
    holdings = enrich_holdings(load_holdings(code))
    impact = related_impact(holdings)

    return {
        "code": fund_code,
        "name": name or f"基金 {code}",
        "source": "东方财富/天天基金公开页面数据",
        "updatedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "latest": clean_points[-1],
        "history": clean_points[-90:],
        "forecast": forecast_data,
        "holdings": holdings,
        "impact": impact,
        "buyView": buy_view(forecast_data, impact),
        "disclaimer": "模型只基于历史净值的动量和波动率估算，不能保证未来收益，也不构成投资建议。",
    }


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path.startswith("/api/fund/"):
            code = self.path.rsplit("/", 1)[-1].split("?", 1)[0]
            self.send_json_response(lambda: load_fund(code))
            return
        if self.path == "/":
            self.path = "/static/index.html"
        return super().do_GET()

    def translate_path(self, path: str) -> str:
        if path.startswith("/static/"):
            return str(ROOT / path.lstrip("/"))
        return str(STATIC / "index.html")

    def send_json_response(self, producer) -> None:
        try:
            payload = {"ok": True, "data": producer()}
            status = 200
        except (ValueError, urllib.error.URLError, TimeoutError) as exc:
            payload = {"ok": False, "error": str(exc)}
            status = 400
        except Exception as exc:
            payload = {"ok": False, "error": f"服务异常：{exc}"}
            status = 500

        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    port = int(os.environ.get("PORT", "8765"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"Fund Lens is running at http://127.0.0.1:{port}")
    print(f"On iPhone, open http://<your-computer-lan-ip>:{port} in Safari.")
    server.serve_forever()


if __name__ == "__main__":
    main()
