premhome-gc1, 11GB Ram, 6 Cores, Public IP

falcon-server-1, with X GB Ram, X Cores, No public IP, only private IP.
eagle-server-1, with X GB Ram, X Cores, No public IP, only private IP.

1. Why not use the flannel's wg interface?

This requires the ndoes to have public IPs. But this wouldn't be the case for my system as the nodes at home only have private IPs.

Steps:

1. Install k3s on gc1
2. Install flux on gc1
3. Deploy zerotier controller on gc1
4. Setup a zerotier interface on gc1
5. Migrate flannel iface to zerotier interface
6. Setup zerotier on the

# Steps taken

1. Setup a zerotier controller: https://docs.zerotier.com/controller

On premhome-gc1,

```sh
TOKEN=$(sudo cat /var/lib/zerotier-one/authtoken.secret)
NODEID=$(sudo zerotier-cli info | cut -d " " -f 3)

# Create a network
NWID=$(curl -X POST "http://localhost:9993/controller/network/${NODEID}______" -H "X-ZT1-AUTH: ${TOKEN}" -d {} | jq -r ".nwid")

# Setup the IP address range and routes for this network
curl -X POST "http://localhost:9993/controller/network/${NWID}" -H "X-ZT1-AUTH: ${TOKEN}" \
    -d '{"ipAssignmentPools": [{"ipRangeStart": "10.222.0.0", "ipRangeEnd": "10.222.0.254"}], "routes": [{"target": "10.222.0.0/23", "via": null}], "rules": [ { "etherType": 2048, "not": true, "or": false, "type": "MATCH_ETHERTYPE" }, { "etherType": 2054, "not": true, "or": false, "type": "MATCH_ETHERTYPE" }, { "etherType": 34525, "not": true, "or": false, "type": "MATCH_ETHERTYPE" }, { "type": "ACTION_DROP" }, { "type": "ACTION_ACCEPT" } ], "v4AssignMode": "zt", "private": true }'

# Authorize the current server
curl -X POST "http://localhost:9993/controller/network/${NWID}/member/${NODEID}" -H "X-ZT1-AUTH: ${TOKEN}" -d '{"authorized": true}'

```

Yay! you now have an interface, and an IP address to broadcast on :D

# What I have

1. premhome-gc1
   IP: 167.253.159.47
2. premhome-falcon-1
   IP: 10.0.0.55
3. premhome-eagle-1
   IP: 10.0.0.248

## Deploying secrets


```sh
op connect server create cluster --vaults cluster
op connect token create cluster --server <Server ID> --vault cluster
# Copy this and paste this to `cluster/1password-token/password`

cat 1password-credentials.json | base64 |  tr '/+' '_-' | tr -d '=' | tr -d '\n' > password
# Upload this file to `cluster/1password-credentials/password`
mv token password
# Upload this file to `cluster/1password-token/password`
kubectl create secret generic -n 1password-system 1password-credentials  --from-literal=password="$(op read -n 'op://cluster/1password-credentials/1password-credentials.json')"
kubectl create secret generic -n 1password-system 1password-token  --from-literal password="$(op read -n 'op://cluster/1password-token/password')"
```
