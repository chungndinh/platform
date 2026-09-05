- Cài theo thứ tự
```
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
```
1. Istio base
```
helm upgrade --install istio-base istio/base \
  -n istio-system \
  --create-namespace \
  --version 1.30.4
```
2. Istiod (Control plane)
```
helm upgrade --install istiod istio/istiod \
  -n istio-system \
  --version 1.30.4 
```
3. Istio CNI
```
helm upgrade --install istio-cni istio/cni \
  -n istio-system \
  --version 1.30.4 \
  -f istio-cni.yaml
```

4. Istio ztunnel
```
helm upgrade --install ztunnel istio/ztunnel \
  -n istio-system \
  --version 1.30.4
```
5. Istio gateway
```
helm upgrade --install istio-ingress istio/gateway \
  -n istio-ingress \
  --version 1.30.4 -f istio-gateway.yaml --create-namespace --wait
```
6. Istio egress gateway
```
helm upgrade --install istio-egress istio/gateway \
  -n istio-egress \
  --version 1.30.4 -f istio-egress.yaml --create-namespace --wait
```
7. Access log của waypoint
```
kubectl apply -f accesslog.yaml
```