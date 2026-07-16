<div align="center">

# Zapret 2 NEXT

**Готовая Windows-сборка Zapret 2 с удобными `.bat`-запусками, подбором стратегии, службой, диагностикой и проверкой целостности**

[![Latest release](https://img.shields.io/github/v/release/Dunterbabochka/zapret2-next?display_name=tag&sort=semver)](https://github.com/Dunterbabochka/zapret2-next/releases/latest)
[![Validate](https://github.com/Dunterbabochka/zapret2-next/actions/workflows/validate.yml/badge.svg)](https://github.com/Dunterbabochka/zapret2-next/actions/workflows/validate.yml)
[![Downloads](https://img.shields.io/github/downloads/Dunterbabochka/zapret2-next/total)](https://github.com/Dunterbabochka/zapret2-next/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)
[![Star this repo](https://img.shields.io/badge/Star-this_repo-yellow?logo=github)](https://github.com/Dunterbabochka/zapret2-next/stargazers)

**Windows 10/11 x64 · Zapret 2 v1.0.2 · Discord · YouTube · WinDivert**

[Скачать последнюю версию](https://github.com/Dunterbabochka/zapret2-next/releases/latest)
·
[Быстрый старт](#quick-start)
·
[Подбор стратегии](#compatibility-wizard)
·
[Service Manager](#service-manager)
·
[Решение проблем](#troubleshooting)

> Если сборка оказалась полезной, поставьте репозиторию **⭐ Star**.  
> Это помогает понять, что проект нужен людям, и мотивирует продолжать развитие.

</div>

---

## Что это такое

**Zapret 2 NEXT** — независимая community-сборка для Windows 10/11 x64 на базе официального движка `winws2` из Zapret 2.

Проект объединяет:

- готовые стратегии для быстрого запуска;
- автоматизированный Compatibility Wizard;
- установку выбранной стратегии как службы Windows;
- отдельные режимы Game Filter, IPSet и Discord Voice;
- диагностику сети и Discord Voice;
- проверку конфигураций, бинарников и SHA256;
- пользовательские списки доменов и IP-исключений;
- инструменты для тестирования и подготовки отчётов.

Это **не VPN, не прокси и не DNS-сервис**. Сборка управляет локальным движком `winws2` и драйвером WinDivert.

> [!IMPORTANT]
> Это не официальный проект и не официальный релиз автора Zapret/Zapret 2.  
> Эффективность стратегии зависит от провайдера, региона, типа подключения, протокола и конкретного способа фильтрации.

> [!WARNING]
> WinDivert работает на уровне сетевого трафика, требует права администратора и может определяться защитным ПО как `RiskTool` или `HackTool`.  
> Скачивайте сборку только из раздела [Releases](https://github.com/Dunterbabochka/zapret2-next/releases) этого репозитория и проверяйте SHA256.

---

## Возможности

| Возможность | Что делает |
|---|---|
| Готовые стратегии | Позволяют запустить один из проверяемых профилей через обычный `.bat` |
| Compatibility Wizard | Локально проверяет шесть публичных стратегий, Discord, YouTube и режимы Discord Voice |
| Service Manager | Устанавливает выбранную конфигурацию как автоматически запускаемую службу Windows |
| Game Filter | Позволяет отдельно включать обработку TCP, UDP или всего игрового трафика |
| IPSet | Ограничивает обработку списком подсетей и поддерживает безопасный fallback |
| Discord Voice | Предлагает режимы `Off`, `Standard` и `Compatible` |
| Пользовательские списки | Позволяют добавлять свои домены, исключения и IP-подсети |
| Диагностика | Проверяет службу, процесс `winws2`, драйвер WinDivert и сетевое окружение |
| Voice Diagnostic | Собирает отдельный отчёт для диагностики Discord Voice |
| Проверка обновлений | Поддерживает ручную и опциональную автоматическую проверку версии |
| Обновление IPSet | Загружает актуальный список и проверяет его формат перед применением |
| Hosts suggestions | Готовит предложения для `hosts`, но не изменяет системный файл автоматически |
| Валидация | Проверяет шаблоны, release policy и закреплённые SHA256 бинарников |
| Тесты пресетов | Генерирует конфигурации и проверяет их через `winws2` |

---

<a id="quick-start"></a>

## Быстрый старт

### Вариант 1 — просто запустить

1. Откройте [последний Release](https://github.com/Dunterbabochka/zapret2-next/releases/latest).
2. Скачайте файл вида:

   ```text
   zapret2-next-vX.Y.Z.zip
   ```

   Не используйте GitHub-архивы **Source code (zip/tar.gz)** как готовую установочную сборку.

3. Распакуйте архив в короткий путь без кириллицы, например:

   ```text
   C:\zapret2-next
   ```

4. Запустите `general.bat` **от имени администратора**.
5. Проверьте Discord, YouTube и нужные сайты.
6. Если стратегия не подходит, закройте текущее окно `winws2` и попробуйте другой `general (...).bat`.

### Вариант 2 — подобрать стратегию

Запустите от имени администратора:

```text
compatibility wizard.bat
```

Wizard проведёт локальную проверку и предложит наиболее подходящую комбинацию. Подробнее: [Compatibility Wizard](#-compatibility-wizard).

### Вариант 3 — установить как службу

Запустите от имени администратора:

```text
service.bat
```

Выберите **Install Service**, затем стратегию. Служба `winws2` будет запускаться вместе с Windows.

---

## Что запускать

| Файл | Назначение |
|---|---|
| `general.bat` | Рекомендуемая стартовая стратегия |
| `general (ALT).bat` | Альтернативный профиль с `fakedsplit` |
| `general (ALT3).bat` | Профиль с `hostfakesplit` |
| `general (ALT5).bat` | Профиль `syndata + multidisorder` |
| `general (ALT11).bat` | Многоэтапный `multisplit` |
| `general (FAKE TLS AUTO ALT2).bat` | Профиль с auto-TTL и `multisplit` |
| `compatibility wizard.bat` | Автоматизированный подбор совместимой конфигурации |
| `service.bat` | Установка, удаление и настройка службы |
| `diagnose discord voice.bat` | Расширенная диагностика Discord Voice |
| `START BETA TEST.bat` | Контролируемое тестирование с формированием отчёта |

---

## Стратегии

### Основные публичные стратегии

| Стратегия | Краткое описание | Когда пробовать |
|---|---|---|
| `general` | `fake + multisplit` | Начните с неё |
| `ALT` | `fake + fakedsplit` | Если `general` не помогает |
| `ALT3` | `hostfakesplit` | Альтернативная обработка HTTP/TLS |
| `ALT5` | `syndata + multidisorder` | Если split-профили работают нестабильно |
| `ALT11` | Многоэтапный `multisplit` | Более сложный fallback |
| `FAKE TLS AUTO ALT2` | auto-TTL + `multisplit` | Для сетей, где помогает подбор TTL |

### Экспериментальные профили

В `service.bat` также доступны opt-in профили:

| Профиль | Характер |
|---|---|
| `CUSTOM SAFE` | Минимальное вмешательство; рекомендуется проверять первым |
| `ALT12` | Зафиксированный проверяемый fallback |
| `CUSTOM BALANCED` | Более сильный вариант, если SAFE не подходит |

Экспериментальные профили:

- не выбираются Compatibility Wizard автоматически;
- не гарантируют работу у любого провайдера;
- должны проверяться отдельно в вашей сети;
- могут вести себя по-разному для web, Discord Voice, QUIC и игр.

Подробности:

- [Описание экспериментальных профилей](docs/CUSTOM-PRESETS.md)
- [Таблица их параметров](docs/CUSTOM-PARAMETERS.md)

---

<a id="compatibility-wizard"></a>

## Compatibility Wizard

`compatibility wizard.bat` — локальный мастер проверки совместимости. Он не обращается к AI-сервисам и не отправляет отчёт автоматически.

Wizard выполняет четыре основных этапа:

1. Проверяет окружение и обнаруживает конфликтующие Zapret-процессы, службы, VPN/proxy и сетевые особенности.
2. Выполняет первый проход по шести публичным web-стратегиям.
3. Повторно тестирует лучшие кандидаты, проверяет выбранную стратегию с IPSet и просит вручную подтвердить Discord/YouTube.
4. Проверяет режимы Discord Voice и повторяет точную финальную комбинацию перед созданием отчёта.

Особенности:

- конфликтующие процессы останавливаются только после явного подтверждения;
- мастер пытается восстановить состояние, которое остановил;
- пользовательские настройки не устанавливаются и не сохраняются автоматически;
- `GameMode` во время Wizard остаётся выключенным;
- `IPSet=any` используется только для диагностического поиска и не выдаётся как постоянная рекомендация;
- результат создаётся в:

  ```text
  runtime\compatibility-results\
  ```

> [!CAUTION]
> Итоговый отчёт может содержать провайдера и регион, IP-адреса и порты, PID, временные метки, локальные пути, логи `winws2` и отфильтрованные метаданные PktMon.  
> Не публикуйте ZIP из диагностики без предварительной проверки и удаления данных, которыми вы не готовы делиться.

---

<a id="service-manager"></a>

## Service Manager

`service.bat` — центральное меню управления установленной конфигурацией.

### Служба

- установка `winws2` как службы Windows;
- удаление службы и регистраций WinDivert;
- просмотр текущего статуса;
- отображение выбранной стратегии и режимов;
- автоматический запуск вместе с Windows.

### Настройки

#### Game Filter

| Режим | Обработка |
|---|---|
| `Off` | Игровой fallback выключен |
| `TCP and UDP` | Включены TCP и UDP |
| `TCP only` | Только TCP |
| `UDP only` | Только UDP |

#### IPSet Filter

- `loaded` — использовать `lists/ipset-all.txt`;
- `none` — не использовать IPSet;
- `any` — только диагностический режим, не сохраняется как постоянная настройка Service Manager.

Если `IPSet=loaded`, но список отсутствует или пуст, renderer безопасно переключается на пустой fallback и не превращает правило в обработку всего трафика.

#### Discord Voice

| Режим | Назначение |
|---|---|
| `Off` | Защищает Discord/STUN от игрового UDP fallback |
| `Standard` | Официальный discovery-fake профиль |
| `Compatible` | Сохранённая подтверждённая последовательность Voice |

### Обновления и инструменты

Service Manager также умеет:

- включать или отключать автоматическую проверку обновлений;
- вручную проверять наличие новой версии;
- обновлять IPSet;
- готовить предложения для системного `hosts`;
- запускать диагностику;
- запускать тесты пресетов.

Системный файл `hosts` автоматически не изменяется.

---

## Пользовательские списки

Готовый Release содержит безопасные шаблоны:

```text
lists\list-general-user.txt
lists\list-exclude-user.txt
lists\ipset-exclude-user.txt
```

| Файл | Назначение |
|---|---|
| `list-general-user.txt` | Дополнительные домены для обработки |
| `list-exclude-user.txt` | Домены, которые необходимо исключить |
| `ipset-exclude-user.txt` | IP-адреса и подсети, которые необходимо исключить |

Добавляйте по одному значению на строку. Не публикуйте пользовательские списки, если в них находятся личные, домашние или корпоративные адреса.

---

## Диагностика Discord Voice

Запустите:

```text
diagnose discord voice.bat
```

Диагностика может:

- запустить временную конфигурацию с отладочным логом;
- проверить свежий Discord/STUN handshake;
- собрать сведения о TCP/UDP-соединениях Discord;
- использовать PktMon для метаданных сетевых пакетов;
- попросить подтвердить двусторонний звук, ping и screen share;
- сформировать `REPORT.txt` и диагностический ZIP.

Результаты сохраняются в:

```text
runtime\voice-diagnostic-YYYYMMDD-HHMMSS\
```

> [!WARNING]
> Диагностические файлы могут раскрывать IP-адреса, порты, PID, время соединений, локальные пути и посещённые SNI-домены.  
> Не прикладывайте полный отчёт к публичному Issue без ручной очистки.

---

## Проверка и тестирование

### Проверка шаблонов и политики сборки

```powershell
powershell -ExecutionPolicy Bypass -File .\utils\validate.ps1
```

### Проверка рантайма и SHA256

```powershell
powershell -ExecutionPolicy Bypass -File .\utils\validate-runtime.ps1
```

### Проверка стандартных пресетов

```powershell
powershell -ExecutionPolicy Bypass -File .\utils\test-presets.ps1 -Suite standard
```

Проверка рантайма и сетевые тесты могут требовать PowerShell с правами администратора.

Результаты сохраняются в:

```text
runtime\test-results
```

> Тесты подтверждают корректность конфигурации и наблюдаемое поведение в конкретном окружении, но не гарантируют совместимость с любым провайдером.

---

## Проверка SHA256

В Release публикуется:

```text
release-sha256.txt
```

Пример проверки архива в PowerShell:

```powershell
Get-FileHash .\zapret2-next-vX.Y.Z.zip -Algorithm SHA256
```

Сравните полученное значение с хэшем из `release-sha256.txt`.

Закреплённая версия движка и контрольные суммы бинарников находятся в [`ENGINE_VERSION`](ENGINE_VERSION). GitHub Actions проверяет SHA256 `winws2.exe`, `WinDivert.dll`, `WinDivert64.sys`, `cygwin1.dll` и `killall.exe` при push и pull request.

---

## Обновление с предыдущей версии

Рекомендуемый порядок:

1. Запомните выбранную стратегию и режимы.
2. Через старый `service.bat` удалите службу.
3. Скачайте новый Release ZIP.
4. Распакуйте его в отдельную новую папку.
5. Перенесите только свои пользовательские списки:

   ```text
   lists\list-general-user.txt
   lists\list-exclude-user.txt
   lists\ipset-exclude-user.txt
   ```

6. Не переносите старые `runtime`, логи, сгенерированные конфиги и бинарники.
7. Запустите новый `service.bat` и установите службу заново.

---

<a id="troubleshooting"></a>

## Если что-то не работает

### Сначала попробуйте

1. Убедитесь, что файл запущен от имени администратора.
2. Закройте другие DPI-bypass инструменты.
3. На время проверки отключите VPN и proxy.
4. Убедитесь, что не запущено несколько экземпляров `winws2.exe`.
5. Попробуйте `general.bat`, затем остальные основные стратегии.
6. Запустите `compatibility wizard.bat`.
7. Проверьте статус через `service.bat`.
8. Запустите диагностику.

### Частые вопросы

<details>
<summary><strong>Антивирус ругается на WinDivert. Это вирус?</strong></summary>

WinDivert — сетевой драйвер, который перехватывает и изменяет сетевой трафик. Из-за этого защитное ПО может классифицировать его как RiskTool/HackTool. Скачивайте сборку только из Releases этого репозитория и сверяйте SHA256.

</details>

<details>
<summary><strong>Почему одна стратегия работает, а другая нет?</strong></summary>

Стратегии используют разные способы обработки пакетов. Результат зависит от провайдера, маршрута, протокола, IPv4/IPv6, QUIC и текущей конфигурации фильтрации.

</details>

<details>
<summary><strong>Почему нельзя скачивать Source code ZIP?</strong></summary>

GitHub автоматически создаёт Source code ZIP из отслеживаемых файлов репозитория. Готовый release-архив дополнительно собирается проектным скриптом и предназначен для запуска пользователем.

</details>

<details>
<summary><strong>Wizard сам установит найденную конфигурацию?</strong></summary>

Нет. Wizard создаёт отчёт и рекомендацию, но не устанавливает и не сохраняет выбранную конфигурацию автоматически.

</details>

<details>
<summary><strong>Можно публиковать диагностический ZIP?</strong></summary>

Только после ручной проверки. Он может содержать IP-адреса, порты, PID, временные метки, локальные пути и подробные логи сетевой активности.

</details>

---

## Структура проекта

| Путь | Содержимое |
|---|---|
| `bin/` | `winws2`, WinDivert, Cygwin и вспомогательные бинарники |
| `lua/` | Lua-библиотеки и профили Zapret 2 |
| `presets/` | Шаблоны стратегий |
| `lists/` | Доменные списки и IPSet |
| `utils/` | Renderer, Wizard, диагностика, тесты и сборка Release |
| `.service/` | Служебные данные для обновлений и конфигурации |
| `runtime/` | Локальные сгенерированные конфиги, логи и отчёты |
| `docs/` | Дополнительная техническая документация |
| `.github/` | GitHub Actions и шаблоны Issues |

---

## Документация

- [Запуск и структура launchers](docs/LAUNCH.md)
- [Экспериментальные профили](docs/CUSTOM-PRESETS.md)
- [Параметры экспериментальных профилей](docs/CUSTOM-PARAMETERS.md)
- [Ручное тестирование](docs/MANUAL_TEST.md)
- [Таблица подтверждённой совместимости](docs/COMPATIBILITY.md)
- [Политика безопасности](SECURITY.md)
- [Сторонние компоненты и лицензии](THIRD_PARTY_NOTICES.md)

---

## Сообщения об ошибках и результаты тестов

Для отчёта о совместимости используйте шаблон Issue и укажите:

- версию Windows;
- провайдера и регион без лишних персональных данных;
- использованную стратегию;
- состояние Discord Web, Discord App, Voice и YouTube;
- воспроизводимые шаги;
- очищенные фрагменты логов.

Не публикуйте:

- raw packet captures;
- полный `winws2-debug.log`;
- личные IP/MAC-адреса;
- локальные пути с именем пользователя;
- токены, cookies и другие секреты.

Уязвимости безопасности не следует публиковать в обычных Issues — см. [`SECURITY.md`](SECURITY.md).

---

## Правовые условия и отказ от гарантий

Проект предоставляется «как есть», без гарантий работоспособности в конкретной сети.

Пользователь самостоятельно отвечает за:

- соблюдение применимого законодательства;
- соблюдение правил провайдера, организации и локальной сети;
- резервное копирование настроек;
- проверку загружаемых бинарников и контрольных сумм;
- безопасное обращение с диагностическими отчётами.

---

## Лицензия и благодарности

Код этой сборки распространяется по лицензии MIT. Сторонние компоненты имеют собственные лицензии и условия.

Основные проекты:

- [bol-van/zapret2](https://github.com/bol-van/zapret2) — движок `winws2` и Lua API;
- [basil00/WinDivert](https://github.com/basil00/WinDivert) — драйвер перехвата трафика;
- Cygwin runtime;
- другие компоненты, перечисленные в [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

---

<div align="center">

## Поддержать проект

Если Zapret 2 NEXT помог вам настроить соединение, сэкономил время или просто оказался удобнее ручной настройки — нажмите **⭐ Star** в верхней части страницы.

Звёздочка ничего не стоит, но помогает проекту стать заметнее и показывает, что дальнейшая разработка имеет смысл.

[⭐ Поставить звезду](https://github.com/Dunterbabochka/zapret2-next)

</div>

---

## English summary

Zapret 2 NEXT is an independent Windows 10/11 x64 bundle built around the official Zapret 2 `winws2` engine and Lua API. It provides ready-to-use launchers, a local Compatibility Wizard, Windows service management, Game/IPSet/Discord Voice modes, diagnostics, validation and reproducible release tooling.

Download only the project release archive, verify SHA256, and remember that strategy effectiveness varies by provider and network.