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
    await $`op whoami --format json`.text();
  } catch {
    throw new Error("You must sign in to 1Password first with `op signin`.");
  }
}

async function loadSecureNoteTemplate(): Promise<OnePasswordTemplate> {
  const templateCategory = "Secure Note";
  const templateText = await $`op item template get ${templateCategory} --format json`
    .text();
  return JSON.parse(templateText) as OnePasswordTemplate;
}

async function main(): Promise<void> {
  await requireCommand("kanidm");
  await requireCommand("op");
  await requireCommand("openssl");
  await requireCommand("tr");
  await ensureOpSession();

  const argClientId = Deno.args[0]?.trim();
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
    `${url}/oauth2/callback`,
  );
  const accessGroup = await promptRequired(
    "Access group",
    `${clientId}_access`,
  );
  const itemTitle = await promptRequired(
    "1Password item title",
    `${clientId}-oauth`,
  );

  console.log(`Creating Kanidm OAuth2 client ${clientId}...`);
  await $`kanidm system oauth2 create ${clientId} ${displayName} ${url}`;
  await $`kanidm system oauth2 add-redirect-url ${clientId} ${redirectUrl}`;
  await $`kanidm group create ${accessGroup}`;
  await $`kanidm system oauth2 update-scope-map ${clientId} ${accessGroup} openid profile groups email`;
  await $`kanidm system oauth2 prefer-short-username ${clientId}`;

  const clientSecretOutput = await $`kanidm system oauth2 show-basic-secret ${clientId}`
    .text();
  const clientSecret = lastNonEmptyLine(clientSecretOutput);
  if (clientSecret.length === 0) {
    throw new Error("Failed to read the client secret from Kanidm.");
  }

  const cookieSecret = (
    await $`openssl rand -base64 32 | tr -- '+/' '-_'`.text()
  ).trim();

  const template = await loadSecureNoteTemplate();
  template.title = itemTitle;
  template.fields = [
    {
      id: "notesPlain",
      label: "notesPlain",
      type: "STRING",
      purpose: "NOTES",
      value: "",
    },
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
      value: cookieSecret,
    },
  ];

  const tempFile = await Deno.makeTempFile({
    prefix: "oauth-item-",
    suffix: ".json",
  });

  try {
    await Deno.writeTextFile(tempFile, JSON.stringify(template));
    await $`op item create --vault cluster --template ${tempFile}`.text();
  } finally {
    await Deno.remove(tempFile).catch(() => undefined);
  }

  console.log(`Created 1Password item ${itemTitle} in vault cluster.`);
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
