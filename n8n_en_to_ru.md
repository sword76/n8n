# Русификация интерфейса n8n в Docker

## Как это работает

n8n компилирует весь текст интерфейса в один Vite JS-чанк при сборке образа.
Файл называется `en-HASH.js` и находится внутри образа по пути:

```
/usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets/
```

Бэкенд n8n (`/rest/translation/...`) обслуживает **только** переводы параметров нод —
строки интерфейса через env-переменные или volume-монтирование добавить нельзя.

Подход: добавить в `Dockerfile` шаг, который при сборке образа перезаписывает
этот чанк русскими строками из `ru.json`.

---

## Шаг 1 — Измените `Dockerfile`

Добавьте следующий блок **между** командами `USER root` и `USER node`:

```dockerfile
# ── Injection of Russian UI translation ───────────────────────────────────────
COPY ru.json /tmp/ru.json

RUN node -e "
const fs = require('fs');
const DIST = '/usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets';

// Find the English locale chunk by pattern (hash changes each n8n version)
const enChunk = fs.readdirSync(DIST)
  .find(f => /^en-[A-Za-z0-9]+\\.js$/.test(f) && !f.includes('legacy'));

if (!enChunk) {
  console.error('ERROR: English locale chunk not found in', DIST);
  process.exit(1);
}

const ru = JSON.parse(fs.readFileSync('/tmp/ru.json', 'utf8'));
const entries = Object.entries(ru)
  .map(([k, v]) => JSON.stringify(k) + ':' + JSON.stringify(v))
  .join(',');

// Overwrite the chunk — same JS module format as the original
fs.writeFileSync(DIST + '/' + enChunk, 'const e={' + entries + '};export{e as t};');
console.log('Russian translation injected into:', enChunk);
"
# ──────────────────────────────────────────────────────────────────────────────
```

После добавления блок должен выглядеть так:

```dockerfile
FROM n8nio/n8n:2.12.1

USER root

# ... существующие COPY для Python, curl и т.д. ...

# ── Injection of Russian UI translation ───────────────────────────────────────
COPY ru.json /tmp/ru.json
RUN node -e "..."
# ──────────────────────────────────────────────────────────────────────────────

USER node

# ... существующие RUN npm install для community nodes ...
```

> **Почему без новой переменной локали:** скрипт заменяет сам English-чанк,
> поэтому русский интерфейс работает при любом значении `N8N_DEFAULT_LOCALE`
> (или без него). Имя файла ищется по регулярному выражению — скрипт
> автоматически адаптируется при обновлении n8n.

---

## Шаг 2 — Пересоберите образ

```bash
# Полная пересборка без кэша (обязательно — чтобы применить изменения в Dockerfile)
docker-compose build --no-cache

# Пересоздать контейнеры с новым образом
docker-compose up -d
```

Или, если нужно пересобрать только n8n-инстансы:

```bash
docker-compose build --no-cache n8n1 n8n2
docker-compose up -d n8n1 n8n2
```

---

## Шаг 3 — Проверка

**Через логи сборки** — убедитесь, что скрипт отработал:

```bash
docker-compose build 2>&1 | grep -E "Russian translation|ERROR"
```

Ожидаемый вывод:
```
Russian translation injected into: en-CWzQTVhM.js
```

**Через exec внутри контейнера** — проверьте наличие кириллицы в чанке:

```bash
docker exec n8n_instance_1 node -e "
const fs = require('fs');
const DIST = '/usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets';
const f = fs.readdirSync(DIST).find(x => /^en-[A-Za-z0-9]+\.js$/.test(x) && !x.includes('legacy'));
const c = fs.readFileSync(DIST + '/' + f, 'utf8');
console.log('Chunk:', f);
console.log('Has Cyrillic:', /[\u0400-\u04FF]/.test(c));
console.log('Sample:', c.slice(c.indexOf('Рабочий'), c.indexOf('Рабочий') + 60));
"
```

Ожидаемый вывод:
```
Chunk: en-CWzQTVhM.js
Has Cyrillic: true
Sample: Рабочий процесс...
```

---

## Обновление n8n до новой версии

При изменении версии образа в `Dockerfile` (например, с `2.12.1` на `2.13.0`)
скрипт работает без правок — он ищет `en-HASH.js` по паттерну, а не по
конкретному имени файла.

```bash
# 1. Измените версию в Dockerfile:
#    FROM n8nio/n8n:2.13.0

# 2. Пересоберите:
docker-compose build --no-cache
docker-compose up -d
```

---

## Часто задаваемые вопросы

| Вопрос | Ответ |
|--------|-------|
| Сломается ли что-то? | Нет. Структура JS-модуля идентична оригиналу. |
| Нужен ли `ru.json` внутри контейнера? | Нет. Он используется только при сборке (`COPY` во `/tmp`). |
| Можно ли оставить возможность переключиться на английский? | Только при полной пересборке n8n из исходников с двумя файлами локалей. |
| Затрагивает ли это переводы параметров нод? | Нет. Параметры нод переводятся отдельно через `/rest/translation/credential-translation`. |
| Работает ли это для Beget (`docker-compose-beget.yaml`)? | Да, но Beget-деплой использует образ `2.9.4` — нужен отдельный `Dockerfile.beget` с той же логикой. |
