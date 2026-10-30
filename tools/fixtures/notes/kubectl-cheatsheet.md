# kubectl stuff i always forget

## context / ns
```bash
kubectl config get-contexts
kubectl config use-context prod-us-east
kubectl config set-context --current --namespace=api
# or just use kubens / kubectx
```

## restart a deployment (no yaml change)
```bash
kubectl rollout restart deployment/api -n prod
kubectl rollout status deployment/api -n prod --timeout=5m
kubectl rollout history deployment/api -n prod
kubectl rollout undo deployment/api -n prod --to-revision=41
```

## debugging pods
```bash
kubectl get pods -n prod -o wide --sort-by=.status.startTime
kubectl describe pod api-7d9f8b6c5-x2kqp -n prod     # events at the bottom!!
kubectl logs -f deploy/api -n prod --since=10m
kubectl logs api-7d9f8b6c5-x2kqp -n prod --previous  # logs from the crashed container
kubectl exec -it api-7d9f8b6c5-x2kqp -n prod -- sh
kubectl debug -it api-7d9f8b6c5-x2kqp --image=busybox --target=api
```

## port forward
```bash
kubectl port-forward svc/postgres 5433:5432 -n data
kubectl port-forward deploy/api 9090:9090 -n prod   # prometheus metrics
```

## secrets
```bash
kubectl get secret api-env -n prod -o jsonpath='{.data.DATABASE_URL}' | base64 -d
kubectl create secret generic api-env --from-env-file=.env.prod -n prod --dry-run=client -o yaml | kubectl apply -f -
```

## scaling
```bash
kubectl scale deployment/worker --replicas=6 -n prod
kubectl get hpa -n prod
kubectl top pods -n prod --sort-by=memory
```

## the "why is it pending" checklist
- `kubectl describe pod` → look for `FailedScheduling`
- insufficient cpu/mem? `kubectl describe nodes | grep -A5 Allocated`
- PVC stuck? `kubectl get pvc -n prod`
- image pull? check `imagePullSecrets` + the tag actually exists

## nuke stuck namespace
```bash
kubectl get ns stuck-ns -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/stuck-ns/finalize" -f -
```
(last resort, ask first lol)
