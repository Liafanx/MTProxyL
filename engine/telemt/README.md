# Сборки telemt с патчами

Наборы патчей к telemt и сборка бинарников с ними workflow
`.github/workflows/build-telemt-custom.yml`. Готовая сборка ставится как свой
бинарник: `mtproxyl engine custom <ссылка на архив>`.

## Устройство

```
engine/telemt/
  DEFAULT          набор для проверочной сборки из ветки engine-build
  apply.sh         клон telemt, checkout, git am серии
  package.sh       strip, архив и sha256 с именами как у релизов telemt
  annotate.sh      ошибки сборки и тестов — в аннотации GitHub
  <набор>/
    base           тег или коммит telemt, к которому применяется серия
    series         порядок патчей
    NNNN-*.patch   патчи в формате git format-patch
```

## Запуск

- **Run workflow** (Build Telemt Custom): набор, при необходимости другой тег
  telemt, ревизия и публикация.
- Тег `telemt-<набор>-mtproxyl-<ревизия>`, например `telemt-3.5.7-mtproxyl-r1`:
  сборка и prerelease с этим тегом.
- Пуш в ветку `engine-build`: тесты и сборка набора из `DEFAULT` без публикации.

Собираются `x86_64`, `x86_64-v3` и `aarch64` под glibc и musl, как в релизах
telemt, плюс `cargo test`. Релиз публикуется только при зелёных тестах и
сборке, как prerelease и без отметки latest.

## Набор 3.5.7

База — telemt 3.5.7. Патчи перенесены с серии для 3.4.25 (наложение на
отрефакторенный код 3.5.x — вручную, логика не менялась):

1. Пауза с джиттером между неудачными попытками добора ME-писателя.
2. `malloc_trim` раз в минуту — память возвращается системе (только glibc: у
   musl этой функции нет, а его аллокатор и так отдаёт страницы).
3. Потолок активных писателей на один DC (`floor_max`) при допуске.
4. Частичная деградация ME: при потере одного DC в Direct уходят только его
   сессии, остальные остаются на Middle-End; после восстановления DC такие
   сессии возвращаются на ME переподключением (гистерезис 10 с). Ключи
   `general.me_direct_to_me_recovery_enabled`,
   `general.me_direct_to_me_recovery_hysteresis_secs`; метрики
   `telemt_me_admission_configured_dcs`, `telemt_me_admission_ready_dcs`,
   `telemt_me_partial_degradation_active`.

## Новый набор

Скопировать серию в `engine/telemt/<набор>/`, записать тег в `base`, проверить
локально `bash engine/telemt/apply.sh <тег> engine/telemt/<набор> /tmp/src`, затем
пуш в `engine-build`.
