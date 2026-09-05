```
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true


```

- Tạo secret chứa cloudflare API token
```
kubectl -n cert-manager create secret generic cloudflare-api-token-secret \
  --from-literal=api-token='YOUR_CLOUDFLARE_API_TOKEN'

```