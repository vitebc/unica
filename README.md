# Unica (vitebc fork)

Универсальный MCP-сервер для 1С:Предприятия. Добавляет LLM-агентам навыки
работы с 1С: создание и редактирование метаданных, форм, ролей, СКД, макетов,
сборка EPF/ERF, работа с конфигурацией, расширениями и информационными базами.

**MCP (Model Context Protocol)** — открытый стандарт: сервер совместим с любым
MCP-клиентом: OpenCode, Claude Desktop, Continue.dev, Cursor и другими.

Форк официального [`IngvarConsulting/unica`](https://github.com/IngvarConsulting/unica)
с дополнительными инструментами.

## Возможности

- Сборка и разборка EPF/ERF
- Создание и редактирование метаданных, форм, ролей, подсистем
- Компиляция JSON-схем в XML 1С (формы, метаданные, СКД, макеты)
- Запуск 1С:Предприятия и Конфигуратора
- Создание и обновление информационных баз
- Поиск и анализ BSL-кода
- Проверка кода на соответствие стандартам 1С
- **Список информационных баз** (парсинг ibases.v8i)

## Установка

### One-liner

**Linux / macOS:**
```sh
curl -fsSL https://github.com/vitebc/unica/raw/main/install.sh | bash -s -- -y --install-skills
```

**Windows (PowerShell 5.1+):**
```powershell
iwr -useb https://github.com/vitebc/unica/raw/main/install.ps1 -OutFile $env:TEMP\unica.ps1; & $env:TEMP\unica.ps1
```

### Подробно (клонированием)

**Linux / macOS:**
```sh
git clone https://github.com/vitebc/unica.git
cd unica
./install.sh
```

**Windows (PowerShell 5.1+):**
```powershell
git clone https://github.com/vitebc/unica.git
cd unica
.\install.ps1
```

Поддерживаемые ОС: Linux x86_64, macOS ARM64, Windows x64.

После установки скрипт сам найдёт или создаст `opencode.json` с MCP-сервером.
Перезапустите OpenCode/Dialect/Claude — инструменты `unica.*` станут доступны.

### Параметры install.sh (Linux / macOS)

```sh
./install.sh [options]
```

| Опция | Назначение | По умолчанию |
|---|---|---|
| `--unica-dir PATH` | Директория установки | `~/.local/share/opencode/unica` |
| `--repo-root PATH` | Путь к репозиторию | родительская папка скрипта |
| `--build-all` | Собирать v8-runner и bsl-analyzer из исходников | скачать pre-built |
| `--skip-verify` | Пропустить SHA-256 проверку | — |
| `--opencode-config PATH` | Путь к `opencode.json` | авто-поиск |
| `--install-skills` | Скопировать навыки в `.opencode/skills/` | — |
| `-y, --yes` | Non-interactive (без запросов) | — |
| `--help` | Показать справку | — |

Примеры:

```sh
# Обычная установка
./install.sh -y

# С установкой навыков в проект
./install.sh -y --install-skills

# Указать opencode.json вручную
./install.sh --opencode-config /path/to/project/opencode.json

# Кастомная директория
./install.sh --unica-dir /opt/unica-opencode

# Полная сборка из исходников (медленно)
./install.sh -y --build-all
```

### Параметры install.ps1 (Windows)

```powershell
.\install.ps1 [-UnicaDir PATH] [-InstallSkills] [-SkipVerify] [-Help]
```

| Параметр | Назначение | По умолчанию |
|---|---|---|
| `-UnicaDir PATH` | Директория установки | `$env:LOCALAPPDATA\opencode\unica` |
| `-RepoRoot PATH` | Путь к репозиторию | родительская папка скрипта |
| `-SkipVerify` | Пропустить SHA-256 проверку | — |
| `-InstallSkills` | Скопировать навыки в `.opencode\skills\` | — |
| `-Help` | Показать справку | — |

### Что устанавливается

```
~/.local/share/opencode/unica/
├── unica              # MCP-сервер (основной binary)
├── v8-runner          # Запуск 1С:Предприятия
├── bsl-analyzer       # Анализатор BSL-кода
├── rlm-tools-bsl      # RLM-инструменты
├── rlm-bsl-index      # RLM-индексатор
├── third-party/
│   └── manifest.json  # SHA-256 всех бинарников
├── skills/            # Навыки 1С (SKILL.md)
└── build/             # Временные файлы сборки
```

Все компоненты собираются из `third-party/tools.lock.json` репозитория:

| Инструмент | Стратегия |
|---|---|
| `unica` | `cargo build` из `vitebc/unica` |
| `v8-runner` | pre-built из `unica-toolchain` |
| `bsl-analyzer` | pre-built из `unica-toolchain` |
| `rlm-tools-bsl` | pre-built из `unica-toolchain` (Linux — PyInstaller) |
| `rlm-bsl-index` | pre-built из `unica-toolchain` (Linux — PyInstaller) |

### Проверка

```json
{
  "mcp": {
    "unica": {
      "type": "local",
      "command": ["~/.local/share/opencode/unica/unica"],
      "enabled": true
    }
  }
}
```

### Удаление

```sh
rm -rf ~/.local/share/opencode/unica
# Удалить секцию "unica" из opencode.json
```

## Серверный режим (SSE)

Unica можно развернуть на сервере для удалённого доступа.

### One-liner

```sh
curl -fsSL https://github.com/vitebc/unica/raw/main/install-server.sh | sudo bash -s -- -y
```

### Быстрый старт

```sh
# На сервере (Linux):
sudo ./install-server.sh -y

# После установки:
# http://<server-ip>:3100/sse
```

Скрипт `install-server.sh`:
1. Устанавливает Unica (вызывает `install.sh`)
2. Устанавливает Node.js + supergateway (SSE bridge)
3. Создаёт systemd-сервис `unica-mcp`
4. Настраивает автозапуск

### Параметры install-server.sh

```sh
sudo ./install-server.sh [options]
```

| Опция | Назначение | По умолчанию |
|---|---|---|
| `-p, --port PORT` | HTTP порт | `3100` |
| `--host HOST` | Интерфейс (0.0.0.0 — все) | `0.0.0.0` |
| `-u, --unica-dir PATH` | Путь к Unica | `~/.local/share/opencode/unica` |
| `-y, --yes` | Non-interactive | — |

### Подключение с рабочей станции

```json
{
  "mcp": {
    "unica": {
      "type": "remote",
      "url": "http://192.168.1.100:3100/sse",
      "enabled": true
    }
  }
}
```

### Управление сервером

```bash
# Статус
sudo systemctl status unica-mcp

# Логи
sudo journalctl -u unica-mcp -f

# Перезапуск
sudo systemctl restart unica-mcp

# Остановка
sudo systemctl stop unica-mcp
```

### Архитектура

```
┌──────────────────┐     SSE/HTTP      ┌──────────────────┐
│  opencode client  │ ◄──────────────► │  unica server    │
│  (ваша машина)    │   :3100/sse      │  (localhost:3100)│
└──────────────────┘                   └──────────────────┘
                                               │
                                               │ stdio
                                               ▼
                                       ┌──────────────────┐
                                       │  unica MCP       │
                                       └──────────────────┘
```

supergateway транслирует JSON-RPC из HTTP (SSE) в stdio и обратно.
SSE-подписки и JSON-RPC сообщения — оба на пути `/mcp`.
На 5-8 одновременных подключений создаётся по одному процессу unica на каждое.

## Использование с другими агентами

Сервер реализует стандартный MCP (JSON-RPC 2.0 over stdio/SSE).
Подойдёт любой MCP-клиент:

```json
{
  "mcpServers": {
    "unica": {
      "command": ["/path/to/unica"],
      "args": []
    }
  }
}
```

Список всех инструментов (`unica.*`) — после запуска отправьте:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/list"}
```

## Требования

- **Linux**: sudo, curl, git, python3, python3-venv (устанавливаются скриптом)
- **macOS**: brew, git, python3 (устанавливаются скриптом)
- **Windows**: Git for Windows, Rust MSVC toolchain, Microsoft C++ Build Tools + Windows SDK, Python 3.10+
- Node.js, `curl`, `wget`, `jq` для обычной установки не нужны

**GitHub API rate limit**: при частых запусках возможен лимит (60 req/h без токена).
Установите `GITHUB_TOKEN` для увеличения:
```sh
export GITHUB_TOKEN=ghp_xxx
```

## Разработка

```sh
# Сборка
cargo build --release --package unica-coder --bin unica

# Полная проверка
cargo fmt --all -- --check
cargo clippy --package unica-coder --all-targets -- -D warnings
cargo test --package unica-coder

# Проверка MCP
cargo run --quiet --bin unica -- --help
```

## Структура репозитория

- `crates/unica-coder/` — MCP runtime
- `crates/unica-bootstrap/` — загрузчик runtime
- `plugins/unica/skills/` — навыки 1С
- `plugins/unica/third-party/tools.lock.json` — версии bundled tools
- `install.sh` — установка для Linux/macOS
- `install.ps1` — установка для Windows
- `install-server.sh` — установка SSE-сервера

[Авторы, источники и лицензии](plugins/unica/ATTRIBUTIONS.md).
Лицензия Unica: LGPL-3.0-or-later.

Поддерживается синхронизация с upstream (`IngvarConsulting/unica`) через
`git fetch upstream && git rebase upstream/main`.
