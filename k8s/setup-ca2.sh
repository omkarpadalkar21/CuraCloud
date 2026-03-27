#!/bin/bash
openssl genrsa -out ca2-key.pem 4096
openssl req -new -key ca2-key.pem -subj "/O=MyOrg/CN=C2 CA" -out ca2-csr.pem
openssl x509 -req -days 1825 -CA root-cert.pem -CAkey root-key.pem -CAcreateserial -in ca2-csr.pem -out ca2-cert.pem -extfile <(printf "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always,issuer")
cat ca2-cert.pem root-cert.pem > ca2-chain.pem
kubectl config use-context cluster-2
kubectl create secret generic cacerts -n istio-system --from-file=ca-cert.pem=ca2-cert.pem --from-file=ca-key.pem=ca2-key.pem --from-file=root-cert.pem=root-cert.pem --from-file=cert-chain.pem=ca2-chain.pem
kubectl rollout restart deployment/istiod -n istio-system
kubectl rollout restart deployment --all -n billing-service
