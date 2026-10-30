effect v4 service pattern

```ts
import { Context, Effect, Layer, Schema } from "effect";

class NoteNotFound extends Schema.TaggedError<NoteNotFound>()("NoteNotFound", { id: Schema.String }) {}

class NotesRepo extends Context.Service<NotesRepo, {
  readonly get: (id: string) => Effect.Effect<Note, NoteNotFound>;
}>()("NotesRepo") {}

const NotesRepoLive = Layer.effect(NotesRepo, Effect.gen(function* () {
  const sql = yield* Sql;
  return {
    get: (id) => sql.one`select * from notes where id = ${id}`.pipe(
      Effect.flatMap(Effect.fromNullable),
      Effect.mapError(() => new NoteNotFound({ id })),
    ),
  };
}));
```
- test layer = `Layer.succeed(NotesRepo, { get: ... })`
- one ManagedRuntime per process, not per request
