"""共享会话状态 — 短期记忆与弹性窗口

chat_histories 和 chat_summaries 是进程级全局状态，
main.py (微信) 和 web_ui.py (Web) 共享。
"""
import logging
from .config import load_config

logger = logging.getLogger("xiaoxinChatAI.core.session")

chat_histories: dict[str, list[dict]] = {}
chat_summaries: dict[str, str] = {}

RECENT_ROUNDS_KEEP = 5


def _build_conversation_rounds(history: list[dict]) -> list[dict]:
    rounds = []
    i = 0
    while i < len(history):
        if history[i]["role"] == "user":
            user_msg = history[i]
            assistant_msg = None
            if i + 1 < len(history) and history[i + 1]["role"] == "assistant":
                assistant_msg = history[i + 1]
                i += 1
            rounds.append({"user": user_msg, "assistant": assistant_msg})
        i += 1
    return rounds


def get_history(user_id: str) -> list[dict]:
    if user_id not in chat_histories:
        chat_histories[user_id] = []
    return chat_histories[user_id]


def _get_max_history() -> int:
    cfg = load_config()
    return cfg.get("memory", {}).get("short_term_max", 20)


def add_to_history(user_id: str, role: str, content: str):
    history = get_history(user_id)
    history.append({"role": role, "content": content})
    max_h = _get_max_history()

    if len(history) > max_h:
        rounds = _build_conversation_rounds(history)

        if len(rounds) > RECENT_ROUNDS_KEEP:
            old_rounds = rounds[:-RECENT_ROUNDS_KEEP]

            summary_parts = []
            for r in old_rounds:
                user_text = r["user"]["content"][:80]
                assistant_text = r["assistant"]["content"][:80] if r["assistant"] else ""
                summary_parts.append(f"用户「{user_text}」→ 回复「{assistant_text}」")

            if summary_parts:
                existing = chat_summaries.get(user_id, "")
                new_summary = "\n".join(summary_parts)
                chat_summaries[user_id] = f"{existing}\n{new_summary}".strip() if existing else new_summary

                if len(chat_summaries[user_id]) > 2000:
                    chat_summaries[user_id] = chat_summaries[user_id][-2000:]

            recent_rounds = rounds[-RECENT_ROUNDS_KEEP:]
            new_history = []
            for r in recent_rounds:
                new_history.append(r["user"])
                if r["assistant"]:
                    new_history.append(r["assistant"])

            chat_histories[user_id] = new_history
        else:
            chat_histories[user_id] = history[-max_h:]


def get_chat_summary(user_id: str) -> str:
    return chat_summaries.get(user_id, "")


def clear_user_history(user_id: str):
    if user_id in chat_histories:
        del chat_histories[user_id]
    if user_id in chat_summaries:
        del chat_summaries[user_id]