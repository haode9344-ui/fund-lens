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


def return_details(points: list[dict[str, Any]], days: int) -> list[dict[str, Any]]:
    details: list[dict[str, Any]] = []
    start = max(1, len(points) - days)
    for index in range(start, len(points)):
        previous = float(points[index - 1]["y"])
        current = float(points[index]["y"])
        change = (current / previous - 1) if previous else 0
        details.append(
            {
                "date": points[index]["x"],
                "value": round(current, 4),
                "changePct": round(change * 100, 2),
            }
        )
    return details


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


def load_market() -> dict[str, Any]:
    url = (
        "https://push2.eastmoney.com/api/qt/ulist.np/get"
        "?fltt=2&secids=1.000001,0.399001,0.399006,1.000300&fields=f2,f3,f12,f14"
    )
    try:
        payload = json.loads(fetch_text(url))
        items = payload.get("data", {}).get("diff", [])
    except Exception:
        items = []
    changes = [float(item.get("f3") or 0) for item in items]
    average = statistics.fmean(changes) if changes else 0
    label = "市场偏震荡"
    if average > 0.4:
        label = "市场偏强"
    elif average < -0.4:
        label = "市场偏弱"
    return {
        "label": label,
        "averageChange": round(average, 2),
        "indices": [
            {
                "name": item.get("f14"),
                "code": item.get("f12"),
                "changePct": item.get("f3"),
                "price": item.get("f2"),
            }
            for item in items
        ],
    }


def event_hints(impact: dict[str, Any]) -> list[str]:
    names = "、".join(item.get("name", "") for item in impact.get("topIndustries", []))
    if re.search(r"白酒|饮料|食品|消费", names):
        return ["消费复苏强弱", "白酒批价变化", "节假日消费预期", "龙头公司财报"]
    if re.search(r"半导体|芯片|电子|通信|计算机|软件|人工智能", names):
        return ["科技政策", "AI 订单变化", "芯片景气度", "美股科技股波动"]
    if re.search(r"医药|医疗|生物", names):
        return ["医保政策", "创新药审批", "药企财报", "集采预期"]
    if re.search(r"新能源|电池|光伏|电力设备", names):
        return ["锂价变化", "装机需求", "海外关税", "龙头订单"]
    if re.search(r"银行|证券|保险|金融", names):
        return ["利率变化", "成交量", "政策预期", "地产信用"]
    return ["大盘风险偏好", "行业政策", "重仓股财报", "资金流向"]


def explanation(forecast_data: dict[str, Any], impact: dict[str, Any], market: dict[str, Any]) -> dict[str, str]:
    market_text = market.get("label", "市场数据暂缺")
    average = market.get("averageChange") or 0
    if average:
        market_text = f"{market_text}（主要指数均值 {average:+.2f}%）"
    contribution = impact.get("todayContributionPct") or 0
    if contribution > 0.25:
        holding_text = f"重仓股今天贡献约 {contribution:+.2f}%"
    elif contribution < -0.25:
        holding_text = f"重仓股今天拖累约 {contribution:+.2f}%"
    else:
        holding_text = "重仓股影响不强"
    if forecast_data["direction"] == "up":
        move = f"偏涨：近 5/10/20 日动量偏正，{holding_text}。"
    else:
        move = f"偏跌：短期动量或市场环境偏弱，{holding_text}。"
    return {
        "market": market_text,
        "move": move,
        "events": "、".join(event_hints(impact)),
    }


def market_from_trend(forecast_data: dict[str, Any]) -> dict[str, Any]:
    short_trend = forecast_data["lastReturnsPct"]["5d"] + forecast_data["lastReturnsPct"]["10d"]
    label = "市场/基金风格偏震荡"
    if short_trend > 1.2:
        label = "市场/基金风格偏强"
    elif short_trend < -1.2:
        label = "市场/基金风格偏弱"
    return {"label": label, "averageChange": round(short_trend / 2, 2), "indices": []}


def tomorrow_detail(
    forecast_data: dict[str, Any],
    impact: dict[str, Any],
    market: dict[str, Any],
    holdings: list[dict[str, Any]],
) -> dict[str, Any]:
    tomorrow = forecast_data.get("tomorrow", {})
    expected = tomorrow.get("expectedPct", 0)
    direction = "偏涨" if expected >= 0 else "偏跌"
    top_holding = next((item for item in holdings if isinstance(item.get("changePct"), (int, float))), None)
    industry = impact.get("topIndustries", [{}])[0].get("name", "重仓行业") if impact.get("topIndustries") else "重仓行业"
    bullish: list[str] = []
    bearish: list[str] = []

    if forecast_data["lastReturnsPct"]["5d"] > 0:
        bullish.append(f"近 5 日累计 {forecast_data['lastReturnsPct']['5d']:+.2f}%，短线动量还在。")
    else:
        bearish.append(f"近 5 日累计 {forecast_data['lastReturnsPct']['5d']:+.2f}%，短线动量偏弱。")

    market_change = market.get("averageChange") or 0
    if market_change > 0.4:
        bullish.append(f"大盘/风格偏强，指数均值 {market_change:+.2f}%。")
    elif market_change < -0.4:
        bearish.append(f"大盘/风格偏弱，指数均值 {market_change:+.2f}%。")
    else:
        bullish.append("大盘没有明显拖累，明天主要看重仓股表现。")

    contribution = impact.get("todayContributionPct") or 0
    if contribution > 0.25:
        bullish.append(f"前十大持仓估算贡献 {contribution:+.2f}%。")
    elif contribution < -0.25:
        bearish.append(f"前十大持仓估算拖累 {contribution:+.2f}%。")
    else:
        bearish.append("重仓股今天没有形成强推动，明天需要确认延续性。")

    if top_holding:
        line = f"{top_holding.get('name')} 今日 {top_holding.get('changePct'):+.2f}%，它对 {industry} 情绪影响较大。"
        if (top_holding.get("changePct") or 0) >= 0:
            bullish.append(line)
        else:
            bearish.append(line)

    conclusion = (
        "明天更像小幅偏涨或震荡上行，不适合追高重仓，适合小额分批观察。"
        if direction == "偏涨"
        else "明天更像偏弱或震荡回撤，先等重仓股止跌和市场情绪改善。"
    )
    return {
        "direction": direction,
        "probabilityUp": tomorrow.get("probabilityUp", forecast_data.get("probabilityUp")),
        "expectedPct": expected,
        "rangePct": tomorrow.get("rangePct", []),
        "bullish": bullish,
        "bearish": bearish,
        "conclusion": conclusion,
    }


def recent_review(
    clean_points: list[dict[str, Any]],
    impact: dict[str, Any],
    market: dict[str, Any],
) -> list[dict[str, Any]]:
    industry = impact.get("topIndustries", [{}])[0].get("name", "当前重仓行业") if impact.get("topIndustries") else "当前重仓行业"
    market_change = market.get("averageChange") or 0
    market_reason = "大盘震荡，主要看重仓行业和个股表现。"
    if market_change > 0.4:
        market_reason = "大盘环境偏强，对基金有托底。"
    elif market_change < -0.4:
        market_reason = "大盘环境偏弱，容易放大回撤。"
    rows: list[dict[str, Any]] = []
    for previous, current in zip(clean_points[-6:-1], clean_points[-5:]):
        change = (current["value"] / previous["value"] - 1) * 100 if previous["value"] else 0
        direction = "上涨" if change >= 0 else "下跌"
        base = "净值抬升，说明当日底层持仓整体贡献偏正。" if change >= 0 else "净值回落，说明当日底层持仓整体承压。"
        rows.append(
            {
                "date": current["date"],
                "changePct": round(change, 2),
                "title": f"{current['date']} {direction} {change:+.2f}%",
                "reason": f"{base}{market_reason}重点观察 {industry}、资金流向和龙头股公告。",
            }
        )
    return list(reversed(rows))


def today_and_after_analysis(
    forecast_data: dict[str, Any],
    impact: dict[str, Any],
    market: dict[str, Any],
    holdings: list[dict[str, Any]],
) -> list[dict[str, str]]:
    leaders = [
        item
        for item in holdings
        if isinstance(item.get("changePct"), (int, float))
    ]
    leaders = sorted(leaders, key=lambda item: abs(item.get("estimatedContributionPct") or 0), reverse=True)[:3]
    if leaders:
        leader_text = "；".join(
            f"{item.get('name')}{item.get('changePct'):+.2f}%，贡献{(item.get('estimatedContributionPct') or 0):+.2f}%"
            for item in leaders
        )
    else:
        leader_text = "重仓股实时数据暂缺，先按基金净值动量和市场风格判断"

    contribution = impact.get("todayContributionPct") or 0
    market_change = market.get("averageChange") or 0
    if contribution > 0.25 or market_change > 0.5:
        today_direction = "今天偏正面"
    elif contribution < -0.25 or market_change < -0.5:
        today_direction = "今天偏负面"
    else:
        today_direction = "今天偏震荡"

    today_reason = (
        f"{today_direction}：市场/风格为{market.get('label')}，"
        f"前十大持仓估算影响 {contribution:+.2f}%。{leader_text}。"
    )

    if forecast_data.get("expectedPct", 0) >= 0:
        after_direction = "今天过后偏涨"
        after_reason = (
            "后市看涨依据：短线趋势没有明显破坏，"
            "若明天重仓股继续不拖累，净值更容易延续反弹。"
        )
    else:
        after_direction = "今天过后偏跌"
        after_reason = (
            "后市看跌依据：短期动量偏弱或波动区间下沿较大，"
            "若明天重仓股继续走弱，净值容易继续回撤。"
        )

    if forecast_data.get("expectedPct", 0) >= 0 and market_change > -0.6:
        buy_reason = "买进原因：不是因为一定会涨，而是短线趋势没有破坏，可用小额分批换取反弹机会。"
    else:
        buy_reason = "暂缓买进原因：今天信号不够强，等明天确认重仓股止跌或指数转强更稳。"

    return [
        {"title": "今天怎么看", "reason": today_reason},
        {"title": "今天以后怎么看", "reason": f"{after_direction}：{after_reason}"},
        {"title": "买进原因", "reason": buy_reason},
    ]


def buy_view(forecast_data: dict[str, Any], impact: dict[str, Any], market: dict[str, Any]) -> dict[str, Any]:
    expected = forecast_data["expectedPct"]
    probability = forecast_data["probabilityUp"]
    drawdown = forecast_data["maxDrawdownPct"]
    contribution = impact.get("todayContributionPct") or 0
    market_ok = (market.get("averageChange") or 0) > -0.6

    if expected > 0.8 and probability >= 60 and contribution >= 0 and market_ok:
        stance = "可以考虑小额分批"
        reason = "买进理由：短期趋势偏正、市场不弱、重仓持仓没有明显拖累；但仍建议分批。"
    elif expected < -0.5 or probability < 45 or contribution < -0.4:
        stance = "先别急着加仓"
        reason = "不急买理由：短期估算偏弱或持仓拖累明显，等连续两三个交易日改善再看。"
    else:
        stance = "观望或定投式少量"
        reason = "少量买进理由：没有明显单边信号，适合按计划小额定投，不适合一次性重仓。"

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
    tomorrow_expected = daily_expected
    tomorrow_interval = 0.95 * volatility
    tomorrow_prob = 1 / (1 + math.exp(-(tomorrow_expected / max(tomorrow_interval / 2, 0.0001))))

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
        "movingAverage": {
            "ma5": round(moving_average([float(p["y"]) for p in points], 5) or 0, 4),
            "ma10": round(moving_average([float(p["y"]) for p in points], 10) or 0, 4),
            "ma20": round(moving_average([float(p["y"]) for p in points], 20) or 0, 4),
        },
        "detailReturns": {
            "5d": return_details(points, 5),
            "10d": return_details(points, 10),
            "20d": return_details(points, 20),
        },
        "tomorrow": {
            "expectedPct": round(tomorrow_expected * 100, 2),
            "rangePct": [
                round((tomorrow_expected - tomorrow_interval) * 100, 2),
                round((tomorrow_expected + tomorrow_interval) * 100, 2),
            ],
            "probabilityUp": round(tomorrow_prob * 100, 1),
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
    market = load_market()
    if market.get("label") == "市场数据暂缺":
        market = market_from_trend(forecast_data)
    explain = explanation(forecast_data, impact, market)

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
        "market": market,
        "explanation": explain,
        "tomorrowDetail": tomorrow_detail(forecast_data, impact, market, holdings),
        "review": today_and_after_analysis(forecast_data, impact, market, holdings),
        "buyView": buy_view(forecast_data, impact, market),
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
        path = path.split("?", 1)[0].split("#", 1)[0]
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
