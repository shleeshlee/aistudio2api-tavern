#!/usr/bin/env bash
# 旧链接兼容：卸载已并入 install.sh（运行后选 3）
exec bash -c "$(curl -fsSL https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.sh)" -- uninstall "$@"
