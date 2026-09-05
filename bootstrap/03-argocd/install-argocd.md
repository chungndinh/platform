```
helm upgrade --install argocd argo/argo-cd   -n argocd   -f values.yaml   --wait --create-namespace

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```
