#!/usr/bin/env python3
"""Prepare the pinned corplink-rs machine helper for Android password auth."""

from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f"expected exactly one source match, got {text.count(old)}: {old!r}")
    return text.replace(old, new)


source = Path(sys.argv[1]) / "src" / "machine.rs"
text = source.read_text()
text = replace_once(
    text,
    '    pub username: Option<String>,\n'
    '    #[serde(default, skip_serializing_if = "Option::is_none")]\n',
    '    pub username: Option<String>,\n'
    '    #[serde(default, skip_serializing_if = "Option::is_none")]\n'
    '    pub password: Option<String>,\n'
    '    #[serde(default, skip_serializing_if = "Option::is_none")]\n',
)
text = replace_once(
    text,
    '        let cookie_file = required(self.cookie_file)?;\n'
    '        let platform = required(self.platform)?;\n'
    '        validate_server(&server)?;\n'
    '        validate_platform(&platform)?;\n',
    '        let cookie_file = required(self.cookie_file)?;\n'
    '        validate_server(&server)?;\n'
    '        if let Some(platform) = &self.platform {\n'
    '            validate_platform(platform)?;\n'
    '        }\n',
)
text = replace_once(
    text,
    '                password: None,\n                platform: Some(platform),\n',
    '                password: self.password,\n                platform: self.platform,\n',
)
text = replace_once(
    text,
    '    if matches!(platform, PLATFORM_LARK | PLATFORM_OIDC) {\n',
    '    if matches!(platform, PLATFORM_LARK | PLATFORM_OIDC | "ldap" | "feilian") {\n',
)
source.write_text(text)
