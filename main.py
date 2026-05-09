"""
xiaoxinChatAI 主程序 — 微信机器人入口

AI 微信机器人 - persona + 智能表情包
"""
import logging
import sys
import re
import json
import random
import asyncio
import time
import os
from pathlib import Path
from clawpy import WxClawBot

from core.config import load_config, save_config, check_config_ready
from core.session import (
    chat_histories,
    chat_summaries,
    get_history,
    add_to_history,
    get_chat_summary,
    clear_user_history,
)
from core.skill import load_skill, get_skill_data, get_bot_name
from core.prompt import parse_ai_response, EMOJI_KEYWORDS
from core.handler import (
    process_message,
    store_messages_to_memory,
    clean_reply_for_sending,
    is_duplicate_message,
    invalidate_llm_cache,
    _get_llm,
)
from memory import memory_store, should_store_memory

os.environ["NO_PROXY"] = "http://127.0.0.1:,localhost"

_last_active_time: dict[str, float] = {}


def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] [%(levelname)-5s] [%(name)s] %(message)s",
        datefmt="%H:%M:%S",
        handlers=[logging.StreamHandler(sys.stdout)],
    )


setup_logging()
logger = logging.getLogger("xiaoxinChatAI.main")

bot = WxClawBot()


def _generate_fallback_reply(msg_type: str, mode: str = "auto", custom_msg: str = "") -> str:
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
    _log = logging.getLogger("xiaoxinChatAI.main")
    cfg = load_config()

    _skip_fallback = False

    if msg.msg_type == "voice":
        raw_text = getattr(msg, "text", None) or ""
        placeholder_patterns = ["[语音]", "[voice]", "[音频]"]

        is_real_text = (
            raw_text.strip()
            and not any(p in raw_text for p in placeholder_patterns)
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
        send_to_ai = img_config.get("send_to_ai", False)

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
                raw_data_str = json.dumps(msg.raw, ensure_ascii=False, indent=2)
            except Exception:
                raw_data_str = str(msg.raw)

            msg.text = f"[用户发送了{type_name}]\n原始数据: {raw_data_str[:500]}"
            _log.info(f"[img] 将{type_name}信息作为文本传给AI处理")
        else:
            _log.info(f"[img] 模式: 友好回复 (send_to_ai=False)")

            fallback_mode = img_config.get("fallback_reply", "auto")
            custom_msg = img_config.get("unsupported_model_msg", "")

            image_reply = _generate_fallback_reply(
                msg.msg_type, mode=fallback_mode, custom_msg=custom_msg
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

    if is_duplicate_message(msg.user_id, msg.text):
        _log.info(f"[msg] {msg.user_id}: 检测到重复消息，忽略: {msg.text[:30]}...")
        return

    _log.info(f"[msg] {msg.user_id}: {msg.text[:50]}")

    _last_active_time[msg.user_id] = time.time()

    await bot.show_typing(msg.user_id)

    try:
        add_to_history(msg.user_id, "user", msg.text)
        history = get_history(msg.user_id)

        result = await process_message(
            user_id=msg.user_id,
            user_message=msg.text,
            history=history[:-1] if history else [],
            include_emoji=True,
        )

        ai_reply = result["reply"]
        emoji_keyword = result["emoji_keyword"]

        if ai_reply:
            add_to_history(msg.user_id, "assistant", ai_reply)
            store_messages_to_memory(
                msg.user_id, msg.text, ai_reply, get_bot_name(get_skill_data(cfg))
            )

        _log.info(
            f"[ai] reply: {ai_reply[:80]}... | emoji: {emoji_keyword} | history_len={len(get_history(msg.user_id))}"
        )

        # 微信特有的多段消息发送
        if ai_reply:
            parts = clean_reply_for_sending(ai_reply)
            features_cfg = cfg.get("features", {})

            if len(parts) > 1:
                max_parts = min(len(parts), features_cfg.get("max_messages", 10))
                send_parts = parts[:max_parts]
                _log.info(f"[multi] 按空格分割为 {len(send_parts)} 条消息发送 (共{len(parts)}部分)")

                for idx, part in enumerate(send_parts):
                    retry_count = 0
                    max_retries = 3

                    while retry_count < max_retries:
                        try:
                            await bot.reply(msg, part)
                            _log.info(f"[multi] 第{idx+1}/{len(send_parts)}条已发送: {part[:30]}...")
                            break
                        except Exception as e:
                            retry_count += 1
                            if retry_count < max_retries:
                                _log.warning(f"[multi] 第{idx+1}条发送失败，第{retry_count}次重试: {e}")
                                await asyncio.sleep(retry_count * 2)
                            else:
                                _log.error(f"[multi] 第{idx+1}条发送失败，已达最大重试次数")

                    if idx < len(send_parts) - 1:
                        await asyncio.sleep(2)

                if len(parts) > max_parts:
                    try:
                        await bot.reply(msg, "... (消息过长，已截断显示)")
                        _log.info(f"[multi] 已发送截断提示 (原{len(parts)}条，发送{max_parts}条)")
                    except Exception as e:
                        _log.warning(f"[multi] 截断提示发送失败: {e}")
            else:
                await bot.reply(msg, parts[0] if parts else ai_reply)

        # 表情包发送
        if emoji_keyword:
            emoji_cfg = features_cfg
            if not emoji_cfg.get("emoji", True):
                _log.info("[emoji] - 功能已禁用")
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
                        _log.info(f"[emoji] OK: {url[:60]}...")
                    else:
                        _log.warning("[emoji] FAIL (API返回空)")
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
    _log = logging.getLogger("xiaoxinChatAI.main")

    while True:
        try:
            proactive_cfg = load_config().get("features", {}).get("proactive_message", {})

            if not proactive_cfg.get("enabled", False):
                await asyncio.sleep(60)
                continue

            check_interval = proactive_cfg.get("interval_minutes", 30) * 60
            await asyncio.sleep(check_interval)
            now = time.time()

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
                        f"{'用户' if m['role'] == 'user' else get_bot_name(get_skill_data(load_config()))}: {m['content'][:100]}"
                        for m in history[-4:]
                    )

                    cfg = load_config()
                    bot_name = get_bot_name(get_skill_data(cfg))
                    skill_data = get_skill_data(cfg)

                    proactive_prompt = f"""你正在主动找用户聊天，根据以下最近的聊天记录，自然延续对话：

最近聊天：
{recent or '（暂无历史）'}

请发送一条简短、自然的开场消息（20字以内），用{bot_name}的口吻：
- 延续上次话题或简单问候
- 口语化，带点{bot_name}的俏皮
- 不要加 [EMOJI] 标记"""

                    system_prompt = ""
                    if skill_data.get("config", {}).get("system_prompt"):
                        system_prompt = f"""你现在是「{bot_name}」，请完全按照以下 Persona 设定来回复。

## 你的身份设定

{skill_data['config']['system_prompt']}

{skill_data['persona']}
"""

                    messages = [
                        {"role": "system", "content": system_prompt} if system_prompt else None,
                        {"role": "user", "content": proactive_prompt},
                    ]
                    messages = [m for m in messages if m is not None]

                    completion = await _get_llm().chat.completions.create(
                        model=cfg.get("model", {}).get("name", "deepseek-chat"),
                        messages=messages,
                        temperature=cfg.get("system", {}).get("temperature", 0.7),
                    )

                    raw_reply = completion.choices[0].message.content or ""
                    reply_text = re.sub(r"\s*\[(?:EMOJI|表情)[:：]?.*?\]\s*", "", raw_reply).strip()
                    reply_text = re.split(r"\n---\n|\n---$", reply_text)[0].strip()

                    if reply_text:
                        await bot.send(user_id, reply_text)
                        _log.info(f"[proactive] OK 已发送给 {user_id}: {reply_text[:50]}...")

                        add_to_history(user_id, "assistant", reply_text)
                        if should_store_memory(reply_text, role="assistant"):
                            memory_store.add(
                                user_id=user_id,
                                content=reply_text,
                                role="assistant",
                                context_summary="[主动消息] 开场",
                            )
                        _last_active_time[user_id] = time.time()

                except Exception as ue:
                    _log.warning(f"[proactive] 发送失败 ({user_id}): {ue}")

        except Exception as e:
            _log.error(f"[proactive] 检查任务异常: {e}")
            await asyncio.sleep(60)


if __name__ == "__main__":
    bot_name = get_bot_name(get_skill_data(load_config()))
    skill_path = load_config().get("skill", {}).get("path", "?")
    print("=" * 50)
    print(f"  xiaoxinChatAI - {bot_name} AI 微信机器人")
    print(f"  Skill: {Path(skill_path).name if skill_path else '?'}")
    print("=" * 50)

    ready, err_msg = check_config_ready()
    if not ready:
        print(f"\n配置检查未通过: {err_msg}")
        print("请先配置好模型和 Skill 后再启动")
        sys.exit(1)

    bot.login()
    print(f"\n[{bot_name}] 已上线!\n")

    async def async_main():
        bot._stopped = False
        await asyncio.gather(
            bot._run_loop(),
            _proactive_checker(),
        )

    try:
        asyncio.run(async_main())
    except KeyboardInterrupt:
        print("\n[bot] 用户退出，正在停止...")
        bot.stop()
    except Exception as e:
        print(f"\n[bot] 异常退出: {e}")
        logger.error(f"Fatal error: {e}", exc_info=True)