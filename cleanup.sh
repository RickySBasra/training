#!/bin/bash
set -e

echo "Deleting all LoadBalancer services..."
kubectl get svc -A --no-headers | grep LoadBalancer | awk '{print $2, $1}' \
  | while read svc ns; do
      echo "Deleting $svc in $ns"
      kubectl delete svc $svc -n $ns
    done

echo "Deleting all Ingresses..."
kubectl get ingress -A --no-headers | awk '{print $2, $1}' \
  | while read ig ns; do
      echo "Deleting $ig in $ns"
      kubectl delete ingress $ig -n $ns
    done

