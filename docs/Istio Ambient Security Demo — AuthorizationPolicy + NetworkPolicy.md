# Istio Ambient Security Demo

## 1. Overview

Demo mô phỏng mô hình bảo mật Kubernetes sử dụng:

- RKE2
- Istio Ambient Mesh
- Istio Waypoint
- Istio AuthorizationPolicy
- Kubernetes NetworkPolicy
- External PostgreSQL
- External HTTPS service (Google)
- ArgoCD / GitOps

Mục tiêu:

1. Workload trong cluster giao tiếp với nhau thông qua Istio Ambient.
2. Kiểm soát traffic nội bộ bằng `AuthorizationPolicy` dựa trên ServiceAccount.
3. External traffic đi qua dedicated egress waypoint.
4. Chỉ những workload được cấp quyền mới được gọi external service.
5. NetworkPolicy đóng vai trò network-level backstop:
   - Cho phép DNS.
   - Cho phép traffic nội bộ cluster.
   - Cho phép HBONE tới egress waypoint.
   - Chặn workload truy cập Internet trực tiếp.
   - Cho phép egress waypoint đi Internet.

---

# 2. Architecture

```text
                              Internet
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
                 Google                    PostgreSQL
               TCP/443                      TCP/5432
                    ▲                           ▲
                    │                           │
                    └───────────┬───────────────┘
                                │
                         Egress Waypoint
                       namespace: istio-egress
                                │
                              HBONE
                                │
                    ┌───────────┴───────────┐
                    │                       │
                  ztunnel                 ztunnel
                    │                       │
             ┌──────┴──────┐         ┌──────┴──────┐
             │             │         │             │
          user-service  order-service ...       api-gateway
             │             │                       │
             └─────────────┴───────────────────────┘
                         Ambient Mesh
```

---

# 3. Namespace Architecture

## app

Chứa các application workload:

```text
app
├── frontend
├── user-service
├── order-service
└── np-test
```

Namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app
  labels:
    istio.io/dataplane-mode: ambient
    workload: "true"
```

---

## middle

Chứa các middleware/API workload:

```text
middle
└── api-gateway
```

Namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: middle
  labels:
    istio.io/dataplane-mode: ambient
    workload: "true"
```

---

## istio-egress

Chứa external egress waypoint:

```text
istio-egress
└── egress-waypoint
```

Namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: istio-egress
  labels:
    istio.io/dataplane-mode: ambient
    name: istio-egress
```

---

# 4. Ambient Mesh

Workload không cần sidecar Envoy.

Traffic được intercept bởi:

```text
Application
     │
     ▼
   ztunnel
     │
     ├── L4 traffic
     │
     └── HBONE
            │
            ▼
        Waypoint
```

Kiểm tra:

```bash
kubectl get pods -A -l app.kubernetes.io/managed-by=istio
```

Kiểm tra ztunnel:

```bash
kubectl get pods -n istio-system -l app=ztunnel -o wide
```

---

# 5. ServiceAccounts

Các workload sử dụng ServiceAccount riêng.

## frontend

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend
  namespace: app
```

Identity:

```text
cluster.local/ns/app/sa/frontend
```

## user-service

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: user-service
  namespace: app
```

Identity:

```text
cluster.local/ns/app/sa/user-service
```

## order-service

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: order-service
  namespace: app
```

Identity:

```text
cluster.local/ns/app/sa/order-service
```

## api-gateway

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-gateway
  namespace: middle
```

Identity:

```text
cluster.local/ns/middle/sa/api-gateway
```

---

# 6. Internal Authorization

## 6.1 Frontend → API Gateway

Requirement:

```text
frontend       → api-gateway    ALLOW
user-service   → api-gateway    DENY
order-service  → api-gateway    DENY
```

AuthorizationPolicy:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend-to-api-gateway
  namespace: middle
spec:
  selector:
    matchLabels:
      app: api-gateway

  action: ALLOW

  rules:
  - from:
    - source:
        principals:
        - cluster.local/ns/app/sa/frontend
```

Policy được enforce tại destination workload / waypoint tùy dataplane configuration.

Điểm quan trọng:

> NetworkPolicy không được sử dụng để phân biệt `frontend`, `user-service` hay `order-service`.

NetworkPolicy chỉ đảm bảo network connectivity.

Identity authorization được thực hiện bởi Istio.

---

# 7. External Egress Waypoint

Tạo Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: egress-waypoint
  namespace: istio-egress
spec:
  gatewayClassName: istio-waypoint

  listeners:
  - name: mesh
    protocol: HBONE
    port: 15008

    allowedRoutes:
      namespaces:
        from: All
```

Kiểm tra:

```bash
kubectl get gateway -n istio-egress
```

Expected:

```text
NAME              CLASS           ADDRESS
egress-waypoint   istio-waypoint  ...
```

Kiểm tra Service:

```bash
kubectl get svc -n istio-egress
```

---

# 8. External PostgreSQL

Giả sử PostgreSQL nằm ngoài cluster:

```text
10.0.3.1:5432
```

## ServiceEntry

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: external-postgresql
  namespace: istio-egress

  labels:
    istio.io/use-waypoint: egress-waypoint

spec:
  hosts:
  - external-postgresql.local

  addresses:
  - 10.0.3.1/32

  ports:
  - number: 5432
    name: tcp-postgresql
    protocol: TCP

  resolution: STATIC

  endpoints:
  - address: 10.0.3.1
```

Lưu ý:

```yaml
resolution: STATIC
```

và:

```yaml
endpoints:
- address: 10.0.3.1
```

để traffic được đưa qua egress waypoint trong mô hình demo này.

---

# 9. PostgreSQL AuthorizationPolicy

Requirement:

```text
user-service   → PostgreSQL    ALLOW
order-service  → PostgreSQL    DENY
frontend       → PostgreSQL    DENY
```

Policy:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-user-service-to-postgresql
  namespace: istio-egress

spec:
  targetRefs:
  - kind: ServiceEntry
    group: networking.istio.io
    name: external-postgresql

  action: ALLOW

  rules:
  - from:
    - source:
        principals:
        - cluster.local/ns/app/sa/user-service
```

Kết quả:

```text
user-service
    │
    │ TCP/5432
    ▼
egress-waypoint
    │
    │ AuthorizationPolicy
    │
    ├── user-service  → ALLOW
    ├── order-service → DENY
    └── frontend      → DENY
    │
    ▼
10.0.3.1:5432
```

---

# 10. External Google

Để demo HTTPS egress:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: google
  namespace: istio-egress

  labels:
    istio.io/use-waypoint: egress-waypoint

spec:
  hosts:
  - google.com
  - www.google.com

  ports:
  - number: 443
    name: tls-https
    protocol: TLS

  resolution: DNS
```

Traffic:

```text
user-service
     │
     ▼
   ztunnel
     │
     │ HBONE
     ▼
egress-waypoint
     │
     ▼
Internet
     │
     ▼
www.google.com:443
```

---

# 11. Google AuthorizationPolicy

Nếu chỉ cho `user-service` truy cập Google:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-user-service-to-google
  namespace: istio-egress

spec:
  targetRefs:
  - kind: ServiceEntry
    group: networking.istio.io
    name: google

  action: ALLOW

  rules:
  - from:
    - source:
        principals:
        - cluster.local/ns/app/sa/user-service
```

Kết quả:

```text
user-service   → Google    ALLOW
order-service  → Google    DENY
frontend       → Google    DENY
```

---

# 12. NetworkPolicy

Istio AuthorizationPolicy kiểm soát:

```text
WHO can access WHAT
```

NetworkPolicy kiểm soát:

```text
WHERE packets can go
```

NetworkPolicy không nên được dùng để thay thế Istio identity authorization.

---

# 13. NetworkPolicy cho app

Mục tiêu:

```text
app workload
    │
    ├── DNS                    ALLOW
    ├── Cluster internal       ALLOW
    ├── HBONE → egress waypoint ALLOW
    │
    └── Direct Internet       DENY
```

Policy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-mesh-egress-only
  namespace: app

spec:
  podSelector: {}

  policyTypes:
  - Egress

  egress:

  # DNS
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system

    ports:
    - protocol: UDP
      port: 53

    - protocol: TCP
      port: 53

  # Internal cluster traffic
  - to:
    - namespaceSelector: {}

  # HBONE to egress waypoint
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: istio-egress

      podSelector:
        matchLabels:
          gateway.networking.k8s.io/gateway-name: egress-waypoint

    ports:
    - protocol: TCP
      port: 15008
```

---

# 14. NetworkPolicy cho middle

Nếu muốn toàn bộ application namespace không được direct Internet:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-mesh-egress-only
  namespace: middle

spec:
  podSelector: {}

  policyTypes:
  - Egress

  egress:

  # DNS
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system

    ports:
    - protocol: UDP
      port: 53

    - protocol: TCP
      port: 53

  # Internal cluster traffic
  - to:
    - namespaceSelector: {}

  # HBONE to egress waypoint
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: istio-egress

      podSelector:
        matchLabels:
          gateway.networking.k8s.io/gateway-name: egress-waypoint

    ports:
    - protocol: TCP
      port: 15008
```

Làm `middle` tương tự để chặn các kết nối ra external nếu như không qua egress.

---

# 15. NetworkPolicy cho Egress Waypoint

Egress waypoint phải được phép đi Internet.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-egress
  namespace: istio-egress

spec:
  podSelector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: egress-waypoint

  policyTypes:
  - Egress

  egress:
  - {}
```

Ý nghĩa:

```text
application
    │
    │ NetworkPolicy
    │
    │ only HBONE
    ▼
egress-waypoint
    │
    │ unrestricted egress
    ▼
Internet
```

---

# 16. Security Layers

Kiến trúc có 3 lớp chính.

## Layer 1 — Istio Ambient

```text
ztunnel
```

Đảm nhiệm:

- Workload interception
- mTLS
- Workload identity
- L4 traffic processing
- HBONE

---

## Layer 2 — Istio AuthorizationPolicy

Kiểm soát:

```text
ServiceAccount → Service
```

Ví dụ:

```text
frontend
   │
   └────→ api-gateway       ALLOW

user-service
   │
   └────→ PostgreSQL        ALLOW

order-service
   │
   └────→ PostgreSQL        DENY
```

Authorization dựa trên SPIFFE identity:

```text
cluster.local/ns/<namespace>/sa/<service-account>
```

---

## Layer 3 — NetworkPolicy

NetworkPolicy là network-level backstop.

```text
Application
    │
    ├── DNS              ALLOW
    ├── Cluster traffic  ALLOW
    ├── HBONE waypoint    ALLOW
    │
    └── Internet          DENY
```

Egress waypoint:

```text
egress-waypoint
    │
    └── Internet          ALLOW
```

---

# 17. Complete Traffic Model

## Internal traffic

```text
frontend
   │
   ▼
ztunnel
   │
   ▼
api-gateway
   │
   ├── NetworkPolicy
   │       └── network connectivity: ALLOW
   │
   └── Istio AuthorizationPolicy
           └── frontend identity: ALLOW
```

---

## Allowed external traffic

```text
user-service
   │
   ▼
ztunnel
   │
   │ HBONE
   ▼
egress-waypoint
   │
   ├── AuthorizationPolicy
   │       └── user-service: ALLOW
   │
   ▼
PostgreSQL
```

---

## Unauthorized external traffic

```text
order-service
   │
   ▼
ztunnel
   │
   │ HBONE
   ▼
egress-waypoint
   │
   ├── AuthorizationPolicy
   │       └── order-service: DENY
   │
   X
PostgreSQL
```

---

## Direct Internet bypass

```text
order-service
     │
     │ direct TCP
     ▼
Internet
     X
NetworkPolicy
     │
     └── DENY
```

NetworkPolicy đảm bảo workload không thể bypass egress waypoint bằng cách kết nối trực tiếp tới Internet.

---

# 18. Test NetworkPolicy

Tạo test Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: curl
  namespace: app
  labels:
    app: curl

spec:
  serviceAccountName: user-service

  containers:
  - name: curl
    image: curlimages/curl:8.10.1

    command:
    - sleep
    - "3600"

  restartPolicy: Never
```

Apply:

```bash
kubectl apply -f curl.yaml
```

---

# 19. Test Google

```bash
kubectl -n app exec -it curl -- \
  curl -v https://www.google.com
```

Nếu Google được khai báo trong ServiceEntry và AuthorizationPolicy cho phép:

```text
curl
 │
 ▼
ztunnel
 │
 ▼
egress-waypoint
 │
 ▼
Google
```

---

# 20. Test PostgreSQL

Test TCP:

```bash
kubectl -n app exec -it curl -- \
  nc -vz -w 3 10.0.3.1 5432
```

Hoặc nếu sử dụng hostname:

```bash
kubectl -n app exec -it curl -- \
  nc -vz -w 3 external-postgresql.local 5432
```

---

# 21. Test Unauthorized ServiceAccount

Tạo Pod với:

```yaml
serviceAccountName: order-service
```

Sau đó test:

```bash
nc -vz -w 3 10.0.3.1 5432
```

Expected:

```text
DENIED
```

Trong khi:

```text
user-service → PostgreSQL
```

Expected:

```text
ALLOWED
```

---

# 22. Verify Istio AuthorizationPolicy

List policy:

```bash
kubectl get authorizationpolicy -A
```

Chi tiết:

```bash
kubectl get authorizationpolicy \
  -n istio-egress \
  allow-user-service-to-postgresql \
  -o yaml
```

Kiểm tra Google:

```bash
kubectl get authorizationpolicy \
  -n istio-egress \
  allow-user-service-to-google \
  -o yaml
```

---

# 23. Verify ServiceEntry

```bash
kubectl get serviceentry -A
```

Expected:

```text
NAMESPACE       NAME
istio-egress    external-postgresql
istio-egress    google
```

Chi tiết:

```bash
kubectl get serviceentry \
  -n istio-egress \
  external-postgresql \
  -o yaml
```

---

# 24. Verify Waypoint

```bash
kubectl get gateway -n istio-egress
```

```bash
kubectl get pods -n istio-egress
```

Kiểm tra logs:

```bash
kubectl logs \
  -n istio-egress \
  -l gateway.networking.k8s.io/gateway-name=egress-waypoint
```

Có thể tìm các request bị deny:

```bash
kubectl logs \
  -n istio-egress \
  -l gateway.networking.k8s.io/gateway-name=egress-waypoint \
  | grep -i denied
```

Ví dụ:

```text
rbac_access_denied_matched_policy
```

---

# 25. Verify NetworkPolicy

```bash
kubectl get networkpolicy -A
```

Expected:

```text
app
  allow-mesh-egress-only

middle
  allow-mesh-egress-only

istio-egress
  allow-external-egress
```

---

# 26. Verify Calico

RKE2 sử dụng Canal, trong đó Calico chịu trách nhiệm NetworkPolicy.

Kiểm tra:

```bash
kubectl get pods -n kube-system | grep rke2-canal
```

Kiểm tra WorkloadEndpoint:

```bash
kubectl logs \
  -n kube-system \
  <rke2-canal-pod> \
  -c calico-node
```

Tìm workload:

```text
app/np-test
```

Có thể thấy:

```text
WorkloadEndpoint(
  node=rke-05,
  orchestrator=k8s,
  workload=app/np-test
)
```

và policy:

```text
deny-external-egress
```

---

# 27. Verify iptables

RKE2 Canal/Calico có thể sử dụng iptables-legacy.

Kiểm tra:

```bash
sudo iptables-legacy -L -n -v
```

Tìm Calico chain:

```bash
sudo iptables-legacy -L | grep cali
```

Ví dụ:

```text
cali-PREROUTING
cali-INPUT
cali-FORWARD
cali-OUTPUT
cali-POSTROUTING
```

Kiểm tra policy chain của workload:

```bash
sudo iptables-legacy \
  -L cali-fw-cali4663b2bbe35 \
  -n -v \
  --line-numbers
```

Nếu packet bị NetworkPolicy drop, counter của rule `DROP` sẽ tăng.

---

# 28. Test Direct Internet Block

Tạo Pod mới:

```bash
kubectl -n app run np-test2 \
  --image=nicolaka/netshoot \
  --restart=Never \
  -- \
  nc -4 -vz -w 3 google.com 443
```

Expected:

```text
FAIL / TIMEOUT
```

vì application Pod không được phép direct Internet.

---

# 29. Test Internet Through Waypoint

Khi Google được khai báo:

```text
ServiceEntry
    │
    ▼
egress-waypoint
```

Traffic phải đi:

```text
Pod
 │
 ▼
ztunnel
 │
 │ HBONE
 ▼
egress-waypoint
 │
 ▼
Internet
```

Không nên có path:

```text
Pod
 │
 └──────────────→ Internet
```

---

# 30. Final Security Matrix

| Source | Destination | NetworkPolicy | Istio AuthZ | Result |
|---|---|---:|---:|---|
| frontend | api-gateway | ALLOW | ALLOW | ALLOW |
| user-service | api-gateway | ALLOW | DENY | DENY |
| order-service | api-gateway | ALLOW | DENY | DENY |
| user-service | PostgreSQL | ALLOW via waypoint | ALLOW | ALLOW |
| order-service | PostgreSQL | ALLOW via waypoint | DENY | DENY |
| frontend | PostgreSQL | ALLOW via waypoint | DENY | DENY |
| user-service | Google | ALLOW via waypoint | ALLOW | ALLOW |
| order-service | Google | ALLOW via waypoint | DENY | DENY |
| app workload | Direct Internet | DENY | N/A | DENY |
| middle workload | Direct Internet | DENY | N/A | DENY |
| egress-waypoint | Internet | ALLOW | N/A | ALLOW |

---

# 31. Design Principle

Không dùng NetworkPolicy để implement business authorization.

Không nên tạo:

```text
frontend → api-gateway
user-service → PostgreSQL
```

bằng NetworkPolicy.

Thay vào đó:

```text
                 ┌──────────────────────────┐
                 │       Istio AuthZ        │
                 │                          │
                 │ ServiceAccount identity  │
                 │        ↓                 │
                 │   WHO → WHAT             │
                 └────────────┬─────────────┘
                              │
                              ▼
                 ┌──────────────────────────┐
                 │     NetworkPolicy        │
                 │                          │
                 │ Network connectivity     │
                 │        ↓                 │
                 │   WHERE packets go       │
                 └──────────────────────────┘
```

Tóm lại:

```text
Istio AuthorizationPolicy
        =
Identity / Service authorization

NetworkPolicy
        =
Network-level backstop

Egress Waypoint
        =
Centralized external traffic enforcement point
```

---

# 32. Final Architecture

```text
                         ┌──────────────────┐
                         │     Internet     │
                         └────────▲─────────┘
                                  │
                           unrestricted
                                  │
                         ┌────────┴─────────┐
                         │ Egress Waypoint  │
                         │  istio-egress    │
                         └────────▲─────────┘
                                  │
                                HBONE
                                  │
             ┌────────────────────┴────────────────────┐
             │                                         │
       ┌─────┴─────┐                             ┌─────┴─────┐
       │    app    │                             │  middle   │
       │            │                             │           │
       │ frontend   │────── Istio AuthZ ────────►│ api-gw    │
       │ user-svc   │                             │           │
       │ order-svc  │                             │           │
       └─────┬─────┘                             └───────────┘
             │
             │ NetworkPolicy
             │
             ├── DNS
             ├── Internal traffic
             └── HBONE → egress waypoint

```

Mô hình này tách rõ:

```text
             Identity Security
                    │
                    ▼
             Istio Ambient
                    │
             AuthorizationPolicy
                    │
                    ▼
             Egress Waypoint
                    │
                    ▼
             Network Security
                    │
             NetworkPolicy
                    │
                    ▼
                Internet
```

Đây là mô hình phù hợp để demo **Zero Trust giữa workload + kiểm soát egress + defense in depth** trên Istio Ambient.