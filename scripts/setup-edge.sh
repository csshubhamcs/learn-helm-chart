#!/usr/bin/env bash
# Builds the edge on the Oracle box: a Floci ALB in front of the k3s NodePorts, and a Floci
# API Gateway (HTTP API v2) with a Keycloak JWT authorizer in front of that.
#
#   Cloudflare ──tunnel──> API Gateway ──> ALB ──> k3s NodePort ──> pods
#
# Every step here was tested against Floci 2.1.0 before being written down: the authorizer
# really rejects a missing or tampered token, the ALB really health-checks and really
# forwards, and the CORS behaviour below was verified rather than assumed.
#
# Idempotent-ish: re-running recreates the API (the pinned id makes that safe) but will
# complain about load balancers that already exist. Delete those first if you need to.
#
#   ./scripts/setup-edge.sh
set -euo pipefail

# ── things you must set ───────────────────────────────────────────────────────
DOMAIN=${DOMAIN:-shubhamsinghrajput.com}
UI_HOST=${UI_HOST:-learn.$DOMAIN}
API_HOST=${API_HOST:-api.$DOMAIN}
KC_HOST=${KC_HOST:-keycloak.$DOMAIN}

# The k3s node's address as seen from inside Floci. `kubectl get nodes -o wide` gives it.
NODE_IP=${NODE_IP:?set NODE_IP to the k3s node address, e.g. NODE_IP=172.28.0.20}

# NodePorts from environments/<env>/*.yaml
USER_NODEPORT=${USER_NODEPORT:-30771}
TASK_NODEPORT=${TASK_NODEPORT:-30772}

# The API id is PINNED with floci:override-id. Without this the id is random and changes on
# every recreate -- and the Cloudflare Host header below would have to be edited each time.
API_ID=${API_ID:-learnapi}
ALB_PORT=${ALB_PORT:-8088}

export AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-http://localhost:4566}
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-test}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-test}
export AWS_REGION=${AWS_REGION:-us-east-1}

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── 1 · target groups, one per service ────────────────────────────────────────
# target-type ip, NOT instance: Floci resolves `instance` targets through EC2 private
# addresses, and a k3s NodePort is not an EC2 instance. `ip` targets were verified to go
# healthy against a real HTTP health check.
say "1 · target groups"
mk_tg() { # mk_tg <name> <port>
  aws elbv2 create-target-group \
    --name "$1" --protocol HTTP --port "$2" --target-type ip --vpc-id vpc-1 \
    --health-check-path /actuator/health \
    --health-check-interval-seconds 10 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
    --query 'TargetGroups[0].TargetGroupArn' --output text
}
TG_USER=$(mk_tg user-service-tg "$USER_NODEPORT")
TG_TASK=$(mk_tg task-service-tg "$TASK_NODEPORT")
aws elbv2 register-targets --target-group-arn "$TG_USER" --targets "Id=$NODE_IP,Port=$USER_NODEPORT"
aws elbv2 register-targets --target-group-arn "$TG_TASK" --targets "Id=$NODE_IP,Port=$TASK_NODEPORT"
echo "  user-service -> $NODE_IP:$USER_NODEPORT"
echo "  task-service -> $NODE_IP:$TASK_NODEPORT"

# ── 2 · the load balancer ─────────────────────────────────────────────────────
say "2 · load balancer"
LB=$(aws elbv2 create-load-balancer --name learn-alb --type application \
      --scheme internet-facing --query 'LoadBalancers[0].LoadBalancerArn' --output text)
LISTENER=$(aws elbv2 create-listener --load-balancer-arn "$LB" \
      --protocol HTTP --port "$ALB_PORT" \
      --default-actions "Type=forward,TargetGroupArn=$TG_USER" \
      --query 'Listeners[0].ListenerArn' --output text)
# Path rules: anything under /api/v1/tasks and /api/v1/admin/tasks belongs to task-service.
# Everything else falls through to the listener's default action (user-service).
aws elbv2 create-rule --listener-arn "$LISTENER" --priority 10 \
  --conditions 'Field=path-pattern,Values=/api/v1/tasks*' \
  --actions "Type=forward,TargetGroupArn=$TG_TASK" >/dev/null
aws elbv2 create-rule --listener-arn "$LISTENER" --priority 20 \
  --conditions 'Field=path-pattern,Values=/api/v1/admin/tasks*' \
  --actions "Type=forward,TargetGroupArn=$TG_TASK" >/dev/null
echo "  listener on :$ALB_PORT, two path rules"

FLOCI_IP=$(aws ec2 describe-instances --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || true)
ALB_BASE=${ALB_BASE:-http://127.0.0.1:$ALB_PORT}

# ── 3 · the HTTP API ──────────────────────────────────────────────────────────
say "3 · API Gateway (HTTP API v2)"
aws apigatewayv2 delete-api --api-id "$API_ID" 2>/dev/null || true
aws apigatewayv2 create-api --name learn-api --protocol-type HTTP \
  --tags "floci:override-id=$API_ID" --query ApiId --output text >/dev/null
echo "  api id pinned to '$API_ID'"

# CORS on the API itself, not on the services. A browser sends an OPTIONS preflight with NO
# Authorization header; without this the JWT authorizer answers 401 and the whole UI fails
# with a CORS error that never mentions authentication. Verified: 401 before, 204 after.
aws apigatewayv2 update-api --api-id "$API_ID" --cors-configuration \
  "AllowOrigins=https://$UI_HOST,AllowMethods=GET,POST,PUT,PATCH,DELETE,OPTIONS,AllowHeaders=authorization,content-type,MaxAge=600" >/dev/null
echo "  CORS allows https://$UI_HOST"

# ── 4 · the JWT authorizer ────────────────────────────────────────────────────
# The issuer is the PUBLIC Keycloak URL, and it must match byte for byte:
#   Keycloak's  --hostname
#   this Issuer
#   each service's spring.security.oauth2.resourceserver.jwt.issuer-uri
# A mismatch fails every request with a bare 401 that names nothing.
say "4 · JWT authorizer"
AUTH=$(aws apigatewayv2 create-authorizer --api-id "$API_ID" --name keycloak-jwt \
  --authorizer-type JWT --identity-source '$request.header.Authorization' \
  --jwt-configuration "Issuer=https://$KC_HOST/realms/p-platform,Audience=learn-api" \
  --query AuthorizerId --output text)
echo "  issuer  https://$KC_HOST/realms/p-platform"
echo "  audience learn-api  (needs the audience mapper on the web-app client)"

# ── 5 · routes ────────────────────────────────────────────────────────────────
say "5 · routes"
mkint() { aws apigatewayv2 create-integration --api-id "$API_ID" \
    --integration-type HTTP_PROXY --integration-method ANY \
    --payload-format-version 1.0 --integration-uri "$1" \
    --query IntegrationId --output text; }
route() { # route "<route key>" <integration uri> <jwt|open>
  local id; id=$(mkint "$2")
  if [ "$3" = open ]; then
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$1" \
      --target "integrations/$id" --authorization-type NONE >/dev/null
  else
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$1" \
      --target "integrations/$id" --authorization-type JWT --authorizer-id "$AUTH" >/dev/null
  fi
  printf '  %-38s %s\n' "$1" "$3"
}

# Registration is the ONLY open route -- you cannot present a token before you have an
# account. It is therefore also the endpoint that most needs rate limiting later.
route 'POST /api/v1/auth/register'        "$ALB_BASE/api/v1/auth/register"        open
route 'ANY /api/v1/users/{proxy+}'        "$ALB_BASE/api/v1/users/{proxy}"        jwt
route 'GET /api/v1/admin/users'           "$ALB_BASE/api/v1/admin/users"          jwt
route 'ANY /api/v1/admin/users/{proxy+}'  "$ALB_BASE/api/v1/admin/users/{proxy}"  jwt
route 'ANY /api/v1/tasks'                 "$ALB_BASE/api/v1/tasks"                jwt
route 'ANY /api/v1/tasks/{proxy+}'        "$ALB_BASE/api/v1/tasks/{proxy}"        jwt
route 'ANY /api/v1/admin/tasks'           "$ALB_BASE/api/v1/admin/tasks"          jwt
route 'ANY /api/v1/admin/tasks/{proxy+}'  "$ALB_BASE/api/v1/admin/tasks/{proxy}"  jwt

aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null
echo "  \$default stage, auto-deploy"

# ── done ──────────────────────────────────────────────────────────────────────
cat <<DONE

$(printf '\033[1mEdge is built.\033[0m')

Invoke URL (inside the box):
  http://$API_ID.execute-api.localhost.floci.io:4566

Cloudflare Zero Trust — Networks > Tunnels > your tunnel > Public Hostname:

  $UI_HOST        ->  http://$NODE_IP:30090
  $API_HOST       ->  http://localhost:4566
                      Additional application settings > HTTP Settings >
                      HTTP Host Header: $API_ID.execute-api.localhost.floci.io
  $KC_HOST        ->  http://$NODE_IP:30080

Check it:
  aws elbv2 describe-target-health --target-group-arn $TG_USER
  curl -i http://$API_ID.execute-api.localhost.floci.io:4566/api/v1/tasks    # expect 401
DONE
