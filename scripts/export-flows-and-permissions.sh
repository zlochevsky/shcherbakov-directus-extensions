#!/bin/sh
# Экспортирует Flows и модель прав доступа (roles/policies/access/permissions)
# из живого Directus в JSON-файлы этого репозитория — для истории и diff'а.
#
# Осознанно НЕ трогает:
#   - directus_settings   — там нет механизма {{$env.X}} как у Flows; если
#     когда-нибудь вписать сюда через Studio реальный AI/mapbox-ключ, он
#     ляжет в БД открытым текстом и попадёт в git при следующем экспорте.
#     Проверено 2026-09-23: сейчас все такие поля пустые, но полагаться на
#     это нельзя — поэтому исключаем саму таблицу, а не полагаемся на
#     бдительность при каждом коммите.
#   - directus_users/sessions/activity/revisions — учётные данные и история,
#     никогда не должны быть в git.
#
# Запуск: ./scripts/export-flows-and-permissions.sh
# Требует: ssh-доступ к хосту bgm (см. ~/.ssh/config), Directus admin-логин
# зашит ниже так же, как во всех остальных диагностических командах сессии
# 2026-09-22/23 — при желании вынести в переменные окружения.

set -e
cd "$(dirname "$0")/.."

ssh bgm '
TOKEN=$(curl -s -X POST http://localhost:8055/auth/login \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"sergey@zlochevsky.com\",\"password\":\"REDACTED\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[\"data\"][\"access_token\"])")

fetch() {
  # $1 = endpoint (с query string), $2 = имя файла
  curl -sg "http://localhost:8055/$1" -H "Authorization: Bearer $TOKEN" \
    | python3 -c "import sys,json; d=json.load(sys.stdin)[\"data\"]; print(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=True))" \
    > "/tmp/directus-export-$2.json"
}

fetch "flows?fields=*,operations.*"           flows
fetch "roles?fields=*"                        roles
fetch "policies?fields=*"                     policies
fetch "access?fields=*"                       access
fetch "permissions?fields=*"                  permissions
'

mkdir -p flows-and-permissions
for name in flows roles policies access permissions; do
  scp -q "bgm:/tmp/directus-export-$name.json" "flows-and-permissions/$name.json"
done
ssh bgm 'rm -f /tmp/directus-export-*.json'

echo "Готово. Посмотрите git diff перед коммитом — особенно flows.json (там код операций)."
