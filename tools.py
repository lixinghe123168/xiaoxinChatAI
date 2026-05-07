"""
xiaoxinChatAI.tools - AI 联网工具模块

提供 Function Calling 工具，让 AI 在需要时自主决定联网搜索：
- web_search: 通用网络搜索（支持 DuckDuckGo/必应/SearXNG）
- get_weather: 天气查询
- get_news: 热点新闻获取

搜索源通过 web_config.json 中的 tools.web_search_source 配置：
- "duckduckgo": DuckDuckGo（默认，海外）
- "bing": 必应搜索（国内可用）
- "searxng": SearXNG 元搜索（国内可用）

工作流程：
1. AI 收到用户消息
2. AI 判断是否需要联网 → 返回 tool_call
3. 执行工具调用，获取结果
4. 将结果传回 AI，生成最终回复
"""

import json
import logging
import re
import asyncio
import aiohttp
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

logger = logging.getLogger("xiaoxinChatAI.tools")

SEARCH_TIMEOUT = 15

_CONFIG_FILE = Path(__file__).parent / "web_config.json"


def _get_search_source() -> str:
    """从 web_config.json 读取搜索源配置"""
    try:
        if _CONFIG_FILE.exists():
            data = json.loads(_CONFIG_FILE.read_text(encoding="utf-8"))
            source = data.get("tools", {}).get("web_search_source", "duckduckgo")
            return source
    except Exception:
        pass
    return "duckduckgo"


TOOL_DEFINITIONS = [
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": (
                "当用户询问你不知道的、或需要最新信息的问题时使用。"
                "包括但不限于：当前事件、新闻、天气、价格、最新数据、"
                "实时比分、新上映电影、热门话题、产品信息等。"
                "如果你的知识可能过时或不完整，就应该搜索。"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "要搜索的关键词或问题",
                    },
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "查询指定城市的当前天气和预报。当用户问天气、温度、下雨、穿衣等时使用。",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {
                        "type": "string",
                        "description": "城市名称，如'北京'、'上海'、'广州'",
                    },
                },
                "required": ["city"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_news",
            "description": "获取最新的热点新闻头条。当用户问最近发生了什么、今日新闻等时使用。",
            "parameters": {
                "type": "object",
                "properties": {
                    "category": {
                        "type": "string",
                        "enum": ["热点", "科技", "娱乐", "体育", "财经", "国际", "国内"],
                        "description": "新闻分类，默认为'热点'",
                    },
                    "count": {
                        "type": "integer",
                        "description": "返回条数，默认5条",
                    },
                },
                "required": [],
            },
        },
    },
]


async def _fetch_json(url: str, params: dict | None = None) -> dict:
    """通用 JSON 请求"""
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=SEARCH_TIMEOUT)) as session:
        async with session.get(url, params=params) as resp:
            return await resp.json()


async def _fetch_text(url: str, params: dict | None = None) -> tuple[int, str]:
    """通用文本请求，返回 (status_code, text)"""
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=SEARCH_TIMEOUT)) as session:
        async with session.get(url, params=params) as resp:
            text = await resp.text()
            return resp.status, text


async def web_search(query: str) -> str:
    """网络搜索 - 根据配置自动选择搜索源
    
    Args:
        query: 搜索关键词
        
    Returns:
        搜索结果摘要文本
    """
    logger.info(f"[tool] web_search: {query}")
    
    source = _get_search_source()
    logger.info(f"[tool] web_search 搜索源: {source}")
    
    if source == "bing":
        return await _search_bing(query)
    elif source == "searxng":
        return await _search_searxng(query)
    else:
        return await _search_duckduckgo(query)


async def _search_duckduckgo(query: str) -> str:
    """DuckDuckGo 搜索"""
    try:
        url = "https://api.duckduckgo.com/"
        params = {
            "q": query,
            "format": "json",
            "no_html": "1",
            "skip_disambig": "1",
        }
        
        status, text = await _fetch_text(url, params)
        
        if status != 200:
            return f"搜索服务暂时不可用 (HTTP {status})"
        
        data = json.loads(text)
        
        results = []
        
        if data.get("Abstract"):
            results.append(f"📌 摘要: {data['Abstract']}")
            if data.get("AbstractURL"):
                results.append(f"   来源: {data['AbstractURL']}")
        
        if data.get("Heading"):
            results.append(f"📎 标题: {data['Heading']}")
        
        if data.get("RelatedTopics"):
            related = data["RelatedTopics"][:5]
            if related and isinstance(related[0], dict):
                for i, topic in enumerate(related[:3], 1):
                    if isinstance(topic, dict):
                        text_val = topic.get("Text", "")
                        clean_text = re.sub(r'<[^>]+>', '', text_val)
                        results.append(f"{i}. {clean_text}")
        
        infobox = data.get("Infobox", {})
        if infobox.get("content"):
            results.append(f"\n📊 详细信息:")
            for item in infobox["content"][:5]:
                if isinstance(item, dict):
                    label = item.get("label", "")
                    value = item.get("value", "")
                    if label and value:
                        clean_value = re.sub(r'<[^>]+>', '', str(value))
                        results.append(f"  • {label}: {clean_value}")
        
        if not results:
            return f"未找到关于「{query}」的相关结果，可以换个关键词试试"
        
        result_text = "\n".join(results)
        
        logger.info(f"[tool] duckduckgo 结果长度: {len(result_text)}")
        return result_text
        
    except json.JSONDecodeError:
        return "搜索结果解析失败"
    except Exception as e:
        logger.error(f"[tool] duckduckgo 失败: {e}")
        return f"搜索出错: {type(e).__name__}"


async def _search_bing(query: str) -> str:
    """必应搜索 - 国内可用，无需 API Key"""
    try:
        url = "https://cn.bing.com/search"
        headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        }
        params = {
            "q": query,
            "ensearch": "0",
        }
        
        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=SEARCH_TIMEOUT),
            headers=headers,
        ) as session:
            async with session.get(url, params=params) as resp:
                if resp.status != 200:
                    return f"搜索服务暂时不可用 (HTTP {resp.status})"
                html = await resp.text()
        
        results = []
        
        # 提取搜索结果标题和摘要
        li_pattern = re.compile(r'<li class="b_algo">.*?</li>', re.DOTALL)
        items = li_pattern.findall(html)[:5]
        
        if not items:
            # 备选 pattern
            h2_pattern = re.compile(r'<h2><a[^>]*href="([^"]*)"[^>]*>(.*?)</a></h2>', re.DOTALL)
            p_pattern = re.compile(r'<p[^>]*>(.*?)</p>', re.DOTALL)
            
            h2_matches = h2_pattern.findall(html)[:5]
            p_matches = p_pattern.findall(html)[:5]
            
            if h2_matches:
                for i, (url, title) in enumerate(h2_matches, 1):
                    clean_title = re.sub(r'<[^>]+>', '', title).strip()
                    results.append(f"{i}. {clean_title}")
                    if i <= len(p_matches):
                        clean_desc = re.sub(r'<[^>]+>', '', p_matches[i-1]).strip()
                        if clean_desc:
                            results.append(f"   {clean_desc[:150]}")
        
        for item in items:
            title_match = re.search(r'<h2><a[^>]*>(.*?)</a></h2>', item, re.DOTALL)
            url_match = re.search(r'<a[^>]*href="([^"]*)"', item)
            desc_match = re.search(r'<p[^>]*>(.*?)</p>', item, re.DOTALL)
            
            if title_match:
                title = re.sub(r'<[^>]+>', '', title_match.group(1)).strip()
                result = f"  {title}"
                if desc_match:
                    desc = re.sub(r'<[^>]+>', '', desc_match.group(1)).strip()
                    if desc:
                        result += f"\n   {desc[:200]}"
                results.append(result)
        
        if not results:
            return f"未找到关于「{query}」的相关结果"
        
        result_text = "\n".join(results)
        logger.info(f"[tool] bing 结果长度: {len(result_text)}")
        return result_text
        
    except asyncio.TimeoutError:
        return "搜索超时，请稍后重试"
    except Exception as e:
        logger.error(f"[tool] bing 失败: {e}")
        return f"搜索出错: {type(e).__name__}"


async def _search_searxng(query: str) -> str:
    """SearXNG 元搜索 - 国内可用，无需 API Key"""
    instances = [
        "https://searx.be",
        "https://search.sapti.me",
        "https://searx.work",
    ]
    
    last_error = ""
    
    for instance in instances:
        try:
            url = f"{instance}/search"
            params = {
                "q": query,
                "format": "json",
                "language": "zh-CN",
                "categories": "general",
                "pageno": 1,
            }
            
            async with aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=10),
            ) as session:
                async with session.get(url, params=params) as resp:
                    if resp.status != 200:
                        last_error = f"HTTP {resp.status}"
                        continue
                    data = await resp.json()
            
            results_list = data.get("results", [])[:5]
            if not results_list:
                last_error = "无结果"
                continue
            
            results = []
            for i, r in enumerate(results_list, 1):
                title = r.get("title", "").strip()
                snippet = r.get("content", "").strip()
                result_url = r.get("url", "")
                
                if title:
                    result = f"{i}. {title}"
                    if snippet:
                        result += f"\n   {snippet[:200]}"
                    if result_url:
                        from urllib.parse import urlparse
                        domain = urlparse(result_url).netloc
                        result += f"\n   🔗 {domain}"
                    results.append(result)
            
            if results:
                result_text = "\n".join(results)
                logger.info(f"[tool] searxng({instance}) 结果长度: {len(result_text)}")
                return result_text
            
            last_error = "无结果"
            
        except asyncio.TimeoutError:
            last_error = "超时"
            logger.warning(f"[tool] searxng 实例超时: {instance}")
            continue
        except Exception as e:
            last_error = f"{type(e).__name__}"
            logger.warning(f"[tool] searxng 实例失败: {instance}: {e}")
            continue
    
    return f"搜索服务暂时不可用（已尝试 {len(instances)} 个节点）"


async def get_weather(city: str) -> str:
    """查询天气 - 使用 Open-Meteo 免费API
    
    Args:
        city: 城市名称
        
    Returns:
        天气信息文本
    """
    logger.info(f"[tool] get_weather: {city}")
    
    city_coords = {
        "北京": (39.9042, 116.4074),
        "上海": (31.2304, 121.4737),
        "广州": (23.1291, 113.2644),
        "深圳": (22.5431, 114.0579),
        "杭州": (30.2741, 120.1551),
        "成都": (30.5728, 104.0668),
        "武汉": (30.5928, 114.3055),
        "南京": (32.0603, 118.7969),
        "重庆": (29.4316, 106.9123),
        "西安": (34.3416, 108.9398),
        "苏州": (31.2989, 120.5853),
        "天津": (39.3434, 117.3616),
        "长沙": (28.2282, 112.9388),
        "郑州": (34.7466, 113.6254),
        "青岛": (36.0671, 120.3826),
        "大连": (38.9140, 121.6147),
        "厦门": (24.4798, 118.0894),
        "昆明": (25.0389, 102.7183),
        "哈尔滨": (45.8038, 126.5350),
        "沈阳": (41.8057, 123.4328),
        "济南": (36.6512, 116.9972),
        "福州": (26.0745, 119.2965),
        "合肥": (31.8206, 117.2272),
        "太原": (37.8706, 112.5489),
        "南昌": (28.6820, 115.8579),
        "南宁": (22.8170, 108.3665),
        "贵阳": (26.6470, 106.6302),
        "兰州": (36.0611, 103.8343),
        "乌鲁木齐": (43.8256, 87.6168),
        "呼和浩特": (40.8414, 111.7519),
        "银川": (38.4872, 106.2309),
        "海口": (20.0440, 110.1999),
        "三亚": (18.2528, 109.5120),
        "珠海": (22.2713, 113.5767),
        "无锡": (31.4912, 120.3119),
        "佛山": (23.0218, 113.1217),
        "东莞": (23.0289, 113.7554),
        "宁波": (29.8683, 121.5440),
    }
    
    coords = city_coords.get(city)
    if not coords:
        similar = [c for c in city_coords if city in c or c in city]
        if similar:
            coords = city_coords[similar[0]]
            city = similar[0]
            logger.info(f"[tool] 匹配到相似城市: {city}")
        else:
            lat, lon = 39.9042, 116.4074
            logger.warning(f"[tool] 未知城市 '{city}'，使用北京坐标")
    
    if coords:
        lat, lon = coords
    
    try:
        url = "https://api.open-meteo.com/v1/forecast"
        params = {
            "latitude": lat,
            "longitude": lon,
            "current": "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m",
            "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum",
            "timezone": "Asia/Shanghai",
            "forecast_days": 3,
        }
        
        data = await _fetch_json(url, params)
        
        current = data.get("current", {})
        daily = data.get("daily", {})
        
        weather_codes = {
            0: "☀️ 晴天", 1: "⛅ 大部晴朗", 2: "🌤️ 局部多云",
            3: "☁️ 多云/阴天", 45: "🌫️ 雾", 48: "🌫️ 雾凇",
            51: "🌧️ 小毛毛雨", 53: "🌧️ 中毛毛雨", 55: "🌧️ 大毛毛雨",
            61: "🌧️ 小雨", 63: "🌧️ 中雨", 65: "🌧️ 大雨",
            71: "❄️ 小雪", 73: "❄️ 中雪", 75: "❄️ 大雪",
            77: "🌨️ 雪粒", 80: "🌦️ 阵雨", 81: "🌦️ 中阵雨", 82: "🌦️ 大阵雨",
            85: "🌨️ 阵雪", 86: "🌨️ 大阵雪", 95: "⛈️ 雷暴", 96: "⛈️ 雷暴+冰雹", 99: "⛈️ 强雷暴+冰雹",
        }
        
        def get_weather_desc(code):
            return weather_codes.get(code, f"天气({code})")
        
        now_temp = current.get("temperature_2m", "N/A")
        feels_like = current.get("apparent_temperature", "N/A")
        humidity = current.get("relative_humidity_2m", "N/A")
        wind = current.get("wind_speed_10m", "N/A")
        wcode = current.get("weather_code", 0)
        weather_now = get_weather_desc(wcode)
        
        lines = [
            f"📍 {city} 当前天气 ({datetime.now().strftime('%H:%M')})",
            f"",
            f"   {weather_now}",
            f"   🌡️ 温度: {now_temp}°C (体感 {feels_like}°C)",
            f"   💧 湿度: {humidity}%",
            f"   💨 风速: {wind} km/h",
        ]
        
        dates = daily.get("time", [])
        max_temps = daily.get("temperature_2m_max", [])
        min_temps = daily.get("temperature_2m_min", [])
        wcodes = daily.get("weather_code", [])
        precips = daily.get("precipitation_sum", [])
        
        if dates:
            lines.append("")
            lines.append("📅 未来几天:")
            
            for i in range(min(3, len(dates))):
                date_str = dates[i]
                date_obj = datetime.strptime(date_str, "%Y-%m-%d")
                
                if i == 0:
                    day_label = "今天"
                elif i == 1:
                    day_label = "明天"
                else:
                    day_label = f"后天"
                
                t_max = max_temps[i] if i < len(max_temps) else "N/A"
                t_min = min_temps[i] if i < len(min_temps) else "N/A"
                wc = wcodes[i] if i < len(wcodes) else 0
                precip = precips[i] if i < len(precips) else 0
                
                w_desc = get_weather_desc(wc)
                rain_info = f", 🌧️降水{precip}mm" if precip > 0 else ""
                
                lines.append(f"   {day_label}: {w_desc}, {t_max}°C / {t_min}°C{rain_info}")
        
        result = "\n".join(lines)
        logger.info(f"[tool] get_weather 成功: {city}")
        return result
        
    except Exception as e:
        logger.error(f"[tool] get_weather 失败: {e}")
        return f"查询天气失败: {type(e).__name__}"


async def get_news(category: str = "热点", count: int = 5) -> str:
    """获取热点新闻 - 使用多个免费源
    
    Args:
        category: 新闻分类
        count: 返回条数
        
    Returns:
        新闻列表文本
    """
    logger.info(f"[tool] get_news: category={category}, count={count}")
    
    try:
        url = "https://news.topurl.cn/api"
        params = {"max": min(count, 10), "type": category}
        
        status, text = await _fetch_text(url, params)
        
        if status != 200:
            return f"新闻服务暂时不可用 (HTTP {status})"
        
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            data = {"data": []}
        
        news_list = data.get("data", [])
        
        if not news_list:
            return "暂时没有获取到新闻数据"
        
        lines = [f"📰 {category}新闻 Top {min(len(news_list), count)}\n"]
        
        now = datetime.now(timezone(timedelta(hours=8)))
        
        for i, item in enumerate(news_list[:count], 1):
            title = item.get("title", "无标题")
            source = item.get("source", "")
            url_link = item.get("url", "")
            pub_date = item.get("publishDate", "")
            
            time_info = ""
            if pub_date:
                try:
                    pub_dt = datetime.fromisoformat(pub_date.replace("Z", "+00:00"))
                    diff = now - pub_dt.astimezone(timezone(timedelta(hours=8)))
                    
                    hours = diff.total_seconds() / 3600
                    if hours < 1:
                        time_info = f"{int(diff.total_seconds() / 60)}分钟前"
                    elif hours < 24:
                        time_info = f"{int(hours)}小时前"
                    else:
                        time_info = f"{int(hours / 24)}天前"
                except:
                    time_info = ""
            
            source_info = f" [{source}]" if source else ""
            time_str = f" ({time_info})" if time_info else ""
            
            lines.append(f"{i}. {title}{source_info}{time_str}")
            if url_link:
                lines.append(f"   🔗 {url_link}")
        
        result = "\n".join(lines)
        logger.info(f"[tool] get_news 成功: {len(news_list)} 条")
        return result
        
    except Exception as e:
        logger.error(f"[tool] get_news 失败: {e}")
        return f"获取新闻失败: {type(e).__name__}"


TOOL_FUNCTIONS = {
    "web_search": web_search,
    "get_weather": get_weather,
    "get_news": get_news,
}


async def execute_tool_call(tool_name: str, arguments: dict) -> str:
    """执行工具调用
    
    Args:
        tool_name: 工具名称
        arguments: 参数字典
        
    Returns:
        工具执行结果的文本
    """
    func = TOOL_FUNCTIONS.get(tool_name)
    if not func:
        return f"未知工具: {tool_name}"
    
    try:
        if asyncio.iscoroutinefunction(func):
            result = await func(**arguments)
        else:
            result = func(**arguments)
        
        return str(result)
        
    except TypeError as e:
        return f"参数错误: {e}"
    except Exception as e:
        logger.error(f"[tool] 执行 {tool_name} 异常: {e}")
        return f"执行出错: {type(e).__name__}: {e}"


def build_tool_use_instruction() -> str:
    """构建工具使用说明，注入 System Prompt"""
    return """

## 联网能力说明

你可以使用以下工具来获取最新信息：

**可用的工具：**
1. **web_search** - 网络搜索：当你不知道答案、需要最新信息、或者知识可能过时时使用
   - 例：查询新闻、事件、价格、最新数据、实时信息等
   
2. **get_weather** - 天气查询：当用户问天气、温度、下雨等时使用
   - 参数：city（城市名）
   
3. **get_news** - 新闻获取：当用户问最近发生什么、今日新闻时使用
   - 参数：category（分类）、count（条数）

**使用规则：**
- 只有在确实需要最新信息时才使用工具
- 如果你的知识足够回答，直接回答即可
- 用户明确要求查东西时，优先使用工具
- 工具返回的结果要用自然语言总结给用户，不要原样复制
"""


if __name__ == "__main__":
    import asyncio
    
    logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
    
    print("=" * 50)
    print("  xiaoxinChatAI 联网工具测试")
    print("=" * 50)
    
    async def test():
        print("\n--- 测试网络搜索 ---")
        result = await web_search("今天天气怎么样 北京")
        print(result[:500])
        
        print("\n--- 测试天气查询 ---")
        result = await get_weather("上海")
        print(result)
        
        print("\n--- 测试新闻获取 ---")
        result = await get_news("热点", 5)
        print(result)
    
    asyncio.run(test())
