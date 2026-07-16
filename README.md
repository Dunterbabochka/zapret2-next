<div align="center">

# Zapret 2 NEXT

**Сборка для Windows с готовыми стратегиями Zapret 2**

Windows 10/11 x64 · Zapret 2 v1.0.2 · Discord · YouTube

</div>

> [!WARNING]
> Драйвер WinDivert запрашивает права администратора и может помечаться защитным ПО как RiskTool. Скачивайте архивы только из [Releases](../../releases) этого репозитория и проверяйте SHA256.

## Быстрый старт

1. Скачайте актуальный архив из [Releases](../../releases) и распакуйте его. Для стабильной работы используйте короткий путь без кириллицы, например `C:\zapret2-next`.
2. Запустите `general.bat` от имени администратора.
3. Если базовая стратегия не помогает, остановите `winws2.exe` и попробуйте один из сценариев `general (…).bat`.
4. Чтобы запускать стратегию вместе с Windows, откройте `service.bat` от имени администратора, выберите **Install Service** и укажите нужный профиль.

## Что входит в сборку

| Компонент | Назначение |
|---|---|
| Движок | Официальный `winws2` из Zapret 2 v1.0.2 |
| Стратегии | Lua API Zapret 2: `--lua-desync`, `--payload`, `--out-range` |
| Запуск | Отдельные `general*.bat` и общий сценарий запуска |
| Служба | Встроенная служба Windows `winws2` |
| Дополнительно | Фильтр игрового трафика, IPSet и пользовательские списки |

Это самостоятельная community-сборка, а не официальный проект или релиз bol-van. Эффективность каждой стратегии зависит от сети, провайдера и типа блокировки.

## Стратегии v0.1.0

- `general` — стартовая стратегия: fake + multisplit;
- `ALT` — fake + fakedsplit;
- `ALT3` — hostfakesplit;
- `ALT5` — syndata + multidisorder;
- `ALT11` — многоэтапный multisplit;
- `FAKE TLS AUTO ALT2` — auto-TTL + multisplit;

В `service.bat` также доступны три opt-in экспериментальных профиля, подтверждённых чистыми web- и Discord Voice-тестами на сети владельца:

- `CUSTOM SAFE` — рекомендуемый вариант с минимальным вмешательством;
- `ALT12` — проверенный fallback;
- `CUSTOM BALANCED` — более сильный вариант, если SAFE не подходит.

Экспериментальные профили не выбираются Compatibility Wizard автоматически и не являются обещанием совместимости с любым провайдером. `CUSTOM AGGRESSIVE` в публичный архив намеренно не включён: для него нет отдельного Voice acceptance.

Профили не универсальны: проверяйте их по очереди и сохраняйте тот, который работает в вашей сети. Если один вариант не подходит, это не означает, что не подойдут остальные.

## Service Manager

`service.bat` управляет службой `winws2`, выбранной стратегией, фильтром игрового трафика, IPSet, обновлением списков и диагностикой. В меню установки после шести основных стратегий показаны `CUSTOM SAFE`, `ALT12` и `CUSTOM BALANCED` с их статусами. Он также готовит подсказки для файла hosts; системный файл hosts автоматически не изменяется.

Если выбран `IPSet=loaded`, но `lists/ipset-all.txt` пуст или отсутствует, renderer безопасно использует `ipset-none.txt`. Пустой список не превращает IPSet fallback в обработку всего трафика. Режим `IPSet=any` оставлен только для явных диагностических overrides: service не сохраняет его как рабочий режим, а Compatibility Wizard не выдаёт его как постоянную рекомендацию.

Пользовательские списки находятся здесь:

- `lists/list-general-user.txt`;
- `lists/list-exclude-user.txt`;
- `lists/ipset-exclude-user.txt`.

## Проверка и тестирование

```powershell
powershell -ExecutionPolicy Bypass -File .\utils\validate.ps1
powershell -ExecutionPolicy Bypass -File .\utils\validate-runtime.ps1
powershell -ExecutionPolicy Bypass -File .\utils\test-presets.ps1 -Suite standard
```

Проверка рантайма и тесты стратегий требуют запуска PowerShell от имени администратора. Результаты тестов сохраняются в `runtime/test-results`.

Тесты не гарантируют работоспособность в конкретной сети: доступность Windows-служб, провайдер, протокол и настройки сети влияют на результат. Не используйте их как обещание обхода блокировок.

## Обновления и безопасность

Версия движка и SHA256 зафиксированы в `ENGINE_VERSION`. После обновления сверяйте этот файл с содержимым Release. Сведения о сторонних компонентах и лицензиях приведены в `THIRD_PARTY_NOTICES.md`.

## English summary

Zapret 2 NEXT is an independent Windows 10/11 x64 bundle combining a familiar batch-file workflow with the official Zapret 2 `winws2` engine and Lua strategy API. Download releases only from this repository, verify SHA256, and expect strategy effectiveness to vary by network.

## Лицензия

Код этой сборки распространяется по MIT. Используемые сторонние компоненты имеют собственные лицензии и условия. См. `LICENSE.txt` и `THIRD_PARTY_NOTICES.md`.
