#!/usr/bin/env bash
# Re-registers the ALB's targets with wherever the backends actually are right now.
#
# WHY THIS EXISTS
# An ALB target group holds ADDRESSES, not names. Nothing re-resolves them. When a container
# or node is recreated and comes back on a different address, the target group still points
# at the old one, health checks fail, and the gateway answers 503 -- while the application
# itself is perfectly healthy and answers 200 if you call it directly.
#
# Measured exactly that: stale target -> unhealthy -> 503 through the gateway, 200 direct.
#
# On real AWS you do not run this: the AWS Load Balancer Controller watches Kubernetes
# Endpoints and re-registers for you. That is the single biggest thing the controller buys,
# and doing it by hand once is how you learn to appreciate it.
#
#   ./scripts/reconcile-targets.sh            # k3s NodePort targets (the Oracle box)
#   MODE=containers ./scripts/reconcile-targets.sh   # plain docker containers (local edge)
set -euo pipefail

export AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-http://localhost:4566}
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-test}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-test}
export AWS_REGION=${AWS_REGION:-us-east-1}
MODE=${MODE:-nodeport}

tg_arn() {
  aws elbv2 describe-target-groups --names "$1" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null
}

# swap whatever is registered for the address given, only if it differs
reconcile() { # reconcile <target-group-name> <wanted-ip> <port>
  local name=$1 want=$2 port=$3 arn current
  arn=$(tg_arn "$name") || { echo "  $name: no such target group"; return; }
  current=$(aws elbv2 describe-target-health --target-group-arn "$arn" \
    --query 'TargetHealthDescriptions[].Target.Id' --output text 2>/dev/null | tr -d '\r')

  if [ "$current" = "$want" ]; then
    local state
    state=$(aws elbv2 describe-target-health --target-group-arn "$arn" \
      --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null | tr -d '\r')
    echo "  $name: already $want ($state)"
    return
  fi

  for old in $current; do
    [ -n "$old" ] && aws elbv2 deregister-targets --target-group-arn "$arn" \
      --targets "Id=$old,Port=$port" >/dev/null 2>&1
  done
  aws elbv2 register-targets --target-group-arn "$arn" --targets "Id=$want,Port=$port" >/dev/null
  echo "  $name: ${current:-<none>} -> $want  (health takes ~20s to turn green)"
}

if [ "$MODE" = containers ]; then
  ip_of() { docker inspect "$1" --format '{{(index .NetworkSettings.Networks "learn_default").IPAddress}}'; }
  echo "reconciling against running containers:"
  reconcile user-service-tg "$(ip_of user-service)" 7701
  reconcile task-service-tg "$(ip_of task-service)" 7702
else
  NODE_IP=${NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')}
  echo "reconciling against k3s node $NODE_IP:"
  reconcile user-service-tg "$NODE_IP" "${USER_NODEPORT:-30771}"
  reconcile task-service-tg "$NODE_IP" "${TASK_NODEPORT:-30772}"
fi

echo
echo "current health:"
for n in user-service-tg task-service-tg; do
  arn=$(tg_arn "$n") || continue
  aws elbv2 describe-target-health --target-group-arn "$arn" \
    --query "TargetHealthDescriptions[].{tg:\`$n\`,Target:Target.Id,State:TargetHealth.State}" --output text 2>/dev/null | sed 's/^/  /'
done
