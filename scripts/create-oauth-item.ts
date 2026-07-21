#!/usr/bin/env -S deno run --allow-run --allow-read --allow-write --allow-env

import { $ } from "jsr:@david/dax@0.45.0";

type OnePasswordField = {
  id: string;
  label: string;
  type: string;
  purpose?: string;
  value: string;
};

type OnePasswordTemplate = {
  title?: string;
  fields?: OnePasswordField[];
  [key: string]: unknown;
};

async function requireCommand(name: string): Promise<void> {
  const path = await $.which(name);
  if (path == null) {
    throw new Error(`Missing required command: ${name}`);
  }
}

async function promptRequired(
  message: string,
  defaultValue?: string,
): Promise<string> {
  const value = await $.prompt(message, {
    default: defaultValue,
    noClear: true,
  });
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    throw new Error(`${message} cannot be empty.`);
  }
  return trimmed;
}

function defaultDisplayName(clientId: string): string {
  return clientId
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join(" ");
}

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

function lastNonEmptyLine(text: string): string {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .at(-1) ?? "";
}

async function ensureOpSession(): Promise<void> {
  try {
    await $`op vault get cluster --format json`.text();
  } catch {
    throw new Error("You must sign in to 1Password first with `op signin`.");
  }
}

async function loadSecureNoteTemplate(): Promise<OnePasswordTemplate> {
  const templateCategory = "Secure Note";
  const templateText =
    await $`op item template get ${templateCategory} --format json`
      .text();
  return JSON.parse(templateText) as OnePasswordTemplate;
}

async function loadExistingItem(
  itemTitle: string,
): Promise<OnePasswordTemplate | undefined> {
  try {
    const itemText =
      await $`op item get ${itemTitle} --vault cluster --format json`
        .text();
    return JSON.parse(itemText) as OnePasswordTemplate;
  } catch {
    return undefined;
  }
}

async function main(): Promise<void> {
  const headlampMode = Deno.args.includes("--headlamp");
  const unknownFlags = Deno.args.filter((arg) =>
    arg.startsWith("--") && arg !== "--headlamp"
  );
  if (unknownFlags.length > 0) {
    throw new Error(`Unknown option: ${unknownFlags.join(", ")}`);
  }

  await requireCommand("kanidm");
  await requireCommand("op");
  if (!headlampMode) {
    await requireCommand("openssl");
    await requireCommand("tr");
  }
  await ensureOpSession();

  const argClientId = Deno.args.find((arg) => !arg.startsWith("--"))?.trim();
  const clientId = argClientId && argClientId.length > 0
    ? argClientId
    : await promptRequired("Client ID");

  const displayName = await promptRequired(
    "Display name",
    defaultDisplayName(clientId),
  );
  const url = trimTrailingSlash(
    await promptRequired("Application URL", `https://${clientId}.yadunut.dev`),
  );
  const redirectUrl = await promptRequired(
    "Redirect URL",
    `${url}/${headlampMode ? "oidc-callback" : "oauth2/callback"}`,
  );
  const accessGroup = await promptRequired(
    "Access group",
    `${clientId}_access`,
  );
  const itemTitle = await promptRequired(
    "1Password item title",
    `${clientId}-${headlampMode ? "oidc" : "oauth"}`,
  );

  const clientDetails = await $`kanidm system oauth2 get ${clientId}`.text();
  const clientExists = !clientDetails.includes("No matching entries");
  if (clientExists) {
    console.log(`Updating Kanidm OAuth2 client ${clientId}...`);
    await $`kanidm system oauth2 set-displayname ${clientId} ${displayName}`;
    await $`kanidm system oauth2 set-landing-url ${clientId} ${url}`;
    if (!clientDetails.includes(redirectUrl)) {
      await $`kanidm system oauth2 add-redirect-url ${clientId} ${redirectUrl}`;
    }
  } else {
    console.log(`Creating Kanidm OAuth2 client ${clientId}...`);
    await $`kanidm system oauth2 create ${clientId} ${displayName} ${url}`;
    await $`kanidm system oauth2 add-redirect-url ${clientId} ${redirectUrl}`;
  }

  const groupDetails = await $`kanidm group get ${accessGroup}`.text();
  const groupExists = !groupDetails.includes("No matching group");
  if (!groupExists) {
    await $`kanidm group create ${accessGroup}`;
  }
  await $`kanidm system oauth2 update-scope-map ${clientId} ${accessGroup} openid profile groups email`;
  await $`kanidm system oauth2 prefer-short-username ${clientId}`;

  const clientSecretOutput =
    await $`kanidm system oauth2 show-basic-secret ${clientId}`
      .text();
  const clientSecret = lastNonEmptyLine(clientSecretOutput);
  if (clientSecret.length === 0) {
    throw new Error("Failed to read the client secret from Kanidm.");
  }

  const cookieSecret = headlampMode
    ? undefined
    : (await $`openssl rand -base64 32 | tr -- '+/' '-_'`.text()).trim();

  const applicationFields: OnePasswordField[] = headlampMode
    ? [
      {
        id: "OIDC_CLIENT_ID",
        label: "OIDC_CLIENT_ID",
        type: "STRING",
        value: clientId,
      },
      {
        id: "OIDC_CLIENT_SECRET",
        label: "OIDC_CLIENT_SECRET",
        type: "CONCEALED",
        value: clientSecret,
      },
      {
        id: "OIDC_ISSUER_URL",
        label: "OIDC_ISSUER_URL",
        type: "STRING",
        value: `https://idm.yadunut.dev/oauth2/openid/${clientId}`,
      },
      {
        id: "OIDC_SCOPES",
        label: "OIDC_SCOPES",
        type: "STRING",
        value: "profile,email,groups",
      },
      {
        id: "OIDC_USE_PKCE",
        label: "OIDC_USE_PKCE",
        type: "STRING",
        value: "true",
      },
      {
        id: "OIDC_CALLBACK_URL",
        label: "OIDC_CALLBACK_URL",
        type: "STRING",
        value: redirectUrl,
      },
    ]
    : [
      {
        id: "client-id",
        label: "client-id",
        type: "STRING",
        value: clientId,
      },
      {
        id: "client-secret",
        label: "client-secret",
        type: "CONCEALED",
        value: clientSecret,
      },
      {
        id: "cookie-secret",
        label: "cookie-secret",
        type: "CONCEALED",
        value: cookieSecret!,
      },
    ];

  const existingItem = headlampMode
    ? await loadExistingItem(itemTitle)
    : undefined;
  const template = existingItem ?? await loadSecureNoteTemplate();
  template.title = itemTitle;
  const fields = template.fields ?? [];
  for (const field of applicationFields) {
    const existingField = fields.find((candidate) =>
      candidate.label === field.label
    );
    if (existingField) {
      Object.assign(existingField, field);
    } else {
      fields.push(field);
    }
  }
  const builtInPassword = fields.find((field) => field.label === "password");
  if (headlampMode && builtInPassword && !builtInPassword.value) {
    builtInPassword.type = "CONCEALED";
    builtInPassword.value = clientSecret;
  }
  if (!fields.some((field) => field.purpose === "NOTES")) {
    fields.unshift({
      id: "notesPlain",
      label: "notesPlain",
      type: "STRING",
      purpose: "NOTES",
      value: "",
    });
  }
  template.fields = fields;

  const tempFile = await Deno.makeTempFile({
    prefix: "oauth-item-",
    suffix: ".json",
  });

  try {
    await Deno.writeTextFile(tempFile, JSON.stringify(template));
    if (existingItem) {
      await $`op item edit ${itemTitle} --vault cluster --template ${tempFile}`
        .text();
    } else {
      await $`op item create --vault cluster --template ${tempFile}`.text();
    }
  } finally {
    await Deno.remove(tempFile).catch(() => undefined);
  }

  console.log(
    `${
      existingItem ? "Updated" : "Created"
    } 1Password item ${itemTitle} in vault cluster.`,
  );
  console.log(`Access group: ${accessGroup}`);
  console.log(`Application URL: ${url}`);
  console.log(`Redirect URL: ${redirectUrl}`);
}

if (import.meta.main) {
  await main().catch((error: unknown) => {
    if (error instanceof Error) {
      console.error(error.message);
    } else {
      console.error(String(error));
    }
    Deno.exit(1);
  });
}
