import { Action, ActionPanel, getPreferenceValues, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { fire } from "./deeplink";

// Same rule as the app's NoteRegistry.isNoteFile: flat folder, visible `.md` files.
const isNoteFile = (name: string) =>
  name.endsWith(".md") && name.length > 3 && !name.startsWith(".") && !name.startsWith("#") && !name.startsWith("~$");

/** First line with text, minus block markers (quote, heading, list, task box) and inline Markdown. */
function title(content: string) {
  for (const raw of content.split(/\r?\n|\r/)) {
    const line = raw
      .replace(/^[ \t]*(?:>[ \t]?)*[ \t]*(?:#{1,6}[ \t]+|(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?/, "")
      .trim();
    if (line.startsWith("```") || line.startsWith("~~~") || /^([-*_])( ?\1){2,}$/.test(line)) continue;
    const text = line
      .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/(\*\*|__|~~|[*_`])/g, "")
      .trim();
    if (text && !/^#{1,6}$/.test(text)) return text;
  }
  return "Untitled";
}

async function loadNotes(folder: string) {
  const names = (await readdir(folder)).filter(isNoteFile);
  const notes = await Promise.all(
    names.map(async (name) => {
      const path = join(folder, name);
      const [info, content] = await Promise.all([stat(path), readFile(path, "utf8")]);
      return { id: name.slice(0, -3), path, title: title(content), modified: info.mtime };
    }),
  );
  return notes.sort((a, b) => b.modified.getTime() - a.modified.getTime());
}

export default function Command() {
  const { notesFolder } = getPreferenceValues<Preferences>();
  const folder = (notesFolder || "~/Notes").replace(/^~(?=$|\/)/, homedir());
  const { data, isLoading, error } = usePromise(loadNotes, [folder]);

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search note titles">
      {error ? <List.EmptyView icon={Icon.Warning} title={`Can't read ${notesFolder || "~/Notes"}`} /> : null}
      {data?.map((note) => (
        <List.Item
          key={note.id}
          icon={Icon.Document}
          title={note.title}
          accessories={[{ date: note.modified }]}
          actions={
            <ActionPanel>
              <Action
                title="Open in Basic Notes"
                icon={Icon.Sidebar}
                onAction={() => fire(`open?id=${encodeURIComponent(note.id)}`)}
              />
              <Action.ShowInFinder path={note.path} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
