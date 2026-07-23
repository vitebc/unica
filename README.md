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

### Локально (stdio)

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

После установки скрипт сам найдёт или создаст `opencode.json` с MCP-сервером.
Перезапустите OpenCode — инструменты `unica.*` станут доступны.

Поддерживаемые ОС: Linux x86_64, macOS ARM64, Windows x64.

### Сервер (SSE)

Для удалённого доступа с рабочих станций:

```sh
sudo ./install-server.sh -y
```

Сервер будет доступен по `http://<ip>:3001/mcp`. В `opencode.json`
на рабочей станции:

```json
{
  "mcp": {
    "unica": {
      "type": "remote",
      "url": "http://192.168.1.100:3001/mcp",
      "enabled": true
    }
  }
}
```

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

На Windows x64 нужны:
- Git for Windows (`git`)
- Rust MSVC toolchain (`cargo` из [rustup.rs](https://rustup.rs))
- Microsoft C++ Build Tools и Windows SDK
- Python 3.10+ для rlm-tools-bsl

## Структура

- `crates/unica-coder/` — MCP runtime
- `crates/unica-bootstrap/` — загрузчик runtime
- `plugins/unica/skills/` — навыки 1С
- `plugins/unica/third-party/tools.lock.json` — версии bundled tools
- `install.sh` — установка для OpenCode
- `install-server.sh` — установка SSE-сервера

[Авторы, источники и лицензии](plugins/unica/ATTRIBUTIONS.md).
Лицензия Unica: LGPL-3.0-or-later.

Поддерживается синхронизация с upstream (`IngvarConsulting/unica`) через
`git fetch upstream && git rebase upstream/main`.
