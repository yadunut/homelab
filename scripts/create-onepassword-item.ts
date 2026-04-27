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

async function promptOptional(
  message: string,
  defaultValue?: string,
): Promise<string> {
  const value = await $.prompt(message, {
    default: defaultValue,
    noClear: true,
  });
  return value.trim();
}

async function promptRequired(
  message: string,
  defaultValue?: string,
): Promise<string> {
  const value = await promptOptional(message, defaultValue);
  if (value.length === 0) {
    throw new Error(`${message} cannot be empty.`);
  }
  return value;
}

async function promptYesNo(
  message: string,
  defaultValue = true,
): Promise<boolean> {
  const suffix = defaultValue ? "Y/n" : "y/N";
  const answer = (await promptOptional(`${message} (${suffix})`)).toLowerCase();

  if (answer.length === 0) {
    return defaultValue;
  }

  if (["y", "yes"].includes(answer)) {
    return true;
  }

  if (["n", "no"].includes(answer)) {
    return false;
  }

  throw new Error(`Invalid response for ${message}.`);
}

function inferNamespaceFromPath(path: string): string | undefined {
  const parts = path.split("/").filter(Boolean);
  const appsIndex = parts.findIndex((part) => part === "apps");
  if (appsIndex === -1 || appsIndex + 1 >= parts.length) {
    return undefined;
  }
  return parts[appsIndex + 1];
}

function dirname(path: string): string {
  const normalized = path.replace(/\/+$/, "");
  const lastSlash = normalized.lastIndexOf("/");
  if (lastSlash === -1) {
    return ".";
  }
  if (lastSlash === 0) {
    return "/";
  }
  return normalized.slice(0, lastSlash);
}

function isSensitiveFieldName(fieldName: string): boolean {
  return /(secret|password|token|key|cookie)/i.test(fieldName);
}

function fieldType(
  fieldName: string,
  generatedValue: boolean,
): "STRING" | "CONCEALED" {
  if (generatedValue || isSensitiveFieldName(fieldName)) {
    return "CONCEALED";
  }
  return "STRING";
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await Deno.stat(path);
    return true;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return false;
    }
    throw error;
  }
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

async function generateSecret(): Promise<string> {
  return (await $`openssl rand -base64 32 | tr -- '+/' '-_'`.text()).trim();
}

function renderManifest(
  resourceName: string,
  namespace: string,
  itemTitle: string,
  vault = "cluster",
): string {
  return [
    "apiVersion: onepassword.com/v1",
    "kind: OnePasswordItem",
    "metadata:",
    `  name: ${resourceName}`,
    `  namespace: ${namespace}`,
    "spec:",
    `  itemPath: "vaults/${vault}/items/${itemTitle}"`,
    "",
  ].join("\n");
}

async function promptFields(): Promise<OnePasswordField[]> {
  const fields: OnePasswordField[] = [];

  console.log(
    "Enter fields for the item. Leave the field name blank when you are done.",
  );

  while (true) {
    const defaultFieldName = fields.length === 0 ? "password" : undefined;
    const name = await promptOptional("Field name", defaultFieldName);

    if (name.length === 0) {
      if (fields.length === 0) {
        throw new Error("At least one field is required.");
      }
      break;
    }

    const value = await promptOptional(
      "Field value (leave blank to generate a password placeholder)",
    );
    const generatedValue = value.length === 0;
    const resolvedValue = generatedValue ? await generateSecret() : value;

    fields.push({
      id: name,
      label: name,
      type: fieldType(name, generatedValue),
      value: resolvedValue,
    });
  }

  return fields;
}

async function maybeWriteManifest(itemTitle: string): Promise<void> {
  const argManifestPath = Deno.args[1]?.trim();
  const manifestPath = argManifestPath && argManifestPath.length > 0
    ? argManifestPath
    : await promptOptional("Manifest path (leave blank to skip)");

  if (manifestPath.length === 0) {
    return;
  }

  const namespace = await promptRequired(
    "Manifest namespace",
    inferNamespaceFromPath(manifestPath),
  );
  const resourceName = await promptRequired(
    "Manifest resource name",
    itemTitle,
  );

  if (await pathExists(manifestPath)) {
    const overwrite = await promptYesNo(
      `Overwrite existing manifest at ${manifestPath}?`,
      false,
    );
    if (!overwrite) {
      console.log(`Skipped writing ${manifestPath}.`);
      return;
    }
  }

  await Deno.mkdir(dirname(manifestPath), { recursive: true });
  await Deno.writeTextFile(
    manifestPath,
    renderManifest(resourceName, namespace, itemTitle),
  );

  console.log(`Wrote manifest ${manifestPath}.`);
}

async function main(): Promise<void> {
  await requireCommand("op");
  await requireCommand("openssl");
  await requireCommand("tr");
  await ensureOpSession();

  const argItemTitle = Deno.args[0]?.trim();
  const itemTitle = argItemTitle && argItemTitle.length > 0
    ? argItemTitle
    : await promptRequired("1Password item title");

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
    ...await promptFields(),
  ];

  const tempFile = await Deno.makeTempFile({
    prefix: "onepassword-item-",
    suffix: ".json",
  });

  try {
    await Deno.writeTextFile(tempFile, JSON.stringify(template));
    await $`op item create --vault cluster --template ${tempFile}`.text();
  } finally {
    await Deno.remove(tempFile).catch(() => undefined);
  }

  console.log(`Created 1Password item ${itemTitle} in vault cluster.`);
  await maybeWriteManifest(itemTitle);
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
