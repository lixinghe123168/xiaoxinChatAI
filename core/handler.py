"""统一消息处理核心 — CLI 和 GUI 共用"""
import json
import re
import time
import hashlib
import logging
from openai import AsyncOpenAI

from .config import load_config, get_model_name, get_temperature
from .session import add_to_history, get_chat_summary
from .skill import get_skill_data, get_bot_name
from .prompt import build_system_prompt_with_memory, parse_ai_response, EMOJI_KEYWORDS

from memory import memory_store, format_retrieved_memories, should_store_memory
from tools import TOOL_DEFINITIONS, execute_tool_call

logger = logging.getLogger("xiaoxinChatAI.core.handler")

_llm_cache = None
_llm_config_hash = None

_MESSAGE_DEDUPE_WINDOW = 10
_processed_messages: dict[str, float] = {}


def _get_llm() -> AsyncOpenAI:
    global _llm_cache, _llm_config_hash

    cfg = load_config()
    model_cfg = cfg.get("model", {})
    timeout = cfg.get("system", {}).get("timeout", 120)

    config_hash = hash((
        model_cfg.get("base_url"),
        model_cfg.get("api_key"),
        timeout,
    ))

    if _llm_cache is None or _llm_config_hash != config_hash:
        _llm_cache = AsyncOpenAI(
            base_url=model_cfg.get("base_url", "https://api.deepseek.com"),
            api_key=model_cfg.get("api_key", ""),
            timeout=timeout,
        )
        _llm_config_hash = config_hash

    return _llm_cache


def invalidate_llm_cache():
    global _llm_cache, _llm_config_hash
    _llm_cache = None
    _llm_config_hash = None


def is_duplicate_message(user_id: str, text: str) -> bool:
    msg_key = f"{user_id}:{hashlib.md5(text.encode()).hexdigest()[:8]}"
    current_time = time.time()

    if msg_key in _processed_messages:
        last_time = _processed_messages[msg_key]
        if current_time - last_time < _MESSAGE_DEDUPE_WINDOW:
            return True

    _processed_messages[msg_key] = current_time

    expired_keys = [
        k for k, t in _processed_messages.items()
        if current_time - t > _MESSAGE_DEDUPE_WINDOW * 2
    ]
    for k in expired_keys:
        del _processed_messages[k]

    return False


async def process_message(
    user_id: str,
    user_message: str,
    history: list[dict],
    include_emoji: bool = True,
) -> dict:
    """处理一条用户消息，返回 AI 回复

    Args:
        user_id: 用户标识
        user_message: 用户消息文本
        history: 当前对话历史（不含本条用户消息）
        include_emoji: 是否启用表情包规则

    Returns:
        {
            "reply": str,            # AI 回复文本
            "emoji_keyword": str|None,
            "used_memory": bool,
            "used_tool": bool,
            "latency_ms": int,
        }
    """
    start_time = time.time()
    cfg = load_config()
    skill_data = get_skill_data(cfg)
    bot_name = get_bot_name(skill_data)

    memory_cfg = cfg.get("memory", {})
    use_tools = cfg.get("tools", {}).get("web_search", True)

    # 1. 检索长期记忆
    retrieved = memory_store.search(
        user_id=user_id,
        query=user_message,
        top_k=memory_cfg.get("retrieval_top_k", 5),
        min_score=memory_cfg.get("retrieval_min_score", 0.2),
    )

    memory_context = ""
    if retrieved:
        memory_context = format_retrieved_memories(retrieved)
        logger.info(f"[memory] 注入 {len(retrieved)} 条参考记忆 (AI自行决定是否使用)")

    # 2. 构建 System Prompt
    system_content = build_system_prompt_with_memory(
        retrieved_memories=memory_context,
        chat_summary=get_chat_summary(user_id),
        skill_data=skill_data,
        bot_name=bot_name,
        cfg=cfg,
        include_emoji=include_emoji,
        include_tools=use_tools,
    )

    # 3. 构建消息
    messages = [
        {"role": "system", "content": system_content},
        *history,
        {"role": "user", "content": user_message},
    ]

    # 4. 调用 LLM
    tools = TOOL_DEFINITIONS if use_tools else None
    completion = await _get_llm().chat.completions.create(
        model=get_model_name(cfg),
        messages=messages,
        tools=tools,
        temperature=get_temperature(cfg),
    )

    choice = completion.choices[0]
    response_message = choice.message
    tool_calls = getattr(response_message, "tool_calls", None)
    used_tool = False

    # 5. 处理工具调用
    if tool_calls and use_tools:
        used_tool = True
        logger.info(f"[tool] AI 请求调用 {len(tool_calls)} 个工具")

        messages.append(response_message.model_dump())

        for tool_call in tool_calls:
            fn_name = tool_call.function.name
            fn_args = json.loads(tool_call.function.arguments)

            logger.info(f"[tool] 执行: {fn_name}({fn_args})")
            tool_result = await execute_tool_call(fn_name, fn_args)
            logger.info(f"[tool] {fn_name} 结果: {str(tool_result)[:100]}...")

            messages.append({
                "role": "tool",
                "tool_call_id": tool_call.id,
                "content": str(tool_result),
            })

        logger.info("[tool] 将工具结果传回 AI 生成最终回复...")

        final_completion = await _get_llm().chat.completions.create(
            model=get_model_name(cfg),
            messages=messages,
            tools=TOOL_DEFINITIONS,
            temperature=get_temperature(cfg),
        )

        raw_reply = final_completion.choices[0].message.content or ""

        if final_completion.choices[0].message.tool_calls:
            logger.warning("[tool] AI 再次请求工具调用，忽略并使用当前结果")
            for tc in final_completion.choices[0].message.tool_calls:
                result = await execute_tool_call(
                    tc.function.name,
                    json.loads(tc.function.arguments),
                )
                raw_reply += f"\n\n[{tc.function.name}]: {result}"
    else:
        raw_reply = response_message.content or ""

    # 6. 解析回复
    ai_reply, emoji_keyword = parse_ai_response(raw_reply)
    latency_ms = int((time.time() - start_time) * 1000)

    return {
        "reply": ai_reply or "（无回复）",
        "emoji_keyword": emoji_keyword,
        "used_memory": bool(retrieved),
        "used_tool": used_tool,
        "latency_ms": latency_ms,
        "history_len": len(history) + 1,
    }


def store_messages_to_memory(
    user_id: str,
    user_text: str,
    ai_reply: str,
    bot_name: str,
):
    """将有价值消息存入长期记忆"""
    if should_store_memory(user_text, role="user"):
        memory_store.add(
            user_id=user_id,
            content=user_text,
            role="user",
            context_summary="用户消息",
        )
    if should_store_memory(ai_reply, role="assistant"):
        memory_store.add(
            user_id=user_id,
            content=ai_reply,
            role="assistant",
            context_summary=f"{bot_name}的回复",
        )


def clean_reply_for_sending(reply: str) -> list[str]:
    """清洗回复文本，返回按空格拆分的多条消息"""
    cleaned = reply.replace("\r\n", "\n").replace("\r", "\n")
    cleaned = re.sub(r"\n?-{3,}\n?", "\n", cleaned)
    cleaned = re.sub(r"\n?—{3,}\n?", "\n", cleaned)

    lines = [l.rstrip() for l in cleaned.split("\n") if l.strip()]
    if len(lines) <= 1:
        send_text = reply
    else:
        send_text = " ".join(l.strip() for l in lines)

    parts = [p.strip() for p in send_text.split(" ") if p.strip()]
    parts = [p for p in parts if not re.match(r"^[-—]{3,}$", p)]
    parts = [p for p in parts if len(p) > 1 or any("\u4e00" <= c <= "\u9fff" for c in p)]

    return parts