#!/bin/bash
# Лаба 5: подготовка, локальный прогон тестов, создание репозитория GitHub, push
set -u
WS="/mnt/c/Users/Maxim/Documents/deepseek-harness/default-workspace/devops"
TOKEN=$(tr -d '\r\n' < "$WS/secrets/gh_token.txt")
umask 077
printf '%s' "$TOKEN" > /root/.gh_token
chmod 600 /root/.gh_token
GH_USER="Qwiwz"
REPO="devops-lab5"
API="https://api.github.com"

p() { echo; echo "P\$ $*"; "$@" 2>&1; echo "[код возврата: $?]"; }
pr() { echo; echo "P\$ $*"; }

echo "=============================================================="
echo "  Лабораторная работа №5. Методология CI/CD"
echo "=============================================================="

# ---------- подготовка рабочей копии ----------
mkdir -p /home/maxim/lab5
if [ ! -d /home/maxim/lab5/src ]; then
  cp -rf "$WS/repos/lab5/." /home/maxim/lab5/
fi
cp -f "$WS/labs/lab5/requirements.txt" /home/maxim/lab5/requirements.txt
cp -f "$WS/labs/lab5/test_user.py" /home/maxim/lab5/tests/test_user.py
mkdir -p /home/maxim/lab5/.github/workflows
cp -f "$WS/labs/lab5/tests.yml" /home/maxim/lab5/.github/workflows/tests.yml
cp -f "$WS/labs/lab5/build-and-delivery.yml" /home/maxim/lab5/.github/workflows/build-and-delivery.yml
chown -R maxim:maxim /home/maxim/lab5
cd /home/maxim/lab5 || exit 1

echo "--- структура проекта ---"
find . -maxdepth 3 -not -path './.git/*' -type f | sort

# ---------- локальный прогон тестов ----------
echo
echo "=========== Локальный прогон тестов (pytest) ==========="
python3 -m pip install --break-system-packages --quiet --disable-pip-version-check \
  -r requirements.txt pytest httpx 2>&1 | tail -3
pr "python3 -m pytest tests/ -v"
cd /home/maxim/lab5 && python3 -m pytest tests/ -v 2>&1 | tail -20

# ---------- GitHub: создание репозитория ----------
echo
echo "=========== Создание репозитория на GitHub ==========="
CREATE=$(curl -4 -s -w '\n%{http_code}' -X POST "$API/user/repos" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d "{\"name\":\"$REPO\",\"description\":\"MTUCI DevOps lab 5: CI/CD pipeline\",\"private\":false,\"auto_init\":false}")
CODE=$(echo "$CREATE" | tail -1)
BODY=$(echo "$CREATE" | sed '$d')
echo "HTTP-код создания репозитория: $CODE"
echo "$BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);print('repo:',d.get('full_name'),'| html_url:',d.get('html_url'),'| message:',d.get('message'))" 2>/dev/null || echo "$BODY" | head -c 300

# ---------- переменная и секрет Actions ----------
echo
echo "=========== Переменная и секрет GitHub Actions ==========="
VAR_CODE=$(curl -4 -s -o /dev/null -w '%{http_code}' -X POST "$API/repos/$GH_USER/$REPO/actions/variables" \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  -d '{"name":"DOCKERHUB_USERNAME","value":"liguratic"}')
if [ "$VAR_CODE" = "409" ] || [ "$VAR_CODE" = "422" ]; then
  VAR_CODE=$(curl -4 -s -o /dev/null -w '%{http_code}' -X PATCH "$API/repos/$GH_USER/$REPO/actions/variables/DOCKERHUB_USERNAME" \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    -d '{"name":"DOCKERHUB_USERNAME","value":"liguratic"}')
fi
echo "переменная DOCKERHUB_USERNAME: HTTP $VAR_CODE"

python3 -m pip install --break-system-packages --quiet --disable-pip-version-check pynacl 2>&1 | tail -2
SECRET_CODE=$(python3 - "$WS/secrets/dockerhub_token.txt" "$GH_USER" "$REPO" <<'PY'
import base64, json, sys, urllib.request
import nacl.public

tok_path, user, repo = sys.argv[1], sys.argv[2], sys.argv[3]
gh = open("/root/.gh_token", encoding="utf-8").read().strip()
dh = open(tok_path, encoding="utf-8").read().strip()
api = "https://api.github.com"

def call(method, url, data=None):
    req = urllib.request.Request(url, method=method,
        headers={"Authorization": f"Bearer {gh}", "Accept": "application/vnd.github+json",
                 "User-Agent": "dsh-agent"},
        data=json.dumps(data).encode() if data else None)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status, r.read()

st, body = call("GET", f"{api}/repos/{user}/{repo}/actions/secrets/public-key")
pk = json.loads(body)
key = nacl.public.PublicKey(base64.b64decode(pk["key"]))
sealed = nacl.public.SealedBox(key).encrypt(dh.encode())
enc = base64.b64encode(sealed).decode()
st2, _ = call("PUT", f"{api}/repos/{user}/{repo}/actions/secrets/DOCKERHUB_TOKEN",
              {"encrypted_value": enc, "key_id": pk["key_id"]})
print(st2)
PY
)
echo "секрет DOCKERHUB_TOKEN: HTTP $SECRET_CODE"

echo
echo "--- список переменных и секретов репозитория ---"
curl -4 -s -H "Authorization: Bearer $TOKEN" "$API/repos/$GH_USER/$REPO/actions/variables" | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print('variables:',[(v['name'],v['value']) for v in d.get('variables',[])])"
curl -4 -s -H "Authorization: Bearer $TOKEN" "$API/repos/$GH_USER/$REPO/actions/secrets" | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print('secrets:',[s['name'] for s in d.get('secrets',[])])"

# ---------- git: инициализация и push ----------
echo
echo "=========== Инициализация git и отправка в GitHub ==========="
cd /home/maxim/lab5 || exit 1
rm -rf .git
p git init
p git config user.name "Бирюков Максим Борисович"
p git config user.email "Liguratic@yandex.ru"
p git config init.defaultBranch main
p git checkout -b main
p git add .
pr "git status --short"
git status --short
p git commit -m "lab5: tests and CI/CD pipelines"

p git remote add origin "https://github.com/$GH_USER/$REPO.git"
p git log --oneline

echo
echo "--- push в GitHub (токен не сохраняется в конфигурации) ---"
git -c credential.helper= push "https://x-access-token:$TOKEN@github.com/$GH_USER/$REPO.git" main 2>&1 | \
  sed "s/$TOKEN/<token>/g"
echo "push_exit=$?"

echo
echo "--- состояние удалённого репозитория ---"
curl -4 -s -H "Authorization: Bearer $TOKEN" "$API/repos/$GH_USER/$REPO" | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print('repo:',d['full_name'],'| default_branch:',d['default_branch'],'| size:',d['size'],'КБ')"
curl -4 -s -H "Authorization: Bearer $TOKEN" "$API/repos/$GH_USER/$REPO/contents/.github/workflows" | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print('workflows:',[x['name'] for x in d])" 2>/dev/null

echo
echo "=== конец транскрипта (подготовка и push) ==="
