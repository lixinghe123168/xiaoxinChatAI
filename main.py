"""
xiaoxinChatAI 主程序

AI 微信机器人 - persona + 智能表情包
"""

import logging
import sys
import re
import json
import random
import asyncio
import os
from pathlib import Path
from openai import AsyncOpenAI
from clawpy import WxClawBot
from memory import (
    memory_store,
    format_retrieved_memories,
    should_store_memory,
)
from tools import (
    TOOL_DEFINITIONS,
    execute_tool_call,
    build_tool_use_instruction,
)

_last_active_time: dict[str, float] = {}

import os
os.environ['NO_PROXY'] = 'http://127.0.0.1:,localhost'


def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] [%(levelname)-5s] [%(name)s] %(message)s",
        datefmt="%H:%M:%S",
        handlers=[logging.StreamHandler(sys.stdout)],
    )


setup_logging()
logger = logging.getLogger("xiaoxinChatAI.main")


_CONFIG_FILE = Path(__file__).parent / "web_config.json"

_WEB_CONFIG_CACHE = None
_WEB_CONFIG_MTIME = 0

def _load_web_config() -> dict:
    """从 web_config.json 读取配置（带mtime缓存）"""
    global _WEB_CONFIG_CACHE, _WEB_CONFIG_MTIME
    try:
        if _CONFIG_FILE.exists():
            mtime = _CONFIG_FILE.stat().st_mtime
            if _WEB_CONFIG_CACHE is not None and mtime == _WEB_CONFIG_MTIME:
                return _WEB_CONFIG_CACHE
            import json as _json
            _WEB_CONFIG_CACHE = _json.loads(_CONFIG_FILE.read_text(encoding="utf-8"))
            _WEB_CONFIG_MTIME = mtime
            return _WEB_CONFIG_CACHE
    except Exception:
        pass
    _WEB_CONFIG_CACHE = {}
    return _WEB_CONFIG_CACHE

def _get_web_config() -> dict:
    return _load_web_config()

_LLM_CACHE = None
_LLM_CONFIG_HASH = None

def _get_llm() -> AsyncOpenAI:
    global _LLM_CACHE, _LLM_CONFIG_HASH
    cfg = _get_web_config().get("model", {})
    timeout = _get_web_config().get("system", {}).get("timeout", 120)
    
    config_hash = hash((cfg.get("base_url"), cfg.get("api_key"), timeout))
    
    if _LLM_CACHE is None or _LLM_CONFIG_HASH != config_hash:
        _LLM_CACHE = AsyncOpenAI(
            base_url=cfg.get("base_url", "https://api.deepseek.com"),
            api_key=cfg.get("api_key", ""),
            timeout=timeout,
        )
        _LLM_CONFIG_HASH = config_hash
    
    return _LLM_CACHE

def _get_skill_data() -> dict:
    skill_path = _get_web_config().get("skill", {}).get("path", "")
    if skill_path and Path(skill_path).exists():
        return load_skill(Path(skill_path))
    return {"config": {}, "persona": "", "memories": ""}

def _check_config_ready(override_cfg: dict = None) -> tuple[bool, str]:
    """检查配置是否就绪（模型 + Skill），返回 (是否就绪, 错误消息)
    
    Args:
        override_cfg: 可选，传入覆盖配置（用于 UI 中未保存时的实时检查）
    """
    cfg = override_cfg if override_cfg is not None else _get_web_config()

    model_cfg = cfg.get("model", {})
    api_key = model_cfg.get("api_key", "")
    if not api_key or api_key.strip() == "":
        return False, "未配置 API Key，请在 web_config.json 中设置 model.api_key"

    skill_cfg = cfg.get("skill", {})
    if skill_cfg.get("enabled", False):
        skill_path_str = skill_cfg.get("path", "")
        if not skill_path_str or not skill_path_str.strip():
            return False, "Skill 已启用但未配置路径，请在 web_config.json 中设置 skill.path"
        skill_path = Path(skill_path_str)
        if not skill_path.exists():
            return False, f"Skill 目录不存在: {skill_path}"
        if not skill_path.is_dir():
            return False, f"Skill 路径不是目录: {skill_path}"
        config_yaml = skill_path / "config.yaml"
        if not config_yaml.exists():
            return False, f"Skill 目录缺少 config.yaml: {skill_path}"

    return True, ""


def _get_bot_name() -> str:
    return "微信"

def _get_max_history() -> int:
    return _get_web_config().get("memory", {}).get("short_term_max", 20)

def load_skill(skill_dir: Path) -> dict:
    """加载 Skill 配置、Persona 和记忆库"""
    result = {
        "config": {},
        "persona": "",
        "memories": "",
    }

    config_file = skill_dir / "config.yaml"
    if config_file.exists():
        text = config_file.read_text(encoding="utf-8")
        lines = [l for l in text.split("\n") if l.strip() and not l.strip().startswith("#")]
        raw = "\n".join(lines)

        name_match = re.search(r"name_zh:\s*(.+)", raw)
        desc_match = re.search(r"description:\s*(.+)", raw)
        prompt_match = re.search(r"system_prompt:\s*\|\s*\n(.+?)(?=\n\w|\Z)", raw, re.DOTALL)
        style_section = re.search(r"response_style:\s*\n((?:\s*-\s*.+\n?)+)", raw)

        result["config"]["name"] = name_match.group(1).strip() if name_match else "小佳"
        result["config"]["description"] = desc_match.group(1).strip() if desc_match else ""
        result["config"]["system_prompt"] = prompt_match.group(1).strip() if prompt_match else ""
        result["config"]["style"] = [l.strip().lstrip("- ").strip() for l in style_section.group(1).split("\n") if l.strip().lstrip("- ").strip()] if style_section else []

    persona_file = skill_dir / "persona.md"
    if persona_file.exists():
        result["persona"] = persona_file.read_text(encoding="utf-8")

    memory_file = skill_dir / "memories.md"
    if memory_file.exists():
        result["memories"] = memory_file.read_text(encoding="utf-8")

    return result


bot = WxClawBot()

chat_histories: dict[str, list[dict]] = {}


def get_history(user_id: str) -> list[dict]:
    if user_id not in chat_histories:
        chat_histories[user_id] = []
    return chat_histories[user_id]


def add_to_history(user_id: str, role: str, content: str):
    history = get_history(user_id)
    history.append({"role": role, "content": content})
    max_h = _get_max_history()
    if len(history) > max_h:
        chat_histories[user_id] = history[-max_h:]

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

TOOL_INSTRUCTION = build_tool_use_instruction()


def _build_system_prompt() -> str:
    skill_data = _get_skill_data()
    bot_name = _get_bot_name()
    return f"""你现在是「{bot_name}」，请完全按照以下 Persona 设定来回复。

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


def _build_full_prompt() -> str:
    return f"{_build_system_prompt()}\n{TOOL_INSTRUCTION}"


def parse_ai_response(text: str) -> tuple[str, str | None]:
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
    
    def _normalize(text: str) -> str:
        s = text.strip().lower()
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
                
                clean_line = re.sub(r"\s*(\[?(?:EMOJI|表情)[:：]?.*?\]?|【.*?】|\[.+?\]|📷?\s*[😊😂🥰😭😅💗🙄👀🎉❤️🔥✨]+)\s*", "", stripped).strip()
                
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
                trailing_kw = re.search(rf"\s*({'|'.join(emoji_keywords_lower)})\s*\]\s*$", stripped.lower())
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
                clean_line = re.sub(r"\s*(\[?(?:EMOJI|表情)[:：]?.*?\]?|【.*?】|\[.+?\]|📷?\s*[😊😂🥰😭😅💗🙄👀🎉❤️🔥✨]+)\s*", "", stripped).strip()
                
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
        import random as _random
        emoji_keyword = _random.choice(EMOJI_KEYWORDS[:10])
    
    reply_text = "\n".join(reply_lines).strip()
    
    if reply_text.endswith("[表情]") or reply_text.endswith("[EMOJI]"):
        reply_text = re.sub(r"\s*\[(?:EMOJI|表情)\]\s*$", "", reply_text).strip()
    
    return reply_text, emoji_keyword



def _generate_fallback_reply(msg_type: str, mode: str = "auto", custom_msg: str = "") -> str:
    """生成非文本消息的回复"""
    
    if mode == "custom" and custom_msg:
        return custom_msg
    
    simple_replies = {
        ("image", "picture", "emoji"): "该模型暂时识别不了图片",
        ("voice",): "该模型暂时识别不了语音",
        ("audio",): "该模型暂时识别不了音频",
        ("video", "video_file"): "该模型暂时识别不了视频",
        ("file",): "该模型暂时处理不了文件",
    }
    
    for types, reply in simple_replies.items():
        if msg_type in types:
            return reply
    
    return f"该模型暂时处理不了{msg_type}"


@bot.on_message
async def handle(msg):
    import logging
    _log = logging.getLogger("xiaoxinChatAI.main")

    cfg = _get_web_config()

    _skip_fallback = False
    
    if msg.msg_type == "voice":
        raw_text = getattr(msg, 'text', None) or ""
        placeholder_patterns = ["[语音]", "[voice]", "[音频]"]
        
        is_real_text = (
            raw_text.strip() and
            not any(p in raw_text for p in placeholder_patterns)
            and len(raw_text.strip()) > 2
        )
        
        if is_real_text:
            _log.info(f"[voice] 微信已转文字: {raw_text[:50]}...")
            _skip_fallback = True
        else:
            _log.info(f"[voice] 语音无文字内容(原始: {raw_text[:30]})，走fallback")
    
    if msg.msg_type != "text" and not _skip_fallback:
        _log.info(f"[msg] {msg.user_id}: 非文本消息类型: {msg.msg_type}")
        
        img_config = cfg.get("features", {}).get("image_handling", {})
        send_to_ai = img_config.get('send_to_ai', False)
        
        if send_to_ai:
            _log.info(f"[img] 模式: 发送给AI (send_to_ai=True)")
            
            msg_type_names = {
                "image": "图片", "picture": "图片", "emoji": "表情包/表情",
                "voice": "语音消息", "audio": "音频",
                "video": "视频", "video_file": "视频",
                "file": "文件",
            }
            type_name = msg_type_names.get(msg.msg_type, msg.msg_type)
            
            raw_data_str = ""
            try:
                import json as _json
                raw_data_str = _json.dumps(msg.raw, ensure_ascii=False, indent=2)
            except:
                raw_data_str = str(msg.raw)
            
            fake_text = f"[用户发送了{type_name}]\n原始数据: {raw_data_str[:500]}"
            
            _log.info(f"[img] 将{type_name}信息作为文本传给AI处理")
            
            msg.text = fake_text
            
        else:
            _log.info(f"[img] 模式: 友好回复 (send_to_ai=False)")
            
            fallback_mode = img_config.get('fallback_reply', 'auto')
            custom_msg = img_config.get('unsupported_model_msg', '')
            
            image_reply = _generate_fallback_reply(
                msg.msg_type,
                mode=fallback_mode,
                custom_msg=custom_msg
            )
            
            if image_reply:
                try:
                    await bot.reply(msg, image_reply)
                    _log.info(f"[img] 已回复友好提示")
                except Exception as e:
                    _log.error(f"[img] 回复失败: {e}")
            
            return

    if not msg.text or not msg.text.strip():
        _log.info(f"[msg] {msg.user_id}: 空文本消息，忽略")
        return

    _log.info(f"[msg] {msg.user_id}: {msg.text[:50]}")

    import time as _time
    _last_active_time[msg.user_id] = _time.time()

    await bot.show_typing(msg.user_id)

    try:
        add_to_history(msg.user_id, "user", msg.text)

        memory_cfg = cfg.get("memory", {})
        model_cfg = cfg.get("model", {})
        features_cfg = cfg.get("features", {})

        retrieved = memory_store.search(
            user_id=msg.user_id,
            query=msg.text,
            top_k=memory_cfg.get("retrieval_top_k", 5),
            min_score=memory_cfg.get("retrieval_min_score", 0.2),
        )

        system_content = _build_full_prompt()

        if retrieved:
            memory_context = format_retrieved_memories(retrieved)
            system_content = f"""{_build_full_prompt()}

{memory_context}

⚠️ 以上「相关记忆」仅供参考。如果与当前话题相关，你可以自然地引用或延续；如果不相关或用户没提到，直接忽略即可，不要强行提及。"""

            _log.info(f"[memory] 注入 {len(retrieved)} 条参考记忆 (AI自行决定是否使用)")

        messages = [
            {"role": "system", "content": system_content},
            *get_history(msg.user_id),
        ]

        completion = await _get_llm().chat.completions.create(
            model=model_cfg.get("name", "deepseek-chat"),
            messages=messages,
            tools=TOOL_DEFINITIONS,
            temperature=cfg.get("system", {}).get("temperature", 0.7),
        )
        
        choice = completion.choices[0]
        response_message = choice.message
        
        tool_calls = getattr(response_message, 'tool_calls', None)
        
        if tool_calls:
            _log.info(f"[tool] AI 请求调用 {len(tool_calls)} 个工具")
            
            messages.append(response_message.model_dump())
            
            for tool_call in tool_calls:
                fn_name = tool_call.function.name
                fn_args = json.loads(tool_call.function.arguments)
                
                _log.info(f"[tool] 执行: {fn_name}({fn_args})")
                
                tool_result = await execute_tool_call(fn_name, fn_args)
                
                _log.info(f"[tool] {fn_name} 结果: {str(tool_result)[:100]}...")
                
                messages.append({
                    "role": "tool",
                    "tool_call_id": tool_call.id,
                    "content": str(tool_result),
                })
            
            _log.info(f"[tool] 将工具结果传回 AI 生成最终回复...")

            cfg_model = model_cfg.get("name", "deepseek-chat")
            cfg_temp = cfg.get("system", {}).get("temperature", 0.7)

            final_completion = await _get_llm().chat.completions.create(
                model=cfg_model,
                messages=messages,
                tools=TOOL_DEFINITIONS,
                temperature=cfg_temp,
            )
            
            raw_reply = final_completion.choices[0].message.content or ""
            
            if final_completion.choices[0].message.tool_calls:
                _log.warning("[tool] AI 再次请求工具调用，忽略并使用当前结果")
                for tc in final_completion.choices[0].message.tool_calls:
                    result = await execute_tool_call(tc.function.name, json.loads(tc.function.arguments))
                    raw_reply += f"\n\n[{tc.function.name}]: {result}"
        else:
            raw_reply = response_message.content or ""

        ai_reply, emoji_keyword = parse_ai_response(raw_reply)

        if ai_reply:

            add_to_history(msg.user_id, "assistant", ai_reply)

            if should_store_memory(msg.text, role="user"):
                memory_store.add(
                    user_id=msg.user_id,
                    content=msg.text,
                    role="user",
                    context_summary="用户消息",
                )
            if should_store_memory(ai_reply, role="assistant"):
                memory_store.add(
                    user_id=msg.user_id,
                    content=ai_reply,
                    role="assistant",
                    context_summary=f"{_get_bot_name()}的回复",
                )
        
        _log.info(f"[ai] reply: {ai_reply[:80]}... | emoji: {emoji_keyword} | history_len={len(get_history(msg.user_id))}")
        if ai_reply:
            cleaned_reply = ai_reply.replace('\r\n', '\n').replace('\r', '\n')

            cleaned_reply = re.sub(r'\n?-{3,}\n?', '\n', cleaned_reply)
            cleaned_reply = re.sub(r'\n?—{3,}\n?', '\n', cleaned_reply)

            lines = [l.rstrip() for l in cleaned_reply.split('\n') if l.strip()]
            if len(lines) <= 1:
                send_text = ai_reply
            else:
                send_text = ' '.join(l.strip() for l in lines)

            parts = [p.strip() for p in send_text.split(' ') if p.strip()]
            parts = [p for p in parts if not re.match(r'^[-—]{3,}$', p)]
            parts = [p for p in parts if len(p) > 1 or any('\u4e00' <= c <= '\u9fff' for c in p)]

            if len(parts) > 1:
                max_parts = min(len(parts), features_cfg.get("max_messages", 3))
                parts = parts[:max_parts]
                _log.info(f"[multi] 按空格分割为 {max_parts} 条消息发送")
                for idx, part in enumerate(parts):
                    await bot.reply(msg, part)
                    _log.info(f"[multi] 第{idx+1}/{max_parts}条已发送")
                    if idx < len(parts) - 1:
                        await asyncio.sleep(0.8)
            else:
                await bot.reply(msg, send_text)

        if emoji_keyword:
            emoji_cfg = features_cfg
            if not emoji_cfg.get("emoji", True):
                _log.info(f"[emoji] - 功能已禁用")
            else:
                roll = random.random()
                _log.info(f"[emoji] keyword={emoji_keyword} | roll={roll:.2f}")

                emoji_prob = emoji_cfg.get("emoji_probability", 0.5)

                if roll < emoji_prob:
                    _log.info(f"[emoji] >>> 发送表情包 [{emoji_keyword}]... (prob={emoji_prob})")
                    emoji_api = emoji_cfg.get("emoji_api", {})
                    url = await bot.reply_emoji(
                        msg,
                        keyword=emoji_keyword,
                        api_id=emoji_api.get("api_id"),
                        api_key=emoji_api.get("api_key"),
                        api_url=emoji_api.get("api_url"),
                    )
                    if url:
                        _log.info(f"[emoji] ✓ 成功: {url[:60]}...")
                    else:
                        _log.warning(f"[emoji] ✗ 失败 (API返回空)")
                else:
                    _log.info(f"[emoji] - 跳过 (prob={emoji_prob})")

    except Exception as e:
        _log.error(f"[error] {type(e).__name__}: {e}")

        try:
            await bot.reply(msg, f"抱歉，处理出错: {e}")
        except Exception:
            pass

    finally:
        await bot.hide_typing(msg.user_id)


@bot.on_message
async def log_handler(msg):
    logger.info(f"[log] {msg.user_id} | {msg.msg_type} | {msg.text[:30]}")


async def _proactive_checker():
    """后台任务：定时检查所有用户，超过最大空闲时间则主动发消息"""
    import time as _time
    _log = logging.getLogger("xiaoxinChatAI.main")

    while True:
        try:
            proactive_cfg = _get_web_config().get("features", {}).get("proactive_message", {})
            check_interval = proactive_cfg.get("interval_minutes", 30) * 60
            await asyncio.sleep(check_interval)
            now = _time.time()
            if not proactive_cfg.get("enabled", False):
                continue

            max_idle = proactive_cfg.get("max_idle_minutes", 120) * 60
            probability = proactive_cfg.get("probability", 0.3)

            for user_id, last_time in list(_last_active_time.items()):
                idle_seconds = now - last_time
                if idle_seconds < max_idle:
                    continue
                if random.random() > probability:
                    continue

                _log.info(f"[proactive] 用户 {user_id} 已空闲 {idle_seconds/60:.0f} 分钟，触发主动消息")

                try:
                    history = get_history(user_id)
                    recent = "\n".join(
                        f"{'用户' if m['role'] == 'user' else _get_bot_name()}: {m['content'][:100]}"
                        for m in history[-4:]
                    )

                    proactive_prompt = f"""你正在主动找用户聊天，根据以下最近的聊天记录，自然延续对话：

最近聊天：
{recent or '（暂无历史）'}

请发送一条简短、自然的开场消息（20字以内），用{_get_bot_name()}的口吻：
- 延续上次话题或简单问候
- 口语化，带点小佳的俏皮
- 不要加 [EMOJI] 标记"""

                    messages = [
                        {"role": "system", "content": _build_system_prompt()},
                        {"role": "user", "content": proactive_prompt},
                    ]

                    completion = await _get_llm().chat.completions.create(
                        model=_get_web_config().get("model", {}).get("name", "deepseek-chat"),
                        messages=messages,
                        temperature=_get_web_config().get("system", {}).get("temperature", 0.7),
                    )

                    raw_reply = completion.choices[0].message.content or ""
                    reply_text = re.sub(r"\s*\[(?:EMOJI|表情)[:：]?.*?\]\s*", "", raw_reply).strip()
                    reply_text = re.split(r"\n---\n|\n---$", reply_text)[0].strip()

                    if reply_text:
                        await bot.send(user_id, reply_text)
                        _log.info(f"[proactive] ✓ 已发送给 {user_id}: {reply_text[:50]}...")

                        add_to_history(user_id, "assistant", reply_text)
                        if should_store_memory(reply_text, role="assistant"):
                            memory_store.add(
                                user_id=user_id,
                                content=reply_text,
                                role="assistant",
                                context_summary="[主动消息] 开场",
                            )
                        _last_active_time[user_id] = _time.time()

                except Exception as ue:
                    _log.warning(f"[proactive] 发送失败 ({user_id}): {ue}")

        except Exception as e:
            _log.error(f"[proactive] 检查任务异常: {e}")
            await asyncio.sleep(60)


if __name__ == "__main__":
    bot_name = _get_bot_name()
    skill_path = _get_web_config().get("skill", {}).get("path", "?")
    print("=" * 50)
    print(f"  xiaoxinChatAI - {bot_name} AI 微信机器人")
    print(f"  Skill: {Path(skill_path).name if skill_path else '?'}")
    print("=" * 50)

    ready, err_msg = _check_config_ready()
    if not ready:
        print(f"\n❌ 配置检查未通过: {err_msg}")
        print("请先配置好模型和 Skill 后再启动")
        sys.exit(1)

    bot.login()
    print(f"\n[{bot_name}] 已上线!\n")

    import threading
    _proactive_thread = threading.Thread(
        target=lambda: asyncio.run(_proactive_checker()),
        daemon=True,
    )
    _proactive_thread.start()

    bot.run()
