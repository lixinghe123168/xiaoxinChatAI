"""Skill 加载 — 解析 config.yaml / persona.md / memories.md"""
import re
import logging
from pathlib import Path

logger = logging.getLogger("xiaoxinChatAI.core.skill")


def load_skill(skill_dir: Path) -> dict:
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


def get_bot_name(skill_data: dict) -> str:
    name = skill_data.get("config", {}).get("name", "")
    if name:
        return name
    return "小欣"


def get_skill_data(config: dict) -> dict:
    skill_path = config.get("skill", {}).get("path", "")
    if skill_path and Path(skill_path).exists():
        return load_skill(Path(skill_path))
    return {"config": {}, "persona": "", "memories": ""}