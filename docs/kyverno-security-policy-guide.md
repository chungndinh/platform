# Kyverno Security Policy Guide

## 1. Mục tiêu

Kyverno được sử dụng làm policy engine cho Kubernetes để kiểm soát security posture của workload.

Trong lab này, nguyên tắc chính là:

- Kyverno được cài đặt qua ArgoCD/Helm.
- Security policy dành cho application workload chỉ áp dụng cho Namespace có label:
  `workload=true`.
- Các namespace platform như `argocd`, `istio-system`, `kyverno`, `vault`... không bị ảnh hưởng nếu không có label này.
- Giai đoạn đầu sử dụng `Audit` để quan sát violation trước khi chuyển sang `Deny`.
- Policy được quản lý bằng GitOps.

---

## 2. Kiến trúc GitOps

Ví dụ cấu trúc repository:

```text
├── argocd
│   ├── applications
│   │   ├── nonprod
│   │   │   └── platform
│   │   └── prod
│   │       ├── platform
│   │       │   ├── kyverno-polices.yaml
│   │       │   └── kyverno.yaml
│   │       └── workloads
│   ├── projects
│   │   └── platform-project.yaml
│   ├── root-apps
│   │   └── prod
│   │       └── root-app.yaml
│   └── values
│       ├── nonprod
│       └── prod
│           ├── platform
│           │   └── kyverno
│           │       └── values.yaml
│           └── workloads
├── bootstrap
│   ├── 00-storage
│   │   ├── cephfs-csi
│   │   │   ├── cephfs-values.yaml
│   │   │   └── pvc.yaml
│   │   ├── host-path
│   │   │   └── install.md
│   │   └── nfs-sc
│   │       ├── deploy.sh
│   │       ├── nfs-sc-values.yaml
│   │       └── nfs-subdir-external-provisioner-4.0.18.tgz
│   ├── 01-cert-manager
│   │   ├── 00.cluster-issuer.yaml
│   │   ├── 01.certificate.yaml
│   │   └── install-cert-manager.md
│   ├── 02-istio-system
│   │   ├── accesslog.yaml
│   │   ├── install-istio-system.md
│   │   ├── istio-cni.yaml
│   │   ├── istio-egress.yaml
│   │   ├── istio-gateway.yaml
│   │   ├── istio-istiod.yaml
│   │   └── org-values
│   │       ├── istio-base.yaml
│   │       ├── istio-cni.yaml
│   │       ├── istio-gateway.yaml
│   │       ├── istio-istiod.yaml
│   │       └── istio-ztunnel.yaml
│   └── 03-argocd
│       ├── gateway.yaml
│       ├── httproute.yaml
│       ├── install-argocd.md
│       ├── org-values
│       │   └── values.yaml
│       └── values.yaml
├── docs
│   └── kyverno-security-policy-guide.md
└── kyverno
    └── policies
        ├── nonprod
        └── prod
            ├── require-run-as-nonroot.yaml
            └── require-service-account.yaml
```

Nếu policy khác nhau giữa môi trường, có thể tổ chức:

```text
kyverno/policies/
├── nonprod/
└── prod/
    ├── require-run-as-nonroot.yaml
    └── require-service-account.yaml
```

Khuyến nghị:

- `common`: policy security bắt buộc ở mọi môi trường.
- `dev`: policy riêng cho dev.
- `staging`: policy riêng cho staging.
- `prod`: policy chặt hơn cho production.

---

# 3. Cài đặt Kyverno

Kyverno được cài bằng Helm thông qua ArgoCD.

Ví dụ values:

```yaml
crds:
  install: true

admissionController:
  replicas: 1

backgroundController:
  replicas: 1

cleanupController:
  replicas: 1

reportsController:
  replicas: 1
```

## ArgoCD Application

Ví dụ:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
spec:
  project: platform

  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno

  sources:
    - repoURL: https://kyverno.github.io/kyverno/
      chart: kyverno
      targetRevision: <KYVERNO_VERSION>
      helm:
        valueFiles:
          - $values/argocd/values/prod/platform/kyverno/values.yaml

    - repoURL: https://github.com/YOUR_ORG/platform.git
      targetRevision: main
      ref: values

  syncPolicy:
    automated:
      prune: true
      selfHeal: true

    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### Tại sao cần ServerSideApply?

Kyverno có các CRD lớn. Khi cài bằng client-side apply có thể gặp lỗi annotation quá dài, ví dụ:

```text
metadata.annotations: Too long
```

Do đó sử dụng:

```yaml
syncOptions:
  - ServerSideApply=true
```

---

# 4. Kiểm tra Kyverno

## Kiểm tra Pod

```bash
kubectl get pods -n kyverno
```

## Kiểm tra CRD

```bash
kubectl get crd | grep kyverno
```

## Kiểm tra ValidatingPolicy

```bash
kubectl get validatingpolicies.policies.kyverno.io
```

Chi tiết:

```bash
kubectl get validatingpolicy <POLICY_NAME> -o yaml
```

---

# 5. API Version của ValidatingPolicy

Cluster hiện tại sử dụng:

```yaml
apiVersion: policies.kyverno.io/v1alpha1
```

Không sử dụng:

```yaml
apiVersion: policies.kyverno.io/v1
```

nếu CRD trong cluster chưa hỗ trợ version đó.

Kiểm tra:

```bash
kubectl get crd validatingpolicies.policies.kyverno.io \
  -o jsonpath='{.spec.versions[*].name}'
```

Nếu kết quả:

```text
v1alpha1
```

thì policy phải dùng:

```yaml
apiVersion: policies.kyverno.io/v1alpha1
```

---

# 6. Quy ước Namespace Workload

Security policy dành cho application chỉ áp dụng vào namespace có:

```yaml
labels:
  workload: "true"
```

Ví dụ:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment
  labels:
    workload: "true"
```

Hoặc:

```bash
kubectl label namespace payment workload=true
```

Kiểm tra:

```bash
kubectl get ns --show-labels
```

---

# 7. Namespace Selector

Các policy workload sử dụng:

```yaml
matchConstraints:
  resourceRules:
    - apiGroups: [...]
      apiVersions: [...]
      operations: ["CREATE", "UPDATE"]
      resources: [...]

  namespaceSelector:
    matchLabels:
      workload: "true"
```

Ý nghĩa:

```text
Namespace có workload=true
        |
        +--> Policy được áp dụng

Namespace không có workload=true
        |
        +--> Policy không match
```

Ví dụ:

```text
payment       workload=true     -> APPLY
order         workload=true     -> APPLY
user          workload=true     -> APPLY

argocd        không có label    -> IGNORE
istio-system  không có label    -> IGNORE
kyverno       không có label    -> IGNORE
vault         không có label    -> IGNORE
```

---

# 8. Policy 1 - Require runAsNonRoot

Mục tiêu: workload không được chạy container với root user.

File:

```text
kyverno/policies/security/require-run-as-nonroot.yaml
```

Policy:

```yaml
apiVersion: policies.kyverno.io/v1alpha1
kind: ValidatingPolicy
metadata:
  name: require-run-as-nonroot
  annotations:
    policies.kyverno.io/title: Require runAsNonRoot
    policies.kyverno.io/category: Security
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
spec:
  validationActions:
    - Audit

  evaluation:
    background:
      enabled: true

  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]

    namespaceSelector:
      matchLabels:
        workload: "true"

  variables:
    - name: ctnrs
      expression: >-
        object.spec.containers +
        object.spec.?initContainers.orValue([]) +
        object.spec.?ephemeralContainers.orValue([])

  validations:
    - expression: >-
        (
          object.spec.?securityContext.?runAsNonRoot.orValue(false) == true
          &&
          variables.ctnrs.all(
            c,
            c.?securityContext.?runAsNonRoot.orValue(true) == true
          )
        )
        ||
        variables.ctnrs.all(
          c,
          c.?securityContext.?runAsNonRoot.orValue(false) == true
        )
      message: >-
        Running as root is not allowed. Either
        spec.securityContext.runAsNonRoot must be set to true,
        or all containers must have
        securityContext.runAsNonRoot=true.
```

## Workload hợp lệ

```yaml
spec:
  securityContext:
    runAsNonRoot: true

  containers:
    - name: app
      image: nginx:alpine
```

## Workload vi phạm

```yaml
spec:
  containers:
    - name: app
      image: nginx:alpine
```

Nếu policy đang `Audit`, resource vẫn được tạo nhưng Kyverno tạo violation trong PolicyReport.

---

# 9. Policy 2 - Require Matching ServiceAccount

## Mục tiêu

Tránh workload tùy tiện sử dụng ServiceAccount có quyền cao hơn.

Kubernetes không có quan hệ mặc định:

```text
Deployment <-> ServiceAccount
```

Một Deployment có thể tham chiếu bất kỳ ServiceAccount nào trong cùng namespace.

Vì vậy lab này sử dụng convention:

```text
Deployment: payment-api
ServiceAccount: payment-api
```

Tức là:

```text
Deployment.metadata.name
          ==
PodTemplate.spec.serviceAccountName
```

File:

```text
kyverno/policies/security/require-matching-service-account.yaml
```

Policy:

```yaml
apiVersion: policies.kyverno.io/v1alpha1
kind: ValidatingPolicy
metadata:
  name: require-matching-service-account
  annotations:
    policies.kyverno.io/title: Require Matching ServiceAccount
    policies.kyverno.io/category: Security
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Deployment
spec:
  validationActions:
    - Audit

  evaluation:
    background:
      enabled: true

  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]

    namespaceSelector:
      matchLabels:
        workload: "true"

  validations:
    - expression: >-
        has(object.spec.template.spec.serviceAccountName)
        &&
        object.spec.template.spec.serviceAccountName != ""
        &&
        object.spec.template.spec.serviceAccountName == object.metadata.name
      message: >-
        Deployment must use a ServiceAccount with the same name
        as the Deployment.
```

## Đúng

```yaml
metadata:
  name: payment-api

spec:
  template:
    spec:
      serviceAccountName: payment-api
```

## Sai

```yaml
metadata:
  name: payment-api

spec:
  template:
    spec:
      serviceAccountName: admin
```

Hoặc không khai báo:

```yaml
spec:
  template:
    spec:
      # serviceAccountName missing
```

---

# 10. Test Policy runAsNonRoot

## Tạo namespace

```bash
kubectl create namespace policy-test
kubectl label namespace policy-test workload=true
```

Kiểm tra:

```bash
kubectl get ns policy-test --show-labels
```

## Pod vi phạm

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-root-pod
  namespace: policy-test
spec:
  containers:
    - name: nginx
      image: nginx:alpine
```

Apply:

```bash
kubectl apply -f test-root-pod.yaml
```

Vì policy đang:

```yaml
validationActions:
  - Audit
```

Pod vẫn được tạo.

Kiểm tra:

```bash
kubectl get pods -n policy-test
```

Kiểm tra report:

```bash
kubectl get policyreports -n policy-test
```

Chi tiết:

```bash
kubectl describe policyreport -n policy-test
```

---

# 11. Test Pod hợp lệ

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-nonroot-pod
  namespace: policy-test
spec:
  securityContext:
    runAsNonRoot: true

  containers:
    - name: nginx
      image: nginx:alpine
```

Apply:

```bash
kubectl apply -f test-nonroot-pod.yaml
```

Kiểm tra:

```bash
kubectl get policyreports -n policy-test -o yaml
```

---

# 12. Test namespace không có workload label

Tạo namespace:

```bash
kubectl create namespace no-policy-test
```

Không gắn:

```text
workload=true
```

Tạo Pod không có runAsNonRoot:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-root-pod
  namespace: no-policy-test
spec:
  containers:
    - name: nginx
      image: nginx:alpine
```

Apply:

```bash
kubectl apply -f test-root-pod.yaml
```

Policy workload không được match namespace này.

---

# 13. Test ServiceAccount Policy

## Tạo ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-api
  namespace: policy-test
```

Apply:

```bash
kubectl apply -f payment-sa.yaml
```

## Deployment đúng

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: policy-test
spec:
  replicas: 1

  selector:
    matchLabels:
      app: payment-api

  template:
    metadata:
      labels:
        app: payment-api

    spec:
      serviceAccountName: payment-api

      containers:
        - name: payment-api
          image: nginx:alpine
```

## Deployment sai

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: policy-test
spec:
  replicas: 1

  selector:
    matchLabels:
      app: payment-api

  template:
    metadata:
      labels:
        app: payment-api

    spec:
      serviceAccountName: admin

      containers:
        - name: payment-api
          image: nginx:alpine
```

Kiểm tra:

```bash
kubectl get policyreports -n policy-test
```

---

# 14. PolicyReport

Xem tất cả namespace:

```bash
kubectl get policyreports -A
```

Ví dụ:

```text
NAMESPACE      NAME       KIND        NAME                  PASS   FAIL
policy-test    ...        Pod         test-root-pod         0      1
```

Xem riêng namespace:

```bash
kubectl get policyreports -n policy-test
```

Chi tiết:

```bash
kubectl describe policyreport -n policy-test
```

Hoặc:

```bash
kubectl get policyreports -n policy-test -o yaml
```

## Xóa toàn bộ PolicyReport

Dùng khi muốn reset kết quả test:

```bash
kubectl delete policyreports --all -A
```

Nếu có ClusterPolicyReport:

```bash
kubectl delete clusterpolicyreports --all
```

Sau đó:

```bash
kubectl get policyreports -A
kubectl get clusterpolicyreports
```

### Lưu ý

PolicyReport là kết quả evaluation/scan. Việc vẫn thấy report cũ không nhất thiết có nghĩa policy đang tiếp tục match resource đó.

Khi thay đổi selector hoặc policy, nên xóa report cũ rồi test resource mới để kiểm tra rõ ràng.

---

# 15. Audit và Deny

## Audit

Giai đoạn đầu:

```yaml
validationActions:
  - Audit
```

Behavior:

```text
Resource
   |
   v
Kyverno
   |
   +-- PASS -> report PASS
   |
   +-- FAIL -> report FAIL
             |
             +-- Resource vẫn được tạo
```

## Deny

Khi policy đã được kiểm chứng, có thể chuyển sang:

```yaml
validationActions:
  - Deny
```

Behavior:

```text
Resource
   |
   v
Kyverno
   |
   +-- PASS -> CREATE/UPDATE
   |
   +-- FAIL -> DENY
```

Khuyến nghị rollout:

```text
Audit
  ↓
Review violations
  ↓
Fix workloads
  ↓
Audit stable
  ↓
Deny
```

---

# 16. Security Policy Roadmap

Sau hai policy đầu tiên, có thể bổ sung theo thứ tự:

## Identity / ServiceAccount

```text
01. Require explicit ServiceAccount
02. Require matching ServiceAccount
03. Restrict privileged ServiceAccount
04. Disable automountServiceAccountToken by default
```

## Container security

```text
05. Require runAsNonRoot
06. Disallow privileged containers
07. Disallow hostNetwork
08. Disallow hostPID
09. Disallow hostIPC
10. Disallow hostPath
11. Restrict Linux capabilities
12. Require seccompProfile
```

## Image security

```text
13. Allow only trusted registries
14. Require image tag
15. Require image digest for production
16. Image signature verification
17. Image vulnerability policy
```

## Resource governance

```text
18. Require CPU requests
19. Require CPU limits
20. Require memory requests
21. Require memory limits
```

## Kubernetes governance

```text
22. Require standard labels
23. Require owner/team labels
24. Restrict Namespace creation
25. Restrict LoadBalancer/NodePort
26. Restrict host ports
27. Restrict dangerous capabilities
```

---

# 17. Khuyến nghị policy cho lab

Nên triển khai theo từng phase:

```text
Phase 1 - Identity
├── require-run-as-nonroot
├── require-matching-service-account
└── disable-automount-service-account-token

Phase 2 - Container hardening
├── disallow-privileged
├── disallow-host-network
├── disallow-host-pid
├── disallow-host-ipc
├── disallow-host-path
└── require-seccomp

Phase 3 - Image security
├── trusted-registry
├── require-image-digest
└── verify-image-signature

Phase 4 - Resource governance
├── require-resource-requests
└── require-resource-limits

Phase 5 - Production enforcement
└── chuyển Audit -> Deny
```

---

# 18. Nguyên tắc quan trọng

### Policy workload

Luôn giới hạn bằng:

```yaml
namespaceSelector:
  matchLabels:
    workload: "true"
```

### Không hard-code privileged SA nếu không có convention

Không nên mặc định tạo policy kiểu:

```text
admin
cluster-admin
root
```

vì tên ServiceAccount có thể khác giữa hệ thống.

Tốt hơn là enforce:

```text
Deployment -> dedicated ServiceAccount
```

và kiểm soát quyền bằng RBAC.

### ServiceAccount không tự tạo privilege

Risk thực sự nằm ở:

```text
Deployment
   ↓
ServiceAccount
   ↓
Role / ClusterRole
   ↓
Permissions
```

Do đó cần kết hợp:

```text
Kyverno
+
RBAC
+
NetworkPolicy
+
Istio AuthorizationPolicy
```

Kyverno kiểm soát workload configuration; RBAC kiểm soát quyền Kubernetes API.

---

# 19. Checklist

## Installation

- [ ] Kyverno installed
- [ ] CRDs ready
- [ ] ArgoCD manages Kyverno
- [ ] ServerSideApply enabled

## Namespace

- [ ] Workload namespace has `workload=true`
- [ ] Platform namespace does not have `workload=true`

## Policy

- [ ] `require-run-as-nonroot`
- [ ] `require-matching-service-account`
- [ ] Audit tested
- [ ] PolicyReport verified
- [ ] Non-workload namespace verified

## Before Deny

- [ ] Existing violations reviewed
- [ ] Workloads fixed
- [ ] Exceptions identified
- [ ] PolicyException strategy defined
- [ ] Change from Audit to Deny

---

# 20. Quick Commands

```bash
# Kyverno pods
kubectl get pods -n kyverno

# Kyverno CRDs
kubectl get crd | grep kyverno

# Policies
kubectl get validatingpolicies.policies.kyverno.io

# Specific policy
kubectl get validatingpolicy require-run-as-nonroot -o yaml

# Namespace labels
kubectl get ns --show-labels

# Policy reports
kubectl get policyreports -A

# Namespace policy reports
kubectl get policyreports -n policy-test

# Detailed report
kubectl describe policyreport -n policy-test

# Reset reports
kubectl delete policyreports --all -A
kubectl delete clusterpolicyreports --all

# Check workload label
kubectl get ns policy-test --show-labels
```
