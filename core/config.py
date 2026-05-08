"""统一配置管理 — main.py 和 web_ui.py 共享"""
import json
from pathlib import Path

CONFIG_FILE = Path(__file__).parent.parent / "web_config.json"

DEFAULT_CONFIG = {
    "model": {
        "name": "deepseek-chat",
        "api_key": "your-api-key-here",
        "base_url": "https://api.deepseek.com",
    },
    "skill": {
        "path": "path/to/your/skill/xiaojia",
        "enabled": True,
    },
    "memory": {
        "short_term_enabled": True,
        "short_term_max": 20,
        "long_term_enabled": True,
        "long_term_max": 200,
        "expire_days": 90,
        "retrieval_top_k": 5,
        "retrieval_min_score": 0.2,
    },
    "tools": {
        "web_search": True,
        "web_search_source": "searxng",
    },
    "features": {
        "emoji": True,
        "emoji_probability": 0.5,
        "emoji_api": {
            "api_id": "",
            "api_key": "",
            "api_url": "",
        },
        "max_messages": 3,
        "proactive_message": {
            "enabled": False,
            "interval_minutes": 30,
            "max_idle_minutes": 120,
            "probability": 0.3,
            "styles": ["延续上次话题", "询问近况", "分享日常", "主动关心"],
        },
        "file_reply": False,
        "video_reply": False,
        "voice_reply": False,
        "typing_indicator": True,
        "image_handling": {
            "send_to_ai": False,
            "fallback_reply": "auto",
            "unsupported_model_msg": "该模型暂时识别不了图片",
        },
    },
    "system": {
        "temperature": 0.7,
        "max_tokens": 2000,
        "timeout": 120,
    },
}

_config_cache = None
_config_mtime = 0


def _deep_merge(base: dict, override: dict) -> dict:
    result = base.copy()
    for key, val in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(val, dict):
            result[key] = _deep_merge(result[key], val)
        else:
            result[key] = val
    return result


def load_config() -> dict:
    global _config_cache, _config_mtime

    try:
        if CONFIG_FILE.exists():
            mtime = CONFIG_FILE.stat().st_mtime
            if _config_cache is not None and mtime == _config_mtime:
                return _config_cache

            saved = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
            _config_cache = _deep_merge(DEFAULT_CONFIG.copy(), saved)
            _config_mtime = mtime
            return _config_cache
    except Exception:
        pass

    _config_cache = DEFAULT_CONFIG.copy()
    return _config_cache


def save_config(config: dict):
    CONFIG_FILE.write_text(
        json.dumps(config, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    global _config_cache, _config_mtime
    _config_cache = None
    _config_mtime = 0


def get_model_name(cfg: dict | None = None) -> str:
    c = cfg or load_config()
    return c.get("model", {}).get("name", "deepseek-chat")


def get_temperature(cfg: dict | None = None) -> float:
    c = cfg or load_config()
    return c.get("system", {}).get("temperature", 0.7)


def get_timeout(cfg: dict | None = None) -> int:
    c = cfg or load_config()
    return c.get("system", {}).get("timeout", 120)


def check_config_ready(override_cfg: dict = None) -> tuple[bool, str]:
    cfg = override_cfg if override_cfg is not None else load_config()

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


def get_llm_kwargs(cfg: dict | None = None) -> dict:
    """获取 LLM 初始化参数"""
    c = cfg or load_config()
    model = c.get("model", {})
    return {
        "model": model.get("name", "deepseek-chat"),
        "temperature": c.get("system", {}).get("temperature", 0.7),
        "max_tokens": c.get("system", {}).get("max_tokens", 2000),
    }