#!/usr/bin/env bash
# =====================================================================
# 펫클리닉 테스트 시나리오 자동 실행 (TC-01 ~ TC-51)
# 로컬, Docker, Kubernetes, EKS에서 같은 스크립트를 접속 주소만 바꿔 실행한다.
#
# 옵션
#   -u <주소>   WEB 주소                       (기본 http://localhost)
#   -l <이름>   환경 이름, 결과 파일 이름에 사용 (기본 local)
#   -r <명령>   TC-50, TC-51용 WAS 재시작 명령  (없으면 두 항목은 SKIP)
#   -a <주소>   API 주소를 따로 지정            (기본 <WEB주소>/api)
#   -h          도움말
# 비밀번호: 환경 변수 PASSWORD가 있으면 사용, 없으면 실행 시 입력(화면에 안 보임).
#           명령줄 옵션으로는 받지 않는다 (history, ps에 남기 때문).
#
# 사용 예
#   로컬  : bash run_scenarios.sh -l local
#   Docker: bash run_scenarios.sh -l docker -r 'docker restart pc-was'
#   K8s   : bash run_scenarios.sh -l k8s -u http://localhost:30080 \
#             -r 'kubectl rollout restart deploy/was && kubectl rollout status deploy/was'
#   EKS   : bash run_scenarios.sh -l eks -u https://<ALB주소> \
#             -r 'kubectl rollout restart deploy/was && kubectl rollout status deploy/was'
#
# 필요 도구: bash(3.2 이상, macOS 기본 bash 가능), curl, python3
# 종료 코드: 0 전부 통과, 1 실패 있음, 2 사전 점검 실패(서버 응답 없음)
# =====================================================================
set -u

WEB_URL="${WEB_URL:-http://localhost}"     # 환경 변수로도 지정 가능 (옵션이 우선)
API_URL="${API_URL:-}"
LABEL="${LABEL:-local}"
RESTART_CMD="${RESTART_CMD:-}"

usage() { sed -n '/^# 옵션/,/^# 종료 코드/p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts "u:l:r:a:h" opt; do
  case "$opt" in
    u) WEB_URL="$OPTARG" ;;
    l) LABEL="$OPTARG" ;;
    r) RESTART_CMD="$OPTARG" ;;
    a) API_URL="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

WEB_URL="${WEB_URL%/}"
API_URL="${API_URL:-$WEB_URL/api}"
API_URL="${API_URL%/}"

if [ -z "${PASSWORD:-}" ]; then
  read -r -s -p "테스트 계정 비밀번호 (SEED_PASSWORD): " PASSWORD; echo
  [ -n "$PASSWORD" ] || { echo "비밀번호가 비어 있습니다."; exit 64; }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RUN="$(date +%m%d%H%M%S)"            # 반복 실행해도 이름이 겹치지 않게 하는 값
RESULT_FILE="results_${LABEL}.tsv"
: > "$RESULT_FILE"

STATUS=""; BODY=""
declare -a IDS=()
declare -a NAMES=() RESULTS=() DETAILS=()   # macOS 기본 bash(3.2)에서도 동작하도록 연관 배열을 쓰지 않음

# ---------- 도구 함수 ----------

# req <쿠키파일> <메서드> <경로> [JSON본문]  → STATUS, BODY 설정
req() {
  local jar=$1 method=$2 path=$3 data=${4:-}
  local args=(-s -o "$TMP/body" -w '%{http_code}' --max-time 20 -X "$method" -b "$TMP/$jar" -c "$TMP/$jar")
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' -d "$data")
  STATUS="$(curl "${args[@]}" "$API_URL$path" 2>/dev/null)" || STATUS=000
  BODY="$(cat "$TMP/body" 2>/dev/null)"
}

# web <경로> → STATUS 설정 (WEB 직접 요청, 쿠키 없음)
web() {
  STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$WEB_URL$1" 2>/dev/null)" || STATUS=000
}

# jv <파이썬식>  → BODY(JSON)를 d 로 받아 식을 계산해 출력
jv() {
  printf '%s' "$BODY" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(eval(sys.argv[1]))' "$1" 2>/dev/null
}

urlenc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

# record <ID> <항목> <PASS|FAIL|SKIP> <상세>
record() {
  IDS+=("$1"); NAMES+=("$2"); RESULTS+=("$3"); DETAILS+=("$4")
  printf '%-6s %-4s %s  (%s)\n' "$1" "$3" "$2" "$4"
}

# expect_status <ID> <항목> <기대코드>  (직전 req의 STATUS 검사)
expect_status() {
  if [ "$STATUS" = "$3" ]; then record "$1" "$2" PASS "HTTP $STATUS"
  else record "$1" "$2" FAIL "기대 $3, 실제 $STATUS"; fi
}

# expect_true <ID> <항목> <조건결과 True/False> <상세>
expect_true() {
  if [ "$3" = "True" ]; then record "$1" "$2" PASS "$4"
  else record "$1" "$2" FAIL "$4"; fi
}

login() {   # login <쿠키파일> <아이디>
  req "$1" POST /login "{\"login_id\":\"$2\",\"password\":\"$PASSWORD\"}"
}

# ---------- 사전 점검 ----------
echo "== 대상: WEB=$WEB_URL  API=$API_URL  LABEL=$LABEL  RUN=$RUN"
HC="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$API_URL/health" 2>/dev/null)"
if [ "$HC" != "200" ]; then
  echo "!! $API_URL/health 응답이 $HC 입니다. WEB, WAS, DB가 실행 중인지 확인하세요."
  exit 2
fi
echo

# ---------- 인증 ----------
echo "[ 인증 (TC-01 ~ TC-06) ]"
login desk1 desk1;  D1_STATUS=$STATUS
expect_true TC-01 "로그인 성공 (간호사)" "$([ "$STATUS" = 200 ] && [ "$(jv 'd["role"]')" = desk ] && echo True || echo False)" "HTTP $STATUS, role=$(jv 'd.get("role")')"
D1_BRANCH="$(jv 'd.get("branch")')"

login vet1 vet1
V1_UID="$(jv 'd.get("uid")')"
expect_true TC-02 "로그인 성공 (수의사)" "$([ "$STATUS" = 200 ] && [ "$(jv 'd["role"]')" = vet ] && echo True || echo False)" "HTTP $STATUS, role=$(jv 'd.get("role")')"

req bad POST /login "{\"login_id\":\"desk1\",\"password\":\"wrong-$RUN\"}"
expect_status TC-03 "로그인 실패" 401

req desk1 GET /desk/vets
expect_status TC-04 "세션 유지 (쿠키로 보호 경로 재호출)" 200

login desk1_out desk1
req desk1_out DELETE /login
LOGOUT_STATUS=$STATUS
req desk1_out GET /desk/vets
expect_true TC-05 "로그아웃" "$([ "$STATUS" = 401 ] && echo True || echo False)" "로그아웃 HTTP $LOGOUT_STATUS, 이후 보호 경로 HTTP $STATUS"

req vet1 GET /desk/vets
expect_status TC-06 "권한 분리 (수의사가 /desk 호출)" 401

# ---------- 등록 ----------
echo
echo "[ 등록 (TC-10 ~ TC-12) ]"
ONAME="테스트${RUN}보호자"
req desk1 POST /desk/owner "{\"oname\":\"$ONAME\",\"pnum\":\"010-0000-0000\",\"address\":\"서울 강남구\",\"pets\":[{\"pname\":\"초코\",\"type\":\"개\",\"gender\":\"수컷\",\"age\":3,\"weight\":5.5}]}"
OID="$(jv 'd.get("oid")')"; PID1="$(jv 'd["pets"][0]["pid"]')"
expect_true TC-10 "보호자와 동물 등록" "$([ "$STATUS" = 200 ] && [ -n "$OID" ] && [ -n "$PID1" ] && echo True || echo False)" "HTTP $STATUS, oid=$OID, pid=$PID1"

req desk1 POST /desk/pet "{\"oid\":${OID:-0},\"pets\":[{\"pname\":\"나비\",\"type\":\"고양이\"}]}"
expect_true TC-11 "동물 추가 등록" "$([ "$STATUS" = 200 ] && [ "$(jv 'len(d["pets"])')" = 2 ] && echo True || echo False)" "HTTP $STATUS, 동물 수=$(jv 'len(d["pets"])')"

req desk1 POST "/desk/pet/${PID1:-0}/consultation" "{\"vet_uid\":${V1_UID:-0},\"purpose\":\"정기 검진\"}"
CID="$(jv 'd.get("cid")')"
expect_true TC-12 "방문 등록" "$([ "$STATUS" = 200 ] && [ "$(jv 'd["status"]')" = "대기" ] && echo True || echo False)" "HTTP $STATUS, cid=$CID, status=$(jv 'd.get("status")')"

# ---------- 조회 ----------
echo
echo "[ 조회 (TC-20 ~ TC-24) ]"
req desk1 GET "/desk/owner?name=$(urlenc "테스트${RUN}")"
expect_true TC-20 "보호자 검색" "$([ "$STATUS" = 200 ] && [ "$(jv "any(o['oid']==${OID:-0} for o in d)")" = True ] && echo True || echo False)" "HTTP $STATUS, 검색 결과 $(jv 'len(d)')건"

req desk1 GET "/desk/owner/${OID:-0}"
expect_true TC-21 "보호자 상세" "$([ "$STATUS" = 200 ] && [ "$(jv "len(d['pets'])==2 and ${PID1:-0} in d['active_pids']")" = True ] && echo True || echo False)" "HTTP $STATUS, 동물 $(jv 'len(d["pets"])')마리, 진행 중 진료 동물 $(jv 'd["active_pids"]')"

req desk1 GET /desk/vets
expect_true TC-22 "지점 수의사 목록" "$([ "$STATUS" = 200 ] && [ "$(jv "len(d)>0 and all(u['branch']=='$D1_BRANCH' and u['role']=='vet' for u in d)")" = True ] && echo True || echo False)" "HTTP $STATUS, ${D1_BRANCH} 수의사 $(jv 'len(d)')명"

req desk1 GET "/desk/pet/${PID1:-0}/consultation"
expect_true TC-23 "진료 이력" "$([ "$STATUS" = 200 ] && [ "$(jv "any(c['cid']==${CID:-0} for c in d)")" = True ] && echo True || echo False)" "HTTP $STATUS, 이력 $(jv 'len(d)')건"

req vet1 GET /vet/consultation
expect_true TC-24 "수의사 대기 목록" "$([ "$STATUS" = 200 ] && [ "$(jv "any(c['cid']==${CID:-0} and c['status']=='대기' for c in d) and all(c['vet_uid']==${V1_UID:-0} and c['status'] in ('대기','진료중') for c in d)")" = True ] && echo True || echo False)" "HTTP $STATUS, 배정 진료 $(jv 'len(d)')건"

# ---------- 수정 ----------
echo
echo "[ 수정 (TC-30 ~ TC-34) ]"
req desk1 PATCH "/desk/owner/${OID:-0}" '{"address":"서울 서초구 수정"}'
S1=$STATUS
req desk1 GET "/desk/owner/${OID:-0}"
expect_true TC-30 "보호자 정보 수정" "$([ "$S1" = 200 ] && [ "$(jv 'd["address"]')" = "서울 서초구 수정" ] && echo True || echo False)" "PATCH HTTP $S1, 재조회 address=$(jv 'd.get("address")')"

req desk1 PATCH "/desk/pet/${PID1:-0}" '{"age":4,"weight":6.5}'
S1=$STATUS
req desk1 GET "/desk/pet/${PID1:-0}"
expect_true TC-31 "동물 정보 수정" "$([ "$S1" = 200 ] && [ "$(jv 'd["age"]')" = 4 ] && echo True || echo False)" "PATCH HTTP $S1, 재조회 age=$(jv 'd.get("age")')"

req vet1 PATCH "/vet/consultation/${CID:-0}/start"
expect_true TC-32 "진료 시작" "$([ "$STATUS" = 200 ] && [ "$(jv 'd["status"]')" = "진료중" ] && echo True || echo False)" "HTTP $STATUS, status=$(jv 'd.get("status")')"

req vet1 PATCH "/vet/consultation/${CID:-0}" '{"diagnosis":"건강함 1차"}'
req vet1 PATCH "/vet/consultation/${CID:-0}" '{"diagnosis":"건강함 최종"}'
S1=$STATUS
req vet1 GET "/vet/consultation/${CID:-0}"
expect_true TC-33 "진단 작성 (재수정 포함)" "$([ "$S1" = 200 ] && [ "$(jv 'd["diagnosis"]')" = "건강함 최종" ] && echo True || echo False)" "PATCH HTTP $S1, 재조회 diagnosis=$(jv 'd.get("diagnosis")')"

req vet1 PATCH "/vet/consultation/${CID:-0}/end"
expect_true TC-34 "진료 종료" "$([ "$STATUS" = 200 ] && [ "$(jv 'd["status"]')" = "종료" ] && echo True || echo False)" "HTTP $STATUS, status=$(jv 'd.get("status")')"

# ---------- 규칙과 보안 ----------
echo
echo "[ 규칙과 보안 (TC-40 ~ TC-46) ]"
login desk2 desk2
req desk2 GET "/desk/owner/${OID:-0}"
expect_status TC-40 "지점 격리 (타 지점 보호자 조회)" 404

login vet3 vet3
V3_UID="$(jv 'd.get("uid")')"
req desk1 POST "/desk/pet/${PID1:-0}/consultation" "{\"vet_uid\":${V3_UID:-0},\"purpose\":\"타 지점 수의사\"}"
expect_status TC-41 "타 지점 수의사 배정" 404

req desk1 POST "/desk/pet/${PID1:-0}/consultation" "{\"vet_uid\":${V1_UID:-0},\"purpose\":\"순서 확인\"}"
CID2="$(jv 'd.get("cid")')"
req vet1 PATCH "/vet/consultation/${CID2:-0}/end"
expect_status TC-42 "순서 위반 (대기 상태에서 종료)" 404

login vet2 vet2
req vet2 GET "/vet/consultation/${CID:-0}"
expect_status TC-43 "남의 진료 접근" 404

req desk1 POST /desk/owner '{"pnum":"010-0000-0000","pets":[{"pname":"x","type":"개"}]}'
expect_status TC-44 "입력 검증 (필수 값 누락)" 422

web /api/docs
expect_status TC-45 "프록시 제외 경로 (WEB 경유 /api/docs)" 404

web /;       S1=$STATUS
web /app.js; S2=$STATUS
expect_true TC-46 "화면 로딩 (/, /app.js)" "$([ "$S1" = 200 ] && [ "$S2" = 200 ] && echo True || echo False)" "/ HTTP $S1, /app.js HTTP $S2"

# ---------- 영속성 ----------
echo
echo "[ 영속성 (TC-50 ~ TC-51) ]"
if [ -z "$RESTART_CMD" ]; then
  record TC-50 "WAS 재시작 후 데이터 유지" SKIP "RESTART_CMD 없음"
  record TC-51 "WAS 재시작 후 세션 유지" SKIP "RESTART_CMD 없음"
else
  echo "-- WAS 재시작: $RESTART_CMD"
  bash -c "$RESTART_CMD" > "$TMP/restart.log" 2>&1
  for i in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API_URL/health" 2>/dev/null)" = 200 ] && break
    sleep 2
  done
  req desk1 GET "/desk/owner/${OID:-0}"      # 재시작 전에 받은 쿠키를 그대로 사용
  expect_true TC-50 "WAS 재시작 후 데이터 유지" "$([ "$STATUS" = 200 ] && [ "$(jv 'd["oname"]')" = "$ONAME" ] && echo True || echo False)" "HTTP $STATUS, oname=$(jv 'd.get("oname")')"
  expect_true TC-51 "WAS 재시작 후 세션 유지" "$([ "$STATUS" = 200 ] && echo True || echo False)" "재시작 전 쿠키로 HTTP $STATUS"
fi

# ---------- 요약 ----------
P=0; F=0; K=0
printf 'ID\t항목\t결과\t상세\n' > "$RESULT_FILE"
for i in "${!IDS[@]}"; do
  printf '%s\t%s\t%s\t%s\n' "${IDS[$i]}" "${NAMES[$i]}" "${RESULTS[$i]}" "${DETAILS[$i]}" >> "$RESULT_FILE"
  case "${RESULTS[$i]}" in PASS) P=$((P+1));; FAIL) F=$((F+1));; *) K=$((K+1));; esac
done
echo
echo "== 요약 [$LABEL] 통과 $P / 실패 $F / SKIP $K  (총 ${#IDS[@]})"
echo "== 결과 파일: $RESULT_FILE"
echo "== 테스트 데이터: 보호자 '$ONAME' (oid=${OID:-?}), 진료 cid=${CID:-?}, ${CID2:-?}"
[ "$F" -eq 0 ]
