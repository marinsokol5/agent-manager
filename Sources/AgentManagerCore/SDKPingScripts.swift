import Foundation

/// Source-of-truth helper scripts for SDK pings. They are embedded in Core so a
/// bare `am` binary and the assembled app behave identically, then materialized
/// into the workspace on demand. Rewriting changed content upgrades helpers with
/// the binary without introducing package resources or installer network access.
enum SDKPingScripts {
    static let claude = #"""
// Agent Manager SDK ping via @anthropic-ai/claude-agent-sdk.
// Usage: node ping.mjs <prompt> <path-to-claude-bin>

import { query } from "@anthropic-ai/claude-agent-sdk";

const prompt = process.argv[2] ?? "Good morning Claude";
const claudeBinary = process.argv[3] || undefined;
const options = {
  model: "haiku",
  maxTurns: 1,
  allowedTools: [],
  ...(claudeBinary ? { pathToClaudeCodeExecutable: claudeBinary } : {}),
};

let result = null;
try {
  for await (const message of query({ prompt, options })) {
    if (message.type === "result") result = message;
  }
} catch (error) {
  console.log(JSON.stringify({ ok: false, error: String(error?.message ?? error) }));
  process.exit(1);
}

if (!result) {
  console.log(JSON.stringify({ ok: false, error: "no result message" }));
  process.exit(1);
}

console.log(JSON.stringify({
  ok: !result.is_error,
  subtype: result.subtype,
  cost_usd: result.total_cost_usd,
  usage: result.usage,
}));
process.exit(result.is_error ? 1 : 0);
"""#

    static let codex = #"""
#!/usr/bin/env python3
"""Agent Manager SDK ping via openai-codex.

Usage: python3 codex_ping.py <prompt> <path-to-codex-bin>
"""

from __future__ import annotations

import json
import os
import sys
from enum import Enum
from typing import Any


def jsonable(value: Any) -> Any:
    if value is None or isinstance(value, str | int | float | bool):
        return value
    if isinstance(value, Enum):
        return value.value
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json", by_alias=False, exclude_none=True)
    if isinstance(value, dict):
        return {str(key): jsonable(item) for key, item in value.items()}
    if isinstance(value, list | tuple):
        return [jsonable(item) for item in value]
    return str(value)


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, separators=(",", ":")))


def main() -> int:
    prompt = sys.argv[1] if len(sys.argv) > 1 else "Good morning Codex"
    codex_binary = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
    cwd = os.environ.get("AGENT_MANAGER_CODEX_SDK_CWD") or os.path.expanduser("~")
    model = os.environ.get("CODEX_SDK_MODEL") or None

    try:
        from openai_codex import ApprovalMode, Codex, CodexConfig, Sandbox
    except ModuleNotFoundError as error:
        if error.name == "openai_codex":
            emit({
                "ok": False,
                "error": "openai-codex is not installed; run `python3 -m pip install openai-codex`",
            })
            return 1
        raise

    try:
        config = CodexConfig(codex_bin=codex_binary, cwd=cwd)
        with Codex(config) as codex:
            thread = codex.thread_start(
                approval_mode=ApprovalMode.deny_all,
                cwd=cwd,
                ephemeral=True,
                model=model,
                sandbox=Sandbox.read_only,
            )
            result = thread.run(
                prompt,
                approval_mode=ApprovalMode.deny_all,
                model=model,
                sandbox=Sandbox.read_only,
            )
    except Exception as error:  # noqa: BLE001 - subprocess boundary
        emit({"ok": False, "error": str(error), "type": type(error).__name__})
        return 1

    emit({
        "ok": True,
        "status": jsonable(result.status),
        "turn_id": result.id,
        "duration_ms": result.duration_ms,
        "final_response": result.final_response,
        "usage": jsonable(result.usage),
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
"""#

    static func materialize(
        in directory: URL,
        fileManager: FileManager = .default)
        throws
        -> (claude: URL, codex: URL)
    {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let claudeURL = directory.appendingPathComponent("ping.mjs")
        let codexURL = directory.appendingPathComponent("codex_ping.py")
        try writeIfChanged(claude, to: claudeURL)
        try writeIfChanged(codex, to: codexURL)
        return (claudeURL, codexURL)
    }

    private static func writeIfChanged(_ source: String, to url: URL) throws {
        let data = Data(source.utf8)
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }
}
