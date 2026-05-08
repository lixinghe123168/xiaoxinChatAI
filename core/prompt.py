"""统一 System Prompt 构建 + AI 回复解析"""
import re
import random
from datetime import datetime
from .skill import get_skill_data, get_bot_name
from .config import load_config

EMOJI_KEYWORDS = [
    "开心", "快乐", "高兴", "哈哈", "笑",
    "难过", "伤心", "悲伤", "哭", "委屈",
    "生气", "愤怒", "火大", "不爽", "讨厌",
    "惊讶", "震惊", "意外", "天哪", "卧槽",
    "害羞", "不好意思", "脸红",
    "搞笑", "沙雕", "逗比", "无语",
    "无奈", "心累", "躺平", "摆烂",
    "感动", "温暖", "治愈", "爱",
    "鄙视", "嫌弃", "傲娇",
    "疑惑", "问号", "不懂", "啥",
    "害怕", "紧张", "慌", "瑟瑟发抖",
    "赞", "牛", "厉害", "666", "强",
    "加油", "努力", "冲",
    "谢谢", "感谢", "抱拳",
    "对不起", "抱歉", "跪下", "求饶",
    "打工人", "上班", "摸鱼", "下班",
    "吃饭", "饿", "美食",
    "睡觉", "困", "熬夜",
    "钱", "穷", "富",
    "可爱", "萌", "乖",
    "酷", "帅", "美",
]


def build_system_prompt(
    skill_data: dict | None = None,
    bot_name: str | None = None,
    cfg: dict | None = None,
    include_emoji: bool = True,
    include_tools: bool = True,
) -> str:
    """构建 System Prompt（主入口）

    Args:
        skill_data: 已加载的 skill 数据，None 则自动加载
        bot_name: Bot 名称，None 则从 skill_data 推断
        cfg: 配置，None 则自动加载
        include_emoji: 是否包含表情包规则
        include_tools: 是否包含联网工具说明
    """
    if cfg is None:
        cfg = load_config()
    if skill_data is None:
        skill_data = get_skill_data(cfg)
    if bot_name is None:
        bot_name = get_bot_name(skill_data)

    now = datetime.now()
    weekday_names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    prompt = f"""当前时间：{now.strftime('%Y年%m月%d日')} {weekday_names[now.weekday()]} {now.strftime('%H:%M:%S')}

你现在是「{bot_name}」，请完全按照以下 Persona 设定来回复。

## 你的身份设定

{skill_data['config'].get('system_prompt', f'你扮演{bot_name}，一个有独特个性的AI助手。\n  性格：幽默有趣，有自己的想法。\n  说话风格：短句为主，口语化。')}

{skill_data['persona']}

## 记忆库（重要：这是背景知识，不要主动提及！）

{skill_data['memories']}

⚠️ 关于记忆库的严格规定：
- 记忆库是用来让你了解"你是谁、你们什么关系、你记得什么"
- **绝对不要**主动把记忆里的具体内容硬塞进回复
- 只有当**用户主动提到相关话题**时，你才可以展开讨论
- 正常闲聊时，记忆库只影响你的语气和态度，不影响你说的内容
"""

    if include_emoji:
        prompt += f"""
## 表情包规则

你需要根据当前对话的情绪和语境，选择一个最合适的表情包关键词。
可选关键词：{', '.join(EMOJI_KEYWORDS)}

输出格式（严格遵守）：
第一行：你的回复（用{bot_name}的口吻和风格）
第二行：[EMOJI:关键词]

注意：
- 必须严格按格式输出，第二行必须是 [EMOJI:xxx] 格式
- 关键词必须从上面列表中选择
- 保持{bot_name}的说话风格：短句、口语化、偶尔毒舌
- 如果不感兴趣可以简短回复或已读不回风格
- **不要编造用户没说过的内容**
"""

    if include_tools:
        prompt += """
## 联网能力说明

你可以使用以下工具来获取最新信息：
- **网络搜索**：当用户问天气、新闻、或者你不知道的最新信息时使用

**使用规则：**
- 只有在确实需要最新信息时才使用工具
- 用户明确要求查东西时，优先使用工具
- 工具返回的结果要用自然语言总结给用户，不要原样复制
"""

    prompt += f"""
⚠️ 回复多样性要求（非常重要）：
- **绝对不要连续使用相同的回复或固定句式**
- **禁止复读特定句子**
- 每次回复都要根据当前对话上下文生成新的、有变化的内容
- 保持语言的丰富性，不要陷入重复模式
- 如果觉得没什么好说的，可以用"嗯"、"哦"、"懂了"等简短回应，也不要复读
- 不要发送解释说明

## 多条消息发送

如果你觉得有必要，可以把一条回复拆成 **2-3条短消息**，用 `空格` 分隔，会更自然。

例如：
第一条短消息 第二条短消息 第三条短消息
[EMOJI:开心]

注意：
- 每条消息要简短（1-2句话），像微信聊天一样自然
- 适用于：补充说明、连续吐槽、先回复再追问
- **不要每条回复都拆多条**，只有需要的时候才拆
- **最后一条可以带表情包标记**
"""
    return prompt


def build_system_prompt_with_memory(
    retrieved_memories: str = "",
    chat_summary: str = "",
    skill_data: dict | None = None,
    bot_name: str | None = None,
    cfg: dict | None = None,
    include_emoji: bool = True,
    include_tools: bool = True,
) -> str:
    """构建带记忆注入的完整 System Prompt"""
    prompt = build_system_prompt(
        skill_data=skill_data,
        bot_name=bot_name,
        cfg=cfg,
        include_emoji=include_emoji,
        include_tools=include_tools,
    )

    if retrieved_memories:
        prompt += f"\n\n{retrieved_memories}\n\n⚠️ 以上「相关记忆」仅供参考。如果与当前话题相关，你可以自然地引用或延续；如果不相关或用户没提到，直接忽略即可，不要强行提及。"

    if chat_summary:
        prompt += "\n\n## 之前对话摘要（已压缩的旧对话轮次）\n" + chat_summary + "\n\n⚠️ 以上是之前聊天的压缩摘要，包含用户提到过的话题和偏好。如果与当前话题相关，请自然延续，不要刻意提及。"

    return prompt


def parse_ai_response(text: str) -> tuple[str, str | None]:
    """解析 AI 回复，分离正文和表情包关键词"""
    lines = text.strip().split("\n")
    emoji_keyword = None
    has_emoji_marker = False

    emoji_patterns = [
        r"\[(?:EMOJI|表情)[:：](.+?)\]",
        r"\[(?:EMOJI|表情)\]",
        r"【(?:EMOJI|表情)[:：]?(.+?)?】",
        r"\[\s*(.+?)\s*\]",
        r"📷?\s*[😊😂🥰😭😅💗🙄👀🎉❤️🔥✨]+(?:\s*(.+?))?\s*$",
    ]

    emoji_keywords_lower = [k.lower() for k in EMOJI_KEYWORDS]

    def _normalize(t: str) -> str:
        s = t.strip().lower()
        s = s.lstrip("[").lstrip("【").lstrip("（")
        s = s.rstrip("]").rstrip("】").rstrip("）")
        return s.strip()

    first_pass_lines = []
    for line in lines:
        stripped = line.strip()
        matched = False

        for pattern in emoji_patterns:
            match = re.search(pattern, stripped, re.IGNORECASE)
            if match:
                has_emoji_marker = True
                keyword = (match.group(1) if match.lastindex and match.group(1) else "").strip()

                if keyword:
                    if keyword.lower() in emoji_keywords_lower or keyword == "随机":
                        emoji_keyword = keyword if keyword != "随机" else None
                    else:
                        emoji_keyword = keyword

                clean_line = re.sub(
                    r"\s*(\[?(?:EMOJI|表情)[:：]?.*?\]?|【.*?】|\[.+?\]|📷?\s*[😊😂🥰😭😅💗🙄👀🎉❤️🔥✨]+)\s*",
                    "", stripped,
                ).strip()

                if clean_line and clean_line not in ["[表情]", "[EMOJI]", "【表情】"]:
                    first_pass_lines.append(stripped)

                matched = True
                break

        if not matched:
            norm = _normalize(stripped)
            if norm in emoji_keywords_lower:
                has_emoji_marker = True
                emoji_keyword = norm
            else:
                trailing_kw = re.search(
                    rf"\s*({'|'.join(emoji_keywords_lower)})\s*\]\s*$",
                    stripped.lower(),
                )
                if trailing_kw:
                    has_emoji_marker = True
                    emoji_keyword = trailing_kw.group(1)
                    text_before = stripped[:stripped.lower().rfind(trailing_kw.group(1))].strip()
                    if text_before:
                        first_pass_lines.append(text_before)
                elif stripped and stripped not in ["[表情]", "[EMOJI]", "【表情】", ""]:
                    first_pass_lines.append(stripped)

    reply_lines = []
    for line in first_pass_lines:
        stripped = line.strip()
        stripped_norm = _normalize(stripped)

        if has_emoji_marker:
            if stripped_norm in emoji_keywords_lower:
                continue
            if stripped.lower() in emoji_keywords_lower:
                continue

        is_emoji_line = False
        clean_line = stripped

        for pattern in emoji_patterns:
            match = re.search(pattern, stripped, re.IGNORECASE)
            if match:
                is_emoji_line = True
                clean_line = re.sub(
                    r"\s*(\[?(?:EMOJI|表情)[:：]?.*?\]?|【.*?】|\[.+?\]|📷?\s*[😊😂🥰😭😅💗🙄👀🎉❤️🔥✨]+)\s*",
                    "", stripped,
                ).strip()

                if clean_line and clean_line not in ["[表情]", "[EMOJI]", "【表情】"]:
                    kw = (match.group(1) or "").strip() if match.lastindex and match.group(1) else ""
                    clean_norm = _normalize(clean_line)
                    if kw and _normalize(kw) == clean_norm:
                        continue
                    if clean_norm in emoji_keywords_lower:
                        continue
                    reply_lines.append(clean_line)
                break

        if not is_emoji_line:
            reply_lines.append(stripped)

    if has_emoji_marker and not emoji_keyword:
        emoji_keyword = random.choice(EMOJI_KEYWORDS[:10])

    reply_text = "\n".join(reply_lines).strip()

    if reply_text.endswith("[表情]") or reply_text.endswith("[EMOJI]"):
        reply_text = re.sub(r"\s*\[(?:EMOJI|表情)\]\s*$", "", reply_text).strip()

    return reply_text, emoji_keyword