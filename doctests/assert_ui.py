#!/usr/bin/env python3
"""Keep token membership in Token Lists, from wire to visible control."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


rep = read("src/token_list_ui.rep")
backend = read("src/token_list_ui_backend.cpp")
qml = read("src/qml/TokenListView.qml")
metadata = read("metadata.json")

checks = {
    "wire exposes membership write":
        "SLOT(void setTokenEnabled(int chainId, QString address, bool enabled))" in rep,
    "page carries enabled state":
        all(f'QStringLiteral("{key}")' in backend for key in ("enabled", "builtin")),
    "backend delegates ownership to token_list_module":
        "modules().token_list_module.set_token_enabled(chainId, address, enabled)" in backend,
    "refused writes republish the stored state":
        "publishPage();" in backend.split("void TokenListUiBackend::setTokenEnabled", 1)[1]
        and 'QStringLiteral("revision"), ++m_pageRevision' in backend,
    "table has an Enabled column":
        'title: "Enabled"' in qml and "cellDelegate: enabledCell" in qml,
    "switch writes membership":
        "root.backend.setTokenEnabled(root.selectedChainId, rowItem.address, checked)" in qml,
    "pinned built-ins cannot be switched off":
        "!rowItem.builtin" in qml and 'rowItem.builtin ? "Built in"' in qml,
    "wallet handoff intent remains provided":
        '"intent": "evm.token_lists.configure"' in metadata,
}

failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL") + ": " + name)
if failed:
    raise SystemExit("token membership contract failed: " + ", ".join(failed))
