# Подготовка релизов

Инструкции для сопровождающих проекта. Пользовательский запуск описан в [README](../README.md).

## Бета-тестирование

Бета-канал — добровольная проверка будущей версии до стабильного релиза. Бета-версия публикуется как обычный GitHub **Pre-release** и не заменяет последнюю стабильную версию.

### Как принять участие

1. Откройте [все Releases](https://github.com/Dunterbabochka/zapret2-next/releases) и выберите версию с пометкой **Pre-release**, например `v0.5.0-beta.1`.
2. Скачайте `zapret2-next-vX.Y.Z-beta.N.zip` и `release-sha256.txt`. Не скачивайте автоматически созданный **Source code ZIP**.
3. [Сверьте SHA256](#проверка-sha256) и распакуйте beta в отдельную папку. Не копируйте её поверх стабильной установки.
4. Запустите `utils/START BETA TEST.bat` от имени администратора и пройдите Compatibility Wizard.
5. Проверьте Discord Web/App, Voice в обе стороны, демонстрацию экрана, YouTube и восстановление прежнего состояния Zapret.
6. Создайте [Beta report](https://github.com/Dunterbabochka/zapret2-next/issues/new?template=beta-report.yml). Итоговый ZIP находится в `runtime\compatibility-results`.

> [!WARNING]
> Диагностический ZIP может содержать IP-адреса, порты, PID, временные метки, локальные пути и подробные сетевые логи. Перед публикацией обязательно проверьте вложение и отправляйте только те данные, которыми готовы поделиться. Не публикуйте raw packet captures, токены или cookies.

Если beta мешает работе, закройте её процессы, удалите beta-папку и продолжайте использовать стабильную версию. Не устанавливайте beta как службу до успешной ручной проверки.

### Как опубликовать beta

Владельцу проекта достаточно создать и отправить prerelease-тег:

```powershell
git tag -a v0.5.0-beta.1 -m "Zapret 2 NEXT v0.5.0-beta.1"
git push origin v0.5.0-beta.1
```

Теги с суффиксом `-alpha`, `-beta` или `-rc` автоматически:

- проходят полную валидацию;
- собираются в единый пользовательский ZIP;
- получают `utils/START BETA TEST.bat` и краткую инструкцию;
- публикуются как открытый GitHub Pre-release вместе с `release-sha256.txt`.

Стабильные теги без prerelease-суффикса по-прежнему создают draft для финальной ручной проверки.

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

Закреплённая версия движка и контрольные суммы бинарников находятся в [`ENGINE_VERSION`](../ENGINE_VERSION). GitHub Actions проверяет SHA256 `winws2.exe`, `WinDivert.dll`, `WinDivert64.sys`, `cygwin1.dll` и `killall.exe` при push и pull request.

---


## Сборка

Из корня проекта:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\build-release.ps1 -Version 0.4.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\build-release.ps1 -Version 0.5.0-beta.1 -Beta
```

Стабильная версия должна совпадать с `.service/version.txt`. Сборщик сохраняет ZIP, распакованную папку и `release-sha256.txt` в `dist`. Это воспроизводимые результаты сборки, а не рабочие данные основной установки. Папку можно удалить, если её копии не используются и архивы не нужны.

Перед выпуском выполните [проверки Windows](MANUAL_TEST.md) и тесты автоматического отчёта:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\validate-support.ps1
```
