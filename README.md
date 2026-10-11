<div align="center">

# Zapret 2 NEXT

**Zapret 2 для Windows 10/11 x64: выбор стратегии, автозапуск и управление через одно меню.**

[![Latest release](https://img.shields.io/github/v/release/Dunterbabochka/zapret2-next?display_name=tag&sort=semver)](https://github.com/Dunterbabochka/zapret2-next/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Dunterbabochka/zapret2-next/total)](https://github.com/Dunterbabochka/zapret2-next/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

[Скачать](https://github.com/Dunterbabochka/zapret2-next/releases/latest) · [Быстрый старт](#quick-start) · [Помощь проекту](#help-project)

</div>

Сборка помогает настроить доступ к Discord, YouTube и другим сайтам. Для Telegram Desktop есть отдельный встроенный модуль. Устанавливать Python не нужно.

Подходящая стратегия зависит от провайдера и сети. Это независимая сборка на основе [Zapret 2](https://github.com/bol-van/zapret2).

## Что нового в 0.4.1

- **Быстрее меню `service.bat`**: ускорены переходы и обновление статусов.
- **11 стратегий Classic/NEXT**: добавлены ALT13 и EXP, ALT12 доступна в обычном меню. CUSTOM SAFE/BALANCED теперь называются NEXT SAFE/BALANCED; старые имена сохранены для совместимости.
- **Автоматический отчёт для помощи**: пункт **13. Run Diagnostics → 2. Create support report (automatic)** проверяет окружение и стратегии, готовит ZIP для GitHub и восстанавливает прежнее состояние службы. Подробные локальные логи в ZIP не включаются.
- **Проще начать и обратиться за помощью**: краткая инструкция вокруг `service.bat`, русская форма обращения с провайдером и необязательным регионом, дополнительный контакт в Discord.
- **Меньше файлов в корне**: здесь остался только `service.bat` среди BAT; стратегии находятся в `strategies`, вспомогательные инструменты — в `utils`, подробные инструкции — в `docs`.
- **Обновлены сборка и проверки**: новая структура ZIP, Telegram-модуль, тесты стратегий, отчётов и восстановления службы.

При обновлении распакуйте релиз в отдельную папку и переустановите службу по [инструкции ниже](#updating).

<a id="quick-start"></a>

## Быстрый старт

1. Откройте [последний релиз](https://github.com/Dunterbabochka/zapret2-next/releases/latest) и скачайте **`zapret2-next-vX.Y.Z.zip`** из **Assets**. Архив **Source code** для установки не подходит.
2. Распакуйте ZIP, например в `C:\zapret2-next`.
3. Откройте **`service.bat`** и подтвердите запрос прав администратора Windows.
4. При необходимости настройте **Game Filter** и **Discord Voice**. Для начала можно оставить исходные настройки.
5. Выберите **1. Install Service**, затем стратегию **general** и подтвердите установку.
6. Проверьте нужные сайты и приложения. Если результат не подошёл, снова выберите **1. Install Service** и другую стратегию.

Готово: Zapret работает в фоне и запускается вместе с Windows. Закрыть окно меню можно. Для просмотра состояния используйте **3. Check Status**, для отключения — **2. Remove Service**.

После установки оставьте папку сборки на месте: служба запускается из неё.

## Telegram Desktop

В `service.bat` откройте **9. Telegram → 1. Enable and connect Telegram**. В Telegram подтвердите подключение к предложенному прокси.

Модуль будет запускаться при входе в Windows. Чтобы отключить его, выберите **4. Disable proxy** в меню Telegram и выключите прокси в самом приложении. [Подробнее о Telegram](docs/TELEGRAM.md).

<a id="troubleshooting"></a>

## Если что-то не работает

- Проверьте **3. Check Status** в `service.bat` и попробуйте другую стратегию через **1. Install Service**.
- На время проверки закройте другие сборки Zapret, VPN и сторонние прокси.
- Откройте **13. Run Diagnostics → 1. Quick check**, чтобы проверить компоненты и окружение.
- Если ни одна стратегия не помогла, подготовьте отчёт по инструкции ниже.

<a id="help-project"></a>

## Помощь проекту

Не подошла ни одна стратегия? Ваш результат поможет улучшить сборку:

1. Откройте **`service.bat` → 13. Run Diagnostics → 2. Create support report (automatic)**.
2. Укажите **провайдера** и, желательно, **область или город** — это необязательно. Подтвердите начало проверки.
3. Дождитесь окончания: проверка сама переберёт стратегии и подготовит ZIP в **`runtime\support-reports`**. Прежнее состояние службы будет восстановлено.
4. [Создайте обращение на GitHub](https://github.com/Dunterbabochka/zapret2-next/issues/new?template=strategy-report.yml), приложите **созданный ZIP** и кратко напишите, что не работает. Провайдер обязателен, область или город — по желанию.

Отчёт для отправки формируется автоматически; подробные локальные логи остаются отдельно. Ничего не отправляется без вашего участия. [Что проверяет диагностика](docs/SUPPORT.md).

Дополнительно можно связаться в **Discord: `codeinoslav1488`**.

Если сборка помогла, поддержите проект **[⭐ звездой](https://github.com/Dunterbabochka/zapret2-next)** — это помогает другим найти его.

## Частые вопросы

<details>
<summary><strong>Какую стратегию выбрать?</strong></summary>

Начните с `general`, затем попробуйте остальные через **1. Install Service**. Универсальной стратегии для всех сетей нет. Для расширенного подбора доступен **13. Run Diagnostics → 3. Compatibility Wizard (advanced)**.

</details>

<details>
<summary><strong>Нужно ли открывать service.bat после каждой перезагрузки?</strong></summary>

После установки службы — нет. Она запускается автоматически. Меню нужно для смены стратегии, настроек и диагностики.

</details>

<details>
<summary><strong>Антивирус реагирует на WinDivert — что делать?</strong></summary>

WinDivert — компонент обработки сетевого трафика, который некоторые антивирусы определяют как RiskTool/HackTool. Скачивайте сборку из [Releases этого проекта](https://github.com/Dunterbabochka/zapret2-next/releases). При срабатывании проверьте название обнаруженного файла и результат **Quick check**.

</details>

<a id="updating"></a>

<details>
<summary><strong>Как обновиться?</strong></summary>

Удалите старую службу через **2. Remove Service**. Если включён Telegram-модуль, отключите его через **9. Telegram → 4. Disable proxy**. Распакуйте новый релиз в отдельную папку и установите службу из нового `service.bat`. Свои списки можно перенести из старой папки `lists`; старые логи и конфиги переносить не нужно.

</details>

## Подробнее

- [Расширенное руководство: настройки, стратегии и Wizard](docs/ADVANCED.md)
- [Telegram Desktop](docs/TELEGRAM.md)
- [Подтверждённая совместимость](docs/COMPATIBILITY.md)
- [Тестирование и подготовка релизов](docs/MAINTAINING.md)
- [Безопасность](SECURITY.md) · [Сторонние компоненты](THIRD_PARTY_NOTICES.md)

Код сборки распространяется по [MIT](LICENSE.txt). Используются [Zapret 2](https://github.com/bol-van/zapret2), [WinDivert](https://github.com/basil00/WinDivert) и [Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy). Проект предоставляется «как есть».
