#!/bin/sh

# OpenWrt captive-portal auto login for CMCC-EDU

# --- User config ---
IFACE="${IFACE:-YOUR_IFACE}"            # The network interface to use (must have an IPv4 address)
USERNAME="${USERNAME:-YOUR_USERNAME}"  # Campus portal username (export beforehand or edit here)
PASSWORD="${PASSWORD:-YOUR_PASSWORD}"  # Campus portal password (export beforehand or edit here)

# --- Connectivity and portal detection ---
# Treat 204/200 as internet accessible
CHECK_URLS="http://connectivitycheck.gstatic.com/generate_204 http://www.baidu.com/ https://cn.bing.com/"
# Probe URL that typically triggers captive portal redirect (Location header)
PROBE_URL="http://www.msftconnecttest.com/redirect"

# --- Constants ---
LOG_TAG="campus_login"
LOCK_FILE="/var/run/campus_login.lock"
COOKIE_JAR="/tmp/campus_login_cookies.txt"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0 Safari/537.36"
CONNECT_TIMEOUT=5
MAX_TIME=12

export LANG=C LC_ALL=C
PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

log() { logger -t "$LOG_TAG" "$*"; }
err() { logger -s -t "$LOG_TAG" "$*"; }

die() {
	code=${2:-1}
	log "退出：$1"
	[ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
	exit "$code"
}

# --- Sanity checks ---
command -v curl >/dev/null 2>&1 || die "curl 未安装，请先 opkg install curl"
command -v logger >/dev/null 2>&1 || echo "警告：logger 不存在，日志仅在控制台输出" >&2

if [ "$IFACE" = "YOUR_IFACE" ] || [ -z "$IFACE" ]; then
	die "请设置 IFACE（可在脚本中或通过环境变量）"
fi
if [ "$USERNAME" = "YOUR_USERNAME" ] || [ -z "$USERNAME" ]; then
	die "请设置 USERNAME（可在脚本中或通过环境变量）"
fi
if [ "$PASSWORD" = "YOUR_PASSWORD" ] || [ -z "$PASSWORD" ]; then
	die "请设置 PASSWORD（可在脚本中或通过环境变量）"
fi

# Verify interface looks valid (best-effort)
if ! ip -4 addr show dev "$IFACE" >/dev/null 2>&1; then
	err "警告：找不到接口 $IFACE（ip -4 addr show dev 失败）。继续尝试，但可能请求失败。"
fi

# --- Locking ---
if [ -e "$LOCK_FILE" ]; then
	PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
	if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
		log "脚本已在运行 (PID: $PID)。退出。"
		exit 0
	else
		log "发现残留锁文件，移除。"
		rm -f "$LOCK_FILE"
	fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit $?' INT TERM EXIT HUP

# --- Curl helper (no eval; safe for parentheses in UA) ---
curl_do() {
	curl \
	  --interface "$IFACE" \
	  -4 -sS \
	  --connect-timeout "$CONNECT_TIMEOUT" \
	  --max-time "$MAX_TIME" \
	  -A "$UA" \
	  -b "$COOKIE_JAR" \
	  -c "$COOKIE_JAR" \
	  -k \
	  "$@"
}

http_code_of() {
	url="$1"
	curl_do -o /dev/null -w "%{http_code}" "$url"
}

# --- Connectivity check ---
is_online=1 # 1 means need login; 0 means already online
log "开始检查网络连接状态（接口：$IFACE）..."
for url in $CHECK_URLS; do
	code=$(http_code_of "$url" || echo 000)
	if [ "$code" = "204" ] || [ "$code" = "200" ]; then
		log "成功访问 $url (HTTP $code)。网络已连接。"
		is_online=0
		break
	else
		log "访问 $url 失败 (HTTP $code)。"
	fi
done

if [ "$is_online" -eq 0 ]; then
	log "无需登录，退出。"
	rm -f "$LOCK_FILE"
	exit 0
fi

# --- Get redirect Location from probe ---
log "所有检查 URL 均无法直连，尝试从 $PROBE_URL 获取重定向信息..."
loc_line=$(curl_do -I "$PROBE_URL" | grep -i '^Location:')
if [ -z "$loc_line" ]; then
	die "未获取到 Location，可能网络异常或探测 URL 变更"
fi
redirect_url=$(echo "$loc_line" | sed -e 's/^[Ll]ocation:[ ]*//; s/\r$//' )
log "获取到重定向 URL: $redirect_url"

# Base portal like http(s)://host[:port] (handle URLs without a path, e.g., http://host?query)
PORTAL_BASE=$(echo "$redirect_url" | sed -n 's,^\(https\?://[^/?#]*\).*,\1,p')
PORTAL_HOST=$(echo "$redirect_url" | sed -n 's,^https\?://\([^/?#]*\).*,\1,p')
if [ -z "$PORTAL_BASE" ] || [ -z "$PORTAL_HOST" ]; then
	die "无法从重定向 URL 提取门户地址"
fi
log "门户基址: $PORTAL_BASE (Host: $PORTAL_HOST)"

# --- Fetch frameset page to extract paramStr for index.jsp ---
TMP_HTML="/tmp/campus_portal_frameset.html"
curl_do -L "$redirect_url" -o "$TMP_HTML" || die "获取门户首页失败"

# Extract paramStr from mainFrame src="style/university/index.jsp?paramStr=..."
PARAM_STR="$(
	grep -o 'index.jsp?paramStr=[^"\'"'"' ]*' "$TMP_HTML" | head -n1 | sed 's/.*paramStr=//'
)"

if [ -z "$PARAM_STR" ]; then
	# Fallback: try to read from 1.txt-like content (if provided separately)
	PARAM_STR="$(sed -n 's/.*index.jsp?paramStr=\([^"\'"'"']*\).*/\1/p' "$TMP_HTML" | head -n1)"
fi

if [ -z "$PARAM_STR" ]; then
	die "从门户页面中未找到 paramStr，无法继续登录"
fi
log "提取到 paramStr (index): ${PARAM_STR#????}*** (已隐藏)"

# --- POST credentials to /authServlet ---
LOGIN_URL="$PORTAL_BASE/authServlet"
INDEX_REFERER="$PORTAL_BASE/style/university/index.jsp?paramStr=$PARAM_STR"

# 仅保留响应头文件，不再保存/解析响应体
TMP_HDR="/tmp/campus_portal_post.hdr"
curl_do \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Host: $PORTAL_HOST" \
    -H "Origin: $PORTAL_BASE" \
    -H "Referer: $INDEX_REFERER" \
    -X POST \
    --data "paramStr=$PARAM_STR" \
    --data "UserType=1" \
    --data "province=" \
    --data "pwdType=1" \
    --data-urlencode "UserName=$USERNAME" \
    --data-urlencode "PassWord=$PASSWORD" \
    "$LOGIN_URL" -D "$TMP_HDR" -o /dev/null || die "登录 POST 请求失败"

log "登录请求已发送，尝试从响应头解析 Location 跳转..."

# 仅从响应头 Location 提取跳转 URL（不再解析响应体）
LOGON_URL=""
if [ -s "$TMP_HDR" ]; then
    LOC_LINE=$(awk 'BEGIN{IGNORECASE=1} /^Location:/{sub(/\r$/,""); print; exit}' "$TMP_HDR")
    if [ -n "$LOC_LINE" ]; then
        LOC_URL=$(echo "$LOC_LINE" | sed -e 's/^[Ll]ocation:[ ]*//')
        case "$LOC_URL" in
            http://*|https://*) LOGON_URL="$LOC_URL" ;;
            /*) LOGON_URL="$PORTAL_BASE$LOC_URL" ;;
            *) LOGON_URL="$PORTAL_BASE/$LOC_URL" ;;
        esac
    fi
fi

if [ -n "$LOGON_URL" ]; then
    case "$LOGON_URL" in
        *login_fail.jsp*)
            err "门户返回登录失败页面 (login_fail.jsp)，可能是账号/密码或参数错误。" ;;
    esac
    log "访问登录完成页: $LOGON_URL"
    curl_do -L "$LOGON_URL" -o /dev/null || err "访问登录完成页失败（忽略）"
else
    log "POST 响应头未提供 Location，跳过登录完成页访问。"
fi

# --- Verify connectivity again ---
sleep 2
verify_ok=0
for url in $CHECK_URLS; do
    code=$(http_code_of "$url" || echo 000)
    if [ "$code" = "204" ] || [ "$code" = "200" ]; then
        log "验证成功：$url 可访问 (HTTP $code)。登录流程完成。"
        verify_ok=1
        break
    fi
done

if [ "$verify_ok" -ne 1 ]; then
    err "登录后仍无法访问公网，可能凭据错误或门户字段不匹配。"
    rm -f "$LOCK_FILE"
    exit 2
fi

log "脚本执行完毕。"
rm -f "$LOCK_FILE"
exit 0

