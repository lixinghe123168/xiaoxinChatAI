"""
xiaoxinChatAI Web 管理界面 - Streamlit 版本

功能:
- 实时聊天测试
- 模型配置 (名称/API Key/地址)
- Skill 人设选择
- 记忆系统配置 (短期/长期)
- 联网搜索开关
- 表情包/文件/视频回复配置
- 对话历史查看
- 记忆库管理

启动方式:
    streamlit run web_ui.py
    
访问: http://localhost:8501
"""

import sys
import os
import json
import re
import asyncio
from pathlib import Path
from datetime import datetime

import streamlit as st

sys.path.insert(0, str(Path(__file__).parent))

from core.config import load_config, save_config, CONFIG_FILE, get_model_name, get_temperature
from core.session import (
    chat_histories,
    chat_summaries,
    get_history,
    add_to_history,
    get_chat_summary,
    clear_user_history,
)
from core.skill import load_skill, get_skill_data, get_bot_name
from core.prompt import EMOJI_KEYWORDS, parse_ai_response
from core.handler import (
    process_message as core_process_message,
    store_messages_to_memory,
    is_duplicate_message,
    _get_llm,
)

from memory import memory_store, LongTermMemory, format_retrieved_memories, should_store_memory
from tools import TOOL_DEFINITIONS, execute_tool_call, web_search, get_weather, get_news
import aiohttp


async def fetch_emoji_image(keyword: str, config: dict) -> str | None:
    """调用表情包 API 获取图片 URL
    
    Args:
        keyword: 表情包关键词
        config: Web UI 配置（包含 emoji_api）
        
    Returns:
        图片 URL，失败返回 None
    """
    emoji_api = config.get('features', {}).get('emoji_api', {})
    api_id = emoji_api.get('api_id', '')
    api_key = emoji_api.get('api_key', '')
    api_url = emoji_api.get('api_url', '')

    if not api_id or not api_key or not api_url:
        return None
    
    params = {
        "id": api_id,
        "key": api_key,
        "limit": 1,
        "words": keyword,
    }
    
    try:
        import json as _json
        
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10)) as session:
            async with session.get(api_url, params=params) as resp:
                text = await resp.text()
                
                if not text or not text.strip():
                    return None
                
                data = _json.loads(text)
                
                if data.get("code") == 200 or data.get("data"):
                    images = data.get("data", [])
                    if images and len(images) > 0:
                        img_url = images[0] if isinstance(images[0], str) else images[0].get("url", "")
                        if img_url:
                            return img_url
        return None
    except _json.JSONDecodeError as e:
        logger.warning(f"[emoji_api] JSON解析失败: {e}, 响应: {text[:100] if 'text' in dir() else 'N/A'}")
        return None
    except Exception as e:
        logger.warning(f"[emoji_api] 获取失败: {e}")
        return None


def split_long_message(text: str, max_length: int = 1500) -> list[str]:
    """拆分长消息为多条
    
    Args:
        text: 原始消息文本
        max_length: 每条消息最大长度（微信限制约 4096 字符，留余量）
        
    Returns:
        拆分后的消息列表
    """
    if len(text) <= max_length:
        return [text]
    
    parts = []
    remaining = text
    
    while len(remaining) > 0:
        if len(remaining) <= max_length:
            parts.append(remaining)
            break
        
        split_pos = max_length
        
        last_newline = remaining.rfind('\n', 0, max_length)
        last_period = remaining.rfind('。', 0, max_length)
        last_comma = remaining.rfind('，', 0, max_length)
        last_space = remaining.rfind(' ', 0, max_length)
        
        for pos in [last_newline, last_period, last_comma, last_space]:
            if pos > max_length * 0.5:
                split_pos = pos + 1
                break
        
        parts.append(remaining[:split_pos].rstrip())
        remaining = remaining[split_pos:].lstrip()
    
    return parts


PROJECT_ROOT = Path(__file__).parent


def init_session_state():
    """初始化 Session State"""
    if 'config' not in st.session_state:
        st.session_state.config = load_config()
    
    if 'messages' not in st.session_state:
        st.session_state.messages = []
    
    if 'user_id' not in st.session_state:
        st.session_state.user_id = f"web_user_{datetime.now().strftime('%Y%m%d%H%M%S')}"
    
    if 'llm' not in st.session_state:
        st.session_state.llm = _get_llm()
    
    if 'skill_data' not in st.session_state:
        skill_path = st.session_state.config['skill']['path']
        if skill_path and Path(skill_path).exists():
            st.session_state.skill_data = load_skill(Path(skill_path))
        else:
            st.session_state.skill_data = {"config": {}, "persona": "", "memories": ""}


from core.prompt import build_system_prompt

def rebuild_system_prompt() -> str:
    """根据当前配置重新构建 System Prompt（Streamlit 适配）"""
    config = st.session_state.config
    return build_system_prompt(
        skill_data=st.session_state.skill_data,
        bot_name=get_bot_name(st.session_state.skill_data),
        cfg=config,
        include_emoji=config['features']['emoji'],
        include_tools=config['tools']['web_search'],
    )


async def process_message(user_message: str) -> dict:
    """处理用户消息 — Streamlit 适配层（核心逻辑委托给 core.handler）"""
    import random
    config = st.session_state.config
    user_id = st.session_state.user_id
    
    start_time = datetime.now()
    
    add_to_history(user_id, "user", user_message)
    history = get_history(user_id)
    
    result = await core_process_message(
        user_id=user_id,
        user_message=user_message,
        history=history[:-1] if history else [],
        include_emoji=config['features']['emoji'],
    )
    
    ai_reply = result["reply"]
    emoji_keyword = result["emoji_keyword"]
    
    if ai_reply:
        add_to_history(user_id, "assistant", ai_reply)
        
        if config['memory']['long_term_enabled']:
            store_messages_to_memory(
                user_id, user_message, ai_reply, get_bot_name(st.session_state.skill_data)
            )
    
    latency = (datetime.now() - start_time).total_seconds() * 1000
    
    emoji_image_url = None
    if emoji_keyword and config['features'].get('emoji', False):
        emoji_roll = random.random()
        if emoji_roll < config['features'].get('emoji_probability', 0.5):
            emoji_image_url = await fetch_emoji_image(emoji_keyword, config)
            if emoji_image_url:
                logger.info(f"[emoji] 获取图片成功: {emoji_image_url[:60]}...")
            else:
                logger.info(f"[emoji] 未获取到图片 (keyword={emoji_keyword})")
    
    reply_parts = split_long_message(ai_reply or "\uff08\u65e0\u56de\u590d\uff09")
    is_split = len(reply_parts) > 1
    
    return {
        "reply": ai_reply or "\uff08\u65e0\u56de\u590d\uff09",
        "reply_parts": reply_parts,
        "is_split": is_split,
        "emoji_keyword": emoji_keyword,
        "emoji_image_url": emoji_image_url,
        "history_len": result.get("history_len", len(get_history(user_id))),
        "used_memory": result.get("used_memory", False),
        "used_tool": result.get("used_tool", False),
        "latency_ms": int(latency),
        "model": config['model']['name'],
    }


async def generate_proactive_message(user_id: str, config: dict) -> dict | None:
    """生成主动消息
    
    Args:
        user_id: 用户 ID
        config: 配置
        
    Returns:
        主动消息结果，或 None（不发送）
    """
    proactive_config = config.get('features', {}).get('proactive_message', {})
    
    if not proactive_config.get('enabled', False):
        return None
    
    history = get_history(user_id)
    if not history:
        return None
    
    last_user_idx = -1
    
    for i in range(len(history) - 1, -1, -1):
        if history[i].get('role') == 'user':
            last_user_idx = i
            break
    
    if last_user_idx < 0:
        return None
    
    import random as _random
    prob_roll = _random.random()
    if prob_roll > proactive_config.get('probability', 0.3):
        return None
    
    styles = proactive_config.get('styles', ['延续上次话题', '询问近况'])
    selected_style = _random.choice(styles)
    
    style_prompts = {
        "延续上次话题": "延续我们上次聊的话题，自然地继续讨论，可以追问细节或分享你的想法",
        "询问近况": "关心用户最近在做什么，过得怎么样，有没有什么新鲜事",
        "分享日常": "分享一些日常琐事、心情、或者你正在做的事情，让对话更自然",
        "主动关心": "表达对用户的关心，比如提醒休息、喝水、注意身体等",
        "幽默调侃": "用轻松幽默的方式调侃一下，或者讲个笑话活跃气氛",
        "撒娇卖萌": "用撒娇、卖萌的语气，表达想念或者想要关注",
    }
    
    style_instruction = style_prompts.get(selected_style, style_prompts["延续上次话题"])
    
    recent_context = ""
    if len(history) >= 2:
        last_msgs = history[-4:]
        context_parts = []
        for msg in last_msgs:
            role_label = "用户" if msg['role'] == 'user' else get_bot_name(st.session_state.skill_data)
            context_parts.append(f"{role_label}: {msg['content'][:100]}")
        recent_context = "\n".join(context_parts)
    
    proactive_prompt = f"""现在是{get_bot_name(st.session_state.skill_data)}主动发起对话的时候。

**任务**: 用{selected_style}的方式，主动给用户发一条消息。

**风格要求**:
{style_instruction}

**注意事项**:
- 消息要简短、自然，像微信聊天一样
- 不要太长（1-3句话即可）
- 要符合{get_bot_name(st.session_state.skill_data)}的人设和语气
- 可以用表情符号增加亲切感
- 不要太刻意，要像随口说的一样

**最近的聊天上下文**:
{recent_context}

**请直接输出消息内容，不要加任何前缀或说明:**"""

    system_content = rebuild_system_prompt()
    
    messages = [
        {"role": "system", "content": system_content},
        *get_history(user_id)[-6:],
        {"role": "user", "content": proactive_prompt},
    ]
    
    try:
        llm = st.session_state.llm
        
        completion = await llm.chat.completions.create(
            model=config['model']['name'],
            messages=messages,
            max_tokens=300,
        )
        
        raw_reply = completion.choices[0].message.content or ""
        ai_reply, emoji_keyword = parse_ai_response(raw_reply)
        
        if not ai_reply or len(ai_reply.strip()) < 2:
            return None
        
        emoji_image_url = None
        if emoji_keyword and config['features'].get('emoji', False):
            emoji_roll = _random.random()
            if emoji_roll < config['features'].get('emoji_probability', 0.5):
                emoji_image_url = await fetch_emoji_image(emoji_keyword, config)
        
        add_to_history(user_id, "assistant", ai_reply)
        
        if should_store_memory(ai_reply, role="assistant"):
            memory_store.add(
                user_id=user_id,
                content=ai_reply,
                role="assistant",
                context_summary=f"[主动消息] {selected_style}",
            )
        
        reply_parts = split_long_message(ai_reply)
        
        return {
            "reply": ai_reply,
            "reply_parts": reply_parts,
            "is_split": len(reply_parts) > 1,
            "emoji_keyword": emoji_keyword,
            "emoji_image_url": emoji_image_url,
            "proactive": True,
            "proactive_style": selected_style,
            "latency_ms": 0,
            "used_memory": False,
            "used_tool": False,
            "history_len": len(get_history(user_id)),
            "model": config['model']['name'],
        }
        
    except Exception as e:
        logger.warning(f"[proactive] 生成失败: {e}")
        return None


def render_sidebar():
    """渲染侧边栏配置面板"""
    with st.sidebar:
        st.title("⚙️ xiaoxinChatAI 配置")
        
        config = st.session_state.config
        
        with st.expander("🤖 模型设置", expanded=True):
            col1, col2 = st.columns(2)
            with col1:
                new_model_name = st.text_input(
                    "模型名称",
                    value=config['model']['name'],
                    help="如: deepseek-chat, deepseek-reasoner, gpt-4o"
                )
            with col2:
                new_timeout = st.number_input(
                    "超时(秒)",
                    value=config['system']['timeout'],
                    min_value=30,
                    max_value=300
                )
            
            new_api_key = st.text_input(
                "API Key",
                value=config['model']['api_key'],
                type="password",
                help="DeepSeek/OpenAI API 密钥"
            )
            
            new_base_url = st.text_input(
                "API 地址",
                value=config['model']['base_url'],
                help="API Base URL"
            )
            
            new_temperature = st.slider(
                "Temperature",
                0.0, 2.0,
                config['system']['temperature'],
                0.1
            )
        
        with st.expander("📁 Skill 人设", expanded=True):
            # ===== 两阶段提交：解决 Streamlit widget session_state 不可变限制 =====
            # 阶段 1（rerun 后）：检测待处理的新路径，在 widget 创建前消费掉
            if st.session_state.get('_pending_skill_path'):
                pending = st.session_state.pop('_pending_skill_path')
                st.session_state['skill_path_input'] = pending
                st.session_state.selected_skill_path = pending
                config['skill']['path'] = pending
                if 'config' in st.session_state:
                    st.session_state.config['skill']['path'] = pending

                # 自动加载 Skill 数据
                if Path(pending).exists():
                    try:
                        st.session_state.skill_data = load_skill(Path(pending))
                        st.session_state.skill_loaded_success = True
                        st.session_state.skill_loaded_name = Path(pending).name
                    except Exception as e:
                        st.session_state.skill_loaded_success = False
                        st.session_state.skill_loaded_error = str(e)

            # 初始化默认值（仅首次）
            if 'skill_path_input' not in st.session_state:
                st.session_state.skill_path_input = config['skill']['path']
            if 'selected_skill_path' not in st.session_state:
                st.session_state.selected_skill_path = config['skill']['path']

            # text_input 由 session_state["skill_path_input"] 驱动
            new_skill_path = st.text_input(
                "Skill 目录路径",
                help="包含 config.yaml, persona.md, memories.md 的目录",
                key="skill_path_input"
            )

            # 用户手动编辑文本框时同步
            if new_skill_path != st.session_state.get('selected_skill_path', ''):
                st.session_state.selected_skill_path = new_skill_path
                config['skill']['path'] = new_skill_path

            col_browse_left, col_browse_right = st.columns([1, 3])

            with col_browse_left:
                if st.button("📂 选择文件夹", use_container_width=True, key="browse_folder_btn"):
                    try:
                        import tkinter as tk
                        from tkinter import filedialog

                        root = tk.Tk()
                        root.withdraw()
                        root.attributes('-topmost', True)

                        current_path = st.session_state.get('selected_skill_path', '')
                        initial_dir = current_path if current_path and Path(current_path).exists() else str(Path.home())

                        selected_path = filedialog.askdirectory(
                            title="选择 Skill 目录",
                            initialdir=initial_dir,
                            mustexist=False,
                        )

                        root.destroy()

                        if selected_path:
                            normalized_path = str(Path(selected_path).resolve())

                            # 阶段 2（当前 run）：存入临时变量，不直接改 widget key
                            st.session_state._pending_skill_path = normalized_path
                            st.rerun()

                    except Exception as e:
                        st.error(f"打开选择器失败: {e}")

            with col_browse_right:
                display_path = st.session_state.get('selected_skill_path', '')
                if display_path and Path(display_path).exists():
                    path_obj = Path(display_path)

                    if path_obj.is_dir():
                        items = list(path_obj.iterdir())
                        files_count = len(items)
                        has_config = any(i.name in ('config.yaml', 'config.yml') for i in items)
                        status_icon = "✅" if has_config else "⚠️"

                        if st.session_state.get('skill_loaded_success'):
                            st.success(f"✅ Skill 已加载: {st.session_state.get('skill_loaded_name', path_obj.name)}")
                            st.session_state.skill_loaded_success = False

                        st.caption(f"{status_icon} 已选中: `{path_obj.name}` ({files_count} 个项目)")
                    else:
                        st.caption(f"📄 文件: `{path_obj.name}`")
                elif display_path:
                    st.caption("❌ 路径不存在")
                else:
                    st.caption("💡 点击左侧按钮或手动输入路径")
            
            skill_enabled = st.checkbox(
                "启用 Skill 人设",
                value=config['skill']['enabled'],
                help="是否加载外部人设配置文件"
            )
            
            btn_col1, btn_col2, btn_col3 = st.columns(3)
            
            with btn_col1:
                if st.button("🔄 重新加载 Skill", use_container_width=True, key="reload_skill_btn"):
                    current_path = st.session_state.selected_skill_path
                    if current_path and Path(current_path).exists():
                        st.session_state.skill_data = load_skill(Path(current_path))
                        st.success(f"✅ Skill 加载成功! Bot: {st.session_state.skill_data.get('config', {}).get('name', '?')}")
                        st.rerun()
                    else:
                        st.error("❌ Skill 目录不存在")
            
            with btn_col2:
                if st.button("📋 打开文件夹", use_container_width=True, key="open_folder_btn"):
                    current_path = st.session_state.selected_skill_path
                    if current_path and Path(current_path).exists():
                        import subprocess
                        import platform
                        
                        path_to_open = Path(current_path)
                        if path_to_open.is_file():
                            path_to_open = path_to_open.parent
                        
                        try:
                            if platform.system() == "Windows":
                                os.startfile(str(path_to_open))
                            elif platform.system() == "Darwin":
                                subprocess.run(["open", str(path_to_open)])
                            else:
                                subprocess.run(["xdg-open", str(path_to_open)])
                            st.success("✅ 已打开文件夹")
                        except Exception as e:
                            st.error(f"打开失败: {e}")
                    else:
                        st.warning("请先输入有效路径")
            
            with btn_col3:
                if st.button("🗑️ 清除路径", use_container_width=True, key="clear_path_btn"):
                    st.session_state.selected_skill_path = ""
                    st.rerun()
        
        with st.expander("🧠 记忆系统", expanded=True):
            st.subheader("短期记忆")
            short_enabled = st.checkbox(
                "启用短期记忆",
                value=config['memory']['short_term_enabled'],
                help="在当前对话中记住之前的消息"
            )
            short_max = st.slider(
                "最大记忆轮数",
                5, 50,
                config['memory']['short_term_max'],
                5,
                help="保留最近的N轮对话"
            )
            
            st.subheader("长期记忆")
            long_enabled = st.checkbox(
                "启用长期记忆",
                value=config['memory']['long_term_enabled'],
                help="按关键词存储到本地文件，跨对话持久化"
            )
            long_max = st.number_input(
                "每用户最大记忆条数",
                value=config['memory']['long_term_max'],
                min_value=50,
                max_value=1000
            )
            expire_days = st.slider(
                "记忆过期天数",
                7, 365,
                config['memory']['expire_days'],
                7
            )
            
            st.markdown("---")
            st.markdown("**检索设置**")
            retrieval_top_k = st.slider(
                "检索返回条数",
                1, 10,
                config['memory'].get('retrieval_top_k', 5),
                1,
                help="每次从长期记忆中检索返回的相关记录条数"
            )
            retrieval_min_score = st.slider(
                "最低匹配分数",
                0.0, 1.0,
                config['memory'].get('retrieval_min_score', 0.2),
                0.05,
                help="低于此分数的记忆不会被检索到"
            )
        
        with st.expander("🔍 联网工具", expanded=True):
            web_search_enabled = st.checkbox(
                "🌐 联网搜索",
                value=config['tools']['web_search'],
                help="开启后AI可搜索网络获取最新信息（天气、新闻、网页等）"
            )
            
            search_source = st.selectbox(
                "📡 搜索源",
                options=["searxng", "bing", "duckduckgo"],
                index=["searxng", "bing", "duckduckgo"].index(config['tools'].get('web_search_source', 'searxng')),
                format_func=lambda x: {
                    "searxng": "🇨🇳 SearXNG（国内可用，推荐）",
                    "bing": "🇨🇳 必应搜索（国内可用）",
                    "duckduckgo": "🌍 DuckDuckGo（海外）",
                }.get(x, x),
                help="选择搜索后端（SearXNG = 聚合多个搜索引擎，国内推荐）"
            )
        
        with st.expander("✨ 功能开关", expanded=True):
            emoji_enabled = st.checkbox(
                "😊 表情包回复",
                value=config['features']['emoji'],
                help="AI 回复时附带表情包关键词"
            )
            
            if emoji_enabled:
                emoji_prob = st.slider(
                    "表情包发送概率",
                    0.0, 1.0,
                    config['features']['emoji_probability'],
                    0.1
                )
                
                st.markdown("---")
                st.markdown("**🔑 表情包 API 配置**")
                st.caption("配置后可根据关键词自动发送表情包图片/动图")
                
                emoji_api = config['features'].get('emoji_api', {})
                
                col_emoji_id, col_emoji_key = st.columns(2)
                
                with col_emoji_id:
                    emoji_api_id = st.text_input(
                        "API ID",
                        value=emoji_api.get('api_id', ''),
                        placeholder="输入你的 API ID",
                        help="表情包服务的应用 ID / App ID"
                    )
                
                with col_emoji_key:
                    emoji_api_key = st.text_input(
                        "API Key",
                        value=emoji_api.get('api_key', ''),
                        type="password",
                        placeholder="输入你的 API Key",
                        help="表情包服务的密钥"
                    )
                
                emoji_api_url = st.text_input(
                    "API 地址 (可选)",
                    value=emoji_api.get('api_url', ''),
                    placeholder="https://api.example.com/emoji",
                    help="自定义表情包 API 接口地址（留空使用默认）"
                )
                
                if emoji_api_id or emoji_api_key or emoji_api_url:
                    filled_count = sum(1 for x in [emoji_api_id, emoji_api_key, emoji_api_url] if x)
                    st.caption(f"📝 已填写 {filled_count}/3 项配置")
                else:
                    st.caption("💡 未配置 API 时，仅输出关键词文本（不发送图片）")
                    
            else:
                emoji_prob = 0.0
                emoji_api_id = ""
                emoji_api_key = ""
                emoji_api_url = ""
            
            file_reply = st.checkbox(
                "📎 文件回复",
                value=config['features']['file_reply'],
                disabled=True,
                help="SDK 已实现但本项目未集成该功能"
            )
            video_reply = st.checkbox(
                "🎬 视频回复",
                value=config['features']['video_reply'],
                disabled=True,
                help="SDK 已实现但本项目未集成该功能"
            )
            voice_reply = st.checkbox(
                "🎤 语音回复",
                value=config['features']['voice_reply'],
                disabled=True,
                help="微信官方尚未推出语音气泡功能，故未集成"
            )
            typing_ind = st.checkbox(
                "⌨️ 打字状态显示",
                value=config['features']['typing_indicator'],
                help="回复前显示\"对方正在输入...\""
            )
        
        st.markdown("---")
        st.markdown("**📷 图片/非文本消息处理**")
        st.caption("用户发送图片、语音、视频等时的处理方式")
        
        img_config = config['features'].get('image_handling', {})
        img_send_to_ai = st.checkbox(
            "📤 发送给 AI 模型",
            value=img_config.get('send_to_ai', False),
            help="开启后，图片/语音等信息会传给 AI 处理（需要模型支持多模态）"
        )

        img_fallback = img_config.get('fallback_reply', 'auto')
        img_custom_msg = img_config.get('unsupported_model_msg', '')

        if not img_send_to_ai:
            img_fallback = st.selectbox(
                "回复方式",
                options=["auto", "friendly", "custom"],
                index=["auto", "friendly", "custom"].index(img_config.get('fallback_reply', 'auto')) if img_config.get('fallback_reply', 'auto') in ["auto", "friendly", "custom"] else 0,
                help="当不发给AI时，如何回复用户"
            )
            
            if img_fallback == "auto":
                st.caption("💡 自动选择：随机从预设库中选一条友好回复")
            elif img_fallback == "friendly":
                st.caption("💬 友好模式：固定使用同一条温和的提示语")
            else:
                img_custom_msg = st.text_area(
                    "自定义回复内容",
                    value=img_config.get('unsupported_model_msg', '该模型暂时识别不了图片'),
                    height=80,
                    help="用户发图时回复的固定内容"
                )
        else:
            st.info("""
**注意事项**
- 开启后图片信息会作为文本传给模型
- 模型可能会"假装看到"或猜测图片内容
- 如果你的模型不能识别图片机器人会委婉提示你奥
            """, icon="⚠️")
        
        st.markdown("---")
        st.markdown("**💬 主动消息**")
        st.caption("AI 主动发起对话（延续话题/关心用户等）")
        
        proactive_config = config['features'].get('proactive_message', {})
        proactive_enabled = st.checkbox(
            "🤖 启用主动消息",
            value=proactive_config.get('enabled', False),
            help="开启后 AI 会定时主动找你聊天"
        )
        
        if proactive_enabled:
            col_int, col_idle = st.columns(2)
            with col_int:
                proactive_interval = st.number_input(
                    "发送间隔(分钟)",
                    value=proactive_config.get('interval_minutes', 30),
                    min_value=5,
                    max_value=120,
                    help="每隔多少分钟检查一次是否需要主动发消息"
                )
            
            with col_idle:
                proactive_max_idle = st.number_input(
                    "最大空闲时间(分钟)",
                    value=proactive_config.get('max_idle_minutes', 60),
                    min_value=10,
                    max_value=360,
                    help="超过这个时间没聊天，才会触发主动消息"
                )
            
            proactive_prob = st.slider(
                "触发概率",
                0.0, 1.0,
                proactive_config.get('probability', 0.3),
                0.1,
                help="即使满足条件，也只有一定概率会真正发送"
            )
            
            proactive_styles = proactive_config.get('styles', [
                "延续上次话题", "询问近况", "分享日常", "主动关心"
            ])
            selected_styles = st.multiselect(
                "消息风格",
                options=[
                    "延续上次话题", 
                    "询问近况", 
                    "分享日常", 
                    "主动关心",
                    "幽默调侃",
                    "撒娇卖萌",
                ],
                default=proactive_styles,
                help="选择 AI 主动消息时使用的风格"
            )
            
            if not selected_styles:
                st.warning("⚠️ 至少选择一种风格")
        else:
            proactive_interval = 30
            proactive_max_idle = 60
            proactive_prob = 0.3
            selected_styles = ["延续上次话题", "询问近况"]
        
        st.divider()
        
        col_save, col_reset = st.columns(2)
        with col_save:
            save_clicked = st.button("💾 保存配置", use_container_width=True, type="primary")
            
            if save_clicked:
                with st.spinner("⏳ 正在保存配置..."):
                    import time
                    time.sleep(0.3)
                
                config['model'] = {
                    "name": new_model_name,
                    "api_key": new_api_key,
                    "base_url": new_base_url,
                }
                config['system']['timeout'] = new_timeout
                config['system']['temperature'] = new_temperature
                config['skill']['path'] = st.session_state.selected_skill_path
                config['skill']['enabled'] = skill_enabled
                config['memory']['short_term_enabled'] = short_enabled
                config['memory']['short_term_max'] = int(short_max)
                config['memory']['long_term_enabled'] = long_enabled
                config['memory']['long_term_max'] = int(long_max)
                config['memory']['expire_days'] = int(expire_days)
                config['memory']['retrieval_top_k'] = int(retrieval_top_k)
                config['memory']['retrieval_min_score'] = float(retrieval_min_score)
                config['tools']['web_search'] = web_search_enabled
                config['tools']['web_search_source'] = search_source
                config['features']['emoji'] = emoji_enabled
                config['features']['emoji_probability'] = float(emoji_prob)
                config['features']['emoji_api'] = {
                    "api_id": emoji_api_id,
                    "api_key": emoji_api_key,
                    "api_url": emoji_api_url,
                }
                config['features']['file_reply'] = file_reply
                config['features']['video_reply'] = video_reply
                config['features']['voice_reply'] = voice_reply
                config['features']['typing_indicator'] = typing_ind
                config['features']['image_handling'] = {
                    "send_to_ai": img_send_to_ai,
                    "fallback_reply": img_fallback,
                    "unsupported_model_msg": img_custom_msg,
                }
                config['features']['proactive_message'] = {
                    "enabled": proactive_enabled,
                    "interval_minutes": int(proactive_interval),
                    "max_idle_minutes": int(proactive_max_idle),
                    "probability": float(proactive_prob),
                    "styles": selected_styles,
                }
                
                save_config(config)
                st.session_state.config = config
                
                skill_path = config['skill']['path']
                if skill_path and Path(skill_path).exists():
                    st.session_state.skill_data = load_skill(Path(skill_path))
                else:
                    st.session_state.skill_data = {"config": {}, "persona": "", "memories": ""}
                
                from openai import AsyncOpenAI
                st.session_state.llm = AsyncOpenAI(
                    base_url=new_base_url,
                    api_key=new_api_key,
                    timeout=new_timeout,
                )
                
                st.toast("✅ 配置已保存！", icon="💾")
                st.balloons()
                
                emoji_api_status = "未配置"
                if emoji_enabled and (emoji_api_id or emoji_api_key):
                    api_filled = sum(1 for x in [emoji_api_id, emoji_api_key, emoji_api_url] if x)
                    emoji_api_status = f"已配置 ({api_filled}/3)"
                elif not emoji_enabled:
                    emoji_api_status = "已禁用"
                
                st.success("""
                **✅ 保存成功！**
                
                - 🤖 模型: **{0}**  
                - 📁 Skill: **{1}**  
                - 🧠 记忆: 短期 **{2}** 轮 / 长期 **{3}** 条  
                - 🔍 联网搜索: **{4}**  
                - 😊 表情包: **{5}** (概率 **{6:.0%}**) | API: **{7}**  
                """.format(
                    new_model_name,
                    Path(st.session_state.selected_skill_path).name if st.session_state.selected_skill_path else "未设置",
                    int(short_max),
                    int(long_max),
                    "✅" if web_search_enabled else "❌",
                    "✅" if emoji_enabled else "❌",
                    float(emoji_prob) if emoji_enabled else 0,
                    emoji_api_status,
                ), icon="🎉")
                
                time.sleep(1.5)
                st.rerun()
        
        with col_reset:
            if st.button("🔄 重置默认", use_container_width=True):
                st.toast("⚠️ 正在重置...", icon="🔄")
                
                if CONFIG_FILE.exists():
                    CONFIG_FILE.unlink()
                    st.toast("🗑️ 已删除旧配置文件", icon="🗑️")
                
                st.session_state.config = load_config()
                st.session_state.selected_skill_path = st.session_state.config.get('skill', {}).get('path', '')
                
                st.warning("""
                **🔄 已重置为默认配置！**
                
                所有设置已恢复到初始状态，包括：
                - 模型参数
                - 记忆系统
                - 联网工具
                - 功能开关
                
                *如需恢复，请重新配置后点击「保存」*
                """, icon="⚡")
                
                import time
                time.sleep(2)
                st.rerun()
        
        st.divider()
        
        st.caption(f"📊 当前状态")
        st.metric("对话轮数", len(get_history(st.session_state.user_id)))
        
        mem_stats = memory_store.get_stats()
        st.metric("长期记忆", mem_stats.get('total_memories', 0))
        
        st.caption(f"🕐 启动时间: {datetime.now().strftime('%H:%M:%S')}")


def render_chat():
    """渲染主聊天区域"""
    config = st.session_state.config
    
    if 'wechat_connected' not in st.session_state:
        st.session_state.wechat_connected = False
    if 'wechat_bot_task' not in st.session_state:
        st.session_state.wechat_bot_task = None
    if 'last_message_time' not in st.session_state:
        st.session_state.last_message_time = datetime.now()
    if 'proactive_enabled' not in st.session_state:
        proactive_cfg = config.get('features', {}).get('proactive_message', {})
        st.session_state.proactive_enabled = proactive_cfg.get('enabled', False)
    
    st.markdown("""
    <style>
    .user-msg {
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%) !important;
        color: white !important;
    }
    .assistant-msg {
        background: #f0f2f5 !important;
    }
    .msg-meta {
        font-size: 11px !important;
        color: #888 !important;
        margin-top: 4px;
    }
    .emoji-tag {
        display: inline-block;
        background: linear-gradient(135deg, #ffecd2 0%, #fcb69f 100%);
        padding: 3px 10px;
        border-radius: 12px;
        font-size: 12px;
        margin-top: 6px;
        border: 1px solid rgba(252,182,159,0.5);
    }
    .stats-tag {
        display: inline-block;
        background: #f8f9fa;
        padding: 4px 10px;
        border-radius: 8px;
        font-size: 11px;
        color: #666;
        margin-top: 4px;
        border: 1px solid #eee;
    }
    </style>
    """, unsafe_allow_html=True)
    
    col_title, col_wechat = st.columns([3, 1])
    
    with col_title:
        st.title(f"💬 {get_bot_name(st.session_state.skill_data)} AI 聊天")
    
    with col_wechat:
        st.write("")
        
        if not st.session_state.wechat_connected:
            if st.button("📱 连接微信", use_container_width=True, type="primary"):
                from core.config import check_config_ready
                ready, err_msg = check_config_ready(override_cfg=config)
                if not ready:
                    st.error(f"❌ 配置未就绪，无法连接微信\n\n{err_msg}")
                else:
                    with st.spinner("🔄 正在启动微信机器人..."):
                        try:
                            from main import bot
                            from clawpy.auth import load_credentials
                            
                            existing_creds = load_credentials()
                            
                            if existing_creds is None:
                                st.session_state.show_qr = True
                                st.rerun()
                            else:
                                import threading
                                
                                def run_bot_in_thread():
                                    from main import bot
                                    bot.run()
                                
                                bot_thread = threading.Thread(
                                    target=run_bot_in_thread,
                                    daemon=True,
                                    name="xiaoxinChatAI_bot"
                                )
                                bot_thread.start()
                                
                                import time
                                time.sleep(2)
                                
                                st.session_state.wechat_bot_thread = bot_thread
                                st.session_state.wechat_connected = True
                                
                                st.toast("✅ 微信已连接！", icon="📱")
                                st.balloons()
                                st.rerun()
                        except Exception as e:
                            st.error(f"❌ 连接失败: {e}")
        
        if st.session_state.get('show_qr', False):
            st.markdown("""
            <div style="
                text-align: center;
                padding: 40px 20px;
                background: linear-gradient(135deg, #667eea10 0%, #764ba210 100%);
                border-radius: 16px;
                border: 2px solid #667eea30;
                margin: 20px 0;
            ">
                <h3 style="margin: 0 0 20px 0;">📱 微信扫码登录</h3>
                <p style="color: #666; margin-bottom: 20px;">
                    请使用 <b>微信扫一扫</b> 下方二维码完成登录
                </p>
            </div>
            """, unsafe_allow_html=True)
            
            qr_placeholder = st.empty()
            
            with qr_placeholder:
                st.info("⏳ 正在获取二维码...")
            
            try:
                from clawpy.core import fetch_qrcode
                
                qr_result = asyncio.run(fetch_qrcode())
                qrcode_url = qr_result.get("qrcode_img_content", "")
                qrcode_key = qr_result.get("qrcode", "")
                
                if qrcode_url:
                    qr_placeholder.markdown(f"""
                    <div style="text-align: center; padding: 20px;">
                        <a href="{qrcode_url}" target="_blank" 
                           style="display: inline-block; padding: 12px 24px; background: #07C160; color: white; border-radius: 8px; text-decoration: none; font-size: 16px; font-weight: bold;">
                            🔗 点击打开二维码链接
                        </a>
                        <p style="color: #888; font-size: 13px; margin-top: 15px;">
                            ⏳ 等待扫码...（二维码有效期约 2 分钟）
                        </p>
                    </div>
                    """, unsafe_allow_html=True)
                    
                    status_placeholder = st.empty()
                    
                    poll_count = 0
                    max_polls = 60
                    
                    while poll_count < max_polls:
                        import time
                        time.sleep(2)
                        poll_count += 1
                        
                        from clawpy.core import poll_qr_status, DEFAULT_BASE_URL
                        status_result = asyncio.run(
                            poll_qr_status(base_url=DEFAULT_BASE_URL, qrcode=qrcode_key)
                        )
                        current_status = status_result.get("status", "wait")
                        
                        status_messages = {
                            "wait": f"⏳ 等待扫码... ({poll_count * 2}s/{max_polls * 2}s)",
                            "scaned": "✅ 已检测到扫码！请在微信中确认...",
                            "confirmed": "✅✓ 登录成功！",
                            "expired": "❌ 二维码已过期",
                        }
                        
                        msg = status_messages.get(current_status, f"状态: {current_status}")
                        
                        if current_status == "wait":
                            progress = min(poll_count / (max_polls * 0.8), 1.0)
                            status_placeholder.markdown(f"""
                            <div style="
                                text-align: center;
                                padding: 10px;
                                background: #f0f4ff;
                                border-radius: 8px;
                                margin-top: 10px;
                            ">
                                <span>{msg}</span>
                                <div style="
                                    background: linear-gradient(90deg, #667eea, #764ba2);
                                    height: 4px;
                                    border-radius: 2px;
                                    width: {progress * 100}%;
                                    margin-top: 8px;
                                "></div>
                            </div>
                            """, unsafe_allow_html=True)
                        elif current_status == "scaned":
                            status_placeholder.success(msg)
                        elif current_status == "confirmed":
                            status_placeholder.success("✅✓✓ 登录成功！正在连接...")
                            
                            bot_token = status_result.get("bot_token")
                            ilink_bot_id = status_result.get("ilink_bot_id")
                            ilink_user_id = status_result.get("ilink_user_id")
                            
                            if bot_token and ilink_bot_id and ilink_user_id:
                                from clawpy.auth import save_credentials
                                from clawpy.types import Credentials
                                creds = Credentials(
                                    token=bot_token,
                                    base_url=DEFAULT_BASE_URL,
                                    bot_id=ilink_bot_id,
                                    user_id=ilink_user_id,
                                )
                                save_credentials(creds)
                            
                            import threading
                            
                            def run_bot_after_login():
                                from main import bot
                                bot.run()
                            
                            bot_thread = threading.Thread(
                                target=run_bot_after_login,
                                daemon=True,
                                name="xiaoxinChatAI_bot"
                            )
                            bot_thread.start()
                            
                            time.sleep(2)
                            
                            st.session_state.wechat_bot_thread = bot_thread
                            st.session_state.wechat_connected = True
                            st.session_state.show_qr = False
                            
                            st.toast("✅ 微信已连接！", icon="📱")
                            st.balloons()
                            st.rerun()
                            break
                        else:
                            status_placeholder.error(msg)
                            st.warning("正在重新获取二维码...")
                            st.session_state.show_qr = False
                            time.sleep(1)
                            st.rerun()
                            break
                else:
                    qr_placeholder.error("❌ 获取二维码失败")
                
            except Exception as e:
                qr_placeholder.error(f"❌ 错误: {e}")
            
            col_cancel = st.columns([3])[0]
            with col_cancel:
                if st.button("取消登录", use_container_width=True):
                    st.session_state.show_qr = False
                    st.rerun()
        
        is_connected = st.session_state.wechat_connected
        
        if st.button("🔌 断开机器人连接", use_container_width=True, disabled=not is_connected):
            try:
                from main import bot
                bot.stop()
            except Exception:
                pass
            st.session_state.wechat_connected = False
            st.toast("⚠️ 已关闭微信连接", icon="🔌")
            st.rerun()
        
        if 'confirm_logout' not in st.session_state:
            st.session_state.confirm_logout = False
        if 'logout_success' not in st.session_state:
            st.session_state.logout_success = False
        
        if st.session_state.logout_success:
            st.success("✅ 已退出微信clawbot连接并清除凭证，下次连接微信时需要重新扫码绑定")
            if st.button("知道了", type="secondary"):
                st.session_state.logout_success = False
                st.rerun()
        
        if st.button("❌ 退出微信clawbot连接", use_container_width=True, type="secondary", disabled=not is_connected):
            st.session_state.confirm_logout = True
            st.rerun()
        
        if st.session_state.confirm_logout:
            st.warning("该操作会永久断开微信clawbot的连接，下次连接微信时需要重新扫码绑定")
            col_confirm, col_cancel = st.columns(2)
            with col_confirm:
                if st.button("确认退出", use_container_width=True, type="primary"):
                    try:
                        from main import bot
                        bot.stop()
                    except Exception:
                        pass
                    try:
                        from clawpy.auth import clear_credentials
                        clear_credentials()
                    except Exception as e:
                        st.error(f"清除凭证失败: {e}")
                    st.session_state.wechat_connected = False
                    st.session_state.confirm_logout = False
                    st.session_state.logout_success = True
                    st.rerun()
            with col_cancel:
                if st.button("取消", use_container_width=True):
                    st.session_state.confirm_logout = False
                    st.rerun()
    
    if st.session_state.wechat_connected:
        st.markdown("""
        <div style="
            text-align: center;
            padding: 60px 20px;
            background: linear-gradient(135deg, #667eea10 0%, #764ba210 100%);
            border-radius: 16px;
            border: 2px dashed #667eea40;
            margin: 20px 0;
        ">
            <div style="font-size: 60px; margin-bottom: 20px;">📱</div>
            <h3 style="color: #333; margin: 0;">微信已连接</h3>
            <p style="color: #666; margin: 10px 0 5px 0;">
                请在 <b>微信客户端</b> 中与 {0} 聊天
            </p>
            <p style="color: #999; font-size: 13px;">
                Web 端聊天已自动隐藏，避免消息重复<br>
                断开微信后可恢复 Web 端聊天
            </p>
        </div>
        """.format(get_bot_name(st.session_state.skill_data)), unsafe_allow_html=True)
        
        with st.expander("📊 微信运行状态", expanded=False):
            st.metric("状态", "✅ 运行中")
            st.metric("对话轮数", len(get_history(st.session_state.user_id)))
            
            mem_stats = memory_store.get_stats()
            st.metric("长期记忆", mem_stats.get('total_memories', 0))
            
            confirm_key_wechat = 'confirm_clear_wechat'
            if st.session_state.get(confirm_key_wechat, False):
                st.warning("⚠️ **再次确认清空当前会话历史？**（不可恢复）", icon="⚠️")
                col_yw, col_nw = st.columns(2)
                with col_yw:
                    if st.button("✅ 确认清空", key="confirm_yes_wechat", type="primary"):
                        cleared_count = len(get_history(selected_uid))
                        
                        if selected_uid in chat_histories:
                            del chat_histories[selected_uid]
                        if selected_uid == st.session_state.user_id:
                            st.session_state.messages = []
                        st.session_state[confirm_key_wechat] = False
                        
                        st.toast(f"🗑️ 已清空 {cleared_count} 条消息！", icon="📋")
                        st.success(f"""**✅ 会话历史已清空！**
- 📊 共删除 **{cleared_count}** 条消息
- 🧠 长期记忆保留（{memory_store.get_stats().get('total_memories', 0)} 条）""", icon="🎉")
                        st.balloons()
                        
                        import time
                        time.sleep(1.2)
                        st.rerun()
                with col_nw:
                    if st.button("❌ 取消", key="confirm_no_wechat"):
                        st.session_state[confirm_key_wechat] = False
                        st.rerun()
            else:
                if st.button("🗑️ 清空当前会话历史", key="clear_wechat_history_btn"):
                    st.session_state[confirm_key_wechat] = True
                    st.rerun()
        
        return
    
    chat_container = st.container(height=520)
    
    with chat_container:
        for i, msg in enumerate(st.session_state.messages):
            role = msg.get("role", "user")
            content = msg.get("content", "")
            
            is_image_msg = msg.get('is_image', False)
            is_image_response = msg.get('is_image_response', False)
            
            if is_image_msg:
                with st.chat_message("user"):
                    img_data = msg.get('image_data', '')
                    img_name = msg.get('image_name', '图片')
                    
                    if img_data:
                        try:
                            import base64 as _base64
                            img_bytes = _base64.b64decode(img_data)
                            st.image(img_bytes, caption=f"📷 {img_name}", width=280)
                        except:
                            st.markdown(f"""
                            <div style="
                                text-align: center;
                                padding: 15px;
                                background: #e3f2fd;
                                border-radius: 8px;
                                border: 2px dashed #90caf9;
                            ">
                                📷 {img_name}
                                <br><small style="color: #666">（图片数据）</small>
                            </div>
                            """, unsafe_allow_html=True)
                    else:
                        st.markdown(f"📷 {content}")
                
                if i + 1 < len(st.session_state.messages):
                    next_msg = st.session_state.messages[i + 1]
                    if next_msg.get('is_image_response'):
                        with st.chat_message("assistant"):
                            model_name = config['model']['name']
                            st.info("""
**📷 图片已收到！**

抱歉，当前模型 **{}** 不支持直接识别图片。

你可以用文字描述一下图片内容，我来帮你分析~
                            """.format(model_name))
                continue
            
            if is_image_response:
                with st.chat_message("assistant"):
                    model_name = config['model']['name']
                    st.info("""
**📷 图片提示**

当前模型 **{}** 不支持识别图片。

请描述图片内容，我会尽力理解~ 💡
                    """.format(model_name))
                continue
            
            is_split = msg.get('is_split', False)
            reply_parts = msg.get('reply_parts', [content])
            
            if is_split and role == "assistant":
                emoji_img_url = msg.get('emoji_image_url')
                emoji_kw = msg.get('emoji_keyword')
                
                for idx, part in enumerate(reply_parts):
                    with st.chat_message("assistant"):
                        st.markdown(part)
                        
                        if idx == len(reply_parts) - 1:
                            if emoji_img_url and config['features'].get('emoji'):
                                try:
                                    st.image(emoji_img_url, width=180, caption=f"😊 `{emoji_kw}`")
                                except:
                                    st.markdown(f'<span class="emoji-tag">😊 `{emoji_kw}`</span>', unsafe_allow_html=True)
                            elif emoji_kw and config['features'].get('emoji'):
                                st.markdown(f'<span class="emoji-tag">😊 `{emoji_kw}`</span>', unsafe_allow_html=True)
                        
                        if msg.get("latency_ms") and idx == len(reply_parts) - 1:
                            parts = []
                            parts.append(f"⏱️ {msg['latency_ms']}ms")
                            
                            if msg.get("used_memory"):
                                parts.append(f"🧠 记忆:✅")
                            else:
                                parts.append(f"🧠 记忆:—")
                            
                            if msg.get("used_tool"):
                                parts.append(f"🔍 联网:✅")
                            else:
                                parts.append(f"🔍 联网:—")
                            
                            stats_html = f'<span class="stats-tag">{" | ".join(parts)} ({len(reply_parts)}条)</span>'
                            st.markdown(stats_html, unsafe_allow_html=True)
            else:
                with st.chat_message(role):
                    st.markdown(content)
                    
                    emoji_img_url = msg.get('emoji_image_url')
                    emoji_kw = msg.get('emoji_keyword')
                    
                    if emoji_img_url and config['features'].get('emoji'):
                        try:
                            st.image(emoji_img_url, width=180, caption=f"😊 `{emoji_kw}`")
                        except:
                            st.markdown(f'<span class="emoji-tag">😊 `{emoji_kw}`</span>', unsafe_allow_html=True)
                    elif emoji_kw and config['features'].get('emoji'):
                        emoji_html = f'<span class="emoji-tag">😊 关键词: `{emoji_kw}`</span>'
                        st.markdown(emoji_html, unsafe_allow_html=True)
                    
                    if msg.get("latency_ms"):
                        parts = []
                        parts.append(f"⏱️ {msg['latency_ms']}ms")
                        
                        if msg.get("used_memory"):
                            parts.append(f"🧠 记忆:✅")
                        else:
                            parts.append(f"🧠 记忆:—")
                        
                        if msg.get("used_tool"):
                            parts.append(f"🔍 联网:✅")
                        else:
                            parts.append(f"🔍 联网:—")
                        
                        stats_html = f'<span class="stats-tag">{" | ".join(parts)}</span>'
                        st.markdown(stats_html, unsafe_allow_html=True)
    
    proactive_cfg = config.get('features', {}).get('proactive_message', {})
    is_proactive_enabled = proactive_cfg.get('enabled', False)
    
    if is_proactive_enabled and not st.session_state.wechat_connected:
        st.markdown("---")
        col_proact1, col_proact2 = st.columns([3, 1])
        
        with col_proact1:
            idle_minutes = (datetime.now() - st.session_state.last_message_time).total_seconds() / 60
            max_idle = proactive_cfg.get('max_idle_minutes', 60)
            
            can_send = idle_minutes >= max_idle
            
            if can_send:
                st.markdown(f"""
                <div style="
                    background: linear-gradient(135deg, #e8f5e9 0%, #c8e6c9 100%);
                    padding: 10px 15px;
                    border-radius: 8px;
                    border-left: 3px solid #4caf50;
                ">
                    💬 <b>可以发送主动消息</b><br>
                    <small style="color: #666;">已空闲 {idle_minutes:.0f} 分钟 (≥ {max_idle} 分钟)</small>
                </div>
                """, unsafe_allow_html=True)
            else:
                remaining = max_idle - idle_minutes
                st.caption(f"⏳ 下次主动消息: 约 {remaining:.0f} 分钟后 (需空闲 ≥ {max_idle} 分钟)")
        
        with col_proact2:
            if st.button("🤖 触发主动消息", use_container_width=True, disabled=not can_send):
                with st.spinner("🤖 正在生成主动消息..."):
                    try:
                        result = asyncio.run(generate_proactive_message(
                            st.session_state.user_id,
                            config
                        ))
                        
                        if result:
                            style_tag = result.get('proactive_style', '')
                            st.session_state.messages.append(result)
                            
                            st.toast(f"✅ 已生成主动消息 [{style_tag}]!", icon="💬")
                            st.balloons()
                            st.rerun()
                        else:
                            st.warning("⚠️ 本次未触发（概率未中或内容过短）")
                    except Exception as e:
                        st.error(f"❌ 生成失败: {e}")
    
    col_input, col_image = st.columns([4, 1])
    
    with col_input:
        prompt = st.chat_input("输入消息...")
    
    with col_image:
        st.write("")
        st.write("")
        uploaded_img = st.file_uploader(
            "📷",
            type=["png", "jpg", "jpeg", "gif", "webp"],
            accept_multiple_files=False,
            label_visibility="collapsed",
            help="发送图片",
            key="chat_image_uploader"
        )
    
    is_new_image_upload = False
    if 'last_uploaded_img_name' not in st.session_state:
        st.session_state.last_uploaded_img_name = None
    
    if uploaded_img and uploaded_img.name != st.session_state.last_uploaded_img_name:
        is_new_image_upload = True
        st.session_state.last_uploaded_img_name = uploaded_img.name
    elif not uploaded_img:
        st.session_state.last_uploaded_img_name = None
    
    image_not_supported_msg = """⚠️ **图片提示**

抱歉，当前模型暂时识别不了图片内容。

📌 **你可以这样描述图片：**
- "这是一张 [风景/人物/美食/表情包] 图片"
- "图片里有一只猫在..."
- "这是刚才你发的截图"

如果你的模型不能识别图片机器人会委婉提示你奥~"""
    
    if is_new_image_upload:
        st.session_state.last_message_time = datetime.now()
        
        img_bytes = uploaded_img.getvalue()
        img_base64 = __import__('base64').b64encode(img_bytes).decode()
        
        img_mime = uploaded_img.type or "image/jpeg"
        
        st.session_state.messages.append({
            "role": "user",
            "content": f"[图片] ({uploaded_img.name}, {len(img_bytes)/1024:.1f}KB)",
            "is_image": True,
            "image_data": img_base64,
            "image_name": uploaded_img.name,
            "image_size": len(img_bytes),
        })
        
        with chat_container:
            with st.chat_message("assistant"):
                
                st.image(uploaded_img, caption=f"📷 {uploaded_img.name}", width=300)
                
                st.markdown(image_not_supported_msg)
                
                st.session_state.messages.append({
                    "role": "assistant",
                    "content": "（模型不支持图片，已提示用户手动描述）",
                    "is_image_response": True,
                })
                
                st.rerun()
    
    elif prompt:
        st.session_state.last_message_time = datetime.now()
        st.session_state.messages.append({
            "role": "user",
            "content": prompt,
        })
        
        with chat_container:
            with st.chat_message("assistant"):
                with st.spinner("AI 思考中..."):
                    try:
                        result = asyncio.run(process_message(prompt))
                        
                        reply_text = result['reply']
                        reply_parts = result.get('reply_parts', [reply_text])
                        is_split = result.get('is_split', False)
                        emoji_img_url = result.get('emoji_image_url')
                        emoji_kw = result.get('emoji_keyword')
                        
                        if is_split:
                            for idx, part in enumerate(reply_parts):
                                with st.chat_message("assistant"):
                                    st.markdown(part)
                                    
                                    if idx == len(reply_parts) - 1:
                                        if emoji_img_url and config['features'].get('emoji'):
                                            try:
                                                st.image(emoji_img_url, width=200, caption=f"😊 `{emoji_kw}`")
                                            except:
                                                st.markdown(f'<span class="emoji-tag">😊 `{emoji_kw}`</span>', unsafe_allow_html=True)
                                        elif emoji_kw and config['features'].get('emoji'):
                                            st.markdown(f'<span class="emoji-tag">😊 `{emoji_kw}`</span>', unsafe_allow_html=True)
                                        
                                        latency = result.get('latency_ms', 0)
                                        mem_status = "✅" if result.get('used_memory') else "—"
                                        tool_status = "✅" if result.get('used_tool') else "—"
                                        history_n = result.get('history_len', 0)
                                        
                                        stats_html = f'<span class="stats-tag">⏱️ {latency}ms | 🧠 记忆:{mem_status} | 🔍 联网:{tool_status} | 📜 {history_n}轮 ({len(reply_parts)}条)</span>'
                                        st.markdown(stats_html, unsafe_allow_html=True)
                        else:
                            with st.chat_message("assistant"):
                                st.markdown(reply_text)
                                
                                if emoji_img_url and config['features'].get('emoji'):
                                    try:
                                        st.image(emoji_img_url, width=200, caption=f"😊 `{emoji_kw}`")
                                    except:
                                        st.markdown(f'<span class="emoji-tag">😊 `{emoji_kw}`</span>', unsafe_allow_html=True)
                                elif emoji_kw and config['features'].get('emoji'):
                                    st.markdown(f'<span class="emoji-tag">😊 `{emoji_kw}`</span>', unsafe_allow_html=True)
                                
                                latency = result.get('latency_ms', 0)
                                mem_status = "✅" if result.get('used_memory') else "—"
                                tool_status = "✅" if result.get('used_tool') else "—"
                                history_n = result.get('history_len', 0)
                                
                                stats_html = f'<span class="stats-tag">⏱️ {latency}ms | 🧠 记忆:{mem_status} | 🔍 联网:{tool_status} | 📜 历史:{history_n}轮</span>'
                                st.markdown(stats_html, unsafe_allow_html=True)
                        
                        st.session_state.messages.append({
                            "role": "assistant",
                            "content": reply_text,
                            "reply_parts": result.get('reply_parts', [reply_text]),
                            "is_split": is_split,
                            "emoji_keyword": result.get('emoji_keyword'),
                            "emoji_image_url": result.get('emoji_image_url'),
                            "latency_ms": result.get('latency_ms'),
                            "used_memory": result['used_memory'],
                            "used_tool": result['used_tool'],
                        })
                        
                    except Exception as e:
                        error_msg = f"❌ 错误: {e}"
                        st.error(error_msg)
                        st.session_state.messages.append({
                            "role": "assistant",
                            "content": error_msg,
                        })


def render_tools_panel():
    """渲染工具测试面板"""
    with st.expander("🛠️ 工具测试", expanded=False):
        tab1, tab2, tab3 = st.tabs(["网络搜索", "天气查询", "新闻获取"])
        
        with tab1:
            search_query = st.text_input("搜索关键词", placeholder="输入要搜索的内容...")
            if st.button("🔍 搜索") and search_query:
                with st.spinner("搜索中..."):
                    try:
                        result = asyncio.run(web_search(search_query))
                        st.text_area("搜索结果", result, height=200)
                    except Exception as e:
                        st.error(f"搜索失败: {e}")
        
        with tab2:
            city = st.text_input("城市", value="北京")
            if st.button("🌤️ 查询天气") and city:
                with st.spinner("查询中..."):
                    try:
                        result = asyncio.run(get_weather(city))
                        st.text_area(f"{city} 天气", result, height=250)
                    except Exception as e:
                        st.error(f"查询失败: {e}")
        
        with tab3:
            col_cat, col_count = st.columns(2)
            with col_cat:
                category = st.selectbox(
                    "分类",
                    ["热点", "科技", "娱乐", "体育", "财经", "国际", "国内"]
                )
            with col_count:
                count = st.slider("条数", 3, 10, 5)
            
            if st.button("📰 获取新闻"):
                with st.spinner("获取中..."):
                    try:
                        result = asyncio.run(get_news(category, count))
                        st.text_area(f"{category}新闻", result, height=300)
                    except Exception as e:
                        st.error(f"获取失败: {e}")


def get_all_known_users() -> list[str]:
    """获取所有已知用户ID列表"""
    users = set()
    
    for uid in chat_histories.keys():
        users.add(uid)
    
    try:
        mem_stats = memory_store.get_stats()
        for uid in mem_stats.get('users_detail', {}).keys():
            users.add(uid)
    except:
        pass
    
    sorted_users = sorted(users, key=lambda x: (
        0 if not x.startswith("web_user_") else 1,
        x
    ))
    
    return sorted_users if sorted_users else [st.session_state.user_id]


def render_memory_panel():
    """渲染记忆管理面板"""
    with st.expander("🧠 记忆管理", expanded=False):
        all_users = get_all_known_users()
        
        col_sel, col_info = st.columns([3, 2])
        with col_sel:
            selected_uid = st.selectbox(
                "👤 选择用户",
                options=all_users,
                index=0,
                format_func=lambda x: (
                    f"📱 {x[-20:]}" if len(x) > 20 and not x.startswith("web_user_")
                    else f"💻 Web UI"
                    if x.startswith("web_user_") else x
                ),
                help="查看/管理该用户的对话历史和记忆",
                key="memory_user_selector"
            )
        
        with col_info:
            hist_count = len(get_history(selected_uid))
            st.metric("短期消息", hist_count)
        
        tab1, tab2, tab3 = st.tabs(["短期历史", "长期记忆", "统计"])
        
        with tab1:
            history = get_history(selected_uid)
            st.caption(f"`{selected_uid[:35]}...` | 共 **{len(history)}** 条消息")
            
            for i, msg in enumerate(reversed(history[-20:])):
                role_emoji = "👤" if msg['role'] == "user" else "🤖"
                st.text(f"{role_emoji} [{msg['role']}] {msg['content'][:80]}...")
            
            confirm_key_short = 'confirm_clear_short'
            if st.session_state.get(confirm_key_short, False):
                st.warning("⚠️ **再次点击确认清空短期历史？**（不可恢复）", icon="⚠️")
                col_y1, col_n1 = st.columns(2)
                with col_y1:
                    if st.button("✅ 确认清空", key="confirm_yes_short", type="primary"):
                        cleared_count = len(get_history(selected_uid))
                        
                        if selected_uid in chat_histories:
                            del chat_histories[selected_uid]
                        if selected_uid == st.session_state.user_id:
                            st.session_state.messages = []
                        st.session_state[confirm_key_short] = False
                        
                        st.toast(f"🗑️ 已清空 {cleared_count} 条消息！", icon="📋")
                        st.success(f"""**✅ 短期历史已清空！**
- 📊 共删除 **{cleared_count}** 条消息
- 👤 用户: `{selected_uid[:30]}...`
- 🧠 长期记忆不受影响""", icon="🎉")
                        st.balloons()
                        
                        import time
                        time.sleep(1.2)
                        st.rerun()
                with col_n1:
                    if st.button("❌ 取消", key="confirm_no_short"):
                        st.session_state[confirm_key_short] = False
                        st.rerun()
            else:
                if st.button("🗑️ 清空短期历史", key="clear_memory_history_btn"):
                    st.session_state[confirm_key_short] = True
                    st.rerun()
        
        with tab2:
            stats = memory_store.get_stats()
            total_mem = stats.get('total_memories', 0)
            
            recent = memory_store.get_recent(selected_uid, n=10)
            user_mem_count = len(memory_store.get_recent(selected_uid, n=9999))
            
            st.caption(f"`{selected_uid[:35]}...` | 该用户: **{user_mem_count}** 条 | 总计: **{total_mem}** 条")
            
            for mem in recent:
                role_emoji = "👤" if mem['role'] == 'user' else "🤖"
                st.text(f"{role_emoji} ({mem.get('age_days', '?')}天前) {mem['content'][:60]}...")
                st.caption(f"   关键词: {', '.join(mem.get('keywords', []))}")
            
            st.markdown("---")
            
            confirm_key_long = 'confirm_clear_long'
            if st.session_state.get(confirm_key_long, False):
                st.warning("⚠️ **再次确认清空所有用户的长期记忆？**（不可恢复）", icon="⚠️")
                col_y2, col_n2 = st.columns(2)
                with col_y2:
                    if st.button("✅ 确认清空", key="confirm_yes_long", type="primary"):
                        removed = memory_store.clear_all()
                        st.session_state[confirm_key_long] = False
                        
                        st.toast(f"🗑️ 已清除 {removed} 条长期记忆！", icon="📋")
                        st.success(f"""**✅ 长期记忆已全部清空！**
- 🗑️ 共删除 **{removed}** 条记忆
- 🧹 所有用户数据已清除""", icon="🎉")
                        st.balloons()
                        
                        import time
                        time.sleep(1.2)
                        st.rerun()
                with col_n2:
                    if st.button("❌ 取消", key="confirm_no_long"):
                        st.session_state[confirm_key_long] = False
                        st.rerun()
            else:
                c_col1, c_col2 = st.columns([3, 1])
                with c_col1:
                    if st.button("🗑️ 清空所有长期记忆", key="clear_long_memory_btn"):
                        st.session_state[confirm_key_long] = True
                        st.rerun()
                with c_col2:
                    st.metric("总记忆", f"{total_mem} 条", help="当前总记忆数", label_visibility="collapsed")
        
        with tab3:
            st.json(stats)
            
            if st.button("🧹 清理过期记忆"):
                removed = memory_store.cleanup_expired()
                st.success(f"清理了 {removed} 条过期记忆")


def render_system_info():
    """渲染系统信息"""
    with st.expander("ℹ️ 系统信息", expanded=False):
        col1, col2 = st.columns(2)
        
        with col1:
            st.subheader("配置文件")
            st.code(f"{CONFIG_FILE}")
            if CONFIG_FILE.exists():
                st.success("✅ 配置文件存在")
                st.json(st.session_state.config)
            else:
                st.info("ℹ️ 使用默认配置（保存后生成文件）")
        
        with col2:
            st.subheader("Skill 信息")
            skill_data = st.session_state.skill_data
            st.json({
                "name": skill_data.get('config', {}).get('name', '未加载'),
                "description": skill_data.get('config', {}).get('description', ''),
                "persona_len": len(skill_data.get('persona', '')),
                "memories_len": len(skill_data.get('memories', '')),
                "path": st.session_state.config['skill']['path'],
            })
        
        st.subheader("环境变量")
        env_info = {
            "Python版本": sys.version.split()[0],
            "工作目录": str(PROJECT_ROOT),
            "用户ID": st.session_state.user_id,
            "模型": st.session_state.config['model']['name'],
            "API地址": st.session_state.config['model']['base_url'],
        }
        st.json(env_info)


def render_doc_panel():
    """渲染说明文档面板"""
    import base64
    doc_path = PROJECT_ROOT / "README.md"
    if doc_path.exists():
        content = doc_path.read_text(encoding="utf-8")
        img_pattern = re.compile(r'!\[([^\]]*)\]\((static/[^)]+)\)')
        def _replace_img(m):
            alt_text = m.group(1)
            img_path = PROJECT_ROOT / m.group(2)
            if img_path.exists():
                img_bytes = img_path.read_bytes()
                ext = img_path.suffix.lower()
                mime = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"}.get(ext.lstrip("."), "image/png")
                b64 = base64.b64encode(img_bytes).decode()
                return f'![{alt_text}](data:{mime};base64,{b64})'
            return m.group(0)
        content = img_pattern.sub(_replace_img, content)
        st.markdown(content)
    else:
        st.info("📖 说明文档（README.md）未找到")


def main():
    st.set_page_config(
        page_title="xiaoxinChatAI AI 聊天",
        page_icon="💬",
        layout="wide",
        initial_sidebar_state="expanded",
    )
    
    init_session_state()
    
    render_sidebar()
    
    tab_chat, tab_tools, tab_memory, tab_info, tab_doc = st.tabs(
        ["💬 聊天", "🛠️ 工具", "🧠 记忆", "ℹ️ 系统", "📖 说明文档"]
    )
    
    with tab_chat:
        render_chat()
    
    with tab_tools:
        render_tools_panel()
    
    with tab_memory:
        render_memory_panel()
    
    with tab_info:
        render_system_info()
    
    with tab_doc:
        render_doc_panel()


if __name__ == "__main__":
    main()
