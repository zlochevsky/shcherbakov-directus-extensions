# shcherbakov Directus extensions

Кастомные interface-расширения для Directus-инстанса на `db.sch.com.ru`
(контейнер `perf-directus-1`, VPS `bgm` в `~/.ssh/config`). Обслуживают сайт
[schugo](https://github.com/zlochevsky/shcherbakov).

Это **исходники**. Живая (собранная) копия лежит на сервере в
`/var/www/sch.com.ru/perf/extensions/` — сюда, в git, `dist/` не коммитится
(см. `.gitignore`), собирается заново при каждом деплое.

`super-table` (directus-extension-super-table) в этот репозиторий не входит —
это стороннее расширение с маркетплейса, своя версионность на
https://github.com/smartlabsAT/directus-super-table, у нас только собранный
`index.js` на сервере.

## Расширения

### `setlist-editor`
Интерфейс на O2M-alias поле `events.songs_performed`. Инлайн-ввод исполнений
концерта с автокомплитом песни по названию (без модалки, без чекбоксов):
печатаете название — Directus ищет по `works` (`name`/`fname`/`incipit`/
`fincipit`/`sort`, явный `_icontains`, не `?search=` — у него в этой базе
известный баг с точным словом кириллицей), Enter/клик создаёт `perfs` с FK на
песню. В строке — чекбоксы нескольких булевых параметров исполнения
(`PARAM_FIELDS` в начале `interface.vue`, там же список остальных ~20 доступных
полей и что чем не стоит захламлять эту форму).

### `perf-picker`
M2O-интерфейс для полей, ссылающихся на *уже существующее* исполнение
(`perfs.id`) — например `sets_entries.perfs_id`. В отличие от
`setlist-editor` ничего не создаёт, только ищет и пишет FK. Тот же паттерн
поиска (`_icontains` по `works_id.*`), плюс сам `id` исполнения — можно найти
по части кода концерта, если песня исполнялась не раз.

## Деплой (вручную, через SSH на `bgm`)

Готового CI/CD нет — разворачивается руками при каждой правке. Несколько
граблей, найденных 2026-09-22 — без них сборка либо падает, либо тихо не
устанавливает зависимости:

1. **`NODE_ENV=production` в контейнере** → голый `npm install` молча
   пропускает `devDependencies` (там как раз `@directus/extensions-sdk` и
   `vue`) без единой ошибки — просто не ставит. Обязательно
   `npm install --include=dev`.
2. **`extensions/` на хосте — bind mount** (`/var/www/sch.com.ru/perf/extensions`
   → `/directus/extensions`). npm-кэш внутри контейнера и bind-mount —
   разные точки монтирования; `npm install` прямо в bind-mounted папке
   резолвит зависимости (package-lock честный), но не извлекает их на диск
   (node_modules остаётся futile ~100КБ вместо ~200+МБ), без единой ошибки.
   Собирать нужно **во временной директории внутри самого контейнера**
   (`/tmp/build-...`), а наружу копировать только готовый `dist/index.js`.
3. **`EXTENSIONS_AUTO_RELOAD` не включён** → Directus не видит новые/
   изменённые расширения без `docker compose restart directus`.
4. **Кэш браузера**: после рестарта иногда нужно жёсткое обновление
   вкладки Directus Studio (Ctrl+Shift+R), обычный F5 может отдать старый
   JS-бандл интерфейса.

Полная последовательность на пример `setlist-editor` (для `perf-picker` —
аналогично, поменять имя папки):

```sh
# 1. Залить исходники в bind-mounted папку на сервере
scp src/index.js src/interface.vue package.json \
    bgm:/var/www/sch.com.ru/perf/extensions/setlist-editor/src/  # ...package.json на уровень выше
ssh bgm 'chown -R shchperf:docker /var/www/sch.com.ru/perf/extensions/setlist-editor'

# 2. Собрать ВНУТРИ контейнера, во временной (не bind-mounted) директории
ssh bgm '
  docker exec perf-directus-1 sh -c "rm -rf /tmp/build-setlist-editor && mkdir -p /tmp/build-setlist-editor/src"
  docker cp /var/www/sch.com.ru/perf/extensions/setlist-editor/package.json   perf-directus-1:/tmp/build-setlist-editor/package.json
  docker cp /var/www/sch.com.ru/perf/extensions/setlist-editor/src/index.js   perf-directus-1:/tmp/build-setlist-editor/src/index.js
  docker cp /var/www/sch.com.ru/perf/extensions/setlist-editor/src/interface.vue perf-directus-1:/tmp/build-setlist-editor/src/interface.vue
  docker exec -w /tmp/build-setlist-editor perf-directus-1 sh -c "npm install --include=dev --no-audit --no-fund"
  docker exec -w /tmp/build-setlist-editor perf-directus-1 sh -c "NODE_ENV=development npm run build"
'

# 3. Забрать готовый бандл обратно в bind-mounted папку
ssh bgm '
  docker cp perf-directus-1:/tmp/build-setlist-editor/dist/index.js /tmp/dist-index.js
  cp /tmp/dist-index.js /var/www/sch.com.ru/perf/extensions/setlist-editor/dist/index.js
  chown shchperf:docker /var/www/sch.com.ru/perf/extensions/setlist-editor/dist/index.js
  docker exec perf-directus-1 rm -rf /tmp/build-setlist-editor
  rm -f /tmp/dist-index.js
'

# 4. Перезапустить Directus, чтобы подхватил новую версию
ssh bgm 'cd /var/www/sch.com.ru/perf && docker compose restart directus'

# 5. В браузере — Ctrl+Shift+R на вкладке Directus Studio
```

Проверить, что загрузилось без ошибок:
```sh
ssh bgm 'docker logs --since 1m perf-directus-1 2>&1 | grep -iE "loaded extensions|error"'
```

## Схема, на которую завязаны расширения

Сверено с `/fields/perfs`, `/fields/sets_entries`, `/fields/works` в базе
2026-09-22 — при расхождениях доверять живой схеме, не этому файлу.

- `perfs`: `id` (text, вида `<events_id>_<works_id>`), `works_id`→`works`,
  `events_id`→`events`, `num` (integer, **не** `number` — поле
  переименовали/пересоздали с этим именем 2026-09-22), ~20 boolean-полей
  параметров исполнения, `performers` (M2M, alias, отдельная скрытая
  junction-таблица `perfs_performers_1`).
- `works`: заголовок песни строится как в `layouts/miscellaneous/catalogue.html`
  сайта — `name` (с `fname`, если есть), а если `name` пусто — `fincipit`.
- `sets_entries`: `id` вида `<sets_id>_<num с ведущими нулями до 3 знаков>_<perfs_id>`
  (Flow «Auto set entry id» на сервере — не в этом репозитории), `perfs_id`→`perfs`,
  `sets_id`→`sets`, `num` (integer).

## Известные ограничения / TODO

- Нет CI — деплой полностью ручной (см. выше).
- Flows (`Auto perf id`, `Auto set entry id`, `Auto event id` и др.) живут
  только в БД Directus, в этот репозиторий не входят — см. обсуждение про
  `directus-sync` для отдельной версионности конфигурации Directus за
  пределами Data Model.
