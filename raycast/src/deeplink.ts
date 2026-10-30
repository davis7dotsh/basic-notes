import { closeMainWindow, showHUD } from "@raycast/api";
import { execFile } from "node:child_process";

/** Fire `basicnotes://<path>` in the background (`open -g`) so the panel takes focus, not Raycast. */
export async function fire(path: string) {
  await closeMainWindow();
  const error = await new Promise<Error | null>((resolve) =>
    execFile("/usr/bin/open", ["-g", `basicnotes://${path}`], (err) => resolve(err)),
  );
  if (error) await showHUD("Basic Notes isn't installed");
}
