#!/bin/zsh
set -e

# =====================================================
# macOS LAPS + JumpCloud Device Attribute Sync
#
# - Ensure a managed local admin account exists
# - Rotate its password to a strong random value (verified locally)
# - Sync the new password to the JumpCloud device's custom attributes
# - On sync/verification failure, roll back to the previous password
# =====================================================

# ---------------- CONFIG ----------------
# JumpCloud Command template variables, substituted at dispatch time:
#   {{Apikey}}             -> JumpCloud Automation Variable (admin-created)
#   {{device.id}}          -> built-in command variable (resolved automatically)
#   {{AdminPass}}          -> Automation Variable: seed/default password for the admin account
#   {{SecureTokenAdmin}}     / {{SecureTokenAdminPass}} -> Automation Variables for an existing
#       SecureToken-holding admin, used to grant SecureToken if the managed admin lacks one.
# Never hardcode real credentials here.
JC_API_KEY={{Apikey}}
JC_SYSTEM_ID={{device.id}}
# EU-region tenants: change this to https://console.eu.jumpcloud.com/api
BASE_URL="https://console.jumpcloud.com/api"

LOCAL_ADMIN_USERNAME="admin"
DEFAULT_LOCAL_ADMIN_PASSWORD={{AdminPass}}

# Existing SecureToken-holding admin — used only to grant SecureToken to the
# managed admin when it lacks one. Best-effort: failures are logged, not fatal.
SECURE_TOKEN_ADMIN={{SecureTokenAdmin}}
SECURE_TOKEN_ADMIN_PASSWORD={{SecureTokenAdminPass}}

MAX_RETRIES=10

# ---------------- helpers ----------------
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

genpass() {
  local chars='ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%^&*()_=+'
  local out=""
  local len=12
  local i=0
  local clen=${#chars}
  while [[ $i -lt $len ]]; do
    out="${out}${chars:$((RANDOM % clen)):1}"
    i=$((i+1))
  done
  echo "$out"
}

# Scopes to the "attributes":[...] array to avoid false matches on other
# fields that also contain "name" (e.g. networkInterfaces, builtInCommands).
extract_attr_value() {
  local json="$1"
  local attr_name="$2"
  local attrs_only
  attrs_only="$(echo "$json" | grep -o '"attributes":\[[^]]*\]' | sed 's/"attributes"://')"
  echo "$attrs_only" | tr '{' '\n' | while IFS= read -r block; do
    name="$(echo "$block" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
    if [[ "$name" == "$attr_name" ]]; then
      echo "$block" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p'
      return
    fi
  done
}

rollback_password() {
  echo "ERROR: Rolling back local password to previous value"

  if sysadminctl \
      -adminUser "$LOCAL_ADMIN_USERNAME" \
      -adminPassword "$NEW_PASSWORD" \
      -resetPasswordFor "$LOCAL_ADMIN_USERNAME" \
      -newPassword "$CURRENT_PASSWORD" >/dev/null 2>&1; then

    if dscl . -authonly "$LOCAL_ADMIN_USERNAME" "$CURRENT_PASSWORD" >/dev/null 2>&1; then
      echo "INFO: Rollback successful"
      echo "ROLLBACK PASSWORD: $CURRENT_PASSWORD"
      exit 1
    fi
  fi

  echo "ERROR: Rollback failed"
  echo "ROLLBACK PASSWORD (intended): $CURRENT_PASSWORD"
  echo "RECOVERY PASSWORD (last known working): $NEW_PASSWORD"
  exit 1
}

# ---------------- root check ----------------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: Script must be run as root"
  exit 1
fi

# ---------------- fetch device from JumpCloud ----------------
echo "INFO: Fetching JumpCloud device: $JC_SYSTEM_ID"

SYSTEM_JSON="$(curl -s -X GET \
  "$BASE_URL/systems/$JC_SYSTEM_ID" \
  -H "x-api-key: $JC_API_KEY" \
  -H "Accept: application/json")"

echo "$SYSTEM_JSON" | grep -q '"_id"' || {
  echo "ERROR: JumpCloud device not found for ID: $JC_SYSTEM_ID"
  exit 1
}

# ---------------- capture previous password (for rollback + rotation auth) ----------------
PREV_PASSWORD="$(extract_attr_value "$SYSTEM_JSON" "$LOCAL_ADMIN_USERNAME")"

if [[ -n "$PREV_PASSWORD" ]]; then
  echo "INFO: Existing attribute '$LOCAL_ADMIN_USERNAME' found — rollback available"
  CURRENT_PASSWORD="$PREV_PASSWORD"
else
  echo "INFO: No existing attribute '$LOCAL_ADMIN_USERNAME' — using default password"
  CURRENT_PASSWORD="$DEFAULT_LOCAL_ADMIN_PASSWORD"
fi

# ---------------- ensure local admin exists ----------------
if ! id "$LOCAL_ADMIN_USERNAME" >/dev/null 2>&1; then
  echo "INFO: Creating local user: $LOCAL_ADMIN_USERNAME"

  LAST_UID="$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)"
  NEW_UID=$(( LAST_UID + 1 ))

  dscl . -create "/Users/$LOCAL_ADMIN_USERNAME"
  dscl . -create "/Users/$LOCAL_ADMIN_USERNAME" UserShell /bin/zsh
  dscl . -create "/Users/$LOCAL_ADMIN_USERNAME" RealName "$LOCAL_ADMIN_USERNAME"
  dscl . -create "/Users/$LOCAL_ADMIN_USERNAME" UniqueID "$NEW_UID"
  dscl . -create "/Users/$LOCAL_ADMIN_USERNAME" PrimaryGroupID 80
  dscl . -create "/Users/$LOCAL_ADMIN_USERNAME" NFSHomeDirectory "/Users/$LOCAL_ADMIN_USERNAME"
  dscl . -passwd "/Users/$LOCAL_ADMIN_USERNAME" "$CURRENT_PASSWORD"
  createhomedir -c -u "$LOCAL_ADMIN_USERNAME" >/dev/null 2>&1 || true

  echo "INFO: Local user created: $LOCAL_ADMIN_USERNAME"
else
  echo "INFO: Local user exists: $LOCAL_ADMIN_USERNAME"
fi

# Ensure member of admin group
if ! dseditgroup -o checkmember -m "$LOCAL_ADMIN_USERNAME" admin >/dev/null 2>&1; then
  dseditgroup -o edit -a "$LOCAL_ADMIN_USERNAME" -t user admin
  echo "INFO: Added $LOCAL_ADMIN_USERNAME to admin group"
fi

# ---------------- check (and best-effort grant) SecureToken ----------------
TOKEN_STATUS="$(sysadminctl -secureTokenStatus "$LOCAL_ADMIN_USERNAME" 2>&1)"

if echo "$TOKEN_STATUS" | grep -qi "ENABLED"; then
  echo "INFO: SecureToken ENABLED for $LOCAL_ADMIN_USERNAME"
else
  echo "INFO: SecureToken DISABLED for $LOCAL_ADMIN_USERNAME — attempting to grant"

  ADMIN_TOKEN_STATUS="$(sysadminctl -secureTokenStatus "$SECURE_TOKEN_ADMIN" 2>&1)"
  if echo "$ADMIN_TOKEN_STATUS" | grep -qi "ENABLED"; then
    sysadminctl \
      -adminUser "$SECURE_TOKEN_ADMIN" \
      -adminPassword "$SECURE_TOKEN_ADMIN_PASSWORD" \
      -secureTokenOn "$LOCAL_ADMIN_USERNAME" \
      -password "$CURRENT_PASSWORD" >/dev/null 2>&1 || true

    TOKEN_STATUS="$(sysadminctl -secureTokenStatus "$LOCAL_ADMIN_USERNAME" 2>&1)"
    if echo "$TOKEN_STATUS" | grep -qi "ENABLED"; then
      echo "INFO: SecureToken granted to $LOCAL_ADMIN_USERNAME"
    else
      echo "WARN: Could not grant SecureToken to $LOCAL_ADMIN_USERNAME — continuing"
    fi
  else
    echo "WARN: SECURE_TOKEN_ADMIN '$SECURE_TOKEN_ADMIN' has no SecureToken — skipping grant"
  fi
fi

# ---------------- rotate password locally ----------------
echo "INFO: Rotating local password"

NEW_PASSWORD=""

for _ in $(seq 1 $MAX_RETRIES); do
  candidate="$(genpass)"

  if sysadminctl \
      -adminUser "$LOCAL_ADMIN_USERNAME" \
      -adminPassword "$CURRENT_PASSWORD" \
      -resetPasswordFor "$LOCAL_ADMIN_USERNAME" \
      -newPassword "$candidate" >/dev/null 2>&1 &&
     dscl . -authonly "$LOCAL_ADMIN_USERNAME" "$candidate" >/dev/null 2>&1; then
    NEW_PASSWORD="$candidate"
    break
  fi
done

[[ -n "$NEW_PASSWORD" ]] || { echo "ERROR: Local password rotation failed after $MAX_RETRIES attempts"; exit 1; }
echo "INFO: Local password rotated and verified"

# ---------------- build updated attributes array ----------------
# Scoped to "attributes":[...] only to prevent duplicate name errors from
# other JSON fields (networkInterfaces, builtInCommands, etc.)
EXISTING_ATTRS_JSON="$(echo "$SYSTEM_JSON" | grep -o '"attributes":\[[^]]*\]' | sed 's/"attributes"://')"

NEW_ATTRS='['
first=true

while IFS= read -r block; do
  attr_name="$(echo "$block" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
  attr_value="$(echo "$block" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')"
  if [[ -n "$attr_name" && "$attr_name" != "$LOCAL_ADMIN_USERNAME" ]]; then
    [[ "$first" == "false" ]] && NEW_ATTRS="${NEW_ATTRS},"
    NEW_ATTRS="${NEW_ATTRS}{\"name\":\"$(json_escape "$attr_name")\",\"value\":\"$(json_escape "$attr_value")\"}"
    first=false
  fi
done < <(echo "$EXISTING_ATTRS_JSON" | tr '{' '\n' | grep '"name"')

[[ "$first" == "false" ]] && NEW_ATTRS="${NEW_ATTRS},"
NEW_ATTRS="${NEW_ATTRS}{\"name\":\"$(json_escape "$LOCAL_ADMIN_USERNAME")\",\"value\":\"$(json_escape "$NEW_PASSWORD")\"}"
NEW_ATTRS="${NEW_ATTRS}]"

PUT_BODY="{\"attributes\":${NEW_ATTRS}}"

# ---------------- sync to JumpCloud (ONE retry) ----------------
jc_put() {
  curl -s -X PUT \
    "$BASE_URL/systems/$JC_SYSTEM_ID" \
    -H "x-api-key: $JC_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$PUT_BODY"
}

echo "INFO: Syncing password to JumpCloud device attribute"
RESP="$(jc_put)" || RESP=""

if ! echo "$RESP" | grep -q "\"name\":\"$(json_escape "$LOCAL_ADMIN_USERNAME")\""; then
  echo "INFO: Retrying JumpCloud sync"
  sleep 1
  RESP="$(jc_put)" || RESP=""
fi

if ! echo "$RESP" | grep -q "\"name\":\"$(json_escape "$LOCAL_ADMIN_USERNAME")\""; then
  echo "ERROR: JumpCloud sync failed"
  echo "$RESP"
  rollback_password
fi

echo "INFO: JumpCloud attribute updated"

# ---------------- final verification ----------------
echo "INFO: Performing final verification using JumpCloud attribute"

VERIFY_JSON="$(curl -s -X GET \
  "$BASE_URL/systems/$JC_SYSTEM_ID" \
  -H "x-api-key: $JC_API_KEY" \
  -H "Accept: application/json")"

JC_PASSWORD="$(extract_attr_value "$VERIFY_JSON" "$LOCAL_ADMIN_USERNAME")"

[[ -n "$JC_PASSWORD" ]] || {
  echo "ERROR: Password attribute missing from JumpCloud after update"
  rollback_password
}

if ! dscl . -authonly "$LOCAL_ADMIN_USERNAME" "$JC_PASSWORD" >/dev/null 2>&1; then
  echo "ERROR: JumpCloud password does NOT authenticate on device"
  rollback_password
fi

echo "SUCCESS: Password rotated and verified from JumpCloud for device $JC_SYSTEM_ID"
