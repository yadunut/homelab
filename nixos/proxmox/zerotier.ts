const BASE_URL = "http://localhost:9993";
const token = Deno.env.get("ZT_TOKEN");
async function main() {
  if (!token) {
    throw new Error("Token is empty");
  }
  const nodeId = (await get("/status")).address;
  // check if networks exist
  const networks = await getNetworks();
  let networkId = "";
  if (networks.length > 0) {
    networkId = networks[0];
  } else {
    const network = await createNetwork(nodeId);
    networkId = network.nwid;
  }
  switch (Deno.args[0]) {
    case "join": {
      console.log(
        `Node should join the network ${networkId} Once joined, fill in the node address below`,
      );
      const nodeAddress = prompt("Node address")?.trim();
      if (!nodeAddress) {
        console.log("Node address is required");
        return;
      }

      await authorizeNode(networkId, nodeAddress);
      console.log("Node authorized");
      return;
    }
    case "configNetwork": {
      const data = await post(`/controller/network/${networkId}`, {
        name: "k3sNetwork",
        "ipAssignmentPools": [{
          "ipRangeStart": "10.222.0.0",
          "ipRangeEnd": "10.222.0.254",
        }],
        "routes": [
          { "target": "10.222.0.0/23", "via": null },
          { "target": "10.42.0.0/16", "via": null },
          // { "target": "10.42.0.0/24", "via": "10.222.0.52" },
          // { "target": "10.42.1.0/24", "via": "10.222.0.63" },
          // { "target": "10.42.2.0/24", "via": "10.222.0.62" },
        ],
        "rules": [
          {
            "etherType": 2048,
            "not": true,
            "or": false,
            "type": "MATCH_ETHERTYPE",
          },
          {
            "etherType": 2054,
            "not": true,
            "or": false,
            "type": "MATCH_ETHERTYPE",
          },
          {
            "etherType": 34525,
            "not": true,
            "or": false,
            "type": "MATCH_ETHERTYPE",
          },
          { "type": "ACTION_DROP" },
          { "type": "ACTION_ACCEPT" },
        ],
        "v4AssignMode": "zt",
        "private": true,
      });
      break;
    }

    case "getNetwork": {
      const data = await get(`/controller/network/${networkId}`) as string[];
      console.log(JSON.stringify(data, null, 2));
      break;
    }
    default:
      throw new Error("unknown option");
  }
}

async function getNetworks() {
  const data = await get("/controller/network") as string[];
  return data;
}

async function createNetwork(nodeId: string) {
  const data = await post(`/controller/network/${nodeId}______`, {
    name: "k3sNetwork",
    "ipAssignmentPools": [{
      "ipRangeStart": "10.222.0.0",
      "ipRangeEnd": "10.222.0.254",
    }],
    "routes": [{ "target": "10.222.0.0/23", "via": null }],
    "rules": [
      {
        "etherType": 2048,
        "not": true,
        "or": false,
        "type": "MATCH_ETHERTYPE",
      },
      {
        "etherType": 2054,
        "not": true,
        "or": false,
        "type": "MATCH_ETHERTYPE",
      },
      {
        "etherType": 34525,
        "not": true,
        "or": false,
        "type": "MATCH_ETHERTYPE",
      },
      { "type": "ACTION_DROP" },
      { "type": "ACTION_ACCEPT" },
    ],
    "v4AssignMode": "zt",
    "private": true,
  }) as {
    name: string;
    nwid: string;
    id: string;
  };
  // configure network routes
  return data;
}

async function _getNetwork(id: string) {
  const data = await get(`/controller/network/${id}`);
  return data;
}

async function authorizeNode(networkId: string, nodeId: string) {
  try {
    const data = await post(
      `/controller/network/${networkId}/member/${nodeId}`,
      {
        authorized: true,
        activeBridge: true,
      },
    );
    return data;
  } catch (e) {
    console.error("ERROR", e);
  }
}

async function get(url: string) {
  console.log(`getting ${url}`);
  const res = await fetch(`${BASE_URL}${url}`, {
    headers: {
      "X-ZT1-AUTH": token,
    },
  });
  const json = await res.json();
  console.log(`Response: ${JSON.stringify(json)}`);
  return json;
}

async function post(url: string, body?: unknown) {
  console.log(`post: ${url}, body: ${JSON.stringify(body)}`);
  const res = await fetch(`${BASE_URL}${url}`, {
    method: "POST",
    body: JSON.stringify(body),
    headers: {
      "X-ZT1-AUTH": token,
    },
  });
  const json = res.json();
  console.log(`Response: ${JSON.stringify(json)}`);
  return json;
}

await main();
